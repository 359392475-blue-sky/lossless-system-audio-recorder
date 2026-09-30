export function createLimits(env,{clock=()=>performance.now()}={}){
  function integer(name,fallback){const n=Number(env[name]??fallback);if(!Number.isSafeInteger(n)||n<1||n>1000000)throw new Error('Invalid resource limit');return n;}
  const requestLimit=integer('MAX_REQUESTS_PER_MINUTE',6000),ticketLimit=integer('MAX_TICKETS_PER_MINUTE',120),maxActive=integer('MAX_ACTIVE_REQUESTS',128),maxDownloads=integer('MAX_ACTIVE_DOWNLOADS',4);
  let windowStart=clock(),requests=0,tickets=0,active=0,downloads=0;
  return function admit(req,res,u){
    if(clock()-windowStart>=60000){windowStart=clock();requests=0;tickets=0;}
    const download=u.pathname==='/r/download'&&req.method==='GET',ticket=/^\/r\/[^/]+\/ticket$/.test(u.pathname)&&req.method==='POST';
    if(++requests>requestLimit||(ticket&&++tickets>ticketLimit)||active>=maxActive||(download&&downloads>=maxDownloads)){
      res.writeHead(429,{'Content-Type':'application/json','Cache-Control':'no-store','Retry-After':'60'});res.end('{"error":"capacity_limited"}');return false;
    }
    active++;if(download)downloads++;
    let released=false;const release=()=>{if(!released){released=true;active--;if(download)downloads--;}};
    res.once('finish',release);res.once('close',release);return true;
  };
}
