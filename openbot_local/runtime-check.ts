/** Exercised against the PostgreSQL protocol test server by smoke.mjs. No model services. */
import assert from 'node:assert/strict';
import postgres from '../.integrations/openbot-local/server/node_modules/postgres';
import {HttpAgent} from '../.integrations/openbot-local/server/node_modules/@ag-ui/client';
import {LocalThreadStore,PersistentAgentRunner,setLocalRuntimeStoreForTests} from '../.integrations/openbot-local/server/src/local-runtime';
const sql=postgres(process.env.DATABASE_URL!,{max:1,onnotice:()=>{}});
const db=new LocalThreadStore(sql);await db.initialize();setLocalRuntimeStoreForTests(db);
try {
 await assert.rejects(()=>fetch('https://api.openai.com/v1/models'),/blocks hosted Intelligence/);
 await assert.rejects(()=>fetch('https://intelligence.copilotkit.ai'),/blocks hosted Intelligence/);
 await assert.rejects(()=>fetch('https://openrouter.ai/api/v1/models'),/Offline demo/);
 const restored=db.owned('local-smoke-thread');assert.equal(restored.messages.length,2);
 assert(restored.events.some(e=>e.type==='RUN_FINISHED'));
 await assert.rejects(()=>db.ensure('forbidden','jevie-research','another-user'),/local operator/);
 assert.throws(()=>db.owned('local-smoke-thread','another-user'),/not found/);
 await db.acquire('lease-test','run-one');
 await assert.rejects(()=>db.acquire('lease-test','run-two'),/already running/);
 await assert.rejects(()=>db.save('lease-test','wrong-run',[],[]),/lease was lost/);
 await db.release('lease-test','run-one');await db.acquire('lease-test','run-two');await db.release('lease-test','run-two');
 const runner=new PersistentAgentRunner();
 const replay:any[]=[];await new Promise<void>((resolve,reject)=>runner.connect({threadId:'local-smoke-thread'}).subscribe({next:e=>replay.push(e),error:reject,complete:resolve}));
 assert(replay.some(e=>e.type==='TEXT_MESSAGE_CONTENT'));
 // A persistence failure must never look like a successfully committed run to the UI.
 const save=db.save.bind(db);db.save=async()=>{throw Error('simulated database write failure');};
 const seen:any[]=[];
 const agent=new HttpAgent({agentId:'jevie-research',url:'http://127.0.0.1:8765/api/ag-ui',headers:{'x-openbot-agent-token':'offline-integration-test-token'}});
 let failure:unknown;
 await new Promise<void>(resolve=>runner.run({threadId:'failed-write',agent,input:{threadId:'failed-write',runId:crypto.randomUUID(),messages:[{id:crypto.randomUUID(),role:'user',content:'/help'}],state:{},tools:[],context:[],forwardedProps:{}}}).subscribe({next:e=>seen.push(e),error:e=>{failure=e;resolve();},complete:resolve}));
 assert(failure);assert(!seen.some(e=>e.type==='RUN_FINISHED'));db.save=save;
 console.log('PASS network boundary, history replay, owner isolation, competing leases, stale writes and persistence-failure reporting');
}finally{await sql.end({timeout:5});}
process.exit(0);
