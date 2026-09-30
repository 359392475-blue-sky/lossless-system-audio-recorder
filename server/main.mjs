import { createService } from './service.mjs';
process.umask(0o077);
try {
  const port = Number(process.env.PORT || 8787), host = process.env.HOST || '127.0.0.1';
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
  const server = createService(process.env);
  server.on('error',()=>{ console.error('Policy service listener failed'); process.exitCode=1; server.close(); });
  server.listen(port,host,()=>console.log('Policy service listening'));
  for (const signal of ['SIGINT','SIGTERM']) process.on(signal,()=>server.close());
} catch { console.error('Policy service startup rejected: check required configuration, key, policy and database'); process.exitCode=1; }
