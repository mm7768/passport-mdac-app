// Isolated only. Tiny synthetic DB metadata + private Storage object pairing.
import assert from 'node:assert/strict';
import {randomUUID, createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {writeFile} from 'node:fs/promises';
const [psql, vault, evidence]=process.argv.slice(2),ref='rvgslhjmiaunylwhcamz';
assert.ok(process.env.PGUSER===`cli_login_postgres.${ref}` || (process.env.PGUSER==='cli_login_postgres'&&process.env.PGHOST===`db.${ref}.supabase.co`));
const run=randomUUID(),tag=run.replaceAll('-',''),schema=`restore_probe_${tag}`,bucket=`restore-probe-${run}`;
const key=process.env.MDAC_TEST_SERVICE_KEY;assert.ok(key);
const objects=[{name:'snapshot.txt',text:`SYNTHETIC SNAPSHOT ${run}`},{name:'post-snapshot.txt',text:`SYNTHETIC POST-SNAPSHOT ${run}`}];
const hash=text=>createHash('sha256').update(text).digest('hex');
const results=[];let failure=null,cleanup=true;
function sql(q){const r=spawnSync(psql,['-X','-qAt','-v','ON_ERROR_STOP=1','-c','SET ROLE postgres;','-c',q],{encoding:'utf8',windowsHide:true,timeout:20000});assert.equal(r.status,0,'Synthetic DB operation failed');return r.stdout.trim();}
async function api(path,method,body,binary=false){
 const r=await fetch(`https://${ref}.supabase.co/storage/v1${path}`,{method,headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':binary?'text/plain':'application/json'},body:body==null?undefined:(binary?body:JSON.stringify(body)),signal:AbortSignal.timeout(20000)});
 assert.ok(r.ok,`Synthetic Storage ${method} status ${r.status}`);return r;
}
function protect(bundle){
 const command="$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Security.Cryptography.ProtectedData; $b=[Text.Encoding]::UTF8.GetBytes([Console]::In.ReadToEnd()); [IO.File]::WriteAllBytes($env:MDAC_VAULT_PATH,[Security.Cryptography.ProtectedData]::Protect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))";
 const r=spawnSync('pwsh.exe',['-NoProfile','-NonInteractive','-Command',command],{input:JSON.stringify(bundle),encoding:'utf8',windowsHide:true,timeout:10000,env:{...process.env,MDAC_VAULT_PATH:vault}});assert.equal(r.status,0,'Paired DPAPI snapshot persistence failed');
}
function unprotect(){
 const command="$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Security.Cryptography.ProtectedData; $b=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($env:MDAC_VAULT_PATH),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser); [Console]::Out.Write([Text.Encoding]::UTF8.GetString($b))";
 const r=spawnSync('pwsh.exe',['-NoProfile','-NonInteractive','-Command',command],{encoding:'utf8',windowsHide:true,timeout:10000,env:{...process.env,MDAC_VAULT_PATH:vault}});assert.equal(r.status,0,'Paired DPAPI decryption failed');return JSON.parse(r.stdout);
}
const ddl=`create schema ${schema}; create table ${schema}.files(object_path text primary key,sha256 text not null,version integer not null);`;
const insert=(o,v)=>`insert into ${schema}.files values('${o.name}','${hash(o.text)}',${v});`;
try{
 await api('/bucket','POST',{id:bucket,name:bucket,public:false});
 sql(ddl+insert(objects[0],1));await api(`/object/${bucket}/${objects[0].name}`,'POST',objects[0].text,true);
 const snapshot={project:ref,run,bucket,schema,restore_point:new Date().toISOString(),ddl,metadata:JSON.parse(sql(`select json_agg(t) from ${schema}.files t`)),objects:[objects[0]],delta:null};
 protect(snapshot);assert.equal(unprotect().metadata[0].sha256,hash(objects[0].text));results.push({name:'encrypted_snapshot_roundtrip',passed:true});
 // Simulate a new write AFTER the recovery point, and retain a separate delta.
 sql(insert(objects[1],2));await api(`/object/${bucket}/${objects[1].name}`,'POST',objects[1].text,true);
 snapshot.delta={at:new Date().toISOString(),object:objects[1],version:2};protect(snapshot);
 sql(`drop schema ${schema} cascade;`);await api(`/object/${bucket}`,'DELETE',{prefixes:objects.map(o=>o.name)});
 const restored=unprotect();assert.equal(restored.project,ref);assert.equal(restored.schema,schema);assert.equal(restored.bucket,bucket);
 sql(restored.ddl+insert(restored.objects[0],1));await api(`/object/${bucket}/${restored.objects[0].name}`,'POST',restored.objects[0].text,true);
 assert.equal(sql(`select count(*) from ${schema}.files`),'1');
 let downloaded=await (await api(`/object/${bucket}/${objects[0].name}`,'GET')).text();assert.equal(hash(downloaded),restored.metadata[0].sha256);
 results.push({name:'database_storage_restored_to_same_snapshot_hash',passed:true});
 // Explicit delta replay, not silent inclusion of unbacked post-snapshot data.
 sql(insert(restored.delta.object,restored.delta.version));await api(`/object/${bucket}/${restored.delta.object.name}`,'POST',restored.delta.object.text,true);
 downloaded=await (await api(`/object/${bucket}/${objects[1].name}`,'GET')).text();assert.equal(hash(downloaded),hash(objects[1].text));assert.equal(sql(`select count(*) from ${schema}.files`),'2');
 results.push({name:'post_snapshot_write_requires_preserved_explicit_delta_replay',passed:true});
}catch(e){failure=e.message;}
finally{
 try{sql(`drop schema if exists ${schema} cascade;`);await api(`/object/${bucket}`,'DELETE',{prefixes:objects.map(o=>o.name)});await api(`/bucket/${bucket}`,'DELETE');}catch{cleanup=false;failure??='Run-owned synthetic restore cleanup incomplete';}
 await writeFile(evidence,JSON.stringify({project:ref,run,checked_utc:new Date().toISOString(),passed:!failure&&cleanup,scope:'Two synthetic text files and dedicated non-API fixture schema only; NOT full production or cross-machine disaster recovery',results,cleanup_run_owned_schema_bucket:cleanup,error:failure},null,2));
}
if(failure){console.error(`Synthetic paired restore failed: ${failure}`);process.exitCode=1;}else console.log('PASS synthetic DB/Storage paired snapshot, explicit post-snapshot delta replay, exact fixture cleanup');
