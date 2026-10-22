"""Run: python start_jevie.py --demo (no dependencies or credentials needed)."""
from __future__ import annotations
import argparse,json,mimetypes,os,secrets,threading,time,urllib.parse,webbrowser
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from jevie_engine import App
from jevie_clients import APIError
from jevie_fees import import_csv

ROOT=Path(__file__).resolve().parent

def load_env(path):
    if not path.exists():return
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        line=line.strip()
        if line and not line.startswith('#') and '=' in line:
            key,value=line.split('=',1)
            if key.strip().isidentifier():os.environ.setdefault(key.strip(),value.strip().strip('\"\''))

def make_handler(app):
    csrf=secrets.token_urlsafe(32)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,fmt,*args):pass
        def valid_host(self):
            host=self.headers.get('Host','').split(':')[0]
            return host in ('127.0.0.1','localhost','terminal.local')
        def send(self,data,status=200,content='application/json'):
            raw=json.dumps(data,allow_nan=False).encode() if content=='application/json' else data
            self.send_response(status);self.send_header('Content-Type',content);self.send_header('Cache-Control','no-store')
            self.send_header('X-Content-Type-Options','nosniff');self.send_header('X-Frame-Options','DENY')
            self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
            self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
        def do_GET(self):
            if not self.valid_host():return self.send({'error':'Invalid host'},403)
            u=urllib.parse.urlsplit(self.path)
            try:
                if u.path=='/api/bootstrap':return self.send(dict(csrf=csrf))
                if u.path=='/api/state':return self.send(app.state())
                if u.path=='/api/chat':return self.send(app.store.events('chat',urllib.parse.parse_qs(u.query).get('symbol',['NVDA'])[0],150))
                if u.path=='/api/models':return self.send(app.router.models())
                if u.path=='/api/health':return self.send(dict(ok=True,mode='demo' if app.demo else 'live' if app.live else 'paper'))
                if u.path in ('/','/index.html','/style.css','/app.js'):
                    name='index.html' if u.path=='/' else u.path[1:]
                    return self.send((ROOT/name).read_bytes(),content=mimetypes.guess_type(name)[0] or 'text/plain')
                return self.send({'error':'Not found'},404)
            except (ValueError,APIError) as e:return self.send({'error':str(e)},400)
            except Exception:return self.send({'error':'Server read failed'},500)
        def do_POST(self):
            if not self.valid_host():return self.send({'error':'Invalid host'},403)
            token=os.getenv('JEVIE_AGENT_TOKEN','')
            bearer=bool(token) and (secrets.compare_digest(self.headers.get('Authorization',''),'Bearer '+token) or secrets.compare_digest(self.headers.get('x-openbot-agent-token',''),token))
            origin=self.headers.get('Origin')
            if origin and urllib.parse.urlsplit(origin).netloc!=self.headers.get('Host'):return self.send({'error':'Cross-origin write refused'},403)
            if not bearer and not secrets.compare_digest(self.headers.get('X-Jevie-CSRF',''),csrf):return self.send({'error':'Session token required'},403)
            try:
                n=int(self.headers.get('Content-Length','0'))
                if not 0<n<=200000:raise ValueError('Invalid payload size')
                body=json.loads(self.rfile.read(n))
                if self.path=='/api/config':return self.send(app.configure(body))
                if self.path=='/api/fees/import':return self.send(app.save_fees(import_csv(str(body.get('csv','')))))
                if self.path=='/api/command':return self.send(app.command(str(body.get('text','')),body.get('symbol','NVDA')))
                if self.path=='/api/ag-ui':
                    if not bearer:return self.send({'error':'Set the OpenBot server-side Bearer token'},403)
                    return self.agent_stream(body)
                return self.send({'error':'Not found'},404)
            except (ValueError,KeyError,TypeError,APIError) as e:return self.send({'error':str(e)},400)
            except Exception:return self.send({'error':'Request failed'},500)
        def agent_stream(self,body):
            app.store.put('openbot_last_request',time.time())
            thread=body.get('threadId') or secrets.token_hex(8);run=body.get('runId') or secrets.token_hex(8)
            messages=body.get('messages',[]);text=next((m.get('content','') for m in reversed(messages) if m.get('role')=='user'),'')
            if not isinstance(text,str):raise ValueError('AG-UI currently accepts text messages')
            # OpenBot receives visible research events, never hidden reasoning or credentials.
            selected=body.get('state',{}).get('symbol',app.config['symbols'][0])
            result=app.command(text,selected)
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Cache-Control','no-cache');self.end_headers()
            def event(v):self.wfile.write(('data: '+json.dumps(v)+'\n\n').encode());self.wfile.flush()
            event(dict(type='RUN_STARTED',threadId=thread,runId=run))
            seen=set();jid=result.get('job');deadline=time.time()+600
            try:
                while jid and time.time()<deadline:
                    for row in app.store.events('chat',limit=300):
                        if row.get('job')==jid and row['id'] not in seen:
                            seen.add(row['id']);mid=str(row['id'])
                            event(dict(type='TEXT_MESSAGE_START',messageId=mid,role='assistant'))
                            event(dict(type='TEXT_MESSAGE_CONTENT',messageId=mid,delta=row['role']+': '+row['text']))
                            event(dict(type='TEXT_MESSAGE_END',messageId=mid))
                    if app.jobs[jid]['status']!='running':break
                    self.wfile.write(b': heartbeat\n\n');self.wfile.flush();time.sleep(1)
                if not jid:
                    mid=secrets.token_hex(6);event(dict(type='TEXT_MESSAGE_START',messageId=mid,role='assistant'));event(dict(type='TEXT_MESSAGE_CONTENT',messageId=mid,delta=json.dumps(result)));event(dict(type='TEXT_MESSAGE_END',messageId=mid))
                if jid and app.jobs[jid]['status'] in ('running','error'):event(dict(type='RUN_ERROR',message=app.jobs[jid].get('error','Research is still running; inspect the dashboard job status')))
                else:event(dict(type='RUN_FINISHED',threadId=thread,runId=run))
            except (BrokenPipeError,ConnectionResetError):pass
    return Handler

def main():
    p=argparse.ArgumentParser(description='Jevie research and paper trading workspace')
    p.add_argument('--demo',action='store_true');p.add_argument('--port',type=int,default=8765);p.add_argument('--host',default='127.0.0.1',choices=['127.0.0.1','0.0.0.0'])
    p.add_argument('--strictPort',action='store_true');p.add_argument('--data-dir');p.add_argument('--no-browser',action='store_true')
    p.add_argument('--live',action='store_true');p.add_argument('--confirm-live');args=p.parse_args()
    if args.host=='0.0.0.0' and os.getenv('JEVIE_PREVIEW')!='1':p.error('Public bind is only allowed for the isolated development preview')
    load_env(ROOT/'.env')
    if args.live and (args.demo or args.confirm_live!='LIVE-ORDERS' or os.getenv('JEVIE_ENABLE_LIVE')!='I_UNDERSTAND_LIVE_ORDERS'):
        p.error('Live needs --live --confirm-live LIVE-ORDERS and JEVIE_ENABLE_LIVE=I_UNDERSTAND_LIVE_ORDERS; never combine with --demo')
    # Discover the pinned local Hermes install; no credential is invented or exposed.
    h=ROOT/'.integrations'/'hermes';hp=h/'.venv'/('Scripts/python.exe' if os.name=='nt' else 'bin/python')
    if (h/'run_agent.py').exists() and hp.exists():
        if not os.getenv('HERMES_SOURCE'):os.environ['HERMES_SOURCE']=str(h)
        if not os.getenv('HERMES_PYTHON'):os.environ['HERMES_PYTHON']=str(hp)
    data=args.data_dir or str(ROOT/'runtime'/('demo' if args.demo else 'live' if args.live else 'paper'))
    app=App(data,demo=args.demo,live=args.live);server=ThreadingHTTPServer((args.host,args.port),make_handler(app))
    print(f'Jevie {"DEMO — synthetic, no orders" if args.demo else "LIVE — REAL MONEY" if args.live else "PAPER — awaiting credentials and Start"}: http://127.0.0.1:{args.port}',flush=True)
    if not args.no_browser:threading.Timer(1,lambda:webbrowser.open(f'http://127.0.0.1:{args.port}')).start()
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:app.close();server.server_close()
if __name__=='__main__':main()
