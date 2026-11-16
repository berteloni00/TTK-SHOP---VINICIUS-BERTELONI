import test from 'node:test';
import assert from 'node:assert/strict';
import { createWorker } from '../tools/fireflies-radar/worker.mjs';
import { canonicalHash } from '../tools/fireflies-radar/handler.mjs';
const raw={id:'meeting-1',title:'Synthetic',dateString:'2026-11-16T12:00:00Z',organizer_email:'owner@example.invalid',is_live:false,sentences:[{index:0,speaker_name:'Person',text:'A request',start_time:'1',end_time:'4'}]};
function setup({wrongAccount=false,live=false,failAI=false,finishFail=false,configured=true,staged=null,stagedHash=null,organizer=raw.organizer_email,aiErrorBody=null,aiErrorStatus=429,aiErrorHeaders={}}={}){
  const steps=[];
  const rpc=async(name,args)=>{steps.push({name,args});switch(name){case'ac_calls_service_secrets':return configured?{fireflies_api_key:'fake-fireflies',openai_api_key:'fake-ai'}:{};case'ac_calls_claim':return{id:'job',meeting_id:'meeting-1',lease_token:'lease',staged_transcript:staged,content_hash:stagedHash};case'ac_calls_worker_context':return{expected_account_email:'owner@example.invalid',settings:{groups:[]},whatsapp_run:null};case'ac_calls_finish':if(finishFail)throw new Error('sql private detail');return{published:true,analysis_id:'analysis'};default:return{saved:true};}};
  const fetchImpl=async(url,opts)=>{const body=JSON.parse(opts.body);steps.push({name:url.includes('openai')?'ai':'provider',query:body.query});if(url.includes('openai')){if(aiErrorBody!==null)return new Response(aiErrorBody,{status:aiErrorStatus,headers:aiErrorHeaders});if(failAI)return new Response('DO NOT LOG',{status:429});return Response.json({choices:[{finish_reason:'stop',message:{content:'{"items":[]}'}}]});}if(body.query.includes('user {'))return Response.json({data:{user:{email:wrongAccount?'other@example.invalid':'owner@example.invalid'}}});return Response.json({data:{transcript:{...raw,is_live:live,organizer_email:organizer}}});};
  const worker=createWorker({rpc,fetchImpl,prepareTranscript:x=>({id:x.id,segments:x.sentences}),buildAnalysisRequest:()=>({model:'test',messages:[]}),validateAndMaterializeAnalysis:draft=>({...draft,validated:true})});
  return {steps,worker};
}
test('transcript is staged privately before analysis and publication',async()=>{const x=setup();const r=await x.worker();assert.equal(r.processed,true);assert.ok(x.steps.findIndex(x=>x.name==='ac_calls_stage_transcript')<x.steps.findIndex(x=>x.name==='ai'));const f=x.steps.find(x=>x.name==='ac_calls_finish');assert.equal(f.args.p_transcript.id,'meeting-1');assert.equal(f.args.p_analysis.validated,true);assert.match(f.args.p_content_hash,/^[a-f0-9]{64}$/);});
test('wrong account fails before reading transcript or sending it to AI',async()=>{const x=setup({wrongAccount:true});assert.equal((await x.worker()).processed,false);assert.equal(x.steps.filter(x=>x.name==='provider').length,1);assert.ok(!x.steps.some(x=>x.name==='ai'));assert.equal(x.steps.at(-1).args.p_error,'FIREFLIES_ACCOUNT_MISMATCH');});
test('a live transcript is never treated as completed',async()=>{const x=setup({live:true});assert.equal((await x.worker()).processed,false);assert.ok(!x.steps.some(x=>x.name==='ai'||x.name==='ac_calls_finish'));assert.equal(x.steps.at(-1).args.p_error,'TRANSCRIPT_NOT_READY');});
test('AI error preserves staged transcript and schedules failure without a fake publication',async()=>{const x=setup({failAI:true});assert.equal((await x.worker()).processed,false);assert.ok(x.steps.some(x=>x.name==='ac_calls_stage_transcript'));assert.ok(!x.steps.some(x=>x.name==='ac_calls_finish'));assert.equal(x.steps.at(-1).args.p_error,'AI_HTTP_429');});

test('429 diagnostics expose only the exact approved code, never provider messages',async()=>{
  const codes=['insufficient_quota','rate_limit_exceeded','credit_balance_exhausted','organization_spend_limit_exceeded','project_spend_limit_exceeded','organization_usage_limit_exceeded','slow_down'];
  for(const code of codes){
    const x=setup({aiErrorBody:JSON.stringify({error:{code,type:'insufficient_quota',message:'private-body-secret sk-do-not-copy'}})});
    const expected='AI_HTTP_429_'+(code==='rate_limit_exceeded'?'RATE_LIMIT':code.toUpperCase());
    const result=await x.worker();assert.deepEqual(result,{processed:false,error:expected});assert.equal(x.steps.at(-1).args.p_error,expected);
    assert.equal(x.steps.filter(s=>s.name==='ai').length,1);assert.ok(!x.steps.some(s=>s.name==='ac_calls_finish'));
    assert.ok(!JSON.stringify([result,x.steps.at(-1)]).includes('private-body-secret'));
  }
});

test('429 type fallback is allowlisted and recognized code takes precedence',async()=>{
  for(const [error,suffix] of [[{type:'insufficient_quota'},'INSUFFICIENT_QUOTA'],[{type:'rate_limit_error'},'RATE_LIMIT'],[{type:'rate_limit_exceeded'},'RATE_LIMIT'],[{code:'project_spend_limit_exceeded',type:'rate_limit_error'},'PROJECT_SPEND_LIMIT_EXCEEDED']]){
    const x=setup({aiErrorBody:JSON.stringify({error})});assert.equal((await x.worker()).error,'AI_HTTP_429_'+suffix);
  }
});

test('invalid JSON, HTML and arbitrary secret-bearing codes keep generic 429',async()=>{
  for(const body of ['<html>private HTML secret</html>','{"error":','null','[]',JSON.stringify({error:{code:'insufficient_quota_secret',type:'unknown',message:'insufficient_quota PRIVATE'}}),JSON.stringify({error:{code:{secret:'PRIVATE'},type:['insufficient_quota']}})]){
    const x=setup({aiErrorBody:body});const result=await x.worker();assert.deepEqual(result,{processed:false,error:'AI_HTTP_429'});assert.equal(x.steps.at(-1).args.p_error,'AI_HTTP_429');
  }
});

test('error diagnostics stop at 8 KiB regardless of content-length and preserve staged retry',async()=>{
  const body=JSON.stringify({error:{code:'insufficient_quota',message:'PRIVATE'.repeat(2000)}});
  for(const headers of [{},{'content-length':String(body.length)}]){
    const x=setup({staged:raw,stagedHash:await canonicalHash(raw),aiErrorBody:body,aiErrorHeaders:headers});
    assert.equal((await x.worker()).error,'AI_HTTP_429');assert.equal(x.steps.filter(s=>s.name==='provider').length,1);assert.equal(x.steps.filter(s=>s.name==='ai').length,1);
    assert.deepEqual(x.steps.find(s=>s.name==='ac_calls_stage_transcript').args.p_transcript,raw);assert.ok(!x.steps.some(s=>s.name==='ac_calls_finish'));
  }
});

test('429 diagnostic labels are not applied to another HTTP status',async()=>{
  const x=setup({aiErrorStatus:401,aiErrorBody:JSON.stringify({error:{code:'insufficient_quota',message:'PRIVATE'}})});
  assert.equal((await x.worker()).error,'AI_HTTP_401');assert.equal(x.steps.at(-1).args.p_error,'AI_HTTP_401');
});
test('lost or failed publication is not reported as processed and does not leak SQL errors',async()=>{const x=setup({finishFail:true});assert.equal((await x.worker()).processed,false);assert.equal(x.steps.at(-1).args.p_error,'PROCESSING_FAILED');});
test('missing credentials does not consume queued attempts',async()=>{const x=setup({configured:false});assert.equal((await x.worker()).processed,false);assert.ok(!x.steps.some(x=>x.name==='ac_calls_claim'));});
test('retry reuses the verified private snapshot without refetching the transcript',async()=>{const x=setup({staged:raw,stagedHash:await canonicalHash(raw)});assert.equal((await x.worker()).processed,true);assert.equal(x.steps.filter(s=>s.name==='provider').length,1);assert.deepEqual(x.steps.find(s=>s.name==='ac_calls_finish').args.p_transcript,raw);});
test('corrupt staged snapshot is rejected before AI',async()=>{const x=setup({staged:raw,stagedHash:'0'.repeat(64)});assert.equal((await x.worker()).processed,false);assert.ok(!x.steps.some(s=>s.name==='ai'));});
test('a signed authorized meeting is not rejected solely for another organizer',async()=>{const x=setup({organizer:'client@example.invalid'});assert.equal((await x.worker()).processed,true);});
test('total worker deadline aborts remote work and still persists the retry',async()=>{const calls=[];const rpc=async(name,args,signal)=>{calls.push({name,args,signal});if(name==='ac_calls_service_secrets')return{fireflies_api_key:'synthetic-fireflies',openai_api_key:'synthetic-ai'};if(name==='ac_calls_claim')return{id:'job',meeting_id:raw.id,lease_token:'lease'};if(name==='ac_calls_worker_context')return{expected_account_email:'owner@example.invalid'};return{};};const fetchImpl=async(_url,{signal})=>new Promise((_,reject)=>{signal.addEventListener('abort',()=>reject(signal.reason),{once:true});});const worker=createWorker({rpc,fetchImpl,workerBudgetMs:15});const keepAlive=setTimeout(()=>{},200);try{assert.equal((await worker()).error,'REMOTE_TIMEOUT');assert.equal(calls.at(-1).name,'ac_calls_fail');assert.equal(calls.at(-1).signal,undefined);}finally{clearTimeout(keepAlive);}});
