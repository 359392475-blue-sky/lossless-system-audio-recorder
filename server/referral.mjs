import { createHash, createHmac, createPublicKey, verify, sign, randomBytes } from 'node:crypto';
import { openSync, closeSync, readSync, fstatSync, statSync, createReadStream } from 'node:fs';
import { httpsURL } from './policy.mjs';

const product='lossless-system-audio-recorder', uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
class Failure extends Error { constructor(status,code){super(code);this.status=status;} }
const fail=(status,code)=>{throw new Failure(status,code);};
const escape=s=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function createReferrals(env,{db,key,now,currentPolicy}) {
  const fields=['REFERRAL_PUBLIC_ORIGIN','REFERRAL_DEVICE_PEPPER','REFERRAL_SERIES','REFERRAL_ARTIFACT_FILE','REFERRAL_ARTIFACT_SHA256'];
  const initialized=db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='referral_configuration'").get() && db.prepare('SELECT 1 FROM referral_configuration WHERE id=1').get();
  if(initialized && fields.some(k=>!env[k])) throw new Error('Initialized referrals require complete configuration');
  if(!fields.some(k=>env[k])) return {enabled:false,handle:async(req,res,u)=>{if(u.pathname==='/v1/referral'||u.pathname.startsWith('/r/')){reply(res,503,{error:'referral_not_configured'});return true;}return false;},stats(){return {status:'not_configured'};},close(){}};
  if(fields.some(k=>!env[k])) throw new Error('Incomplete referral configuration');
  const origin=new URL(httpsURL(env.REFERRAL_PUBLIC_ORIGIN));
  if(origin.pathname!=='/'||origin.search||Buffer.byteLength(env.REFERRAL_DEVICE_PEPPER)<32||!/^\d+\.\d+$/.test(env.REFERRAL_SERIES)||Number(env.RELEASE_ARTIFACT_BUILD)<6||!/^[a-f0-9]{64}$/.test(env.REFERRAL_ARTIFACT_SHA256)) throw new Error('Invalid referral configuration');
  const fd=openSync(env.REFERRAL_ARTIFACT_FILE,'r');
  let bytes, artifactStat;
  try {
    const stat=fstatSync(fd);bytes=stat.size;artifactStat=stat;
    if(!stat.isFile()||bytes<4)throw new Error('Invalid artifact');
    const chunk=Buffer.alloc(65536), hash=createHash('sha256');let offset=0,n;
    while((n=readSync(fd,chunk,0,chunk.length,offset))>0){if(offset===0&&!chunk.subarray(0,4).equals(Buffer.from([80,75,3,4])))throw new Error('Artifact must be ZIP');hash.update(chunk.subarray(0,n));offset+=n;}
    if(offset!==bytes||hash.digest('hex')!==env.REFERRAL_ARTIFACT_SHA256)throw new Error('Artifact digest mismatch');
  } catch(e){closeSync(fd);throw e;}
  closeSync(fd);
  db.exec(`BEGIN IMMEDIATE;
    CREATE TABLE IF NOT EXISTS referral_configuration(id INTEGER PRIMARY KEY CHECK(id=1),pepper_fingerprint TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS referral_devices(id TEXT PRIMARY KEY,hardware TEXT NOT NULL UNIQUE,activated INTEGER NOT NULL DEFAULT 0,qualified INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS referral_accounts(device TEXT NOT NULL,series TEXT NOT NULL,code TEXT NOT NULL UNIQUE,used INTEGER NOT NULL DEFAULT 0,qualified_count INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(device,series));
    CREATE TABLE IF NOT EXISTS referral_tickets(id TEXT PRIMARY KEY,inviter TEXT NOT NULL,series TEXT NOT NULL,expires INTEGER NOT NULL,delivered INTEGER NOT NULL DEFAULT 0,bound TEXT UNIQUE,qualified INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS referral_operations(device TEXT NOT NULL,series TEXT NOT NULL,id TEXT NOT NULL,state TEXT NOT NULL,PRIMARY KEY(device,series,id));
    CREATE TABLE IF NOT EXISTS referral_nonces(device TEXT NOT NULL,nonce TEXT NOT NULL,expires INTEGER NOT NULL,PRIMARY KEY(device,nonce));
    INSERT OR IGNORE INTO schema_version VALUES(2);COMMIT;`);
  const seconds=()=>Math.floor(now()/1000), hmac=(namespace,value)=>createHmac('sha256',env.REFERRAL_DEVICE_PEPPER).update(namespace+':'+value).digest('hex');
  const fingerprint=hmac('configuration',product),storedFingerprint=db.prepare('SELECT pepper_fingerprint FROM referral_configuration WHERE id=1').get();
  if(storedFingerprint && storedFingerprint.pepper_fingerprint!==fingerprint) throw new Error('Referral device pepper cannot be changed');
  db.prepare('INSERT OR IGNORE INTO referral_configuration VALUES(1,?)').run(fingerprint);
  function transaction(fn){db.exec('BEGIN IMMEDIATE');try{const v=fn();db.exec('COMMIT');return v;}catch(e){db.exec('ROLLBACK');throw e;}}
  function account(device,series){return db.prepare('SELECT * FROM referral_accounts WHERE device=? AND series=?').get(device,series);}
  function register(id,hardware,series){
    const old=db.prepare('SELECT * FROM referral_devices WHERE id=?').get(id);
    if(old&&old.hardware!==hardware)fail(409,'device_identity_mismatch');
    if(!old){if(db.prepare('SELECT id FROM referral_devices WHERE hardware=?').get(hardware))fail(409,'device_key_already_registered');db.prepare('INSERT INTO referral_devices(id,hardware) VALUES(?,?)').run(id,hardware);}
    if(!account(id,series))db.prepare('INSERT INTO referral_accounts(device,series,code) VALUES(?,?,?)').run(id,series,randomBytes(12).toString('base64url'));
  }
  function state(id,p){const issuedAt=seconds();const a=account(id,p.series),pending=db.prepare("SELECT id FROM referral_operations WHERE device=? AND series=? AND state='reserved' ORDER BY id").all(id,p.series).map(x=>x.id);return {schema:1,product,nonce:p.nonce,publicKey:p.publicKey,series:p.series,issuedAt,expiresAt:issuedAt+60,referralCode:a.code,shareURL:new URL('/r/'+a.code,origin).href,qualifiedCount:a.qualified_count,requiredCount:2,freeLimit:5,usedTrials:a.used,reservedTrials:pending.length,unlocked:a.qualified_count>=2,canRecord:a.qualified_count>=2||a.used+pending.length<5,pendingOperationIDs:pending,...(p.operationID?{operationID:p.operationID}:{})};}
  async function action(req,res){
    const body=await readJSON(req);if(!body||Object.keys(body).sort().join(',')!=='payload,signature')fail(400,'invalid_envelope');
    const raw=decode64(body.payload),signature=decode64(body.signature);if(raw.length>12000||signature.length!==64)fail(400,'invalid_envelope');
    let p;try{p=JSON.parse(raw);}catch{fail(400,'invalid_payload');}
    const allowed=['schema','product','action','publicKey','deviceHash','series','build','nonce','issuedAt','operationID','ticket'];
    if(!p||Array.isArray(p)||Object.keys(p).some(k=>!allowed.includes(k))||p.schema!==1||p.product!==product||!['status','claim','begin','complete','cancel'].includes(p.action)||typeof p.nonce!=='string'||!uuid.test(p.nonce)||!Number.isSafeInteger(p.issuedAt)||Math.abs(seconds()-p.issuedAt)>60||p.series!==env.REFERRAL_SERIES||!Number.isSafeInteger(p.build)||p.build<6||typeof p.deviceHash!=='string'||!/^([a-fA-F0-9]{64})$/.test(p.deviceHash))fail(400,'invalid_payload');
    const operation=['begin','complete','cancel'].includes(p.action);
    if(operation?(typeof p.operationID!=='string'||!uuid.test(p.operationID)):p.operationID!==undefined)fail(400,'invalid_operation');
    if(p.action==='claim'?(typeof p.ticket!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(p.ticket)):p.ticket!==undefined)fail(400,'invalid_ticket');
    const pub=decode64(p.publicKey);if(pub.length!==32)fail(400,'invalid_public_key');
    const publicKey=createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),pub]),format:'der',type:'spki'});
    if(!verify(null,raw,publicKey,signature))fail(401,'invalid_signature');
    const id=hmac('key',p.publicKey),hardware=hmac('hardware',p.deviceHash.toLowerCase());
    transaction(()=>{db.prepare('DELETE FROM referral_nonces WHERE expires<?').run(seconds());if(db.prepare('SELECT 1 FROM referral_nonces WHERE device=? AND nonce=?').get(id,p.nonce))fail(409,'replayed_nonce');db.prepare('INSERT INTO referral_nonces VALUES(?,?,?)').run(id,p.nonce,seconds()+120);});
    const policy = p.action === 'begin' ? currentPolicy() : null;
    const result=transaction(()=>{
      register(id,hardware,p.series);
      if(p.action==='claim'){
        const ticket=db.prepare('SELECT * FROM referral_tickets WHERE id=?').get(hmac('ticket',p.ticket));
        const device=db.prepare('SELECT * FROM referral_devices WHERE id=?').get(id);
        if(!ticket||ticket.expires<seconds()||ticket.series!==p.series)fail(409,'ticket_expired_or_unknown');
        if(!ticket.delivered)fail(409,'download_not_completed');
        if(ticket.inviter===id)fail(409,'self_invite');
        if(ticket.bound===id)return state(id,p);
        if(device.activated||device.qualified)fail(409,'device_already_activated');
        if(ticket.bound||db.prepare('SELECT 1 FROM referral_tickets WHERE bound=?').get(id))fail(409,'ticket_already_bound');
        db.prepare('UPDATE referral_tickets SET bound=? WHERE id=? AND bound IS NULL').run(id,ticket.id);
      }
      if(operation){
        const op=db.prepare('SELECT state FROM referral_operations WHERE device=? AND series=? AND id=?').get(id,p.series,p.operationID);
        if(p.action==='begin'){
          if(p.build<policy.minimumBuild&&(policy.level===4||(policy.level===3&&seconds()>=policy.effectiveAt)))fail(403,'upgrade_required');
          if(op&&op.state!=='reserved')fail(409,'operation_finalized');
          if(!op){if(!state(id,p).canRecord)fail(403,'trial_limit_reached');db.prepare("INSERT INTO referral_operations VALUES(?,?,?,'reserved')").run(id,p.series,p.operationID);}
        }else if(p.action==='cancel'){
          if(!op)db.prepare("INSERT INTO referral_operations VALUES(?,?,?,'cancelled')").run(id,p.series,p.operationID);
          if(op?.state==='completed')fail(409,'operation_finalized');
          db.prepare("UPDATE referral_operations SET state='cancelled' WHERE device=? AND series=? AND id=?").run(id,p.series,p.operationID);
        }else{
          if(!op||op.state==='cancelled')fail(409,'unknown_operation');
          if(op.state==='reserved'){
            db.prepare("UPDATE referral_operations SET state='completed' WHERE device=? AND series=? AND id=?").run(id,p.series,p.operationID);
            db.prepare('UPDATE referral_accounts SET used=used+1 WHERE device=? AND series=?').run(id,p.series);
            db.prepare('UPDATE referral_devices SET activated=1 WHERE id=?').run(id);
            const ticket=db.prepare('SELECT * FROM referral_tickets WHERE bound=? AND qualified=0 AND delivered=1').get(id);
            if(ticket&&ticket.expires>=seconds()&&!db.prepare('SELECT qualified FROM referral_devices WHERE id=?').get(id).qualified){
              db.prepare('UPDATE referral_devices SET qualified=1 WHERE id=?').run(id);db.prepare('UPDATE referral_tickets SET qualified=1 WHERE id=?').run(ticket.id);db.prepare('UPDATE referral_accounts SET qualified_count=qualified_count+1 WHERE device=? AND series=?').run(ticket.inviter,ticket.series);
            }
          }
        }
      }
      return state(id,p);
    });
    const payload=Buffer.from(JSON.stringify(result));reply(res,200,{payload:payload.toString('base64'),signature:sign(null,payload,key).toString('base64')});
  }
  async function handle(req,res,u){
    if(u.pathname!=='/v1/referral'&&!u.pathname.startsWith('/r/'))return false;
    try{
      if(u.pathname==='/v1/referral'){if(req.method!=='POST')fail(405,'method_not_allowed');await action(req,res);return true;}
      if(u.pathname==='/r/download'){
        if(req.method!=='GET'&&req.method!=='HEAD')fail(405,'method_not_allowed');
        const value=u.searchParams.get('ticket');if(!/^[A-Za-z0-9_-]{43}$/.test(value??'')||u.searchParams.size!==1)fail(400,'invalid_ticket');
        const ticket=db.prepare('SELECT * FROM referral_tickets WHERE id=?').get(hmac('ticket',value));
        if(!ticket||ticket.expires<seconds())fail(409,'ticket_expired_or_unknown');
        if(req.headers.range)fail(416,'range_not_supported');
        const stat=statSync(env.REFERRAL_ARTIFACT_FILE);if(stat.size!==bytes||stat.ino!==artifactStat.ino||stat.dev!==artifactStat.dev||stat.mtimeMs!==artifactStat.mtimeMs)fail(503,'artifact_changed');
        res.writeHead(200,{'Content-Type':'application/zip','Content-Length':bytes,'Content-Disposition':'attachment; filename="LosslessRecorder.zip"','Cache-Control':'no-store','Referrer-Policy':'no-referrer'});
        if(req.method==='HEAD'){res.end();return true;}
        const stream=createReadStream(env.REFERRAL_ARTIFACT_FILE,{start:0,end:bytes-1}),hash=createHash('sha256');let sent=0,ended=false;
        stream.on('data',chunk=>{sent+=chunk.length;hash.update(chunk);});stream.on('end',()=>{ended=true;});stream.on('error',()=>res.destroy());res.on('close',()=>stream.destroy());
        res.on('finish',()=>{try{if(ended&&sent===bytes&&hash.digest('hex')===env.REFERRAL_ARTIFACT_SHA256)db.prepare('UPDATE referral_tickets SET delivered=1 WHERE id=? AND expires>=?').run(ticket.id,seconds());}catch{}});
        stream.pipe(res);return true;
      }
      const match=/^\/r\/([A-Za-z0-9_-]{16})(\/ticket)?$/.exec(u.pathname);if(!match)fail(404,'not_found');
      const a=db.prepare('SELECT * FROM referral_accounts WHERE code=?').get(match[1]);if(!a||a.series!==env.REFERRAL_SERIES)fail(404,'invalid_referral_code');
      if(match[2]){
        if(req.method!=='POST')fail(405,'method_not_allowed');
        const token=randomBytes(32).toString('base64url');db.prepare('INSERT INTO referral_tickets(id,inviter,series,expires) VALUES(?,?,?,?)').run(hmac('ticket',token),a.device,a.series,seconds()+7*86400);
        const downloadURL=new URL('/r/download?ticket='+token,origin).href,activationURL='lossless-recorder://activate?ticket='+token;
        if(req.headers.accept?.includes('application/json'))reply(res,200,{ticket:token,downloadURL,activationURL,expiresAt:seconds()+7*86400});
        else html(res,`<h1>下载并激活</h1><p>请完整下载、安装并打开应用，再点击激活。邀请凭证七天内有效，仅可绑定一台新设备。</p><p><a href="${escape(downloadURL)}">1. 下载录音机 ZIP</a></p><p><a href="${escape(activationURL)}">2. 安装后打开录音机并激活邀请</a></p><p>若系统无法打开，请在应用中手动粘贴以下凭证：</p><textarea readonly rows="3">${token}</textarea><p>首次成功录音后才计入邀请；下载安装本身不解锁奖励。</p><nav><a href="/privacy">隐私说明</a> · <a href="/license">使用许可</a> · <a href="/support">反馈与权益帮助</a></nav>`);
      }else{if(req.method!=='GET'&&req.method!=='HEAD')fail(405,'method_not_allowed');html(res,`<h1>无损系统录音机</h1><p>好友邀请你试用。免登录，可完成五次成功录音；邀请两台新设备完整下载并首次成功录音，可解锁 ${escape(a.series)} 系列无限免费使用，仍需联网验证和升级。</p><form method="post" action="/r/${a.code}/ticket"><button>生成下载与激活凭证</button></form><p>会使用去标识化设备摘要和安装密钥去重；录音留在本机，应用服务不保存 IP，但网络托管方能接触连接信息。凭证七天有效。</p><nav><a href="/privacy">隐私说明</a> · <a href="/license">使用许可</a> · <a href="/support">反馈与权益帮助</a></nav>`,req.method==='HEAD');}
    }catch(e){if(!res.headersSent)reply(res,e instanceof Failure?e.status:503,{error:e instanceof Failure?e.message:'referral_unavailable'});else res.destroy();}
    return true;
  }
  function stats(){
    const tickets=db.prepare('SELECT COUNT(*) inviteTickets,COALESCE(SUM(delivered),0) deliveredTickets,COALESCE(SUM(qualified),0) qualifiedInvites FROM referral_tickets').get();
    const devices=db.prepare('SELECT COALESCE(SUM(activated),0) activatedDevices FROM referral_devices').get();
    const accounts=db.prepare('SELECT COUNT(*) unlockedDeviceSeries FROM referral_accounts WHERE qualified_count>=2').get();
    const bySeries=db.prepare('SELECT series,COUNT(*) registeredDeviceSeries,COALESCE(SUM(qualified_count>=2),0) unlockedDeviceSeries FROM referral_accounts GROUP BY series ORDER BY series').all();
    return {status:'available',...tickets,...devices,...accounts,bySeries,deliveryMeaning:'Server finished sending complete SHA256-matched artifact; not proof of client save or install'};
  }
  function ready(){const stat=statSync(env.REFERRAL_ARTIFACT_FILE);if(stat.size!==bytes||stat.ino!==artifactStat.ino||stat.dev!==artifactStat.dev||stat.mtimeMs!==artifactStat.mtimeMs)throw new Error('Artifact changed');db.prepare('SELECT 1 FROM referral_configuration WHERE id=1').get();}
  return {enabled:true,handle,stats,ready,close(){}};
}
function reply(res,status,value){res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store','Referrer-Policy':'no-referrer'});res.end(JSON.stringify(value));}
function html(res,body,head=false){res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",'Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'});res.end(head?undefined:`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>无损系统录音机邀请</title><body style="font:18px system-ui;max-width:680px;margin:60px auto;padding:24px;line-height:1.7">${body}</body></html>`);}
function decode64(s){if(typeof s!=='string'||s.length>20000)fail(400,'invalid_base64');const b=Buffer.from(s,'base64');if(b.toString('base64')!==s)fail(400,'invalid_base64');return b;}
async function readJSON(req){let bytes=0;const chunks=[];for await(const chunk of req){bytes+=chunk.length;if(bytes>20000)fail(400,'body_too_large');chunks.push(chunk);}try{return JSON.parse(Buffer.concat(chunks));}catch{fail(400,'invalid_json');}}
