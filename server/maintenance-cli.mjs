import { checkHealth,scheduledBackup } from './maintenance.mjs';
process.umask(0o077);
try{const command=process.argv[2];if(!['backup','health'].includes(command)||process.argv.length!==3)throw new Error();console.log(JSON.stringify(await(command==='backup'?scheduledBackup(process.env):checkHealth(process.env))));}
catch{console.error('Recorder maintenance failed: check readiness, disk capacity, backup age/integrity and private configuration.');process.exitCode=1;}
