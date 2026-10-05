// Real HTTP coverage. Production mode is anonymous/read-only only.
import assert from 'node:assert/strict';
import {randomUUID, randomBytes} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {writeFile, access} from 'node:fs/promises';
import {resolve, relative} from 'node:path';
const [ref, psql, vaultArg, evidenceArg] = process.argv.slice(2);
assert.ok(['rvgslhjmiaunylwhcamz','xdmcxhvdqsbcqedfprcy'].includes(ref));
const isolated=ref==='rvgslhjmiaunylwhcamz', url=`https://${ref}.supabase.co`;
const publicKey=process.env.MDAC_TEST_ANON_KEY, serviceKey=process.env.MDAC_TEST_SERVICE_KEY;
assert.ok(publicKey?.startsWith('sb_publishable_'));
const results=[], identities=[], run=randomUUID(), vault=resolve(vaultArg), evidence=resolve(evidenceArg);
assert.ok(relative(process.cwd(),vault).startsWith('..'),'Vault must be outside repo');
if(isolated){try{await access(vault);throw Error('Existing credential vault');}catch(e){if(e.code!=='ENOENT')throw e;}}
function sql(query){
 const r=spawnSync(psql,['-X','-qAt','-v','ON_ERROR_STOP=1','-c','SET ROLE postgres;','-c',query],{encoding:'utf8',windowsHide:true,timeout:20000});
 assert.equal(r.status,0,'Isolated profile setup failed; no SQL output logged');return r.stdout.trim();
}
const q=v=>`'${String(v).replaceAll("'","''")}'`;
function saveVault(){
 const r=spawnSync('pwsh.exe',['-NoProfile','-NonInteractive','-Command',"$ErrorActionPreference='Stop'; ConvertTo-SecureString ([Console]::In.ReadToEnd()) -AsPlainText -Force | Export-Clixml -LiteralPath $env:MDAC_VAULT_PATH"],{input:JSON.stringify({ref,run,identities:identities.map(({token,...identity})=>identity)}),encoding:'utf8',windowsHide:true,timeout:10000,env:{...process.env,MDAC_VAULT_PATH:vault}});
 assert.equal(r.status,0,'DPAPI persistence failed');
}
async function request(path,body,key=publicKey,token=null,method='POST'){
 const headers={apikey:key,'Content-Type':'application/json','Accept-Profile':'public','Content-Profile':'public'};
 if(token)headers.Authorization=`Bearer ${token}`;
 const r=await fetch(url+path,{method,headers,body:body===null?undefined:JSON.stringify(body),signal:AbortSignal.timeout(20000)});
 const data=await r.json().catch(()=>null);return {status:r.status,data};
}
async function denied(label,token=null){
 for(const fn of ['get_mdac_batch_memberships','get_workers_health']){
  const r=await request(`/rest/v1/rpc/${fn}`,{},publicKey,token);
  assert.ok([401,403].includes(r.status),`${label}: ${fn} denial status`);
  assert.equal(r.data?.code,'42501',`${label}: permission error required`);
  results.push({name:`${label}_${fn}`,status:r.status,code:r.data.code,business_data_returned:false,passed:true});
 }
}
let error=null,cleanup=true;
try{
 await denied('anonymous_publishable_no_access_token');
 if(isolated){
  assert.ok(serviceKey);
  for(const [name,role,mode] of [['owner','OWNER','FULL'],['operator','OPERATOR','FULL'],['review','OPERATOR','REVIEW_ONLY']]){
   const identity={name,role,mode,email:`read-rpc-${name}-${run}@example.invalid`,password:`Aa1!${randomBytes(24).toString('base64url')}`,id:null};
   identities.push(identity);saveVault();
   const created=await request('/auth/v1/admin/users',{email:identity.email,password:identity.password,email_confirm:true,user_metadata:{name:'SYNTHETIC READ RPC'}},serviceKey,serviceKey);
   assert.equal(created.status,200,'Synthetic Auth creation');identity.id=created.data.id;assert.match(identity.id,/^[\da-f-]{36}$/);saveVault();
   sql(`update public.profiles set role=${q(role)},access_mode=${q(mode)},access_expires_at=${mode==='FULL'?'null':"now()+interval '1 hour'"},is_active=true,deleted_at=null,must_change_password=false where id=${q(identity.id)}`);
   const login=await request('/auth/v1/token?grant_type=password',{email:identity.email,password:identity.password});assert.equal(login.status,200,'Synthetic login');
   identity.token=login.data.access_token;
   // Never persist JWTs. Profile changes below use the same original JWT.
   const memberships=await request('/rest/v1/rpc/get_mdac_batch_memberships',{},publicKey,identity.token);
   assert.equal(memberships.status,200);assert.ok(Array.isArray(memberships.data));
   for(const m of memberships.data)assert.ok(m.batch_id&&typeof m.name==='string'&&m.created_at&&Array.isArray(m.customer_ids));
   const health=await request('/rest/v1/rpc/get_workers_health',{},publicKey,identity.token);assert.equal(health.status,200);
   assert.deepEqual(Object.keys(health.data).sort(),['gmail_pin','mdac','ocr','reg_check','visit_pass']);
   if(name!=='owner')for(const h of Object.values(health.data))assert.ok(h.hostname==null);
   results.push({name:`${name}_real_login_and_two_reads`,status:200,membership_rows:memberships.data.length,health_keys:5,passed:true});
  }
  const op=identities[1];
  for(const [state,change] of [['inactive','is_active=false'],['deleted','deleted_at=now()'],['expired',"access_mode='REVIEW_ONLY',access_expires_at=now()-interval '1 minute'"]]){
   sql(`update public.profiles set is_active=true,deleted_at=null,access_mode='FULL',access_expires_at=null where id=${q(op.id)}; update public.profiles set ${change} where id=${q(op.id)}`);
   await denied(`same_jwt_${state}_profile`,op.token);
  }
 }
}catch(e){error=e.message;console.error(`Acceptance failed: ${error}`);}
finally{
 if(isolated)for(const i of identities.filter(i=>i.id)){
  try{sql(`update public.profiles set is_active=false where id=${q(i.id)}; delete from public.profiles where id=${q(i.id)}`);
   const r=await request(`/auth/v1/admin/users/${i.id}`,{should_soft_delete:false},serviceKey,serviceKey,'DELETE');assert.equal(r.status,200);
   assert.equal(sql(`select count(*) from auth.users where id=${q(i.id)}`),'0');
  }catch{cleanup=false;error??='Run-owned synthetic account cleanup incomplete; DPAPI recovery vault retained';}
 }
 await writeFile(evidence,JSON.stringify({project:ref,run,checked_utc:new Date().toISOString(),passed:!error&&cleanup,scope:isolated?'Real Auth/API; synthetic accounts removed; no browser UI':'Production anonymous HTTP only; no business writes',public_schema_exposed:results.length>0,results,cleanup_run_owned_accounts:isolated?cleanup:null,error},null,2));
}
if(error)process.exitCode=1;else console.log(`PASS ${results.length} HTTP checks; ${isolated?'isolated synthetic account cleanup complete':'production read-only'}`);
