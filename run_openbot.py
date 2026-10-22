"""Run the pinned OpenBot interface with Jevie's remote coworker and OpenRouter."""
import argparse,base64,json,os,secrets,subprocess,time
from pathlib import Path
from setup_integrations import ROOT,bun_path,write_tenant
from start_jevie import load_env
from jevie_models import OPENBOT_MODEL

def configuration():
    load_env(ROOT/'.env')
    required=('OPENROUTER_API_KEY','INTELLIGENCE_API_KEY','DATABASE_URL')
    missing=[name for name in required if not os.getenv(name)]
    path=ROOT/'.integrations'/'openbot';bun=bun_path()
    if not bun:missing.append('Bun (run setup_integrations.py --install-openbot)')
    if not (path/'node_modules').exists():missing.append('OpenBot dependencies')
    return path,bun,missing

def environment(model):
    # Do not forward broker credentials or direct-provider keys to OpenBot.
    env={k:v for k,v in os.environ.items() if k in ('PATH','HOME','USERPROFILE','SYSTEMROOT','TMPDIR','TEMP','TMP','LANG')}
    runtime=ROOT/'runtime';runtime.mkdir(exist_ok=True)
    private=runtime/'openbot-secrets.json'
    if not private.exists():
        fd=os.open(private,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as f:json.dump(dict(encryption=base64.b64encode(secrets.token_bytes(32)).decode(),worker=secrets.token_urlsafe(32)),f)
    saved=json.loads(private.read_text())
    token=os.getenv('JEVIE_AGENT_TOKEN')
    if not token:
        token=secrets.token_urlsafe(32)
        # Only fills a missing/empty setting; preserves existing settings and keys.
        target=ROOT/'.env';lines=target.read_text().splitlines() if target.exists() else []
        lines=[line for line in lines if not line.strip().startswith('JEVIE_AGENT_TOKEN=')]
        target.write_text('\n'.join(lines)+'\nJEVIE_AGENT_TOKEN='+token+'\n');target.chmod(0o600)
        print('Generated local endpoint token. Restart Jevie to load it.')
    tenant=runtime/'openbot-tenant';write_tenant(tenant,model)
    env.update(DATABASE_URL=os.environ['DATABASE_URL'],KEY_ENCRYPTION_KEY=saved['encryption'],WORKER_SHARED_SECRET=saved['worker'],
        OPENBOT_SINGLE_USER='true',NODE_ENV='development',PORT='3001',SERVER_PORT='3001',APP_PORT='3010',
        TENANT_PACKAGE_DIR=str(tenant),INTELLIGENCE_API_KEY=os.environ['INTELLIGENCE_API_KEY'],
        INTELLIGENCE_API_URL='https://api.intelligence.copilotkit.ai',INTELLIGENCE_GATEWAY_WS_URL='wss://realtime.intelligence.copilotkit.ai',
        OPENAI_API_KEY=os.environ['OPENROUTER_API_KEY'],OPENAI_BASE_URL='https://openrouter.ai/api/v1',BOT_MODEL=model,AGENT_BOT_MODEL=model,
        MANAGED_AGENT_AG_UI_URL='http://127.0.0.1:8765/api/ag-ui',MANAGED_AGENT_TOKEN=token,AGENT_ENDPOINT_ALLOWED_HOSTS='127.0.0.1:8765',
        AGENT_STALL_TIMEOUT_MS='600000',OPENBOT_LEARNING_AUTO_ASSIGN='false',OPENBOT_MEMORY_SOURCE_DEFAULTS='false',OPENBOT_PROACTIVE_DEFAULTS='false')
    return env

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');parser.add_argument('--model',default=OPENBOT_MODEL);args=parser.parse_args()
    path,bun,missing=configuration()
    if missing:
        print('OpenBot cannot start yet. Missing: '+', '.join(missing));return 1
    if args.check:print('Required configuration and installation are present. Authentication and database connectivity are not yet verified.');return 0
    if '/' not in args.model:raise ValueError('Use an exact OpenRouter provider/model ID')
    env=environment(args.model)
    env['PATH']=str(Path(bun).parent)+os.pathsep+env.get('PATH','')
    # Uses the official migration runner and official server, with a loopback binding.
    subprocess.run([bun,'server/scripts/migrate.ts'],cwd=path,env=env,check=True)
    subprocess.run([bun,'scripts/generate-app-config.ts'],cwd=path,env=env,check=True)
    # Upstream has no bind-host option. Build a local copy with just its listener
    # bound to loopback; preserve the pinned source and all server functionality.
    from setup_integrations import loopback_server
    launcher=loopback_server(path,bun,env)
    processes=[]
    try:
        processes.append(subprocess.Popen([bun,str(launcher)],cwd=path,env=env))
        processes.append(subprocess.Popen([bun,'--bun','node_modules/vite/bin/vite.js','--host','127.0.0.1','--port','3010'],cwd=path/'app',env=env))
        print('OpenBot: http://127.0.0.1:3010 — start Jevie separately on port 8765.')
        while all(p.poll() is None for p in processes):time.sleep(.5)
    except KeyboardInterrupt:pass
    finally:
        for p in processes:
            if p.poll() is None:p.terminate()
        for p in processes:
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
    return next((p.returncode for p in processes if p.returncode and p.returncode>0),0)
if __name__=='__main__':raise SystemExit(main())
