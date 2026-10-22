"""Apply the audited Jevie fork overlay to the pinned, bundled MIT OpenBot source."""
from pathlib import Path
import hashlib,json,shutil,tarfile
ROOT=Path(__file__).resolve().parents[1]
TARGET=ROOT/'.integrations'/'openbot-local'

def generate_install_sql():
 journal=json.loads((TARGET/'server/drizzle/meta/_journal.json').read_text())
 chunks=[(ROOT/'openbot_local/bootstrap.sql').read_text(),
  'set search_path=openbot,public,extensions;\ncreate schema if not exists drizzle;\ncreate table if not exists drizzle.__drizzle_migrations(id serial primary key,hash text not null,created_at bigint);']
 for item in journal['entries']:
  sql=(TARGET/'server/drizzle'/f"{item['tag']}.sql").read_text()
  digest=hashlib.sha256(sql.encode()).hexdigest()
  chunks.extend([sql.replace('--> statement-breakpoint',''),f"insert into drizzle.__drizzle_migrations(hash,created_at) values('{digest}',{int(item['when'])});"])
 chunks.append('''
alter function openbot.prevent_audit_event_mutation() set search_path=pg_catalog,openbot;
revoke all on schema openbot,jevie_runtime,drizzle from public;
revoke all on all tables in schema openbot,jevie_runtime,drizzle from public;
revoke all on all sequences in schema openbot,jevie_runtime,drizzle from public;
do $$ declare t record; r text; begin
 for t in select schemaname,tablename from pg_tables where schemaname in ('openbot','jevie_runtime','drizzle') loop
  execute format('alter table %I.%I enable row level security',t.schemaname,t.tablename);
 end loop;
 foreach r in array array['anon','authenticated'] loop
  if exists(select 1 from pg_roles where rolname=r) then
   execute format('revoke all on schema openbot,jevie_runtime,drizzle from %I',r);
   execute format('revoke all on all tables in schema openbot,jevie_runtime,drizzle from %I',r);
   execute format('revoke all on all sequences in schema openbot,jevie_runtime,drizzle from %I',r);
  end if;
 end loop;
end $$;
reset search_path;
''')
 (ROOT/'openbot_local/fresh-install.sql').write_text('\n'.join(chunks),newline='\n')

def replace(path,old,new):
 p=TARGET/path;s=p.read_text()
 if s.count(old)!=1:raise RuntimeError(f'Pinned source marker changed: {path}: {old[:70]}')
 p.write_text(s.replace(old,new),newline='\n')

def prepare():
 manifest=json.loads((ROOT/'vendor/openbot-source.json').read_text())
 archive=ROOT/'vendor/openbot-source.tar.gz'
 if hashlib.sha256(archive.read_bytes()).hexdigest()!=manifest['sha256']:raise RuntimeError('OpenBot archive checksum mismatch')
 TARGET.mkdir(parents=True,exist_ok=True)
 with tarfile.open(archive) as t:t.extractall(TARGET,filter='data')
 shutil.copyfile(ROOT/'openbot_local/local-runtime.ts',TARGET/'server/src/local-runtime.ts')
 # The fork exclusively uses local SSE. The empty compatibility fields do not authorize a service.
 p=TARGET/'server/src/config.ts';s=p.read_text();a=s.index('function runtimeCapabilities(');b=s.index('\n/**',a)
 s=s[:a]+'''function runtimeCapabilities(environment: Environment): RuntimeCapabilities {
  if (!singleUserEnabled(environment, false)) throw new Error("Jevie local runtime requires explicit single-user mode");
  return { mode: "local", durableHistory: true,
    intelligence: {apiUrl: "", gatewayWsUrl: "", apiKey: ""} };
}
'''+s[b:]
 s=s.replace('mode: "intelligence";','mode: "local";');p.write_text(s,newline='\n')
 # No hosted client is constructed. Existing narrow thread/lock ports use our SQL implementation.
 p=TARGET/'server/src/intelligence-client.ts';s=p.read_text();a=s.index('export function createIntelligenceClient(')
 s=s[:a]+'''export function createIntelligenceClient(_settings?: unknown): CopilotKitIntelligence {
  return createLocalRuntimeClient();
}
''';s='import {createLocalRuntimeClient} from "./local-runtime";\n'+s;p.write_text(s,newline='\n')
 p=TARGET/'server/src/index.ts';s=p.read_text()
 s=s.replace('  CopilotKitIntelligence,\n  IntelligenceAgentRunner,','  type CopilotKitIntelligence,')
 s='import {initializeLocalRuntime, createLocalRuntimeClient, PersistentAgentRunner} from "./local-runtime";\n'+s
 s=s.replace('const database = createDatabase(config.databaseUrl);','const database = createDatabase(config.databaseUrl);\nawait initializeLocalRuntime(config.databaseUrl);')
 a=s.index('const routineIntelligence = observeIntelligenceAuthentication(');b=s.index('\nconst approvalComputerTools',a)
 s=s[:a]+'const routineIntelligence = createLocalRuntimeClient();\n'+s[b:]
 a=s.index('const routineAgentRunner = new IntelligenceAgentRunner(');b=s.index('\n\nconst routineRunner',a)
 s=s[:a]+'const routineAgentRunner = new PersistentAgentRunner();'+s[b:]
 a=s.index('void reportIntelligenceEntitlement({');b=s.index('\n});',a)+4
 s=s[:a]+'// Local fork: hosted Intelligence entitlements are not requested.'+s[b:]
 p.write_text(s,newline='\n')
 p=TARGET/'server/src/copilot.ts';s=p.read_text()
 s='import {createLocalRuntimeClient, PersistentAgentRunner} from "./local-runtime";\n'+s
 a=s.index('  const intelligenceClient: CopilotKitIntelligence =');b=s.index('\n  const runtime = new CopilotRuntime(',a)
 s=s[:a]+'''  const intelligenceClient = createLocalRuntimeClient();
  // Hermes owns learning in Jevie; no hosted Learning container is attached.
  const learning: LearningRuntime | undefined = undefined;
'''+s[b:]
 s=s.replace('    identifyUser,','    runner: new PersistentAgentRunner(),')
 s=s.replace('    learning,\n    /**','    learning: learning as LearningRuntime | undefined,\n    /**')
 s=s.replace('    intelligence: intelligenceClient,\n    licenseToken: intelligence.licenseToken,','')
 p.write_text(s,newline='\n')
 replace('server/src/agents/handoff-wiring.ts','import { IntelligenceAgentRunner } from "@copilotkit/runtime/v2";','import { PersistentAgentRunner as IntelligenceAgentRunner } from "../local-runtime";')
 # Harden the local single-user HTTP boundary against DNS rebinding and cross-origin writes.
 p=TARGET/'server/src/app.ts';s=p.read_text();needle='  const app = new Hono'
 pos=s.find(needle)
 if pos<0:raise RuntimeError('Cannot find Hono app construction')
 end=s.index(';',pos)+1
 s=s[:end]+'''
  app.use("*", async (c, next) => {
    const host = new URL(c.req.url).hostname;
    if (!["localhost", "127.0.0.1", "[::1]"].includes(host)) return c.json({error:"Local access only"},403);
    const origin = c.req.header("origin");
    if (origin && !["http://127.0.0.1:3010","http://localhost:3010","http://127.0.0.1:3001","http://localhost:3001"].includes(origin))
      return c.json({error:"Cross-origin access denied"},403);
    await next();
  });
'''+s[end:];p.write_text(s,newline='\n')
 # Fresh-install migrations use a private schema and retain no obsolete document vector index.
 for p in (TARGET/'server/drizzle').glob('*.sql'):
  s=p.read_text().replace('"public".','"openbot".').replace('public.','openbot.')
  s=s.replace('CREATE EXTENSION IF NOT EXISTS vector;','-- Obsolete document index is removed by migration 0010; no extension needed.')
  s=s.replace('"embedding" vector(1536)','"embedding" bytea')
  s=s.replace('DROP EXTENSION IF EXISTS "vector";','-- Never remove a database-wide extension used by another application.')
  p.write_text(s,newline='\n')
 # Every database connection, including work queues and listeners, uses the same private search path.
 # DATABASE_URL carries search_path and the launcher checks it before startup.
 generate_install_sql()
 print('Prepared full OpenBot fork at '+str(TARGET))
 return TARGET
if __name__=='__main__':prepare()
