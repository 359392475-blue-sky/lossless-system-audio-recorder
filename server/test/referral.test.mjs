import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,writeFileSync,rmSync,readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { request } from 'node:http';
import { generateKeyPairSync,createHash,sign,verify,randomUUID,randomBytes } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { createService } from '../service.mjs';
function identity(){const keys=generateKeyPairSync('ed25519');return {...keys,publicKeyRaw:keys.publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64'),hardware:randomBytes(32).toString('hex')};}
async function fixture(t,{large=false,existing=false,artifactBuild=6}={}){
 const dir=mkdtempSync(join(tmpdir(),'referral-test-')),keys=generateKeyPairSync('ed25519');let clock=1900000000000;
 const zip=Buffer.concat([Buffer.from('504b0304','hex'),Buffer.alloc(large?16*1024*1024:1024,31)]);
 const env={POLICY_FILE:join(dir,'policy.json'),POLICY_PRIVATE_KEY_FILE:join(dir,'key'),STATS_DB:join(dir,'db'),ADMIN_TOKEN:'a'.repeat(32),RELEASE_ARTIFACT_URL:'https://example.com/v6/Recorder.zip',RELEASE_ARTIFACT_BUILD:String(artifactBuild),REFERRAL_PUBLIC_ORIGIN:'https://recorder.example.com',REFERRAL_DEVICE_PEPPER:'p'.repeat(32),REFERRAL_SERIES:'3.2',REFERRAL_ARTIFACT_FILE:join(dir,'Recorder.zip'),REFERRAL_ARTIFACT_SHA256:createHash('sha256').update(zip).digest('hex')};
 const policy={schema:1,product:'lossless-system-audio-recorder',sequence:1,level:0,minimumBuild:6,effectiveAt:0,latestBuild:artifactBuild,title:'Version',message:'',downloadURL:env.RELEASE_ARTIFACT_URL};
 writeFileSync(env.POLICY_FILE,JSON.stringify(policy));writeFileSync(env.POLICY_PRIVATE_KEY_FILE,keys.privateKey.export({type:'pkcs8',format:'pem'}));writeFileSync(env.REFERRAL_ARTIFACT_FILE,zip);
 if(existing){const old=new DatabaseSync(env.STATS_DB);old.exec('CREATE TABLE schema_version(version INTEGER PRIMARY KEY);INSERT INTO schema_version VALUES(1);CREATE TABLE download_entry_requests(day TEXT,channel TEXT,count INTEGER,PRIMARY KEY(day,channel));INSERT INTO download_entry_requests VALUES(\'2026-09-14\',\'website\',9);');old.close();}
 const server=createService(env,{now:()=>clock});server.listen(0,'127.0.0.1');await once(server,'listening');const origin=`http://127.0.0.1:${server.address().port}`;
 t.after(async()=>{server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(dir,{recursive:true,force:true});});
 const get=(path,options)=>fetch(origin+path,options);
 function envelope(who,action,extra={}){const p={schema:1,product:'lossless-system-audio-recorder',action,publicKey:who.publicKeyRaw,deviceHash:who.hardware,series:'3.2',build:6,nonce:randomUUID(),issuedAt:Math.floor(clock/1000),...extra};const raw=Buffer.from(JSON.stringify(p));return {payload:raw.toString('base64'),signature:sign(null,raw,who.privateKey).toString('base64')};}
 async function send(who,action,extra={},body){const e=body||envelope(who,action,extra),r=await get('/v1/referral',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(e)}),json=await r.json();if(r.ok){const raw=Buffer.from(json.payload,'base64');assert(verify(null,raw,keys.publicKey,Buffer.from(json.signature,'base64')));const s=JSON.parse(raw);assert.equal(s.publicKey,who.publicKeyRaw);assert.equal(s.nonce,JSON.parse(Buffer.from(e.payload,'base64')).nonce);assert.equal(s.expiresAt-s.issuedAt,60);return {status:r.status,...s};}return {status:r.status,...json};}
 async function ticket(who){const s=await send(who,'status');const r=await get('/r/'+s.referralCode+'/ticket',{method:'POST',headers:{Accept:'application/json'}});assert.equal(r.status,200);return r.json();}
 async function download(ticket){const r=await get('/r/download?ticket='+ticket.ticket);assert.equal(r.status,200);assert.deepEqual(Buffer.from(await r.arrayBuffer()),zip);}
 async function success(who){const operationID=randomUUID();assert.equal((await send(who,'begin',{operationID})).status,200);return send(who,'complete',{operationID});}
 return {env,policy,get,send,envelope,ticket,download,success,origin,setClock:v=>clock=v,advance:seconds=>clock+=seconds*1000,setPolicy:p=>writeFileSync(env.POLICY_FILE,JSON.stringify(p))};
}
test('five successful recordings, idempotent reservation/completion, cancel tombstones',async t=>{
 const f=await fixture(t),who=identity(),op=randomUUID();
 let s=await f.send(who,'status');assert.equal(s.usedTrials,0);assert.equal(s.freeLimit,5);
 assert.equal((await f.send(who,'begin',{operationID:op})).reservedTrials,1);
 assert.equal((await f.send(who,'begin',{operationID:op})).reservedTrials,1);
 assert.equal((await f.send(who,'complete',{operationID:op})).usedTrials,1);
 assert.equal((await f.send(who,'complete',{operationID:op})).usedTrials,1);
 assert.equal((await f.send(who,'cancel',{operationID:op})).status,409);
 assert.equal((await f.send(who,'begin',{operationID:op})).status,409);
 const canceled=randomUUID();assert.equal((await f.send(who,'cancel',{operationID:canceled})).status,200);assert.equal((await f.send(who,'begin',{operationID:canceled})).status,409);
 for(let i=0;i<4;i++)await f.success(who);
 s=await f.send(who,'status');assert.equal(s.usedTrials,5);assert.equal(s.canRecord,false);assert.equal((await f.send(who,'begin',{operationID:randomUUID()})).error,'trial_limit_reached');
});
test('two distinct delivered and first-used devices unlock same series without expiry',async t=>{
 const f=await fixture(t),inviter=identity();
 for(let i=0;i<2;i++){const invited=identity(),ticket=await f.ticket(inviter);assert.equal((await f.send(invited,'claim',{ticket:ticket.ticket})).error,'download_not_completed');await f.download(ticket);assert.equal((await f.send(invited,'claim',{ticket:ticket.ticket})).status,200);assert.equal((await f.send(inviter,'status')).qualifiedCount,i);await f.success(invited);assert.equal((await f.send(inviter,'status')).qualifiedCount,i+1);}
 let state=await f.send(inviter,'status');assert.equal(state.unlocked,true);
 const metrics=await (await f.get('/admin/stats',{headers:{Authorization:'Bearer '+f.env.ADMIN_TOKEN}})).json();assert.equal(metrics.referrals.qualifiedInvites,2);assert.equal(metrics.referrals.deliveredTickets,2);assert.equal(metrics.referrals.unlockedDeviceSeries,1);assert.equal(metrics.referrals.activatedDevices,2);assert(!JSON.stringify(metrics.referrals).includes(inviter.publicKeyRaw));
 for(let i=0;i<7;i++)await f.success(inviter);
 f.advance(8*86400);state=await f.send(inviter,'status');assert.equal(state.unlocked,true);assert.equal(state.canRecord,true);assert.equal(state.usedTrials,7);
});
test('self invitation, activated devices, ticket rebinding, hardware key reset rejected',async t=>{
 const f=await fixture(t),owner=identity(),a=identity(),b=identity(),ticket=await f.ticket(owner);await f.download(ticket);
 assert.equal((await f.send(owner,'claim',{ticket:ticket.ticket})).error,'self_invite');
 await f.success(b);assert.equal((await f.send(b,'claim',{ticket:ticket.ticket})).error,'device_already_activated');
 assert.equal((await f.send(a,'claim',{ticket:ticket.ticket})).status,200);assert.equal((await f.send(a,'claim',{ticket:ticket.ticket})).status,200);
 assert.equal((await f.send(identity(),'claim',{ticket:ticket.ticket})).error,'ticket_already_bound');
 const reset=identity();reset.hardware=a.hardware;assert.equal((await f.send(reset,'status')).error,'device_key_already_registered');
});
test('nonce replay, invalid signature, stale clock, series/build and malformed operation rejected',async t=>{
 const f=await fixture(t),who=identity(),body=f.envelope(who,'status');assert.equal((await f.send(who,'status',{},body)).status,200);assert.equal((await f.send(who,'status',{},body)).error,'replayed_nonce');
 body.signature=Buffer.alloc(64).toString('base64');assert.equal((await f.send(who,'status',{},body)).error,'invalid_signature');
 for(const extra of [{issuedAt:1},{series:'3.3'},{build:5},{deviceHash:'x'}])assert.equal((await f.send(who,'status',extra)).status,400);
 assert.equal((await f.send(who,'begin')).error,'invalid_operation');
});
test('policy enforcement checked each begin but complete/cancel/status survive blocked policy',async t=>{
 const f=await fixture(t),who=identity(),op=randomUUID();await f.send(who,'begin',{operationID:op});
 // Cannot advertise higher build than artifact: test force policy using build below min via future artifact.
 f.setPolicy({...f.policy,sequence:2,level:4});
 assert.equal((await f.send(who,'begin',{operationID:op})).status,200);
 f.setPolicy({...f.policy,sequence:3,latestBuild:7,minimumBuild:7,level:4});
 assert.equal((await f.send(who,'begin',{operationID:op})).status,503);
 assert.equal((await f.send(who,'complete',{operationID:op})).status,200);
 assert.equal((await f.send(who,'status')).usedTrials,1);
 assert.equal((await f.send(who,'cancel',{operationID:randomUUID()})).status,200);
});
test('reservations include concurrent pending requests and release after cancellation',async t=>{
 const f=await fixture(t),who=identity(),ops=Array.from({length:8},()=>randomUUID());
 const results=await Promise.all(ops.map(operationID=>f.send(who,'begin',{operationID})));assert.equal(results.filter(r=>r.status===200).length,5);
 const s=await f.send(who,'status');assert.equal(s.pendingOperationIDs.length,5);await f.send(who,'cancel',{operationID:s.pendingOperationIDs[0]});assert.equal((await f.send(who,'begin',{operationID:randomUUID()})).status,200);
});
test('HEAD, ranged request, aborted download, and expired ticket do not qualify',async t=>{
 const f=await fixture(t,{large:true}),owner=identity(),who=identity(),ticket=await f.ticket(owner),path='/r/download?ticket='+ticket.ticket;
 assert.equal((await f.get(path,{method:'HEAD'})).status,200);assert.equal((await f.send(who,'claim',{ticket:ticket.ticket})).error,'download_not_completed');
 assert.equal((await f.get(path,{headers:{Range:'bytes=0-100'}})).status,416);
 await new Promise(resolve=>{const req=request(f.origin+path,res=>{res.once('data',()=>{res.destroy();req.destroy();resolve();});});req.on('error',()=>resolve());req.end();});
 assert.equal((await f.send(who,'claim',{ticket:ticket.ticket})).error,'download_not_completed');
 f.advance(7*86400+1);assert.equal((await f.get(path)).status,409);assert.equal((await f.send(who,'claim',{ticket:ticket.ticket})).error,'ticket_expired_or_unknown');
});
test('old schema migration retains counters and never stores raw identity or ticket',async t=>{
 const f=await fixture(t,{existing:true}),who=identity(),ticket=await f.ticket(who);await f.send(who,'status');
 const db=new DatabaseSync(f.env.STATS_DB);assert.equal(db.prepare('SELECT MAX(version) version FROM schema_version').get().version,2);assert.equal(db.prepare('SELECT count FROM download_entry_requests').get().count,9);
 const row=db.prepare('SELECT * FROM referral_devices').get();assert.notEqual(row.id,who.publicKeyRaw);assert.notEqual(row.hardware,who.hardware);assert.notEqual(db.prepare('SELECT id FROM referral_tickets').get().id,ticket.ticket);db.close();
});
test('referral config and artifact hash fail closed, browser flow shows explicit activation',async t=>{
 const f=await fixture(t);assert.throws(()=>createService({...f.env,REFERRAL_ARTIFACT_SHA256:'0'.repeat(64)}),/digest/);assert.throws(()=>createService({...f.env,REFERRAL_DEVICE_PEPPER:''}),/Incomplete/);
 const owner=identity(),s=await f.send(owner,'status'),r=await f.get('/r/'+s.referralCode);assert.equal(r.status,200);assert.match(await r.text(),/五次成功录音/);
 const page=await f.get('/r/'+s.referralCode+'/ticket',{method:'POST'});assert.match(await page.text(),/lossless-recorder:\/\/activate\?ticket=/);
});

test('level4 and elapsed level3 reject old build even for existing reservation',async t=>{
 const f=await fixture(t,{artifactBuild:7}),who=identity(),op=randomUUID();await f.send(who,'begin',{operationID:op});
 f.setPolicy({...f.policy,sequence:2,level:3,minimumBuild:7,effectiveAt:1900000010});
 assert.equal((await f.send(who,'begin',{operationID:op})).status,200);f.advance(11);
 assert.equal((await f.send(who,'begin',{operationID:op})).error,'upgrade_required');
 assert.equal((await f.send(who,'complete',{operationID:op})).status,200);
 f.setPolicy({...f.policy,sequence:3,level:4,minimumBuild:7});
 assert.equal((await f.send(who,'begin',{operationID:randomUUID()})).error,'upgrade_required');
 assert.equal((await f.send(who,'begin',{operationID:randomUUID(),build:7})).status,200);
});
test('pepper rotation and modified artifact rejected',async t=>{
 const f=await fixture(t),ticket=await f.ticket(identity());
 assert.throws(()=>createService({...f.env,REFERRAL_DEVICE_PEPPER:'q'.repeat(32)}),/pepper cannot be changed/);
 const file=readFileSync(f.env.REFERRAL_ARTIFACT_FILE);file[10]=42;writeFileSync(f.env.REFERRAL_ARTIFACT_FILE,file);
 assert.equal((await f.get('/r/download?ticket='+ticket.ticket)).status,503);
});
