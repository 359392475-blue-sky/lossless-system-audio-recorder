// Local-only operational checks. Emits aggregate status, never credentials or device IDs.
import { statfsSync,readdirSync,statSync } from 'node:fs';
import { join } from 'node:path';
import { onlineBackup,verifyBackup } from './operations.mjs';
export async function checkHealth(env,{fetchImpl=fetch,now=Date.now()}={}){
 const port=Number(env.PORT||8787);
 if(!Number.isInteger(port)||port<1||port>65535||!env.BACKUP_DIR)throw new Error('Invalid operations configuration');
 const r=await fetchImpl(`http://127.0.0.1:${port}/ready`,{signal:AbortSignal.timeout(10000),redirect:'error'});
 if(r.status!==200||(await r.json()).status!=='ready')throw new Error('Service not ready');
 const disk=statfsSync(env.BACKUP_DIR),freeBytes=disk.bavail*disk.bsize;
 if(freeBytes<1024**3)throw new Error('Less than 1 GiB available');
 const candidates=readdirSync(env.BACKUP_DIR).filter(x=>/^scheduled-.*\.sqlite$/.test(x)).map(x=>({path:join(env.BACKUP_DIR,x),time:statSync(join(env.BACKUP_DIR,x)).mtimeMs})).sort((a,b)=>b.time-a.time);
 if(!candidates.length||now-candidates[0].time>36*3600*1000)throw new Error('Verified backup missing or older than 36 hours');
 verifyBackup(candidates[0].path);
 return {status:'healthy',ready:true,backupVerified:true,freeBytes,backupAgeSeconds:Math.max(0,Math.floor((now-candidates[0].time)/1000)),publicDeploymentVerified:false};
}
export async function scheduledBackup(env){
 if(!env.STATS_DB||!env.BACKUP_DIR)throw new Error('Database and backup directory required');
 const destination=join(env.BACKUP_DIR,`scheduled-${new Date().toISOString().replaceAll(':','-')}.sqlite`);
 const manifest=await onlineBackup(env.STATS_DB,destination);verifyBackup(destination);
 return {status:'backup_verified',createdAt:manifest.createdAt,policySequence:manifest.state.policySequence};
}
