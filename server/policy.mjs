import { readFileSync } from 'node:fs';

const fields = ['schema','product','sequence','level','minimumBuild','effectiveAt','latestBuild','title','message','downloadURL'];
export function httpsURL(value) {
  if (typeof value !== 'string') throw new Error('HTTPS URL required');
  const u = new URL(value);
  if (u.protocol !== 'https:' || u.username || u.password || u.hash) throw new Error('HTTPS URL required');
  return u.href;
}
export function validatePolicy(p) {
  if (!p || Array.isArray(p) || typeof p !== 'object' || Object.keys(p).length !== fields.length || fields.some(k => !Object.hasOwn(p,k))) throw new Error('Invalid policy fields');
  if (p.schema !== 1 || p.product !== 'lossless-system-audio-recorder') throw new Error('Invalid policy identity');
  for (const k of ['sequence','level','minimumBuild','effectiveAt','latestBuild']) if (!Number.isSafeInteger(p[k])) throw new Error('Invalid integer');
  if (p.sequence < 0 || p.level < 0 || p.level > 4 || p.minimumBuild < 1 || p.latestBuild < p.minimumBuild || p.effectiveAt < 0) throw new Error('Invalid policy bounds');
  if (typeof p.title !== 'string' || !p.title.trim() || p.title.length > 200 || typeof p.message !== 'string' || p.message.length > 4000) throw new Error('Invalid policy text');
  httpsURL(p.downloadURL);
  return Object.fromEntries(fields.map(k => [k,p[k]]));
}
export function readPolicy(path) { return validatePolicy(JSON.parse(readFileSync(path,'utf8'))); }
