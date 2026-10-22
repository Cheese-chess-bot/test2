import {PGlite} from '@electric-sql/pglite';
import {PGLiteSocketServer} from '@electric-sql/pglite-socket';
import {spawn} from 'node:child_process';
import {readFile,writeFile} from 'node:fs/promises';
let db=await PGlite.create();
// Leave the database empty so the real launcher must perform the fresh installation.
await db.exec('set search_path=openbot,public,extensions;');
let server=new PGLiteSocketServer({db,port:55433,host:'127.0.0.1',maxConnections:64});await server.start();
const env={...process.env,DATABASE_URL:'postgres://postgres:postgres@127.0.0.1:55433/postgres',JEVIE_AGENT_TOKEN:'offline-integration-test-token',OPENROUTER_API_KEY:''};
const children=[];
function start(args){const p=spawn('python3',args,{env,stdio:'inherit',detached:true});children.push(p);return p;}
start(['start_jevie.py','--demo','--no-browser','--data-dir','runtime/openbot-smoke-demo']);
start(['run_openbot.py','--demo']);
try {
 let ok=false;
 for(let i=0;i<90;i++){await new Promise(r=>setTimeout(r,1000));try{if((await fetch('http://127.0.0.1:3001/health')).ok){ok=true;break;}}catch{}if(children.some(p=>p.exitCode!==null))throw Error('Child process exited');}
 if(!ok)throw Error('API did not start');
 console.log('SMOKE API HEALTH OK');
 for(const path of ['/api/copilotkit/info','/api/me']){const response=await fetch('http://127.0.0.1:3001'+path);const body=await response.text();console.log(path,response.status,body.slice(0,3500));}
 const payload={threadId:'local-smoke-thread',runId:crypto.randomUUID(),messages:[{id:crypto.randomUUID(),role:'user',content:'/help'}],state:{symbol:'NVDA'},tools:[],context:[],forwardedProps:{}};
 const chat=await fetch('http://127.0.0.1:3001/api/copilotkit/agent/jevie-research/run',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),signal:AbortSignal.timeout(30000)});
 const events=await chat.text();console.log('PASS real Jevie AG-UI chat stream',chat.status);
 if(chat.status!==200 || !events.includes('RUN_FINISHED') || events.includes('RUN_ERROR'))throw Error('Chat stream failed');
 const history=await fetch('http://127.0.0.1:3001/api/copilotkit/threads/local-smoke-thread/messages');const saved=await history.json();if(saved.messages?.length!==2)throw Error('Missing saved messages');console.log('PASS persisted messages');
 const threads=await fetch('http://127.0.0.1:3001/api/copilotkit/threads');if(!(await threads.json()).threads?.some(t=>t.id==='local-smoke-thread'))throw Error('Missing thread listing');
 const origin=await fetch('http://127.0.0.1:3001/health',{headers:{Origin:'https://evil.example'}});if(origin.status!==403)throw Error('Origin guard failed');
 const ui=await fetch('http://127.0.0.1:3010');console.log('SMOKE UI',ui.status,(await ui.text()).includes('root'));
 // Restart both the database engine and OpenBot; the restored UI history must be identical.
 for(const p of children){try{process.kill(-p.pid,'SIGTERM');}catch{}}
 await Promise.all(children.map(p=>p.exitCode!==null?Promise.resolve():new Promise(r=>p.on('exit',r))));children.length=0;
 await server.stop();
 await db.exec(`insert into jevie_runtime.threads(id,owner_id,agent_id,active_run,lock_until,events)
   values('interrupted-test','dev-local-user','jevie-research','crashed-run',now()+interval '120 seconds',
   '[{"type":"RUN_STARTED","threadId":"interrupted-test","runId":"crashed-run"}]'::jsonb);`);
 const snapshot=await db.dumpDataDir();await db.close();
 db=await PGlite.create({loadDataDir:snapshot});await db.exec('set search_path=openbot,public,extensions;');
 server=new PGLiteSocketServer({db,port:55433,host:'127.0.0.1',maxConnections:64});await server.start();
 start(['start_jevie.py','--demo','--no-browser','--data-dir','runtime/openbot-smoke-demo']);
 start(['run_openbot.py','--demo']);
 let restarted=false;for(let i=0;i<60;i++){await new Promise(r=>setTimeout(r,500));try{if((await fetch('http://127.0.0.1:3001/health')).ok){restarted=true;break;}}catch{}}
 if(!restarted)throw Error('Restart failed');
 const reloaded=await (await fetch('http://127.0.0.1:3001/api/copilotkit/threads/local-smoke-thread/messages')).json();
 if(JSON.stringify(reloaded)!==JSON.stringify(saved))throw Error('Restart changed conversation history');
 console.log('PASS full database and API restart preserves chat history');
 const interrupted=await (await fetch('http://127.0.0.1:3001/api/copilotkit/threads/interrupted-test/events')).text();
 if(!interrupted.includes('CONTROLLER_RESTARTED'))throw Error('Interrupted run was not closed');
 console.log('PASS interrupted run recovery');
 const check=spawn('.integrations/tooling/node_modules/.bin/bun',['--preload','./openbot_local/network-policy.ts','openbot_local/runtime-check.ts'],{env:{...env,OPENBOT_OFFLINE:'true'},stdio:'inherit'});
 const checkCode=await new Promise(r=>check.on('exit',r));if(checkCode!==0)throw Error('Runtime checks failed');
 await writeFile('runtime/openbot-smoke-result.json',JSON.stringify({health:true,ui:ui.status}));
}finally{for(const p of children){try{process.kill(-p.pid,'SIGTERM');}catch{}}await server.stop();await db.close();}

console.log('PASS all offline OpenBot integration checks');process.exit(0);
