"""HTTP adapters: OpenRouter is the only model gateway; fixed broker hosts."""
import json, os, threading, time, urllib.request, urllib.parse, urllib.error
from datetime import datetime, timedelta, timezone
from jevie_core import QUESTIONS,battery_validate,validate_bars

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): return None

class APIError(RuntimeError): pass

def request(url,headers=None,body=None,method=None,timeout=30):
    req=urllib.request.Request(url,data=json.dumps(body).encode() if body is not None else None,
        headers={'Content-Type':'application/json',**(headers or {})},method=method)
    try:
        with urllib.request.build_opener(NoRedirect).open(req,timeout=timeout) as resp: return json.load(resp)
    except urllib.error.HTTPError as e: raise APIError(f'{urllib.parse.urlsplit(url).hostname}: HTTP {e.code}') from None
    except (OSError,ValueError) as e: raise APIError(f'{urllib.parse.urlsplit(url).hostname}: connection or JSON error') from None

class OpenRouter:
    def __init__(self,key=None):
        self.key=key if key is not None else os.getenv('OPENROUTER_API_KEY','');self.lock=threading.Lock();self.cooldown=0
    def call(self,path,body):
        if not self.key: raise APIError('Set OPENROUTER_API_KEY in your local environment')
        with self.lock:
            if time.time()<self.cooldown: raise APIError('OpenRouter cooldown after rate limit')
        try:
            return request('https://openrouter.ai/'+path,{'Authorization':'Bearer '+self.key},body,timeout=45)
        except APIError as e:
            if '429' in str(e):
                with self.lock:self.cooldown=time.time()+60
            raise
    def chat(self,model,messages,max_tokens=5000):
        if not model or '/' not in model: raise ValueError('Choose a valid OpenRouter model ID')
        data=self.call('api/v1/chat/completions',dict(model=model,messages=messages,temperature=.2,max_tokens=max_tokens))
        try: return data['choices'][0]['message']['content'],dict(model=data.get('model',model),usage=data.get('usage',{}))
        except (KeyError,IndexError,TypeError): raise APIError('OpenRouter returned no assistant content')
    def battery(self,snapshot):
        t=time.time();data=self.call('api/alpha/decisions',dict(model=os.getenv('OPENROUTER_JEV_MODEL','typesafe/jev-1.14'),state=json.dumps(snapshot),questions=QUESTIONS))
        return dict(answers=battery_validate(data.get('answers')),model=data.get('model','typesafe/jev-1.14'),latency_ms=round((time.time()-t)*1000),as_of=time.time(),usage=data.get('usage',{}))
    @staticmethod
    def models():
        return [{'id':m['id'],'name':m.get('name',m['id'])} for m in request('https://openrouter.ai/api/v1/models')['data'] if m['id'].split('/')[0] in ('openai','anthropic','google','moonshotai')]

class Alpaca:
    def __init__(self,live=False):
        if live and os.getenv('JEVIE_ENABLE_LIVE')!='I_UNDERSTAND_LIVE_ORDERS': raise ValueError('Live trading requires explicit local opt-in')
        self.live=live;self.base='https://api.alpaca.markets' if live else 'https://paper-api.alpaca.markets'
        prefix='ALPACA_LIVE_' if live else 'ALPACA_'
        self.key=os.getenv(prefix+'API_KEY','');self.secret=os.getenv(prefix+'SECRET_KEY','')
    @property
    def ready(self): return bool(self.key and self.secret)
    def get(self,path,body=None,method=None,data=False):
        if not self.ready: raise APIError('Set Alpaca '+('live' if self.live else 'paper')+' keys locally')
        base='https://data.alpaca.markets' if data else self.base
        return request(base+path,{'APCA-API-KEY-ID':self.key,'APCA-API-SECRET-KEY':self.secret},body,method)
    def bars(self,symbol,start,end,timeframe='1Day'):
        out=[];token=None;now=datetime.now(timezone.utc);duration={'1Min':60,'5Min':300,'15Min':900,'1Hour':3600,'1Day':86400}[timeframe]
        for _ in range(30):
            params=dict(start=start+'T00:00:00Z',end=end+'T23:59:59Z',timeframe=timeframe,limit=10000,adjustment='all',feed=os.getenv('ALPACA_DATA_FEED','iex'),sort='asc')
            if token:params['page_token']=token
            d=self.get('/v2/stocks/'+symbol+'/bars?'+urllib.parse.urlencode(params),data=True)
            for b in d.get('bars') or []:
                if datetime.fromisoformat(b['t'].replace('Z','+00:00'))+timedelta(seconds=duration)<=now: out.append(b)
            token=d.get('next_page_token')
            if not token: break
        if token: raise APIError('History exceeds 300,000 bars; narrow the date range')
        return validate_bars(out)
    def quote(self,symbol): return self.get('/v2/stocks/'+symbol+'/quotes/latest?feed='+os.getenv('ALPACA_DATA_FEED','iex'),data=True)['quote']
    def clock(self): return self.get('/v2/clock')
    def account(self): return self.get('/v2/account')
    def asset(self,symbol):return self.get('/v2/assets/'+urllib.parse.quote(symbol,safe=''))
    def fee_activities(self,after):
        rows=[];token=None
        for _ in range(100):
            args=dict(activity_types='FEE,CFEE',after=after,direction='asc',page_size=100)
            if token:args['page_token']=token
            page=self.get('/v2/account/activities?'+urllib.parse.urlencode(args))
            rows.extend(page)
            if len(page)<100:return rows
            token=page[-1]['id']
        raise APIError('Fee activity range too large; narrow the import date')
    def positions(self): return self.get('/v2/positions')
    def orders(self,status='all'): return self.get('/v2/orders?'+urllib.parse.urlencode(dict(status=status,limit=500,direction='desc')))
    def order(self,body): return self.get('/v2/orders',body,'POST')
    def find_order(self,cid):
        return self.get('/v2/orders:by_client_order_id?'+urllib.parse.urlencode({'client_order_id':cid}))
    def cancel(self,oid):
        # DELETE returns 204, so use a dedicated no-content reader.
        req=urllib.request.Request(self.base+'/v2/orders/'+urllib.parse.quote(oid,safe=''),headers={'APCA-API-KEY-ID':self.key,'APCA-API-SECRET-KEY':self.secret},method='DELETE')
        try:
            with urllib.request.build_opener(NoRedirect).open(req,timeout=20): pass
        except urllib.error.HTTPError as e: raise APIError(f'Alpaca cancel HTTP {e.code}') from None
    def news(self,symbol):
        d=self.get('/v1beta1/news?'+urllib.parse.urlencode(dict(symbols=symbol,limit=12,sort='desc')),data=True)
        return [dict(headline=n['headline'],url=n['url'],created_at=n['created_at'],summary=n.get('summary','')[:1000]) for n in d.get('news',[])]
