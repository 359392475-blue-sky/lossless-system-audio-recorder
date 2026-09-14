import { readFileSync, writeFileSync, renameSync, unlinkSync, openSync, closeSync, realpathSync } from 'node:fs';
import { dirname, basename, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { readPolicy, validatePolicy, httpsURL } from './policy.mjs';
try {
  const [command,path] = process.argv.slice(2);
  if (command === 'policy') {
    if (!process.env.POLICY_FILE || !path) throw new Error('POLICY_FILE and proposed policy JSON path required');
    const next = validatePolicy(JSON.parse(readFileSync(path,'utf8')));
    const policyPath = join(realpathSync(dirname(process.env.POLICY_FILE)),basename(process.env.POLICY_FILE));
    const lockPath = `${policyPath}.lock`;
    let lock;
    try { lock = openSync(lockPath,'wx',0o600); } catch (e) { if(e.code === 'EEXIST') throw new Error('Policy update locked by another process; retry after it finishes'); throw e; }
    try {
      writeFileSync(lock,String(process.pid)+'\n');
      let previous;
      try { previous = readPolicy(policyPath); } catch (e) { if (e.code !== 'ENOENT') throw e; }
      if (previous && next.sequence <= previous.sequence) throw new Error('Replacement, including rollback, requires higher sequence');
      const temp = `${policyPath}.${randomUUID()}.tmp`;
      try { writeFileSync(temp,JSON.stringify(next,null,2)+'\n',{mode:0o600,flag:'wx'}); renameSync(temp,policyPath); } finally { try { unlinkSync(temp); } catch {} }
    } finally { closeSync(lock); unlinkSync(lockPath); }
    console.log(`Policy installed at sequence ${next.sequence}`);
  } else if (command === 'stats') {
    if (!process.env.STATS_ORIGIN || !process.env.ADMIN_TOKEN) throw new Error('STATS_ORIGIN and ADMIN_TOKEN required');
    const origin = new URL(httpsURL(process.env.STATS_ORIGIN));
    const res = await fetch(new URL('/admin/stats',origin),{headers:{Authorization:`Bearer ${process.env.ADMIN_TOKEN}`},signal:AbortSignal.timeout(30000),redirect:'error'});
    if (!res.ok) throw new Error('Statistics request failed');
    console.log(JSON.stringify(await res.json(),null,2));
  } else throw new Error('Usage: node cli.mjs policy proposed.json | stats');
} catch (e) { console.error(e.message); process.exitCode=1; }
