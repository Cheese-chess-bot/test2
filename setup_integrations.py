"""Install pinned Hermes and the bundled Jevie OpenBot fork."""
import argparse,json,os,shutil,subprocess,sys
from pathlib import Path
from jevie_models import OPENBOT_MODEL
ROOT=Path(__file__).resolve().parent
SOURCES={
 'hermes':('https://github.com/NousResearch/hermes-agent.git','92663ae8054ae81f207f46d83512d3f879dc698d'),
 'openbot':('https://github.com/CopilotKit/OpenBot.git','636c6fe14c3bba2f3e9b845101f8723e974064b7')}

def run(args,cwd=None):subprocess.run(args,cwd=cwd,check=True)
def checkout(name):
 url,sha=SOURCES[name];target=ROOT/'.integrations'/name
 if not (target/'.git').exists():
  target.mkdir(parents=True,exist_ok=True);run(['git','init',str(target)]);run(['git','remote','add','origin',url],target)
 origin=subprocess.check_output(['git','remote','get-url','origin'],cwd=target,text=True).strip()
 if origin!=url:raise RuntimeError('Integration remote differs from the official source')
 if subprocess.check_output(['git','status','--porcelain'],cwd=target,text=True).strip():raise RuntimeError('Integration checkout has local modifications; preserve them before updating')
 run(['git','fetch','--depth','1','origin',sha],target);run(['git','checkout','--detach',sha],target);return target

def write_tenant(tenant,model):
 tenant.mkdir(parents=True,exist_ok=True)
 files={
  'brand.yaml':{'tenant':{'id':'jevie','product_name':'Jevie Research'}},
  'model.yaml':{'model':{'provider':'openai','credential_secret_ref':'openai-api-key','default_model':model}},
  'channels.yaml':{'channels':[{'id':'jevie-research','name':'Strategy research','description':'Research, debate and evaluate stock strategies.','permitted_agents':['jevie-research'],'allowed_groups':['all']}]},
  'knowledge.yaml':{'sources':[]},'skills.yaml':{'skills':[]},
  'agents.yaml':{'agents':[{'id':'jevie-research','name':'Jevie Research','title':'Strategy laboratory','role_description':'Research and evaluate stock strategies through Jevie. Accept an enabled ticker or /research TICKER, /backtest TICKER, /evolve TICKER, /status.','avatar_seed':'jevie','type':'remote-ag-ui','endpoint':'${MANAGED_AGENT_AG_UI_URL:-}'}]}}
 # JSON is valid YAML; encoding values this way avoids unsafe string interpolation.
 for filename,value in files.items():(tenant/filename).write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')

def bun_path():
 local=ROOT/'.integrations'/'tooling'/'node_modules'/'.bin'/('bun.exe' if os.name=='nt' else 'bun')
 return shutil.which('bun') or (str(local) if local.exists() else None)

def install_openbot(path):
 bun=bun_path()
 if not bun:
  npm=shutil.which('npm')
  if not npm:raise RuntimeError('Install Bun or Node/npm first')
  run([npm,'install','--prefix',str(ROOT/'.integrations'/'tooling'),'bun@1.4.3','--no-audit','--no-fund'])
  bun=bun_path()
 run([bun,'install','--frozen-lockfile'],path)

def loopback_server(path,bun,env):
 """Load the real server with one documented local-only listener transform."""
 runtime=ROOT/'runtime';runtime.mkdir(exist_ok=True)
 output=runtime/'openbot-server.ts'
 output.write_text('''import {readFile} from 'node:fs/promises';
import {plugin} from 'bun';
plugin({name:'jevie-loopback',setup(build){build.onLoad({filter:/server[\\\\/]src[\\\\/]http-server\\.ts$/},async args=>{
 const source=await readFile(args.path,'utf8');
 const marker='serve<SocketData>({';
 if(source.split(marker).length!==2)throw new Error('Pinned listener changed; refusing unbounded single-user server');
 return {contents:source.replace(marker,marker+' hostname: "127.0.0.1",'),loader:'ts'};
});}});
await import(ENTRY);
'''.replace('ENTRY',json.dumps(str(path/'server/src/index.ts'))))
 return output

def main():
 p=argparse.ArgumentParser();p.add_argument('--hermes',action='store_true');p.add_argument('--openbot',action='store_true');p.add_argument('--openbot-model',default=OPENBOT_MODEL);p.add_argument('--install-hermes',action='store_true');p.add_argument('--install-openbot',action='store_true');args=p.parse_args()
 if not (args.hermes or args.openbot or args.install_hermes or args.install_openbot):p.error('Select --install-hermes and/or --install-openbot')
 if '/' not in args.openbot_model:p.error('--openbot-model must be an exact OpenRouter model ID')
 if args.hermes or args.install_hermes:
  path=checkout('hermes')
  if args.install_hermes:
   uv=shutil.which('uv')
   if not uv:raise RuntimeError('Install uv from https://docs.astral.sh/uv/ first')
   run([uv,'sync','--python','3.14'],path)
  exe=path/'.venv'/('Scripts/python.exe' if os.name=='nt' else 'bin/python')
  print('Add locally to .env:\nHERMES_SOURCE='+str(path)+'\nHERMES_PYTHON='+str(exe))
 if args.openbot or args.install_openbot:
  from openbot_local.patch import prepare
  path=prepare()
  tenant=ROOT/'runtime'/'openbot-tenant';write_tenant(tenant,args.openbot_model)
  if args.install_openbot:install_openbot(path)
  print('OpenBot source: '+str(path))
  print('Custom tenant: '+str(tenant))
  print('Run python run_openbot.py --check. Add OpenRouter and PostgreSQL/Supabase DATABASE_URL to .env. No CopilotKit Intelligence key is used. No service has been started.')
if __name__=='__main__':main()
