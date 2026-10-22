/** Jevie's PostgreSQL-backed SSE runtime. No CopilotKit Intelligence service or license is used.
 * OpenBot remains single-user and loopback-only. CopilotKit's MIT SSE runner supplies AG-UI semantics.
 */
import { InMemoryAgentRunner, ɵGLOBAL_STORE, type CopilotKitIntelligence,
  type AgentRunnerRunRequest, type AgentRunnerConnectRequest, type AgentRunnerStopRequest,
  type LocalThreadEndpointRecord } from '@copilotkit/runtime/v2';
import { type BaseEvent, type Message, compactEvents } from '@ag-ui/client';
import { Observable, ReplaySubject, concat, from } from 'rxjs';
import postgres, { type Sql } from 'postgres';

const OWNER = 'dev-local-user';
const MAX_THREAD_BYTES = 8 * 1024 * 1024;
const clone = <T>(value:T):T => structuredClone(value);
const failure = (status:number,message:string) => Object.assign(new Error(message),{status});
type Row = {id:string; owner_id:string; agent_id:string; name:string|null; messages:Message[];
  events:BaseEvent[]; created_at:Date; updated_at:Date; active_run:string|null; lock_until:Date|null};

export class LocalThreadStore {
  readonly rows = new Map<string,Row>();
  constructor(readonly sql:Sql) {}
  async initialize() {
    // DDL is installed by the fork migration, never silently on an arbitrary database.
    const rows = await this.sql<Row[]>`select * from jevie_runtime.threads order by updated_at desc limit 2000`;
    for (const row of rows) {
      this.rows.set(row.id,row);
      this.hydrate(row);
    }
  }
  hydrate(row:Row) {
    const existing=ɵGLOBAL_STORE.peek(row.id);
    if(existing?.isRunning)return;
    if(row.events.length || row.messages.length) {
      ɵGLOBAL_STORE.appendRun(row.id,{threadId:row.id,runId:'restored-'+row.id,
        agentId:row.agent_id,parentRunId:null,events:clone(row.events),messages:clone(row.messages),createdAt:row.created_at.getTime()});
    }
  }
  async ensure(id:string,agent:string,user=OWNER) {
    if(user!==OWNER)throw failure(403,'This Jevie fork supports only its local operator');
    const existing=this.rows.get(id);
    if(existing){if(existing.owner_id!==user)throw failure(404,'Thread not found');return existing;}
    const [row]=await this.sql<Row[]>`insert into jevie_runtime.threads(id,owner_id,agent_id)
      values(${id},${user},${agent}) on conflict(id) do update set id=excluded.id returning *`;
    if(!row || row.owner_id!==user)throw failure(404,'Thread not found');
    this.rows.set(id,row);this.hydrate(row);return row;
  }
  owned(id:string,user=OWNER) {
    const row=this.rows.get(id);
    if(!row || row.owner_id!==user || user!==OWNER)throw failure(404,'Thread not found');
    return row;
  }
  async acquire(id:string,runId:string,user=OWNER,agent='default') {
    await this.ensure(id,agent,user);
    const [row]=await this.sql<Row[]>`update jevie_runtime.threads
      set active_run=${runId},lock_until=now()+interval '120 seconds'
      where id=${id} and owner_id=${user} and (active_run is null or lock_until<now() or active_run=${runId}) returning *`;
    if(!row)throw failure(409,'Thread already running');
    this.rows.set(id,row);return row;
  }
  async renew(id:string,runId:string) {
    const rows=await this.sql`update jevie_runtime.threads set lock_until=now()+interval '120 seconds'
      where id=${id} and active_run=${runId} returning id`;
    if(!rows.length)throw failure(409,'Thread lease was lost');
  }
  async release(id:string,runId:string) {
    await this.sql`update jevie_runtime.threads set active_run=null,lock_until=null where id=${id} and active_run=${runId}`;
    const row=this.rows.get(id);if(row?.active_run===runId){row.active_run=null;row.lock_until=null;}
  }
  async save(id:string,runId:string,messages:Message[],events:BaseEvent[]) {
    if(JSON.stringify({messages,events}).length>MAX_THREAD_BYTES)throw failure(413,'Thread reached its history limit; start a new conversation');
    const [row]=await this.sql<Row[]>`update jevie_runtime.threads set messages=${this.sql.json(messages as never)},
      events=${this.sql.json(events as never)},updated_at=now(),lock_until=now()+interval '120 seconds'
      where id=${id} and active_run=${runId} returning *`;
    if(!row)throw failure(409,'Thread lease was lost');
    this.rows.set(id,row);
  }
  async remove(id:string,user=OWNER) {
    const row=this.owned(id,user);if(row.active_run && row.lock_until && row.lock_until>new Date())throw failure(409,'Stop this thread first');
    await this.sql`delete from jevie_runtime.threads where id=${id} and owner_id=${user}`;
    this.rows.delete(id);const cached=ɵGLOBAL_STORE.peek(id);if(cached){cached.historicRuns=[];cached.messagesSnapshot=[];}
  }
  summary(row:Row):LocalThreadEndpointRecord {
    return {id:row.id,name:row.name,agentId:row.agent_id,organizationId:'local',createdById:row.owner_id,
      archived:false,createdAt:row.created_at.toISOString(),updatedAt:row.updated_at.toISOString()};
  }
}

let configuredStore:LocalThreadStore|undefined;
let initialized:Promise<LocalThreadStore>|undefined;
export async function initializeLocalRuntime(url:string) {
  if(!initialized)initialized=(async()=>{
    if(process.env.OPENBOT_SINGLE_USER!=='true')throw new Error('Jevie local runtime requires OPENBOT_SINGLE_USER=true');
    // Two connections: the dedicated deployment lock and a small query pool. No transaction pooler.
    let ownsLock=false;
    const lock=postgres(url,{max:1,idle_timeout:0,max_lifetime:null,onnotice:()=>{},
      onclose:()=>{if(ownsLock){console.error('Database controller lock lost; stopping OpenBot');process.exit(1);}}});
    const [held]=await lock`select pg_try_advisory_lock(hashtextextended('jevie:openbot-single-controller',0)) as held`;
    if(!held?.held){await lock.end();throw new Error('Another OpenBot controller already uses this database');}
    ownsLock=true;
    const store=new LocalThreadStore(postgres(url,{max:3,onnotice:()=>{}}));
    // The deployment lock proves no other controller is running. Preserve partial history,
    // but release leases left by a process crash so the operator can resume the conversation.
    await store.sql`update jevie_runtime.threads set
      events=case when events->-1->>'type' in ('RUN_FINISHED','RUN_ERROR') then events else
        events || jsonb_build_array(jsonb_build_object('type','RUN_ERROR','code','CONTROLLER_RESTARTED',
          'message','OpenBot restarted during this run. Partial history was preserved; send a new message to continue.')) end,
      active_run=null,lock_until=null where active_run is not null`;
    await store.initialize();configuredStore=store;return store;
  })();
  return initialized;
}
export function setLocalRuntimeStoreForTests(store:LocalThreadStore){configuredStore=store;}
const store=()=>{if(!configuredStore)throw new Error('Initialize local runtime before starting OpenBot');return configuredStore;};
const active = new Map<string,ReplaySubject<BaseEvent>>();
const activeRunIds=new Map<string,string>();
const priorEvents=new Map<string,BaseEvent[]>();
const cancelled=new Set<string>();
const base=new InMemoryAgentRunner({maxThreads:2000,maxRunsPerThread:100,maxBytes:128*1024*1024});

/** Keeps generated events durable before forwarding them; disconnecting a subscriber does not stop work. */
export class PersistentAgentRunner extends InMemoryAgentRunner {
  constructor(_compat?:unknown){super();}
  run(request:AgentRunnerRunRequest):Observable<BaseEvent> {
    const output=new ReplaySubject<BaseEvent>();
    if(active.has(request.threadId)){output.error(failure(409,'Thread already running'));return output;}
    priorEvents.set(request.threadId,clone(store().rows.get(request.threadId)?.events??[]));
    active.set(request.threadId,output);activeRunIds.set(request.threadId,request.input.runId);
    void (async()=>{
      const db=store(),id=request.threadId,runId=request.input.runId;
      let renew:ReturnType<typeof setInterval>|undefined;
      let timer:ReturnType<typeof setTimeout>|undefined;
      try {
        const row=await db.acquire(id,runId,OWNER,request.agent.agentId??'default');
        if(cancelled.has(id))throw failure(409,'Run cancelled before starting');
        // The server owns history. Only genuinely new input messages are appended to saved history.
        const known=new Set(row.messages.map(m=>m.id));
        const inputMessages=request.input.messages.filter(m=>!known.has(m.id));
        request={...request,input:{...request.input,messages:[...clone(row.messages),...inputMessages]}};
        request.agent.setMessages(request.input.messages);
        const before=clone(row.events),collected:BaseEvent[]=[];
        const terminal:BaseEvent[]=[];
        let pending:BaseEvent[]=[],chain=Promise.resolve(),persistError:unknown;
        const flush=()=>{
          if(timer){clearTimeout(timer);timer=undefined;}
          if(!pending.length)return;
          const batch=pending;pending=[];
          const events=compactEvents([...before,...clone(collected)]),messages=clone(request.agent.messages);
          chain=chain.then(async()=>{
            if(persistError)return;
            try{await db.save(id,runId,messages,events);for(const event of batch){if(event.type==='RUN_FINISHED'||event.type==='RUN_ERROR')terminal.push(event);else output.next(event);}}
            catch(error){persistError=error;await base.stop({threadId:id,runId});}
          });
        };
        renew=setInterval(()=>{void db.renew(id,runId).catch(error=>{persistError=error;void base.stop({threadId:id,runId});});},30000);
        await new Promise<void>((resolve,reject)=>{
          base.run(request).subscribe({next(event){
            const safe=clone(event);collected.push(safe);pending.push(safe);
            if(pending.length>=32)flush();else if(!timer)timer=setTimeout(flush,25);
          },error:reject,complete:resolve});
        });
        flush();await chain;if(persistError)throw persistError;
        // Ensure the final message snapshot matches the completed agent, including tool results.
        await db.save(id,runId,clone(request.agent.messages),compactEvents([...before,...collected]));
        await db.release(id,runId);for(const event of terminal)output.next(event);output.complete();
      } catch(error) {
        try{await store().release(request.threadId,request.input.runId);}catch{}
        output.error(error);
      } finally {if(timer)clearTimeout(timer);if(renew)clearInterval(renew);active.delete(request.threadId);activeRunIds.delete(request.threadId);priorEvents.delete(request.threadId);cancelled.delete(request.threadId);}
    })();
    return output.asObservable();
  }
  connect(request:AgentRunnerConnectRequest):Observable<BaseEvent> {
    const running=active.get(request.threadId);
    if(running)return concat(from(clone(priorEvents.get(request.threadId)??[])),running.asObservable());
    const output=new ReplaySubject<BaseEvent>();
    const row=store().rows.get(request.threadId);
    if(row){for(const event of row.events)output.next(clone(event));}
    output.complete();return output.asObservable();
  }
  async isRunning({threadId}:{threadId:string}){return active.has(threadId);}
  async stop(request:AgentRunnerStopRequest){
    if(request.runId && activeRunIds.get(request.threadId)!==request.runId)return false;
    if(!active.has(request.threadId))return false;
    cancelled.add(request.threadId);await base.stop(request);return true;
  }
  listThreads(){return [...store().rows.values()].filter(r=>r.owner_id===OWNER).map(r=>store().summary(r)) as ReturnType<InMemoryAgentRunner['listThreads']>;}
  getThreadMessages(id:string){return clone(store().rows.get(id)?.messages??[]);}
  getThreadEvents(id:string){return clone(store().rows.get(id)?.events??[]);}
  getThreadState(id:string){
    const events=this.getThreadEvents(id);
    for(let i=events.length-1;i>=0;i--)if(events[i].type==='STATE_SNAPSHOT')return (events[i] as BaseEvent & {snapshot:Record<string,unknown>}).snapshot;
    return null;
  }
  clearThreads(){throw failure(405,'Use explicit per-thread deletion; bulk history deletion is disabled');}
}

class LocalRuntimeClient {
  async getThread({threadId,userId}:{threadId:string;userId:string}){return store().summary(store().owned(threadId,userId));}
  async getOrCreateThread({threadId,userId,agentId}:{threadId:string;userId:string;agentId:string}){
    const created=!store().rows.has(threadId);const row=await store().ensure(threadId,agentId,userId);return {thread:store().summary(row),created};
  }
  async getThreadMessages({threadId,userId}:{threadId:string;userId:string}){
    return {messages:clone(store().owned(threadId,userId).messages).map(m=>{
      if(m.role==='assistant' && m.toolCalls)return {...m,toolCalls:m.toolCalls.map(t=>({id:t.id,name:t.function.name,args:t.function.arguments}))};
      return m;
    })};
  }
  async deleteThread({threadId,userId}:{threadId:string;userId:string}){await store().remove(threadId,userId);}
  async ɵacquireThreadLock({threadId,runId,userId,agentId}:{threadId:string;runId:string;userId:string;agentId:string}){
    await store().acquire(threadId,runId,userId,agentId);return {runId};
  }
  async ɵrenewThreadLock({threadId,runId}:{threadId:string;runId:string}){await store().renew(threadId,runId);}
  async ɵcleanupThreadLock({threadId,runId}:{threadId:string;runId:string}){await store().release(threadId,runId);}
  // Compatibility metadata only. All runners are in-process; these are never connection credentials.
  ɵgetRunnerWsUrl(){return 'local:';}
  ɵgetRunnerAuthToken(){return '';}
  async getRuntimeEntitlements(){return {status:'ready',entitlement:{active:false,planCode:'local',features:{memory:false,learning:false}}};}
  async getInspectorLearning(){throw failure(501,'Hosted Learning is replaced by Hermes; use /evolve in Jevie');}
}
// Structural compatibility for OpenBot's existing thread/lock ports; never constructs the hosted client.
export function createLocalRuntimeClient():CopilotKitIntelligence{return new LocalRuntimeClient() as unknown as CopilotKitIntelligence;}
