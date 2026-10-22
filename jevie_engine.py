"""Application state, independent research jobs, portfolio checks and order reconciliation."""
from __future__ import annotations
import copy,hashlib,json,os,threading,time,uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
from datetime import date,datetime,timedelta,timezone
from pathlib import Path
from jevie_core import *
from jevie_clients import OpenRouter,Alpaca,APIError
from jevie_research import Research
from jevie_policy import compose_policy
from jevie_fees import normalize,reconcile_view,import_csv

DEFAULT=dict(symbols=['NVDA','AMD'],timeframe='1Day',start='2022-01-01',end=(date.today()-timedelta(days=1)).isoformat(),fee_bps=1,slippage_bps=3,auto_research=False,debate_rounds=3,diverse_models=True,
 models=dict(researcher='google/gemini-4-argon',challenger='openai/gpt-6.1-sol',critic='anthropic/claude-sonnet-5.5',decider='moonshotai/kimi-k3',evolver='anthropic/claude-sonnet-5.5'))

class App:
    def __init__(self,root, demo=False,live=False):
        self.root=Path(root).resolve();self.root.mkdir(parents=True,exist_ok=True);self.demo=demo;self.live=live
        self.store=Store(self.root/'jevie.sqlite');self.lock=threading.RLock();self.stop=threading.Event()
        if demo and live:raise ValueError('Demo cannot use live execution')
        self.config={**copy.deepcopy(DEFAULT),**self.store.get('config',{})};self.running=False;self.jobs={};self.workers={s:dict(symbol=s,status='STANDBY',signal='hold',reason='Start after configuration',battery=None,price=None) for s in TICKERS}
        self.config['models']={k:self.config['models'].get(k) or v for k,v in DEFAULT['models'].items()}
        self.router=OpenRouter();self.broker=Alpaca(live);self.research=Research(self);self.pool=ThreadPoolExecutor(max_workers=5)
        self.battery_jobs={};self.account=None;self.clock=None;self.last_error='';self.last_sync=None;self.history={};self.fee_sync_at=0;self.assets={}
        self.base_equity=self.store.get('base_equity');self.peak=self.store.get('peak_equity',0)
        self.killed=self.store.get('killed',False)
        self.thread=threading.Thread(target=self.loop,daemon=True);self.thread.start()
    def chat(self,symbol,role,text,job='',meta=None):
        self.store.event('chat',symbol,dict(role=role,text=text,job=job,meta=meta or {}))
    def state(self):
        fees=self.fees_view()
        with self.lock:
            return dict(mode='DEMO' if self.demo else 'LIVE' if self.live else 'PAPER',running=self.running,config=copy.deepcopy(self.config),workers=copy.deepcopy(self.workers),jobs=copy.deepcopy(list(self.jobs.values())),account=self.account,clock=self.clock,last_error=self.last_error,last_sync=self.last_sync,
                connections=dict(openrouter=bool(self.router.key),alpaca=self.broker.ready,hermes=bool(os.getenv('HERMES_PYTHON') and os.getenv('HERMES_SOURCE'))),
                integrations=dict(hermes_last_success=self.store.get('hermes_last_success'),openbot_last_request=self.store.get('openbot_last_request')),
                portfolio=self.store.get('portfolio',{}),equity=self.store.events('equity',limit=600),trades=fees['trades'][-500:],fees={k:v for k,v in fees.items() if k!='trades'},
                reports={s:self.store.get('report:'+s) for s in self.config['symbols']},
                active={s:self.store.get('active:'+s) for s in self.config['symbols']})
    def configure(self,raw):
        allowed=set(DEFAULT)
        if not isinstance(raw,dict) or set(raw)-allowed:raise ValueError('Unknown configuration fields')
        with self.lock:
            if self.running or any(j['status']=='running' for j in self.jobs.values()):raise ValueError('Pause trading and finish research before changing configuration')
            cfg=copy.deepcopy(self.config);cfg.update(raw);cfg['symbols']=symbols(cfg['symbols'])
            if cfg['timeframe'] not in TIMEFRAMES:raise ValueError('Invalid timeframe')
            for k in ('start','end'):date.fromisoformat(cfg[k])
            if cfg['start']>=cfg['end'] or date.fromisoformat(cfg['end'])>=date.today():raise ValueError('Use a history end date before today and after the start')
            cfg['fee_bps']=number(cfg['fee_bps'],0,100,'fee bps');cfg['slippage_bps']=number(cfg['slippage_bps'],0,200,'slippage bps')
            if not isinstance(cfg['auto_research'],bool):raise ValueError('auto_research must be a boolean')
            if type(cfg['debate_rounds']) is not int or not 1<=cfg['debate_rounds']<=12:raise ValueError('Use 1–12 rounds per research budget')
            if not isinstance(cfg['diverse_models'],bool):raise ValueError('diverse_models must be boolean')
            if set(cfg['models'])!=set(DEFAULT['models']):raise ValueError('Set all five model roles')
            for m in cfg['models'].values():
                if not isinstance(m,str) or len(m)>160 or (m and '/' not in m):raise ValueError('Invalid OpenRouter model ID')
            for s in set(self.config['symbols'])-set(cfg['symbols']):
                if self.store.get('position:'+s,{}).get('qty',0) or self.store.get('pending:'+s):raise ValueError('Cannot disable a stock with exposure or an unresolved order')
            self.config=cfg;self.store.put('config',cfg)
        return cfg
    def job(self,symbol,kind='research',override=None,rolling=False,prompt=''):
        if symbol not in self.config['symbols']:raise ValueError('Enable this ticker first (2–5 workers)')
        with self.lock:
            if any(j['symbol']==symbol and j['status']=='running' for j in self.jobs.values()):raise ValueError('Research already running for this ticker')
            jid=uuid.uuid4().hex[:12];self.jobs[jid]=dict(id=jid,symbol=symbol,kind=kind,status='running',started=time.time())
        def run():
            try:
                if kind=='discuss':self.research.discuss(symbol,prompt,jid)
                elif kind=='evolve':
                    report=self.store.get('report:'+symbol)
                    if not report:raise ValueError('Run research before evolution')
                    self.research.learn(symbol,report,jid)
                    # Updated Hermes lessons become inputs to the next discovery cycle.
                    self.research.run(symbol,jid,rolling=rolling)
                else:self.research.run(symbol,jid,override,rolling=rolling)
                with self.lock:self.jobs[jid]['status']='done'
            except Exception as exc:
                message=str(exc) if isinstance(exc,(ValueError,APIError)) else f'{type(exc).__name__}: job failed; inspect local configuration'
                with self.lock:self.jobs[jid].update(status='error',error=message)
                self.chat(symbol,'error',message,jid)
            finally:
                with self.lock:self.jobs[jid]['finished']=time.time()
        self.pool.submit(run);return dict(job=jid)
    def command(self,text,selected='NVDA'):
        parts=text.strip().split()
        if not parts:raise ValueError('Enter a command or ticker')
        cmd=parts[0].lower();sym=parts[1].upper() if len(parts)>1 else selected
        if cmd.upper() in TICKERS:sym=cmd.upper();cmd='/research'
        if cmd in ('/research','/debate','/backtest'):return self.job(sym)
        if cmd=='/evolve':return self.job(sym,'evolve')
        if cmd=='/news':
            news=[] if self.demo else self.broker.news(sym)
            self.chat(sym,'news',json.dumps(news,indent=2) if news else 'No live news in offline demo.');return dict(news=news)
        if cmd=='/start':return self.start()
        if cmd=='/pause':
            with self.lock:self.running=False
            return dict(message='Paused new orders. Existing positions and resting orders remain; monitoring continues.')
        if cmd=='/rollback':
            with self.lock:
                if self.store.get('position:'+sym,{}).get('qty',0) or self.store.get('pending:'+sym):raise ValueError('Rollback waits until the worker is flat and orders reconciled')
                prev=self.store.get('previous:'+sym)
                if not prev:raise ValueError('No prior active version')
                self.store.put('active:'+sym,prev)
            return dict(message='Previous strategy restored')
        if cmd=='/status':return self.state()
        if cmd=='/fees':self.sync_fees();return self.fees_view()
        if cmd=='/assignfee':
            if len(parts)!=3:raise ValueError('Use /assignfee ACTIVITY_ID ORDER_ID')
            return self.assign_fee(parts[1],parts[2])
        if cmd=='/help':return dict(message='NVDA | /research AMD | /evolve NVDA | /news AMZN | /fees | /assignfee ACTIVITY_ID ORDER_ID | /start | /pause | /rollback NVDA | /status. Plain messages continue the model discussion for the selected stock.')
        if cmd.startswith('/'):raise ValueError('Unknown command; use /help')
        return self.job(selected,'discuss',prompt=text)
    def start(self):
        symbols(self.config['symbols'])
        if self.killed:raise ValueError('Drawdown stop is latched; operator review is required')
        if not self.demo and (not self.broker.ready or not self.router.key):raise ValueError('Alpaca and OpenRouter credentials are required')
        if self.live:
            a=self.broker.account()
            if a.get('status')!='ACTIVE' or a.get('trading_blocked') or a.get('account_blocked'):raise ValueError('Live account is not authorized by Alpaca for trading')
        with self.lock:self.running=True
        return dict(message='Workers started; trading waits for a qualifying strategy, fresh battery and open market')
    def fees_view(self):
        return reconcile_view(self.store.events('fill',limit=100000),list(self.store.get('broker_fees',{}).values()),self.store.get('fee_links',{}))
    def save_fees(self,fees):
        with self.lock:
            records=self.store.get('broker_fees',{})
            for f in fees:records[f['id']]=f
            self.store.put('broker_fees',records)
        return dict(records=len(records))
    def sync_fees(self):
        if self.demo:return dict(message='No broker fees in demo')
        after=self.store.get('fee_after',(date.today()-timedelta(days=30)).isoformat())
        result=self.save_fees([f for r in self.broker.fee_activities(after) if (f:=normalize(r))])
        self.store.put('fee_after',(date.today()-timedelta(days=7)).isoformat());self.fee_sync_at=time.time();return result
    def assign_fee(self,fid,oid):
        if fid not in self.store.get('broker_fees',{}):raise ValueError('Unknown fee activity')
        if not any(f['order_id']==oid for f in self.store.events('fill',limit=100000)):raise ValueError('Choose a Jevie-owned filled order')
        links=self.store.get('fee_links',{});links[fid]=oid;self.store.put('fee_links',links)
        self.store.event('fee_link','',dict(fee_id=fid,order_id=oid));return dict(message='Fee linked; displayed P/L recomputed')
    def reconcile(self,order):
        sym=order['symbol'];cid=order.get('client_order_id','')
        if not cid.startswith('jv2-'):return
        total=float(order.get('filled_qty') or 0);avg=float(order.get('filled_avg_price') or 0)
        old=self.store.get('filltotal:'+order['id'],dict(qty=0,notional=0))
        delta=total-old['qty']
        if delta>1e-8:
            notional=total*avg-old['notional'];price=notional/delta;side=order['side'];fee=notional*self.config['fee_bps']/10000
            p=self.store.get('position:'+sym,dict(qty=0,basis=0,entry_fees=0))
            gross=net=None
            if side=='buy':
                p['basis']=(p['basis']*p['qty']+notional)/(p['qty']+delta);p['qty']+=delta;p['entry_fees']+=fee
            else:
                used=min(delta,p['qty']);entry_cost=p['entry_fees']*used/p['qty'] if p['qty'] else 0
                gross=used*(price-p['basis']);net=gross-entry_cost-fee;p['qty']=max(0,p['qty']-delta);p['entry_fees']=max(0,p['entry_fees']-entry_cost)
            # All writes are one database transaction, including the idempotency checkpoint.
            with self.store.lock:
                db=self.store.db
                try:
                    db.execute('BEGIN IMMEDIATE')
                    for k,v in [('position:'+sym,p),('filltotal:'+order['id'],dict(qty=total,notional=total*avg))]:
                        db.execute('INSERT OR REPLACE INTO kv VALUES(?,?)',(k,json.dumps(v)))
                    payload=dict(order_id=order['id'],side=side,qty=delta,price=price,fee=fee,fee_source='estimated',gross_pnl=gross,net_pnl=net,mode='live' if self.live else 'paper',filled_at=order.get('filled_at'),version=cid)
                    db.execute('INSERT INTO events(t,kind,symbol,payload) VALUES(?,?,?,?)',(time.time(),'fill',sym,json.dumps(payload)));db.commit()
                except Exception:db.rollback();raise
        if order.get('status') in ('filled','canceled','expired','rejected','replaced'):
            pending=self.store.get('pending:'+sym)
            if pending and pending['cid']==cid:self.store.put('pending:'+sym,None)
    def sync(self):
        clock=self.broker.clock();account=self.broker.account();positions=self.broker.positions();orders=self.broker.orders()
        if account.get('status')!='ACTIVE' or account.get('trading_blocked') or account.get('account_blocked'):
            self.running=False;self.last_error='Alpaca account blocks trading'
        for o in reversed(orders):self.reconcile(o)
        for s in self.config['symbols']:
            pending=self.store.get('pending:'+s)
            if pending and pending['cid'] not in [o.get('client_order_id') for o in orders]:
                try:self.reconcile(self.broker.find_order(pending['cid']))
                except APIError:pass # ambiguous submissions remain blocked until resolved by broker/operator
        equity=float(account['equity']);cash=float(account['cash'])
        with self.lock:
            self.account=dict(equity=equity,cash=cash,buying_power=float(account['buying_power']),status=account['status']);self.clock=clock;self.last_sync=time.time()
        if self.base_equity is None:self.base_equity=equity;self.store.put('base_equity',equity)
        self.peak=max(self.peak,equity);self.store.put('peak_equity',self.peak)
        dd=1-equity/self.peak if self.peak else 0
        self.store.put('portfolio',dict(equity=equity,cash=cash,drawdown_pct=dd*100,positions=positions))
        self.store.event('equity','',dict(equity=equity,pnl=equity-self.base_equity))
        if time.time()-self.fee_sync_at>300:
            try:self.sync_fees()
            except APIError as exc:self.last_error='Fee sync: '+str(exc);self.fee_sync_at=time.time()
        if dd>=.10:
            self.killed=True;self.store.put('killed',True)
            self.running=False;self.last_error='KILL: account drawdown reached 10%; new orders disabled. Positions remain.'
            for o in orders:
                if o.get('client_order_id','').startswith('jv2-') and o.get('status') in ('new','accepted','partially_filled'):
                    try:self.broker.cancel(o['id'])
                    except APIError:pass
        return clock,account,positions,orders,dd
    def tick(self,symbol,clock,account,positions,orders,dd):
        w=self.workers[symbol];p=self.store.get('position:'+symbol,dict(qty=0,basis=0,entry_fees=0))
        broker_position=next((x for x in positions if x['symbol']==symbol),{})
        broker_qty=float(broker_position.get('qty',0))
        if abs(broker_qty-p['qty'])>1e-5:
            w.update(status='RECONCILE',signal='hold',reason='Broker position differs from Jevie ledger; resolve manual/external trades');return
        pending=self.store.get('pending:'+symbol)
        candidate=self.store.get('candidate:'+symbol)
        if candidate and not p['qty'] and not pending:
            current=self.store.get('active:'+symbol)
            self.store.put('previous:'+symbol,current);self.store.put('active:'+symbol,candidate);self.store.put('candidate:'+symbol,None)
            self.chat(symbol,'system','Activated evaluated strategy '+candidate['version']+' for '+('LIVE' if self.live else 'paper')+' trading.')
        active=self.store.get('active:'+symbol)
        if not clock['is_open']:w.update(status='MARKET_CLOSED',signal='hold',reason='Waiting for Alpaca market clock');return
        if not active:w.update(status='ORDER_PENDING' if pending else 'RESEARCH_NEEDED',signal='hold',reason='Waiting for order reconciliation' if pending else 'No strategy has passed evaluation');return
        q=self.broker.quote(symbol);bid=float(q['bp']);ask=float(q['ap']);stamp=datetime.fromisoformat(q['t'].replace('Z','+00:00')).timestamp();age=time.time()-stamp
        if bid<=0 or ask<bid or not -5<=age<=30:w.update(status='STALE_DATA',signal='late',reason='Quote is stale or invalid');return
        mid=(bid+ask)/2;w['price']=mid
        key=(symbol,active['timeframe']);cached=self.history.get(key)
        if not cached or time.time()-cached[0]>60:
            days=600 if active['timeframe']=='1Day' else 35
            bars=self.broker.bars(symbol,(date.today()-timedelta(days=days)).isoformat(),date.today().isoformat(),active['timeframe'])
            self.history[key]=(time.time(),bars)
        else:bars=cached[1]
        s=Strategy.parse(active['strategy']);target=signal(bars,s,p['qty']>0,p['basis'],dict(qty=p['qty'],basis=p['basis']))
        snapshot=dict(symbol=symbol,mid=mid,spread_bps=(ask-bid)/mid*10000,bid_size=q.get('bs'),ask_size=q.get('as'),inventory=p['qty'],basis=p['basis'],drawdown=dd,
                      closes=[b['c'] for b in bars[-50:]],data_age_s=age,depth_available=False,trade_classification_available=False,
                      execution_history=self.store.events('fill',symbol,20))
        future=self.battery_jobs.get(symbol)
        if future and future.done():
            try:w['battery']=future.result()
            except Exception as exc:w['battery']=None;w['reason']=str(exc)
            self.battery_jobs.pop(symbol,None)
        battery=w.get('battery');stale=not battery or time.time()-battery['as_of']>60
        if symbol not in self.battery_jobs and (not battery or time.time()-battery['as_of']>20):self.battery_jobs[symbol]=self.pool.submit(self.router.battery,snapshot)
        stop_loss=p['qty']>0 and mid<=p['basis']*(1-s.stop_pct)
        policy=compose_policy(battery['answers'],p['qty']) if not stale else dict(kind='LATE',allow_entry=False,size_scale=0,reduce_inventory=False,cancel_entries=True,reason='Battery stale')
        w['policy']=policy
        if self.running and policy['cancel_entries']:
            for o in orders:
                if o['symbol']==symbol and o.get('client_order_id','').startswith('jv2-') and o['side']=='buy' and o['status'] in ('new','accepted','partially_filled'):
                    self.broker.cancel(o['id'])
        if pending:w.update(status='ORDER_PENDING',signal='hold',reason='Waiting for broker reconciliation');return
        if stop_loss:target='sell'
        elif stale:w.update(status='HOLD_LATE',signal='late',reason='Waiting for a fresh Jev battery');return
        elif policy['reduce_inventory']:target='sell'
        elif not policy['allow_entry'] and target=='buy':target='hold'
        if not self.running or self.killed or dd>=.10:
            w.update(status='PAUSED',signal='hold',reason='New orders paused');return
        w.update(status=policy['kind'],signal=target,reason=policy['reason'],version=active['version'])
        if target=='hold' or (target=='buy' and p['qty']>0) or (target=='sell' and p['qty']==0):return
        if any(o['symbol']==symbol and o['status'] in ('new','accepted','pending_new','partially_filled','pending_cancel') for o in orders):return
        equity=float(account['equity']);cash=float(account['cash']);gross=sum(abs(float(x['market_value'])) for x in positions)
        # Max 20% per stock, 80% gross across all positions; reserve pending buys.
        reserved=sum(float(o.get('notional') or float(o.get('qty') or 0)*mid) for o in orders if o['side']=='buy' and o['status'] in ('new','accepted','pending_new','partially_filled'))
        if target=='buy':
            if snapshot['spread_bps']>30:w.update(status='WIDE_SPREAD',signal='hold');return
            notional=min(equity*s.allocation*policy['size_scale'],cash-reserved-10,equity*.8-gross-reserved)
            if notional<10:return
            qty=round(notional/ask,6)
            if symbol not in self.assets:self.assets[symbol]=self.broker.asset(symbol)
            asset=self.assets[symbol]
            if not asset.get('tradable') or asset.get('status')!='active':w.update(status='ASSET_BLOCKED',signal='hold');return
            if not asset.get('fractionable'):qty=int(qty)
        else:qty=round(p['qty'],6)
        if qty<=0:return
        identity=f'{symbol}:{active["version"]}:{bars[-1]["t"]}:{target}'
        cid='jv2-'+symbol+'-'+hashlib.sha256(identity.encode()).hexdigest()[:20]
        # Serialize the final submission with Pause/configuration changes. A successful
        # pause response means no new order can begin after that response.
        with self.lock:
            if not self.running or self.killed or symbol not in self.config['symbols']:return
            if not self.store.claim('intent:'+cid,dict(at=time.time())):return
            self.store.put('pending:'+symbol,dict(cid=cid,at=time.time(),side=target))
            # Never blindly retry an uncertain POST. Reconciliation by client ID owns recovery.
            order=self.broker.order(dict(symbol=symbol,qty=str(qty),side=target,type='market',time_in_force='day',client_order_id=cid))
        self.reconcile(order)
        self.store.event('order',symbol,dict(cid=cid,side=target,status=order['status'],id=order['id']))
        # This shared cycle stops after a submit; refresh account before the next symbol can spend.
        return True
    def loop(self):
        while not self.stop.wait(3):
            try:
                if self.demo:
                    for s in self.config['symbols']:
                        self.workers[s].update(status='DEMO',reason='Synthetic history; no broker orders',price=demo_bars(s)[-1]['c'])
                    continue
                if not self.broker.ready:continue
                clock,account,positions,orders,dd=self.sync()
                for s in list(self.config['symbols']):
                    try:
                        submitted=self.tick(s,clock,account,positions,orders,dd)
                        if submitted:break
                    except Exception as exc:
                        self.workers[s].update(status='ERROR',signal='hold',reason=str(exc) if isinstance(exc,(ValueError,APIError)) else type(exc).__name__)
                if self.config['auto_research'] and self.running:
                    for s in self.config['symbols']:
                        last=self.store.get('auto:'+s,0)
                        if time.time()-last>86400:
                            self.store.put('auto:'+s,time.time())
                            try:self.job(s,'evolve' if self.store.get('report:'+s) and os.getenv('HERMES_PYTHON') else 'research',rolling=True)
                            except ValueError:pass
            except Exception as exc:self.last_error=str(exc) if isinstance(exc,(ValueError,APIError)) else type(exc).__name__
            self.stop.wait(12)
    def close(self):
        self.stop.set();self.running=False;self.pool.shutdown(wait=False,cancel_futures=True)
