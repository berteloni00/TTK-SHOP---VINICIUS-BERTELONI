import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { createHandler, verifyEvent, canonicalHash } from '../tools/fireflies-radar/handler.mjs';
if (!globalThis.crypto) globalThis.crypto = webcrypto;
const secret = 'synthetic-secret-only';
const event = {event:'meeting.transcribed',meeting_id:'synthetic-1',timestamp:1794850000000};
async function request(payload=event, signature=true, path='/fireflies-radar/webhook') {
  const raw=JSON.stringify(payload);
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const sig=Buffer.from(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(raw))).toString('hex');
  return new Request('https://example.test'+path,{method:'POST',body:raw,headers:signature?{'X-Hub-Signature':'sha256='+sig}:{}});
}
function setup({failPersist=false}={}) {
  const calls=[];const scheduled=[];
  const rpc=async(name,args)=>{calls.push({name,args});if(name==='ac_calls_service_secrets')return {webhook_secret:secret,worker_secret:'worker-test'};if(failPersist)throw new Error('DO NOT EXPOSE THIS SECRET');return {job_id:'job',status:'queued',duplicate:false};};
  return {calls,scheduled,handler:createHandler({rpc,runOneJob:async()=>{calls.push({name:'worker'});return {processed:false};},waitUntil:p=>scheduled.push(p)})};
}
test('valid event is enqueued before ACK and background execution',async()=>{const x=setup();const res=await x.handler(await request());assert.equal(res.status,202);await Promise.all(x.scheduled);assert.ok(x.calls.findIndex(x=>x.name==='ac_calls_enqueue')<x.calls.findIndex(x=>x.name==='worker'));assert.equal(x.calls[1].args.p_event.revision,0);});
test('invalid signature never writes or processes',async()=>{const x=setup();assert.equal((await x.handler(await request(event,false))).status,401);assert.equal(x.calls.length,1);assert.equal(x.scheduled.length,0);});
test('failure to persist returns retryable error and never false success',async()=>{const x=setup({failPersist:true});const res=await x.handler(await request());assert.equal(res.status,503);assert.doesNotMatch(await res.text(),/SECRET/);assert.equal(x.scheduled.length,0);});
test('other signed events are ignored without enqueue',async()=>{const x=setup();const res=await x.handler(await request({...event,event:'meeting.summarized'}));assert.equal(res.status,200);assert.equal(x.calls.length,1);});
test('worker endpoint requires its private bearer',async()=>{const x=setup();const req=new Request('https://example.test/fireflies-radar/worker',{method:'POST'});assert.equal((await x.handler(req)).status,401);assert.equal(x.calls.length,1);});
test('worker authorized request invokes exactly one job',async()=>{const x=setup();const req=new Request('https://example.test/fireflies-radar/worker',{method:'POST',headers:{Authorization:'Bearer worker-test'}});assert.equal((await x.handler(req)).status,200);assert.equal(x.calls.filter(x=>x.name==='worker').length,1);});
test('signature and body validation reject tampering and impossible timestamps',async()=>{const req=await request({...event,timestamp:true});const bytes=new Uint8Array(await req.arrayBuffer());await assert.rejects(()=>verifyEvent(bytes,req.headers.get('X-Hub-Signature'),secret),/INVALID_EVENT/);await assert.rejects(()=>verifyEvent(new TextEncoder().encode('{}'),req.headers.get('X-Hub-Signature'),secret),/INVALID_SIGNATURE/);});
test('content hash is independent of object ordering but changes with transcript',async()=>{assert.equal(await canonicalHash({a:1,b:{x:2,y:3}}),await canonicalHash({b:{y:3,x:2},a:1}));assert.notEqual(await canonicalHash({text:'a'}),await canonicalHash({text:'b'}));});
test('unconfigured receiver rejects before enqueue',async()=>{const h=createHandler({rpc:async()=>({}),runOneJob:async()=>assert.fail(),waitUntil:()=>assert.fail()});assert.equal((await h(await request())).status,503);});
test('oversized payload is refused before parsing',async()=>{const x=setup();const req=new Request('https://example.test/fireflies-radar/webhook',{method:'POST',body:'a'.repeat(65537)});assert.equal((await x.handler(req)).status,413);assert.equal(x.calls.length,0);});
test('a stalled webhook returns retryable failure before its total deadline',async()=>{const h=createHandler({rpc:()=>new Promise(()=>{}),runOneJob:async()=>assert.fail(),waitUntil:()=>assert.fail(),webhookDeadlineMs:10});const start=Date.now();assert.equal((await h(await request())).status,503);assert.ok(Date.now()-start<1000);});
