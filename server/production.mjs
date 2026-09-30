import { lstatSync,readFileSync,openSync,closeSync,existsSync } from 'node:fs';
import { dirname,isAbsolute } from 'node:path';
import { createPublicKey } from 'node:crypto';

function privatePath(path,directory=false){
  if(!path||!isAbsolute(path))throw new Error('Production paths must be absolute');
  const stat=lstatSync(path);
  if(stat.isSymbolicLink()||(directory?!stat.isDirectory():!stat.isFile())||(stat.mode&0o777)!==(directory?0o700:0o600))throw new Error('Production private paths require directory 0700 / file 0600');
}
export function validateProduction(env){
  if(env.NODE_ENV!=='production')return;
  if(['ADMIN_TOKEN','REFERRAL_DEVICE_PEPPER','RELEASE_ARTIFACT_URL','REFERRAL_PUBLIC_ORIGIN'].some(k=>/REPLACE|example\.invalid/i.test(env[k]||'')))throw new Error('Production placeholder configuration rejected');
  if(env.HOST && env.HOST!=='127.0.0.1')throw new Error('Production service must bind loopback');
  for(const key of ['REFERRAL_PUBLIC_ORIGIN','REFERRAL_DEVICE_PEPPER','REFERRAL_SERIES','REFERRAL_ARTIFACT_FILE','REFERRAL_ARTIFACT_SHA256','RELEASE_MANIFEST_FILE'])if(!env[key])throw new Error('Production referral and release manifest configuration required');
  for(const key of ['POLICY_FILE','POLICY_PRIVATE_KEY_FILE','REFERRAL_ARTIFACT_FILE','RELEASE_MANIFEST_FILE'])privatePath(env[key]);
  for(const directory of new Set(['POLICY_FILE','POLICY_PRIVATE_KEY_FILE','STATS_DB','REFERRAL_ARTIFACT_FILE','RELEASE_MANIFEST_FILE'].map(k=>dirname(env[k]||''))))privatePath(directory,true);
  for(const path of [env.STATS_DB,env.STATS_DB+'-wal',env.STATS_DB+'-shm'])if(existsSync(path))privatePath(path);
  const manifest=JSON.parse(readFileSync(env.RELEASE_MANIFEST_FILE,'utf8'));
  const expected=['schema','product','version','build','sha256','bytes','bundleID','policyPublicKey','signingTeamID','notarizationID'];
  if(!manifest||Object.keys(manifest).sort().join(',')!==expected.sort().join(',')||manifest.schema!==1||manifest.product!=='lossless-system-audio-recorder'||typeof manifest.version!=='string'||!/^\d+\.\d+\.\d+$/.test(manifest.version)||manifest.version.split('.').slice(0,2).join('.')!==env.REFERRAL_SERIES||manifest.build!==Number(env.RELEASE_ARTIFACT_BUILD)||manifest.build<6||manifest.sha256!==env.REFERRAL_ARTIFACT_SHA256||manifest.bytes!==lstatSync(env.REFERRAL_ARTIFACT_FILE).size||!Number.isSafeInteger(manifest.bytes)||manifest.bytes<4||manifest.bundleID!=='app.lowpower.lossless-system-audio-recorder'||!/^[A-Z0-9]{10}$/.test(manifest.signingTeamID)||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(manifest.notarizationID))throw new Error('Production release manifest mismatch');
  const pub=createPublicKey(readFileSync(env.POLICY_PRIVATE_KEY_FILE)).export({format:'der',type:'spki'}).subarray(-32).toString('base64');
  if(manifest.policyPublicKey!==pub)throw new Error('Release manifest policy public key mismatch');
}
export function createPrivateDatabaseFile(path){
  try{const fd=openSync(path,'wx',0o600);closeSync(fd);}catch(e){if(e.code!=='EEXIST')throw e;}
}
