// Pure, testable HTTP boundary. Secrets and persistence are injected by the Edge runtime.
const encoder = new TextEncoder();
const MAX_EVENT_BYTES=65536;
const idPattern=/^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,255}$/;
const json=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
export async function canonicalHash(value){
  function canonical(v){if(Array.isArray(v))return v.map(canonical);if(v&&typeof v==='object')return Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])]));if(typeof v==='number'&&!Number.isFinite(v))throw new Error('INVALID_NUMBER');return v;}
  const digest=await crypto.subtle.digest('SHA-256',encoder.encode(JSON.stringify(canonical(value))));
  return Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('');
}
async function verifySignature(bytes,signature,secret){
  if(!secret)throw new Error('NOT_CONFIGURED');
  if(!/^sha256=[0-9a-f]{64}$/.test(signature||''))throw new Error('INVALID_SIGNATURE');
  const key=await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
  const digest=Uint8Array.from(signature.slice(7).match(/../g),x=>parseInt(x,16));
  if(!await crypto.subtle.verify('HMAC',key,digest,bytes))throw new Error('INVALID_SIGNATURE');
}
export async function verifyEvent(bytes,signature,secret){
  await verifySignature(bytes,signature,secret);
  let body;try{body=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{throw new Error('INVALID_EVENT');}
  const timestamp=body?.timestamp, revision=Object.hasOwn(body||{},'reprocessed_at')?body.reprocessed_at:0;
  if(!body||Array.isArray(body)||typeof body.event!=='string'||!/^[a-z][a-z0-9_.-]{0,127}$/.test(body.event)||typeof body.meeting_id!=='string'||!idPattern.test(body.meeting_id)||!Number.isSafeInteger(timestamp)||timestamp<=0||timestamp>253402300799999||!Number.isSafeInteger(revision)||revision<0||revision>timestamp)throw new Error('INVALID_EVENT');
  return {meeting_id:body.meeting_id,event:body.event,revision,delivery_timestamp_ms:timestamp};
}
async function boundedBody(req){
  const declared=Number(req.headers.get('Content-Length')||0);
  if(declared>MAX_EVENT_BYTES)throw new Error('TOO_LARGE');
  const reader=req.body?.getReader();if(!reader)return new Uint8Array();
  const chunks=[];let length=0;
  while(true){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>MAX_EVENT_BYTES){await reader.cancel();throw new Error('TOO_LARGE');}chunks.push(value);}
  const result=new Uint8Array(length);let at=0;for(const chunk of chunks){result.set(chunk,at);at+=chunk.length;}return result;
}
export function createHandler({rpc,runOneJob,waitUntil,webhookDeadlineMs=22000}){
  async function route(req){
    const path=new URL(req.url).pathname;
    if(req.method==='GET'&&path.endsWith('/health'))return json({service:'radar-calls',reachable:true});
    if(req.method!=='POST')return json({error:'METHOD_NOT_ALLOWED'},405);
    if(!path.endsWith('/worker')&&!path.endsWith('/webhook')&&!path.endsWith('/fireflies-radar'))return json({error:'NOT_FOUND'},404);
    try{
      const bytes=await boundedBody(req);
      const secrets=await rpc('ac_calls_service_secrets',{});
      if(path.endsWith('/worker')){
        // pg_net queues are readable by DB roles on managed Supabase. Only an
        // expiring signed proof enters that queue, never the reusable secret.
        await verifySignature(bytes,req.headers.get('X-Radar-Worker-Signature'),secrets?.worker_secret);
        let tick;try{tick=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{return json({error:'UNAUTHORIZED'},401);}
        if(tick?.scope!=='radar.calls.recovery'||!Number.isSafeInteger(tick.timestamp)||Math.abs(Date.now()-tick.timestamp)>90000)return json({error:'UNAUTHORIZED'},401);
        const result=await runOneJob();return json({ok:true,processed:Boolean(result?.processed)});
      }
      const event=await verifyEvent(bytes,req.headers.get('X-Hub-Signature'),secrets?.webhook_secret);
      if(event.event!=='meeting.transcribed')return json({accepted:false,reason:'EVENT_IGNORED'});
      const queued=await rpc('ac_calls_enqueue',{p_event:event});
      // Register background work only after the durable transaction succeeded.
      waitUntil(Promise.resolve().then(()=>runOneJob()).catch(()=>undefined));
      return json({accepted:true,duplicate:Boolean(queued?.duplicate)},202);
    }catch(error){
      const code=error?.message;
      if(code==='INVALID_SIGNATURE')return json({error:code},401);
      if(code==='INVALID_EVENT')return json({error:code},400);
      if(code==='TOO_LARGE')return json({error:code},413);
      return json({error:code==='NOT_CONFIGURED'?'NOT_CONFIGURED':'TEMPORARY_FAILURE'},503);
    }
  }
  return async function handle(req){
    if(req.method!=='POST'||new URL(req.url).pathname.endsWith('/worker'))return route(req);
    let timer;
    const deadline=new Promise(resolve=>{timer=setTimeout(()=>resolve(json({error:'TEMPORARY_FAILURE'},503)),webhookDeadlineMs);});
    try{return await Promise.race([route(req),deadline]);}finally{clearTimeout(timer);}
  };
}
