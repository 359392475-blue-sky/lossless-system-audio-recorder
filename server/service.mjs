import { createServer } from 'node:http';
import { createPrivateKey, sign, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { readPolicy, httpsURL } from './policy.mjs';
import { createReferrals } from './referral.mjs';

export function createService(env, { fetchImpl = fetch, now = () => Date.now() } = {}) {
  for (const k of ['POLICY_FILE','POLICY_PRIVATE_KEY_FILE','STATS_DB','ADMIN_TOKEN','RELEASE_ARTIFACT_URL','RELEASE_ARTIFACT_BUILD']) if (!env[k]) throw new Error(`Required configuration: ${k}`);
  if (Buffer.byteLength(env.ADMIN_TOKEN) < 32) throw new Error('ADMIN_TOKEN requires at least 32 bytes');
  const artifact = httpsURL(env.RELEASE_ARTIFACT_URL);
  const artifactBuild = Number(env.RELEASE_ARTIFACT_BUILD);
  if (!/^[1-9][0-9]*$/.test(env.RELEASE_ARTIFACT_BUILD) || !Number.isSafeInteger(artifactBuild) || artifactBuild < 5) throw new Error('RELEASE_ARTIFACT_BUILD must be an integer >= 5');
  const downloadEntry = httpsURL(env.RELEASE_DOWNLOAD_URL || artifact);
  if (/\/latest(?:\/|$)|\/releases\/latest(?:\/|$)/i.test(new URL(artifact).pathname)) throw new Error('Use a pinned release artifact URL');
  const key = createPrivateKey(readFileSync(env.POLICY_PRIVATE_KEY_FILE));
  if (key.asymmetricKeyType !== 'ed25519') throw new Error('Ed25519 private key required');
  if (env.GITHUB_REPOSITORY && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(env.GITHUB_REPOSITORY)) throw new Error('Invalid GitHub repository');
  readPolicy(env.POLICY_FILE);
  const db = new DatabaseSync(env.STATS_DB);
  db.exec('PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS schema_version(version INTEGER PRIMARY KEY); INSERT OR IGNORE INTO schema_version VALUES(1); CREATE TABLE IF NOT EXISTS policy_state(id INTEGER PRIMARY KEY CHECK(id=1), sequence INTEGER NOT NULL, canonical TEXT NOT NULL); CREATE TABLE IF NOT EXISTS download_entry_requests(day TEXT NOT NULL,channel TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(day,channel));');
  if (db.prepare('SELECT MAX(version) AS version FROM schema_version').get().version > 2) { db.close(); throw new Error('Unsupported database schema'); }
  function currentPolicy() {
    const p = readPolicy(env.POLICY_FILE), canonical = JSON.stringify(p);
    if (p.latestBuild !== artifactBuild || p.minimumBuild > artifactBuild) throw new Error('Policy requires a different release artifact build');
    if (httpsURL(p.downloadURL) !== downloadEntry) throw new Error('Policy download URL does not match configured release entry');
    db.exec('BEGIN IMMEDIATE');
    try {
      const prev = db.prepare('SELECT sequence,canonical FROM policy_state WHERE id=1').get();
      if (prev && (p.sequence < prev.sequence || (p.sequence === prev.sequence && canonical !== prev.canonical))) throw new Error('Policy sequence rollback or reuse');
      db.prepare('INSERT INTO policy_state VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET sequence=excluded.sequence,canonical=excluded.canonical').run(p.sequence,canonical);
      db.exec('COMMIT'); return p;
    } catch (e) { db.exec('ROLLBACK'); throw e; }
  }
  try { currentPolicy(); } catch (e) { db.close(); throw e; }
  let referrals;
  try { referrals = createReferrals(env,{db,key,now,currentPolicy}); } catch(e) { db.close(); throw e; }
  const increment = db.prepare('INSERT INTO download_entry_requests VALUES(?,?,1) ON CONFLICT(day,channel) DO UPDATE SET count=count+1');
  const token = Buffer.from(`Bearer ${env.ADMIN_TOKEN}`);
  async function githubStats() {
    if (!env.GITHUB_REPOSITORY) return {status:'not_configured',metric:'github_asset_download_count'};
    try {
      const assets = [];
      for (let page=1; page<=100; page++) {
        const headers = {Accept:'application/vnd.github+json','X-GitHub-Api-Version':'2026-03-10','User-Agent':'lossless-recorder-stats'};
        if (env.GITHUB_TOKEN) headers.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
        const response = await fetchImpl(`https://api.github.com/repos/${env.GITHUB_REPOSITORY}/releases?per_page=100&page=${page}`, {headers,signal:AbortSignal.timeout(10000),redirect:'error'});
        if (!response.ok) throw new Error('GitHub unavailable');
        const releases = await response.json();
        if (!Array.isArray(releases)) throw new Error('Invalid GitHub response');
        for (const release of releases) {
          if (release.draft) continue;
          if (!Array.isArray(release.assets)) throw new Error('Invalid assets');
          for (const a of release.assets) {
            if (!Number.isSafeInteger(a.download_count) || a.download_count < 0 || !Number.isSafeInteger(a.id) || typeof a.name !== 'string') throw new Error('Invalid asset count');
            assets.push({release:release.tag_name,assetID:a.id,name:a.name,download_count:a.download_count});
          }
        }
        if (releases.length < 100) return {status:'available',metric:'github_asset_download_count',assets};
      }
      throw new Error('GitHub pagination limit');
    } catch { return {status:'unavailable',metric:'github_asset_download_count'}; }
  }
  function json(res,status,value,head=false) { res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}); res.end(head ? undefined : JSON.stringify(value)); }
  const server = createServer(async (req,res) => {
    try {
      const u = new URL(req.url,'http://localhost');
      const head = req.method === 'HEAD';
      if (await referrals.handle(req,res,u)) return;
      if (!['GET','HEAD'].includes(req.method)) return json(res,405,{error:'method_not_allowed'});
      if (u.pathname === '/health') return json(res,200,{status:'alive'},head);
      if (u.pathname === '/ready') { currentPolicy(); return json(res,200,{status:'ready'},head); }
      if (u.pathname === '/v1/policy') {
        const build = u.searchParams.get('build'), nonce = u.searchParams.get('nonce');
        if ([...u.searchParams.keys()].some(k => !['build','nonce'].includes(k)) || u.searchParams.getAll('build').length !== 1 || u.searchParams.getAll('nonce').length !== 1 || !/^[1-9][0-9]*$/.test(build ?? '') || !Number.isSafeInteger(Number(build)) || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(nonce ?? '')) return json(res,400,{error:'invalid_request'},head);
        let p = currentPolicy();
        if (referrals.enabled && Number(build) < 6) {
          p = {...p,level:4,minimumBuild:Math.max(6,p.minimumBuild),title:'请升级以继续使用',message:'当前版本不支持录音试用与邀请权益验证。请下载安装最新版本后继续录音；已有录音仍可保存。'};
        }
        const issuedAt = Math.floor(now()/1000);
        const payload = Buffer.from(JSON.stringify({...p,nonce,clientBuild:Number(build),issuedAt,expiresAt:issuedAt+60}));
        return json(res,200,{payload:payload.toString('base64'),signature:sign(null,payload,key).toString('base64')},head);
      }
      if (u.pathname === '/download') {
        const channel = u.searchParams.get('channel');
        if (u.searchParams.getAll('channel').length !== 1 || [...u.searchParams.keys()].some(k=>k!=='channel') || !['website','github','other'].includes(channel)) return json(res,400,{error:'invalid_channel'},head);
        currentPolicy();
        if (!head) increment.run(new Date(now()).toISOString().slice(0,10),channel);
        res.writeHead(302,{Location:artifact,'Cache-Control':'no-store'}); return res.end();
      }
      if (u.pathname === '/admin/stats') {
        const supplied = Buffer.from(req.headers.authorization ?? '');
        // Compare equal-sized buffers even for a wrong-length token.
        const equal = timingSafeEqual(token,supplied.length === token.length ? supplied : Buffer.alloc(token.length));
        if (!equal || supplied.length !== token.length) return json(res,401,{error:'unauthorized'},head);
        const rows = db.prepare('SELECT day,channel,count FROM download_entry_requests ORDER BY day,channel').all();
        return json(res,200,{download_entry_requests:{timezone:'UTC',meaning:'Successful download entry redirects; not completed downloads or unique users',rows},referrals:referrals.stats(),github:head ? {status:'not_requested'} : await githubStats(),aggregation:'Do not add the two metrics'},head);
      }
      return json(res,404,{error:'not_found'},head);
    } catch { if (!res.headersSent) json(res,503,{error:'service_unavailable'}); else res.end(); }
  });
  server.on('close',()=>{referrals.close();db.close();});
  return server;
}
