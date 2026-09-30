import { onlineBackup,verifyBackup,restoreBackup,listReservations,cancelReservation } from './operations.mjs';
import { createService } from './service.mjs';
process.umask(0o077);
try{
 const [command,...args]=process.argv.slice(2);
 let result;
 if(command==='check'){const service=createService(process.env);service.close();result={status:'configuration_valid',publicDeploymentVerified:false};}
 else if(command==='backup'){if(args.length!==1||!process.env.STATS_DB)throw new Error('backup requires STATS_DB and destination');result=await onlineBackup(process.env.STATS_DB,args[0]);}
 else if(command==='verify-backup'){if(args.length!==1)throw new Error('verify-backup requires backup path');result=verifyBackup(args[0]);}
 else if(command==='restore'){if(args.length!==2)throw new Error('restore requires backup and new destination paths');result=restoreBackup(args[0],args[1]);}
 else if(command==='reservations'){if(!process.env.STATS_DB)throw new Error('STATS_DB required');result=listReservations(process.env.STATS_DB);}
 else if(command==='cancel-reservation'){
   if(args.length!==4||args[3]!=='--confirm-process-ended'||!process.env.STATS_DB)throw new Error('cancel-reservation HANDLE OPERATOR REASON --confirm-process-ended required');
   result=cancelReservation(process.env.STATS_DB,args[0],{operator:args[1],reason:args[2],confirmed:true});
 }else throw new Error('Commands: check | backup DEST | verify-backup BACKUP | restore BACKUP NEW_DEST | reservations | cancel-reservation HANDLE OPERATOR REASON --confirm-process-ended');
 console.log(JSON.stringify(result,null,2));
}catch{console.error('Operation rejected; verify configuration, private file permissions and command arguments. No automatic refund or activation performed.');process.exitCode=1;}
