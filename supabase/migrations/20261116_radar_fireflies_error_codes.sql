-- Narrow diagnostic update only. No data/configuration writes or retries.
-- CREATE OR REPLACE preserves the existing RPC ACL; require the base migration.
begin;
do $$ begin
  if to_regprocedure('public.ac_calls_fail(uuid,uuid,text)') is null then
    raise exception 'CALLS_BASE_MIGRATION_REQUIRED';
  end if;
end; $$;
create or replace function public.ac_calls_fail(p_job_id uuid,p_lease_token uuid,p_error text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j ac_radar_private.calls_jobs; safe_error text;
begin
  perform ac_radar_private.calls_require_service();select * into j from ac_radar_private.calls_jobs where id=p_job_id for update;
  if not found or j.status<>'processing' or j.lease_token is distinct from p_lease_token or j.lease_expires_at<=clock_timestamp() then raise exception 'CALLS_LEASE_INVALID';end if;
  -- Store only known diagnostic codes, never arbitrary provider text/URLs/tokens.
  safe_error:=case when p_error in('ANALYSIS_INVALID','TRANSCRIPT_INVALID','TRANSCRIPT_NOT_READY','TRANSCRIPT_COLLISION','FIREFLIES_AUTH','FIREFLIES_FORBIDDEN','FIREFLIES_RATE_LIMIT','FIREFLIES_UNAVAILABLE','OPENAI_AUTH','OPENAI_RATE_LIMIT','OPENAI_UNAVAILABLE','ACCOUNT_MISMATCH','CONFIGURATION_REQUIRED','FIREFLIES_GRAPHQL_ERROR','FIREFLIES_ACCOUNT_MISMATCH','FIREFLIES_TRANSCRIPT_MISMATCH','AI_INVALID_OUTPUT','AI_INCOMPLETE_OUTPUT','TRANSCRIPT_TOO_LONG_REQUIRES_REVIEW','INVALID_ANALYSIS','RESPONSE_TOO_LARGE','REMOTE_TIMEOUT','PROCESSING_FAILED','AI_HTTP_429_INSUFFICIENT_QUOTA','AI_HTTP_429_RATE_LIMIT','AI_HTTP_429_CREDIT_BALANCE_EXHAUSTED','AI_HTTP_429_ORGANIZATION_SPEND_LIMIT_EXCEEDED','AI_HTTP_429_PROJECT_SPEND_LIMIT_EXCEEDED','AI_HTTP_429_ORGANIZATION_USAGE_LIMIT_EXCEEDED','AI_HTTP_429_SLOW_DOWN')
    or p_error ~ '^(FIREFLIES|AI)_HTTP_[1-5][0-9]{2}$' then p_error else 'CALLS_PROCESSING_FAILED' end;
  update ac_radar_private.calls_jobs set status=case when attempts>=5 then 'failed' else 'retry' end,last_error=safe_error,
    next_attempt_at=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,attempts-1)::integer)),lease_expires_at=null,updated_at=clock_timestamp()
    where id=j.id returning * into j;
  return jsonb_build_object('status',j.status,'attempts',j.attempts,'next_attempt_at',j.next_attempt_at);
end; $$;
commit;
