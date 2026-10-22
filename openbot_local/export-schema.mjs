/** Development-only: collapse the upstream migration chain into an additive fresh install. */
import {PGlite} from '@electric-sql/pglite';
import {pgDump} from '@electric-sql/pglite-tools/pg_dump';
import {readFile,writeFile} from 'node:fs/promises';
const db=await PGlite.create();
try{
 await db.exec(await readFile(new URL('./fresh-install.sql',import.meta.url),'utf8'));
 const dump=await pgDump({pg:db,args:['--schema=openbot','--schema=jevie_runtime','--schema=drizzle','--no-owner','--no-privileges']});
 let sql=await dump.text();
 sql=sql.split('\n').filter(line=>!line.startsWith('\\restrict ')&&!line.startsWith('\\unrestrict ')).join('\n');
 const guard=`-- Additive fresh-install snapshot. Refuses existing application schemas; never deletes user data.
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('openbot','jevie_runtime','drizzle')) THEN
  RAISE EXCEPTION 'OpenBot schemas already exist; refusing fresh installation';
 END IF;
END $$;
`;
 const permissions=`
REVOKE ALL ON SCHEMA openbot,jevie_runtime,drizzle FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA openbot,jevie_runtime,drizzle FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA openbot,jevie_runtime,drizzle FROM PUBLIC;
DO $$ DECLARE r text; BEGIN
 FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN
   EXECUTE format('REVOKE ALL ON SCHEMA openbot,jevie_runtime,drizzle FROM %I',r);
   EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA openbot,jevie_runtime,drizzle FROM %I',r);
   EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA openbot,jevie_runtime,drizzle FROM %I',r);
  END IF;
 END LOOP;
END $$;
`;
 sql=guard+sql+permissions;
 // Validate the exact deployable snapshot in a different, empty PostgreSQL engine.
 const fresh=await PGlite.create();await fresh.exec(sql);
 const result=await fresh.query("select count(*)::int as tables, bool_and(rowsecurity) as all_rls from pg_tables where schemaname in ('openbot','jevie_runtime','drizzle')");
 console.log('Validated additive snapshot',result.rows);await fresh.close();
 await writeFile(new URL('../supabase/migrations/20261022185447_jevie_openbot_additive_install.sql',import.meta.url),sql);
}finally{await db.close();}
