import {canonicalHash} from './handler.mjs';
const TRANSCRIPT_QUERY=`query RadarTranscript($id:String!){transcript(id:$id){id title date dateString duration transcript_url organizer_email is_live speakers{id name} sentences{index speaker_id speaker_name text start_time end_time}}}`;
const allowedErrors=/^(FIREFLIES_(HTTP_\d{3}|GRAPHQL_ERROR|ACCOUNT_MISMATCH|TRANSCRIPT_MISMATCH)|AI_(HTTP_\d{3}|INVALID_OUTPUT|INCOMPLETE_OUTPUT)|TRANSCRIPT_(NOT_READY|TOO_LONG_REQUIRES_REVIEW)|INVALID_ANALYSIS|RESPONSE_TOO_LARGE|REMOTE_TIMEOUT)$/;
async function readJson(response,maxBytes){
  if(Number(response.headers.get('content-length')||0)>maxBytes)throw new Error('RESPONSE_TOO_LARGE');
  const reader=response.body?.getReader();const chunks=[];let size=0;
  if(!reader)throw new Error('INVALID_ANALYSIS');
  while(true){const r=await reader.read();if(r.done)break;size+=r.value.length;if(size>maxBytes){await reader.cancel();throw new Error('RESPONSE_TOO_LARGE');}chunks.push(r.value);}
  const bytes=new Uint8Array(size);let p=0;for(const chunk of chunks){bytes.set(chunk,p);p+=chunk.length;}
  return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
}
export function createRpc({url,serviceKey,fetchImpl=fetch}){
  if(!/^https:\/\/[a-z0-9]+\.supabase\.co$/.test(url)||!serviceKey)throw new Error('BACKEND_NOT_CONFIGURED');
  return async(name,args,signal)=>{
    if(!/^ac_calls_[a-z_]+$/.test(name))throw new Error('RPC_NOT_ALLOWED');
    const timeout=AbortSignal.timeout(8000);
    const response=await fetchImpl(url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:serviceKey,Authorization:'Bearer '+serviceKey,'Content-Type':'application/json'},body:JSON.stringify(args),signal:signal?AbortSignal.any([signal,timeout]):timeout,redirect:'error'});
    if(!response.ok)throw new Error('RPC_FAILED');
    return readJson(response,24*1024*1024);
  };
}
export function createWorker({rpc,fetchImpl=fetch,prepareTranscript,buildAnalysisRequest,validateAndMaterializeAnalysis,workerBudgetMs=120000}){
  return async function runOneJob(){
    // Leave time to persist failure before the shortest hosted runtime limit.
    const budget=AbortSignal.timeout(workerBudgetMs);
    const call=(name,args)=>rpc(name,args,budget);
    const secrets=await call('ac_calls_service_secrets',{});
    if(!secrets?.fireflies_api_key||!secrets?.openai_api_key)return {processed:false};
    const job=await call('ac_calls_claim',{p_lease_seconds:300});
    if(!job)return {processed:false};
    try{
      const context=await call('ac_calls_worker_context',{});
      const expected=context?.expected_account_email?.trim().toLowerCase();
      if(!expected)throw new Error('FIREFLIES_ACCOUNT_MISMATCH');
      async function fireflies(query,variables={}){
        const response=await fetchImpl('https://api.fireflies.ai/graphql',{method:'POST',headers:{Authorization:'Bearer '+secrets.fireflies_api_key,'Content-Type':'application/json'},body:JSON.stringify({query,variables}),signal:AbortSignal.any([budget,AbortSignal.timeout(20000)]),redirect:'error'});
        if(!response.ok)throw new Error('FIREFLIES_HTTP_'+response.status);
        const body=await readJson(response,16*1024*1024);
        if(body.errors?.length)throw new Error('FIREFLIES_GRAPHQL_ERROR');
        return body.data;
      }
      const profile=await fireflies('query RadarAccount { user { email } }');
      if(profile?.user?.email?.trim().toLowerCase()!==expected)throw new Error('FIREFLIES_ACCOUNT_MISMATCH');
      // Retry from the immutable private download, even if provider metadata changes.
      const raw=job.staged_transcript??(await fireflies(TRANSCRIPT_QUERY,{id:job.meeting_id}))?.transcript;
      if(!raw||raw.is_live===true||!Array.isArray(raw.sentences)||raw.sentences.length===0)throw new Error('TRANSCRIPT_NOT_READY');
      if(raw.id!==job.meeting_id)throw new Error('FIREFLIES_TRANSCRIPT_MISMATCH');
      const contentHash=await canonicalHash(raw);
      if(job.staged_transcript&&contentHash!==job.content_hash)throw new Error('FIREFLIES_TRANSCRIPT_MISMATCH');
      await call('ac_calls_stage_transcript',{p_job_id:job.id,p_lease_token:job.lease_token,p_transcript:raw,p_content_hash:contentHash});
      const transcript=prepareTranscript(raw);
      const request=buildAnalysisRequest(transcript,context);
      const requestBody=JSON.stringify(request);
      // Fail explicitly rather than silently truncating a long meeting.
      if(requestBody.length>1200000)throw new Error('TRANSCRIPT_TOO_LONG_REQUIRES_REVIEW');
      const response=await fetchImpl('https://api.openai.com/v1/chat/completions',{method:'POST',headers:{Authorization:'Bearer '+secrets.openai_api_key,'Content-Type':'application/json'},body:requestBody,signal:AbortSignal.any([budget,AbortSignal.timeout(90000)]),redirect:'error'});
      if(!response.ok)throw new Error('AI_HTTP_'+response.status);
      const body=await readJson(response,2*1024*1024);
      const choice=body.choices?.[0];
      if(choice?.finish_reason!=='stop')throw new Error('AI_INCOMPLETE_OUTPUT');
      let draft;try{draft=JSON.parse(choice.message.content);}catch{throw new Error('AI_INVALID_OUTPUT');}
      let analysis;try{analysis=validateAndMaterializeAnalysis(draft,transcript,context);}catch{throw new Error('INVALID_ANALYSIS');}
      const result=await call('ac_calls_finish',{p_job_id:job.id,p_lease_token:job.lease_token,p_analysis:analysis,p_transcript:raw,p_content_hash:contentHash});
      return {processed:true,published:Boolean(result?.published),analysis_id:result?.analysis_id};
    }catch(error){
      const reason=error?.name==='TimeoutError'||error?.name==='AbortError'?'REMOTE_TIMEOUT':allowedErrors.test(error?.message||'')?error.message:'PROCESSING_FAILED';
      // If even failure persistence fails, lease expiry lets the recovery tick retry.
      try{await rpc('ac_calls_fail',{p_job_id:job.id,p_lease_token:job.lease_token,p_error:reason});}catch{}
      return {processed:false,error:reason};
    }
  };
}
