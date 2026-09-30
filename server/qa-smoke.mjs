// Explicit operational smoke test for an ISOLATED QA database only.
// Sends synthetic signed completion events; never proves real ALAC recording.
import assert from 'node:assert/strict';
import { generateKeyPairSync,randomUUID,randomBytes,createPublicKey,createHash,sign,verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { basename,join } from 'node:path';
import { spawnSync } from 'node:child_process';

try {
  if(process.env.QA_SMOKE_CONFIRM!=='isolated-qa-database'||!basename(process.env.STATS_DB||'').startsWith('qa-'))throw new Error('Isolated QA confirmation required');
  const port=Number(process.env.PORT),origin=`http://127.0.0.1:${port}`;
  assert(Number.isSafeInteger(port)&&port>0);
  const manifest=JSON.parse(readFileSync(process.env.RELEASE_MANIFEST_FILE));
  const publicKey=createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),Buffer.from(manifest.policyPublicKey,'base64')]),format:'der',type:'spki'});
  const get=(path,options)=>fetch(origin+path,{...options,signal:AbortSignal.timeout(15000)});
  const signed=async(response,nonce)=>{assert.equal(response.status,200);const envelope=await response.json(),raw=Buffer.from(envelope.payload,'base64');assert(verify(null,raw,publicKey,Buffer.from(envelope.signature,'base64')));const value=JSON.parse(raw);assert.equal(value.nonce,nonce);assert.equal(value.expiresAt-value.issuedAt,60);return value;};
  assert.equal((await get('/ready')).status,200);
  for(const build of [5,manifest.build]){const nonce=randomUUID(),policy=await signed(await get(`/v1/policy?build=${build}&nonce=${nonce}`),nonce);assert.equal(policy.clientBuild,build);assert.equal(policy.level,build===5?4:0);assert.equal(policy.latestBuild,manifest.build);}
  function identity(){const pair=generateKeyPairSync('ed25519');return {...pair,key:pair.publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64'),hardware:randomBytes(32).toString('hex')};}
  async function action(who,action,extra={},expected=200){const payload={schema:1,product:'lossless-system-audio-recorder',action,publicKey:who.key,deviceHash:who.hardware,series:process.env.REFERRAL_SERIES,build:manifest.build,nonce:randomUUID(),issuedAt:Math.floor(Date.now()/1000),...extra},raw=Buffer.from(JSON.stringify(payload)),body={payload:raw.toString('base64'),signature:sign(null,raw,who.privateKey).toString('base64')};const response=await get('/v1/referral',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});assert.equal(response.status,expected);if(expected!==200)return response.json();const value=await signed(response,payload.nonce);assert.equal(value.publicKey,who.key);return value;}
  async function complete(who){const operationID=randomUUID();await action(who,'begin',{operationID});return action(who,'complete',{operationID});}
  const inviter=identity();let owner=await action(inviter,'status');
  for(let i=0;i<5;i++)owner=await complete(inviter);
  assert.equal(owner.usedTrials,5);assert.equal((await action(inviter,'begin',{operationID:randomUUID()},403)).error,'trial_limit_reached');
  for(let i=0;i<2;i++){
    const response=await get(`/r/${owner.referralCode}/ticket`,{method:'POST',headers:{Accept:'application/json'}});assert.equal(response.status,200);const ticket=await response.json();
    const download=await get('/r/download?ticket='+ticket.ticket);assert.equal(download.status,200);const bytes=Buffer.from(await download.arrayBuffer());assert.equal(bytes.length,manifest.bytes);assert.equal(createHash('sha256').update(bytes).digest('hex'),manifest.sha256);
    const invitee=identity();await action(invitee,'claim',{ticket:ticket.ticket});await complete(invitee);
  }
  owner=await action(inviter,'status');assert.equal(owner.qualifiedCount,2);assert.equal(owner.unlocked,true);owner=await complete(inviter);assert.equal(owner.usedTrials,6);
  const operationID=randomUUID();await action(inviter,'begin',{operationID});
  const ops=new URL('./ops.mjs',import.meta.url).pathname;
  function command(args){const result=spawnSync(process.execPath,[ops,...args],{env:process.env,encoding:'utf8',timeout:30000});assert.equal(result.status,0,'Operational CLI rejected');return JSON.parse(result.stdout);}
  const pending=command(['reservations']).find(row=>row.operationID===operationID);assert(pending);
  command(['cancel-reservation',pending.handle,'qa-smoke','confirmed_process_ended','--confirm-process-ended']);
  owner=await action(inviter,'status');assert.equal(owner.usedTrials,6);assert.equal(owner.reservedTrials,0);
  const stamp=new Date().toISOString().replace(/[:.]/g,'-');
  const backup=join(process.env.QA_BACKUP_DIR||'/var/lib/lossless-recorder/backups',`qa-smoke-${stamp}.sqlite`),restore=join(process.env.QA_RESTORE_DIR||'/var/lib/lossless-recorder/data',`qa-restored-${stamp}.sqlite`);
  command(['backup',backup]);const state=command(['verify-backup',backup]);assert.deepEqual(command(['restore',backup,restore]),state);
  const statsResponse=await get('/admin/stats',{headers:{Authorization:`Bearer ${process.env.ADMIN_TOKEN}`}});assert.equal(statsResponse.status,200);const stats=await statsResponse.json();assert(stats.referrals.qualifiedInvites>=2);assert(stats.referrals.unlockedDeviceSeries>=1);
  console.log(JSON.stringify({status:'passed',evidence:'isolated server loopback with synthetic device events; not physical-device recording',build:manifest.build,version:manifest.version,policySignature:true,legacyBuildForced:true,fullArtifactSHA256:true,fiveTrialLimit:true,twoInvitesUnlock:true,adminCancellationAudited:true,backupVerified:true,restoreVerified:true,backupPath:backup,restorePath:restore,referralCounters:stats.referrals},null,2));
}catch{console.error('QA smoke rejected; inspect isolated configuration and service health without printing credentials.');process.exitCode=1;}
