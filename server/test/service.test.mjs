import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify, randomUUID } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { spawnSync, spawn } from 'node:child_process';
import { createService } from '../service.mjs';

const base = {schema:1,product:'lossless-system-audio-recorder',sequence:1,level:0,minimumBuild:1,effectiveAt:0,latestBuild:7,title:'Update',message:'Please upgrade',downloadURL:'https://example.com/download?channel=other'};
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(),'recorder-server-test-'));
  const keys = generateKeyPairSync('ed25519');
  const env = {POLICY_FILE:join(dir,'policy.json'),POLICY_PRIVATE_KEY_FILE:join(dir,'key.pem'),STATS_DB:join(dir,'stats.db'),ADMIN_TOKEN:'test-only-token-012345678901234567890',RELEASE_ARTIFACT_URL:'https://example.com/releases/7/Recorder.dmg',RELEASE_ARTIFACT_BUILD:'7',RELEASE_DOWNLOAD_URL:base.downloadURL};
  writeFileSync(env.POLICY_PRIVATE_KEY_FILE,keys.privateKey.export({type:'pkcs8',format:'pem'}));
  const policy = p=>writeFileSync(env.POLICY_FILE,JSON.stringify(p)); policy(base);
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  return {env,keys,policy};
}
async function start(t,f,options) {
  const server = createService(f.env,options); server.listen(0,'127.0.0.1'); await once(server,'listening');
  t.after(async()=>{server.closeAllConnections(); await new Promise(resolve=>server.close(resolve));});
  const origin=`http://127.0.0.1:${server.address().port}`;
  return {server,get:(path,options)=>fetch(origin+path,options),stats:()=>fetch(origin+'/admin/stats',{headers:{Authorization:`Bearer ${f.env.ADMIN_TOKEN}`}}).then(r=>r.json())};
}
test('signed fresh policy binds build and nonce for all levels',async t=>{
  const f=fixture(t), s=await start(t,f,{now:()=>1900000000000});
  for (let level=0;level<=4;level++) {
    f.policy({...base,level,sequence:level+1});
    const nonce=randomUUID(), response=await s.get(`/v1/policy?build=2&nonce=${nonce}`);
    assert.equal(response.status,200);
    const signed=await response.json(), bytes=Buffer.from(signed.payload,'base64');
    assert(verify(null,bytes,f.keys.publicKey,Buffer.from(signed.signature,'base64')));
    const p=JSON.parse(bytes); assert.equal(p.clientBuild,2); assert.equal(p.nonce,nonce); assert.equal(p.level,level); assert.equal(p.expiresAt-p.issuedAt,60);
    assert.equal(p.issuedAt,1900000000);
  }
});
test('invalid query is rejected and startup is fail closed',async t=>{
  const f=fixture(t);
  for (const k of Object.keys(f.env).filter(k=>k!=='RELEASE_DOWNLOAD_URL')) assert.throws(()=>createService({...f.env,[k]:''}));
  for (const change of [{level:5},{sequence:-1},{minimumBuild:0},{latestBuild:0},{downloadURL:'http://example.com'},{extra:true},{schema:2}]) {
    f.policy({...base,...change}); assert.throws(()=>createService(f.env));
  }
  f.policy(base); const s=await start(t,f);
  for (const query of ['','build=0&nonce='+randomUUID(),'build=1&nonce=bad','build=1&build=2&nonce='+randomUUID(),'build=9007199254740992&nonce='+randomUUID()]) assert.equal((await s.get('/v1/policy?'+query)).status,400);
});
test('persisted sequence rejects rollback and reused sequence, health differs from ready',async t=>{
  const f=fixture(t), s=await start(t,f);
  f.policy({...base,level:4,sequence:2}); assert.equal((await s.get('/ready')).status,200);
  for (const p of [base,{...base,level:0,sequence:2}]) {
    f.policy(p); assert.equal((await s.get('/ready')).status,503); assert.equal((await s.get('/health')).status,200);
    assert.equal((await s.get('/download?channel=website',{redirect:'manual'})).status,503);
  }
  f.policy({...base,sequence:3}); assert.equal((await s.get('/ready')).status,200);
  f.policy(base); assert.throws(()=>createService(f.env),/rollback/);
});
test('redirect counts are atomic, HEAD/errors excluded and stats authenticated',async t=>{
  const f=fixture(t), s=await start(t,f,{now:()=>1900000000000});
  assert.equal((await s.get('/admin/stats')).status,401);
  assert.equal((await s.get('/admin/stats',{headers:{Authorization:'Bearer '+'x'.repeat(f.env.ADMIN_TOKEN.length)}})).status,401);
  assert.equal((await s.get('/download?channel=website',{method:'HEAD',redirect:'manual'})).status,302);
  assert.equal((await s.get('/download?channel=bad',{redirect:'manual'})).status,400);
  assert.equal((await s.get('/download?channel=website&url=https://evil.example',{redirect:'manual'})).status,400);
  assert.equal((await s.get('/download?channel=website',{method:'POST'})).status,405);
  const responses=await Promise.all(Array.from({length:40},()=>s.get('/download?channel=website',{redirect:'manual'})));
  for(const r of responses) { assert.equal(r.status,302); assert.equal(r.headers.get('location'),f.env.RELEASE_ARTIFACT_URL); assert.equal(r.headers.get('set-cookie'),null); }
  const stats=await s.stats(); assert.deepEqual(stats.download_entry_requests.rows,[{day:'2030-03-17',channel:'website',count:40}]); assert.equal(stats.github.status,'not_configured');
});
test('GitHub official counts are separate and errors explicitly unavailable',async t=>{
  const f=fixture(t); f.env.GITHUB_REPOSITORY='owner/repo'; let failing=false;
  const s=await start(t,f,{fetchImpl:async(url,options)=>{
    assert.equal(url,'https://api.github.com/repos/owner/repo/releases?per_page=100&page=1');
    assert.equal(options.headers['X-GitHub-Api-Version'],'2026-03-10');
    if(failing) throw new Error('test outage');
    return {ok:true,json:async()=>[{tag_name:'v7',assets:[{id:1,name:'Recorder.dmg',download_count:123}]}]};
  }});
  const stats=await s.stats(); assert.equal(stats.github.assets[0].download_count,123); assert.deepEqual(stats.download_entry_requests.rows,[]);
  failing=true; assert.equal((await s.stats()).github.status,'unavailable');
});
test('policy CLI demands higher sequence even when withdrawing enforcement',t=>{
  const f=fixture(t), proposed=join(f.env.POLICY_FILE+'-proposed');
  const run=()=>spawnSync(process.execPath,[new URL('../cli.mjs',import.meta.url).pathname,'policy',proposed],{env:{...process.env,...f.env},encoding:'utf8'});
  writeFileSync(proposed,JSON.stringify({...base,sequence:1,level:4})); assert.equal(run().status,1);
  writeFileSync(proposed,JSON.stringify({...base,sequence:2,level:4})); assert.equal(run().status,0);
  writeFileSync(proposed,JSON.stringify({...base,sequence:3,level:0})); assert.equal(run().status,0);
});
test('artifact build and upgrade URL must match policy before sequence is committed',async t=>{
  const f=fixture(t);
  for(const value of ['4','0','7.5','07','9007199254740992']) assert.throws(()=>createService({...f.env,RELEASE_ARTIFACT_BUILD:value}),/BUILD/);
  assert.throws(()=>createService({...f.env,RELEASE_ARTIFACT_BUILD:'8'}),/different release/);
  assert.throws(()=>createService({...f.env,RELEASE_DOWNLOAD_URL:'https://example.com/wrong'}),/download URL/);
  const s=await start(t,f);
  f.policy({...base,sequence:20,minimumBuild:8,latestBuild:8,level:4});
  assert.equal((await s.get('/ready')).status,503);
  assert.equal((await s.get(`/v1/policy?build=7&nonce=${randomUUID()}`)).status,503);
  f.policy({...base,sequence:2}); assert.equal((await s.get('/ready')).status,200);
  f.policy({...base,sequence:30,downloadURL:'https://example.com/old-installer'});
  assert.equal((await s.get('/ready')).status,503);
  f.policy({...base,sequence:3}); assert.equal((await s.get('/ready')).status,200);
});
test('CLI cross-process lock rejects contenders without replacing current policy',async t=>{
  const f=fixture(t), proposed=f.env.POLICY_FILE+'-proposed';
  writeFileSync(proposed,JSON.stringify({...base,sequence:2}));
  const lock=f.env.POLICY_FILE+'.lock';
  const holder=spawn(process.execPath,['-e',"const fs=require('node:fs');const p=process.argv[1];fs.writeFileSync(p,String(process.pid),{flag:'wx'});process.stdout.write('locked');process.stdin.resume();process.stdin.on('end',()=>fs.unlinkSync(p));",lock],{stdio:['pipe','pipe','pipe']});
  await once(holder.stdout,'data');
  const blocked=spawnSync(process.execPath,[new URL('../cli.mjs',import.meta.url).pathname,'policy',proposed],{env:{...process.env,...f.env},encoding:'utf8'});
  assert.equal(blocked.status,1); assert.match(blocked.stderr,/locked/); assert.equal(JSON.parse(readFileSync(f.env.POLICY_FILE)).sequence,1);
  const released=once(holder,'exit'); holder.stdin.end(); await released;
  const attempts=Array.from({length:12},(_,i)=>i+2).reverse().map(async sequence=>{
    const file=proposed+'-'+sequence;writeFileSync(file,JSON.stringify({...base,sequence}));
    const child=spawn(process.execPath,[new URL('../cli.mjs',import.meta.url).pathname,'policy',file],{env:{...process.env,...f.env},stdio:'ignore'});
    const [code]=await once(child,'exit'); return {sequence,code};
  });
  const results=await Promise.all(attempts),successful=results.filter(r=>r.code===0);
  assert(successful.length>0);
  assert.equal(JSON.parse(readFileSync(f.env.POLICY_FILE)).sequence,Math.max(...successful.map(r=>r.sequence)));
});

test('HTTP resource limiter returns stable 429 without serving excess requests',async t=>{
 const f=fixture(t);f.env.MAX_REQUESTS_PER_MINUTE='2';const s=await start(t,f);
 assert.equal((await s.get('/health')).status,200);assert.equal((await s.get('/ready')).status,200);
 const response=await s.get('/health');assert.equal(response.status,429);assert.equal(response.headers.get('retry-after'),'60');assert.deepEqual(await response.json(),{error:'capacity_limited'});
});

test('public information and feedback pages are reachable without leaking configuration',async t=>{
 const f=fixture(t),server=createService(f.env);server.listen(0,'127.0.0.1');await once(server,'listening');t.after(()=>new Promise(resolve=>server.close(resolve)));
 const origin=`http://127.0.0.1:${server.address().port}`;
 for(const path of ['/','/privacy','/license','/support']){const r=await fetch(origin+path);assert.equal(r.status,200);assert.match(r.headers.get('content-security-policy'),/frame-ancestors 'none'/);const text=await r.text();assert.match(text,/隐私/);assert(!text.includes(f.env.ADMIN_TOKEN));assert.equal((await fetch(origin+path,{method:'HEAD'})).status,200);}
 const support=await(await fetch(origin+'/support')).text();assert.match(support,/github.com\/359392475-blue-sky\/lossless-system-audio-recorder\/issues/);assert.match(support,/公开页面/);assert.equal((await fetch(origin+'/support',{method:'POST'})).status,405);
});
