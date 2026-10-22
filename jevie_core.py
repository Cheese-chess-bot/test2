"""Validated strategies, chronological simulation, judgment battery and durable records."""
from __future__ import annotations
import hashlib, json, math, random, sqlite3, threading, time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

TICKERS = ('NVDA', 'AMD', 'TSLA', 'AAPL', 'AMZN')
TIMEFRAMES = ('1Min', '5Min', '15Min', '1Hour', '1Day')

def number(value, lo, hi, label='value'):
    if isinstance(value, bool): raise ValueError(f'{label} must be numeric')
    v = float(value)
    if not math.isfinite(v) or not lo <= v <= hi: raise ValueError(f'{label} must be between {lo} and {hi}')
    return v

def symbols(values):
    if not isinstance(values, list) or not 2 <= len(values) <= 5: raise ValueError('Enable 2–5 stock workers')
    v = [str(x).upper().strip() for x in values]
    if len(set(v)) != len(v) or any(x not in TICKERS for x in v): raise ValueError('Use unique NVDA, AMD, TSLA, AAPL, AMZN symbols')
    return v

@dataclass(frozen=True)
class Strategy:
    family: str = 'trend'
    fast: int = 10
    slow: int = 40
    entry: float = 1.5
    exit: float = 0.0
    stop_pct: float = 0.03
    allocation: float = 0.15
    python_code: str = ''
    parameters: dict = field(default_factory=dict)
    warmup: int = 40
    @classmethod
    def parse(cls, raw):
        if not isinstance(raw, dict) or set(raw) - set(cls.__dataclass_fields__): raise ValueError('Unknown strategy fields')
        v = asdict(cls()); v.update(raw)
        if v['family'] not in ('trend', 'reversion', 'breakout','python'): raise ValueError('Unsupported strategy family')
        if v['family']=='python':
            from jevie_sandbox import validate_source
            validate_source(v['python_code'])
        elif v['python_code']:raise ValueError('Python source requires the python family')
        if not isinstance(v['parameters'],dict) or len(json.dumps(v['parameters'],allow_nan=False))>4000:raise ValueError('Invalid strategy parameters')
        warmup=number(v['warmup'],2,2000,'warmup')
        if int(warmup)!=warmup:raise ValueError('warmup must be an integer')
        v['warmup']=int(warmup)
        for k in ('fast', 'slow'):
            n = number(v[k], 2, 120, k)
            if int(n) != n: raise ValueError('Lookbacks must be integers')
            v[k] = int(n)
        if v['fast'] >= v['slow']: raise ValueError('fast must be less than slow')
        for k, low, high in [('entry', 0.1, 4), ('exit', -1, 1), ('stop_pct', .005, .1), ('allocation', .01, .2)]:
            v[k] = number(v[k], low, high, k)
        return cls(**v)
    @property
    def version(self): return hashlib.sha256(json.dumps(asdict(self), sort_keys=True).encode()).hexdigest()[:12]

def signal(bars, strategy, held=False, basis=0, position=None):
    """Only receives completed bars; engine executes on a subsequent observation."""
    s = Strategy.parse(asdict(strategy))
    if len(bars) < (s.warmup if s.family=='python' else s.slow): return 'hold'
    prices = [b['c'] for b in bars[-s.slow:]]; price = prices[-1]
    if held and basis and price <= basis * (1 - s.stop_pct): return 'sell'
    if s.family=='python':
        if len(bars)<s.warmup:return 'hold'
        from jevie_sandbox import StrategyProcess
        with StrategyProcess(s.python_code,s.parameters) as worker:return worker.decide(bars,position or dict(qty=1 if held else 0,basis=basis))
    fast = sum(prices[-s.fast:]) / s.fast; slow = sum(prices) / len(prices)
    if s.family == 'trend': return 'buy' if fast > slow else 'sell' if held else 'hold'
    if s.family == 'breakout':
        return 'buy' if price > max(prices[:-1]) else 'sell' if held and price < fast else 'hold'
    sd = (sum((p-slow)**2 for p in prices)/len(prices))**.5
    z = (price-slow)/sd if sd else 0
    return 'buy' if z < -s.entry else 'sell' if held and z > s.exit else 'hold'

def validate_bars(bars):
    if len(bars) < 60: raise ValueError('Need at least 60 complete bars')
    last = ''
    for b in bars:
        if b['t'] <= last: raise ValueError('Bars must be unique and chronological')
        last = b['t']
        for k in ('o','h','l','c'): number(b[k], .000001, 1e8, k)
        number(b['v'], 0, 1e15, 'volume')
        if b['h'] < max(b['o'],b['c'],b['l']) or b['l'] > min(b['o'],b['c']): raise ValueError('Invalid OHLC ordering')
    return bars

def demo_bars(symbol, count=700):
    """Reproducible synthetic fixture. Never used to authorize broker execution."""
    rng = random.Random(symbol); p = {'NVDA':130,'AMD':145,'TSLA':240,'AAPL':210,'AMZN':190}[symbol]
    out=[]; t=datetime(2022,1,3,tzinfo=timezone.utc)
    while len(out)<count:
        if t.weekday()<5:
            i=len(out); o=p*(1+rng.gauss(0,.003)); p=o*math.exp(.0005+.005*math.sin(i/60)+rng.gauss(0,.013))
            out.append(dict(t=t.isoformat(),o=o,h=max(o,p)*1.006,l=min(o,p)*.994,c=p,v=rng.randint(100000,5000000)))
        t+=timedelta(days=1)
    return out

def simulate(bars, strategy, start=0, end=None, fee_bps=1, slippage_bps=3, cash=10000):
    from contextlib import nullcontext
    from jevie_sandbox import StrategyProcess
    s=Strategy.parse(asdict(strategy))
    with StrategyProcess(s.python_code,s.parameters) if s.family=='python' else nullcontext(None) as worker:
        return _simulate(bars,s,start,end,fee_bps,slippage_bps,cash,worker)

def _simulate(bars, strategy, start=0, end=None, fee_bps=1, slippage_bps=3, cash=10000, worker=None):
    """Signal at preceding close, fill at next open; no same-bar lookahead."""
    validate_bars(bars); s=Strategy.parse(asdict(strategy)); end=end or len(bars)
    fee_bps=number(fee_bps,0,100,'fee bps'); slippage_bps=number(slippage_bps,0,200,'slippage bps')
    initial=number(cash,1,1e9,'cash'); qty=basis=entry_fee=0.; high=initial; dd=0.; ledger=[]; curve=[]; fees=0.
    warmup=s.warmup if s.family=='python' else s.slow
    for i in range(max(start,warmup),end):
        b=bars[i]
        action=worker.decide(bars[:i],dict(qty=qty,basis=basis,cash=cash)) if worker else signal(bars[:i],s,qty>0,basis)
        if qty and bars[i-1]['c']<=basis*(1-s.stop_pct):action='sell'
        if action=='buy' and qty==0:
            price=b['o']*(1+slippage_bps/10000); notional=min(cash/(1+fee_bps/10000),initial*s.allocation)
            qty=notional/price; basis=price; entry_fee=notional*fee_bps/10000; cash-=notional+entry_fee; fees+=entry_fee
            ledger.append(dict(t=b['t'],side='buy',qty=qty,price=price,fee=entry_fee,gross_pnl=None,net_pnl=None))
        elif action=='sell' and qty>0:
            price=b['o']*(1-slippage_bps/10000); fee=qty*price*fee_bps/10000; gross=qty*(price-basis)
            cash+=qty*price-fee; fees+=fee
            ledger.append(dict(t=b['t'],side='sell',qty=qty,price=price,fee=fee,gross_pnl=gross,net_pnl=gross-entry_fee-fee));qty=0
        value=cash+qty*b['c']; high=max(high,value); dd=max(dd,1-value/high)
        curve.append(dict(t=b['t'],equity=round(value,4),pnl=round(value-initial,4)))
    if not curve: raise ValueError('Not enough bars for this lookback')
    # Terminal mark includes estimated exit costs so an open winner is not free to close.
    closing_cost=qty*bars[end-1]['c']*(fee_bps+slippage_bps)/10000
    value=curve[-1]['equity']-closing_cost
    returns=[curve[i]['equity']/curve[i-1]['equity']-1 for i in range(1,len(curve))]
    mean=sum(returns)/max(1,len(returns)); sd=(sum((r-mean)**2 for r in returns)/max(1,len(returns)))**.5
    closes=[r for r in ledger if r['side']=='sell']
    return dict(net_pnl=round(value-initial,4),return_pct=(value/initial-1)*100,max_drawdown_pct=dd*100,
                fees=round(fees,4),estimated_exit_cost=round(closing_cost,4),closed_trades=len(closes),
                win_rate=sum(r['net_pnl']>0 for r in closes)/max(1,len(closes)),
                bar_sharpe=mean/sd if sd else 0,curve=curve,ledger=ledger,
                benchmark_pct=(bars[end-1]['c']/bars[max(start,warmup)]['o']-1)*100,
                assumptions='Long/flat; next-open fills; estimated fees and slippage; no intrabar stop guarantee')

def gate(validation, test):
    reasons=[]
    for name,r in [('validation',validation),('holdout',test)]:
        if r['closed_trades']<5: reasons.append(f'{name}: fewer than 5 closed trades')
        if r['net_pnl']<=0: reasons.append(f'{name}: net return is not positive')
        if r['max_drawdown_pct']>10: reasons.append(f'{name}: drawdown exceeds 10%')
    return reasons

QUESTIONS={
 'regime':dict(type='choice',instructions='What market regime does this state describe?',criteria={x:None for x in ['trending','mean_reverting','high_vol','crisis']}),
 'direction':dict(type='choice',instructions='What is the near-term price bias?',criteria={x:None for x in ['up','down','neutral']}),
 'toxic_flow':dict(type='noul',instructions='Is the aggressive flow likely informed rather than noise? Missing depth and trade classification limit evidence.'),
 'liquidity_stressed':dict(type='noul',instructions='Is liquidity stressed relative to recent observations?'),
 'quote_environment':dict(type='score',instructions='How favourable is this state for providing liquidity?',criteria=['Do not quote','Marginal','Standard','Excellent']),
 'inventory_pressure':dict(type='score',instructions='Given current inventory, how urgent is it to cut the position?',criteria=['None','Mild','Skew hard','Reduce now']),
 'execution_health':dict(type='score',instructions='Given observed fills, rejects, slippage and latency, how healthy is execution?',criteria=['Broken','Degraded','Normal','Optimal'])}

def battery_validate(answers):
    if not isinstance(answers,dict): raise ValueError('Invalid battery response')
    for key,q in QUESTIONS.items():
        a=answers.get(key,{})
        if a.get('type')!=q['type']: raise ValueError(f'Invalid battery type: {key}')
        if q['type']=='noul': number(a.get('noul'),0,1,key)
        elif q['type']=='score':
            number(a.get('score'),0,3,key); number(a.get('confidence'),0,1,'confidence')
        else:
            if a.get('choice') not in q['criteria']: raise ValueError(f'Invalid choice: {key}')
            number(a.get('confidence'),0,1,'confidence')
    return answers

class Store:
    def __init__(self,path):
        Path(path).parent.mkdir(parents=True,exist_ok=True)
        self.lock=threading.RLock(); self.db=sqlite3.connect(path,check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY,v TEXT); CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT,t REAL,kind TEXT,symbol TEXT,payload TEXT);')
    def get(self,k,default=None):
        with self.lock:
            r=self.db.execute('SELECT v FROM kv WHERE k=?',(k,)).fetchone()
            return json.loads(r[0]) if r else default
    def put(self,k,v):
        with self.lock,self.db: self.db.execute('INSERT OR REPLACE INTO kv VALUES(?,?)',(k,json.dumps(v,allow_nan=False)))
    def claim(self,k,v):
        with self.lock,self.db:
            return self.db.execute('INSERT OR IGNORE INTO kv VALUES(?,?)',(k,json.dumps(v))).rowcount==1
    def event(self,kind,symbol,payload):
        with self.lock,self.db:
            self.db.execute('INSERT INTO events(t,kind,symbol,payload) VALUES(?,?,?,?)',(time.time(),kind,symbol,json.dumps(payload,allow_nan=False)))
    def events(self,kind=None,symbol=None,limit=250):
        clauses=[];args=[]
        if kind: clauses.append('kind=?');args.append(kind)
        if symbol: clauses.append('symbol=?');args.append(symbol)
        query='SELECT id,t,kind,symbol,payload FROM events'+(' WHERE '+' AND '.join(clauses) if clauses else '')+' ORDER BY id DESC LIMIT ?';args.append(limit)
        with self.lock: rows=self.db.execute(query,args).fetchall()
        return [dict(id=i,t=t,kind=k,symbol=s,**json.loads(p)) for i,t,k,s,p in reversed(rows)]
