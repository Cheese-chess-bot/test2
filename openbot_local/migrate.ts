/** Install only into a fresh private schema; preserve all other project data. */
import postgres from '../.integrations/openbot-local/server/node_modules/postgres';
import {readFile} from 'node:fs/promises';
import {applyMigrations} from '../.integrations/openbot-local/server/src/db/apply-migrations';
const value=process.env.DATABASE_URL;
if(!value)throw new Error('Set DATABASE_URL locally');
const url=new URL(value);
if(url.port==='6543')throw new Error('Use a direct connection or Supabase Session pooler on 5432; transaction pooling cannot hold OpenBot locks');
const sql=postgres(value,{max:1,onnotice:()=>{}});
try {
 const [existing]=await sql`select to_regclass('openbot.users')::text as present`;
 if(!existing.present){
  await sql.begin(async tx=>{await tx.unsafe(await readFile(new URL('../supabase/migrations/20261022185447_jevie_openbot_additive_install.sql',import.meta.url),'utf8'));});
  // pg_dump sets an empty session search path while restoring qualified objects.
  await sql`set search_path=openbot,public,extensions`;
 }else{
  await sql.unsafe(await readFile(new URL('./bootstrap.sql',import.meta.url),'utf8'));
  await applyMigrations(sql,new URL('../.integrations/openbot-local/server/drizzle',import.meta.url).pathname);
 }
 const [path]=await sql`select current_schemas(false) as schemas`;
 if(path.schemas[0]!=='openbot')throw new Error('DATABASE_URL must set search_path=openbot,public,extensions; configure the dedicated database role or connection parameters');
 console.log('Private OpenBot schema and local runtime ready');
}finally{await sql.end({timeout:5});}
