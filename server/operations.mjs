import { DatabaseSync,backup } from 'node:sqlite';
import { createHash,randomUUID } from 'node:crypto';
import { existsSync,readFileSync,writeFileSync,chmodSync,copyFileSync,constants,unlinkSync,lstatSync,openSync,closeSync,readSync } from 'node:fs';
import { dirname,isAbsolute } from 'node:path';

function requirePrivateDir(path){if(!isAbsolute(path))throw new Error('Absolute path required');const s=lstatSync(dirname(path));if(!s.isDirectory()||s.isSymbolicLink()||(s.mode&0o777)!==0o700)throw new Error('Destination directory requires 0700');}
function absent(path){if([path,path+'-wal',path+'-shm',path+'.manifest.json'].some(existsSync))throw new Error('Destination exists; refusing replacement');requirePrivateDir(path);}
function digest(path){const fd=openSync(path,'r'),buffer=Buffer.alloc(65536),hash=createHash('sha256');try{let n;while((n=readSync(fd,buffer,0,buffer.length,null))>0)hash.update(buffer.subarray(0,n));return hash.digest('hex');}finally{closeSync(fd);}}
function summary(db){
 const integrity=db.prepare('PRAGMA integrity_check').all();if(integrity.length!==1||Object.values(integrity[0])[0]!=='ok')throw new Error('SQLite integrity verification failed');
 const version=db.prepare('SELECT MAX(version) version FROM schema_version').get().version;if(![1,2].includes(version))throw new Error('Unsupported database schema');
 const sequence=db.prepare('SELECT MAX(sequence) sequence FROM policy_state').get().sequence??null;
 const counters=db.prepare('SELECT COALESCE(SUM(count),0) downloadEntries FROM download_entry_requests').get();
 const tables=db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(x=>x.name);
 const counts={};for(const table of ['referral_devices','referral_accounts','referral_operations','referral_tickets','referral_admin_audit'])if(tables.includes(table))counts[table]=db.prepare(`SELECT COUNT(*) count FROM ${table}`).get().count;
 return {schema:version,policySequence:sequence,...counters,counts};
}
export async function onlineBackup(source,destination){
 absent(destination);const temp=destination+'.'+randomUUID()+'.tmp';let db;
 try{db=new DatabaseSync(source,{readOnly:true});await backup(db,temp);chmodSync(temp,0o600);const snapshot=new DatabaseSync(temp);let state;try{snapshot.exec('PRAGMA journal_mode=DELETE');state=summary(snapshot);}finally{snapshot.close();}
 const manifest={schema:1,createdAt:new Date().toISOString(),sha256:digest(temp),state};
 // Exclusive hard copy prevents a concurrent backup from overwriting a winning destination.
 copyFileSync(temp,destination,constants.COPYFILE_EXCL);chmodSync(destination,0o600);writeFileSync(destination+'.manifest.json',JSON.stringify(manifest,null,2)+'\n',{flag:'wx',mode:0o600});return manifest;
 }finally{db?.close();for(const path of [temp,temp+'-wal',temp+'-shm'])try{unlinkSync(path);}catch{}}
}
export function verifyBackup(path){
 const manifest=JSON.parse(readFileSync(path+'.manifest.json','utf8'));if(manifest.schema!==1||manifest.sha256!==digest(path))throw new Error('Backup digest mismatch');
 const db=new DatabaseSync(path,{readOnly:true});try{const actual=summary(db);if(JSON.stringify(actual)!==JSON.stringify(manifest.state))throw new Error('Backup state mismatch');return actual;}finally{db.close();}
}
export function restoreBackup(source,destination){
 absent(destination);const state=verifyBackup(source);copyFileSync(source,destination,constants.COPYFILE_EXCL);chmodSync(destination,0o600);
 const db=new DatabaseSync(destination,{readOnly:true});try{if(JSON.stringify(summary(db))!==JSON.stringify(state))throw new Error('Restored state mismatch');}finally{db.close();}return state;
}
const handle=row=>createHash('sha256').update(row.device+'\0'+row.series+'\0'+row.id).digest('hex');
export function listReservations(path){const db=new DatabaseSync(path,{readOnly:true});try{return db.prepare("SELECT device,series,id,state FROM referral_operations WHERE state='reserved' ORDER BY series,id LIMIT 1000").all().map(row=>({handle:handle(row),series:row.series,operationID:row.id,state:row.state}));}finally{db.close();}}
export function cancelReservation(path,target,{operator,reason,confirmed}){
 if(!confirmed||!/^[a-f0-9]{64}$/.test(target)||!/^[A-Za-z0-9_.-]{1,64}$/.test(operator)||!['confirmed_process_ended','user_confirmed_abandoned','incident_recovery'].includes(reason))throw new Error('Explicit confirmation, operator and allowed reason required');
 const db=new DatabaseSync(path);db.exec('PRAGMA busy_timeout=5000;BEGIN IMMEDIATE');
 try{
 let row;for(const candidate of db.prepare('SELECT device,series,id,state FROM referral_operations').iterate())if(handle(candidate)===target){row=candidate;break;}if(!row)throw new Error('Reservation not found');if(row.state!=='reserved')throw new Error('Reservation already finalized; no refund allowed');
 db.exec('CREATE TABLE IF NOT EXISTS referral_admin_audit(id TEXT PRIMARY KEY,created_at INTEGER NOT NULL,operator TEXT NOT NULL,reason TEXT NOT NULL,operation_handle TEXT NOT NULL,previous_state TEXT NOT NULL,next_state TEXT NOT NULL)');
 const result=db.prepare("UPDATE referral_operations SET state='cancelled' WHERE device=? AND series=? AND id=? AND state='reserved'").run(row.device,row.series,row.id);if(result.changes!==1)throw new Error('Reservation changed concurrently');
 db.prepare("INSERT INTO referral_admin_audit VALUES(?,?,?,?,?,'reserved','cancelled')").run(randomUUID(),Math.floor(Date.now()/1000),operator,reason,target);
 db.exec('COMMIT');return {handle:target,series:row.series,state:'cancelled',usedTrialsChanged:false};
 }catch(e){db.exec('ROLLBACK');throw e;}finally{db.close();}
}
