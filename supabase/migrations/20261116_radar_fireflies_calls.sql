-- Calls v1, additive to supabase-radar.sql. No WhatsApp table/RPC is changed.
-- Requires real Supabase Vault. Tests substitute only Vault's storage API.
-- service_role remains globally privileged: keep its key only in Supabase Edge.
-- A verified, signed event may be queued while disabled; claim fails closed.
-- enabled permits processing/testing, not a claim of verified end-to-end activation.
-- Set expected_account_email and webhook_url administratively after installation.
begin;

create table if not exists ac_radar_private.calls_config (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false,
  expected_account_email text not null default '',
  webhook_url text not null default '',
  fireflies_secret_id uuid, openai_secret_id uuid,
  webhook_secret_id uuid, worker_secret_id uuid,
  updated_at timestamptz not null default now()
);
insert into ac_radar_private.calls_config(singleton) values(true) on conflict do nothing;

create table if not exists ac_radar_private.calls_jobs (
  id uuid primary key default gen_random_uuid(),
  meeting_id text not null,
  event text not null check(event='meeting.transcribed'),
  revision bigint not null check(revision>=0 and revision<=253402300799999),
  delivery_timestamp_ms bigint not null,
  status text not null default 'queued' check(status in('queued','processing','retry','completed','failed')),
  attempts integer not null default 0 check(attempts between 0 and 5),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid, lease_expires_at timestamptz,
  staged_transcript jsonb, content_hash text,
  analysis_id uuid, published boolean,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(meeting_id,event,revision),
  check(staged_transcript is null or octet_length(staged_transcript::text)<=16777216),
  check(last_error is null or length(last_error)<=500)
);
create index if not exists calls_jobs_ready on ac_radar_private.calls_jobs(status,next_attempt_at,created_at);
create table if not exists ac_radar_private.call_analyses (
  analysis_id uuid primary key default gen_random_uuid(),
  job_id uuid not null unique references ac_radar_private.calls_jobs(id),
  meeting_id text not null,
  revision bigint not null,
  content_hash text not null,
  analyzed_at timestamptz not null default now(),
  payload jsonb not null check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=2097152),
  unique(meeting_id,revision)
);
create table if not exists ac_radar_private.call_heads (
  meeting_id text primary key,
  revision bigint not null,
  analysis_id uuid not null unique references ac_radar_private.call_analyses(analysis_id)
);
alter table ac_radar_private.calls_config enable row level security;
alter table ac_radar_private.calls_jobs enable row level security;
alter table ac_radar_private.call_analyses enable row level security;
alter table ac_radar_private.call_heads enable row level security;
revoke all on ac_radar_private.calls_config,ac_radar_private.calls_jobs,ac_radar_private.call_analyses,ac_radar_private.call_heads from public,anon,authenticated,service_role;

create or replace function ac_radar_private.calls_assert(p_ok boolean,p_message text) returns void
language plpgsql set search_path='' as $$
begin
  if not coalesce(p_ok,false) then raise exception using errcode='22023',message='CALLS_INVALID: '||p_message; end if;
end; $$;
create or replace function ac_radar_private.calls_require_service() returns void
language plpgsql set search_path='' as $$
begin
  if auth.role() is distinct from 'service_role' then raise exception using errcode='42501',message='CALLS_FORBIDDEN'; end if;
end; $$;
create or replace function ac_radar_private.calls_fields(p_row jsonb,p_required text[],p_optional text[] default '{}') returns void
language plpgsql set search_path='' as $$
begin
  perform ac_radar_private.calls_assert(jsonb_typeof(p_row)='object' and p_row ?& p_required,'missing object fields');
  perform ac_radar_private.calls_assert(not exists(select 1 from jsonb_object_keys(p_row) k where not(k=any(p_required||p_optional))),'unexpected object fields');
end; $$;
create or replace function ac_radar_private.calls_text(p_value jsonb,p_nullable boolean default false,p_limit integer default 4000) returns void
language plpgsql set search_path='' as $$
begin
  if p_nullable and p_value='null'::jsonb then return; end if;
  perform ac_radar_private.calls_assert(jsonb_typeof(p_value)='string' and length(trim(p_value#>>'{}')) between 1 and p_limit,'invalid text');
end; $$;
create or replace function ac_radar_private.calls_strings(p_value jsonb) returns void
language plpgsql set search_path='' as $$
begin
  perform ac_radar_private.calls_assert(jsonb_typeof(p_value)='array','expected list');
  perform ac_radar_private.calls_assert(jsonb_array_length(p_value)<=1000 and not exists(select 1 from jsonb_array_elements(p_value) x where jsonb_typeof(x)<>'string' or length(x#>>'{}')>8000),'invalid string list');
end; $$;
create or replace function ac_radar_private.calls_date(p_value jsonb,p_precision jsonb) returns void
language plpgsql set search_path='' as $$
declare v text:=p_value#>>'{}'; precision_text text:=p_precision#>>'{}'; d date; t timestamptz;
begin
  if p_value='null'::jsonb then perform ac_radar_private.calls_assert(p_precision='null'::jsonb,'unknown date has precision'); return; end if;
  perform ac_radar_private.calls_assert(jsonb_typeof(p_value)='string' and precision_text in('date','datetime'),'invalid date precision');
  begin
    if precision_text='date' then
      perform ac_radar_private.calls_assert(v ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$','invalid date');
      d:=v::date;
      perform ac_radar_private.calls_assert(isfinite(d) and to_char(d,'YYYY-MM-DD')=v,'invalid calendar day');
    else
      perform ac_radar_private.calls_assert(v ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$','timezone required');
      d:=substring(v from 1 for 10)::date; t:=v::timestamptz;
      perform ac_radar_private.calls_assert(isfinite(t) and to_char(d,'YYYY-MM-DD')=substring(v from 1 for 10),'invalid datetime');
    end if;
  exception when others then raise exception using errcode='22023',message='CALLS_INVALID: invalid calendar date'; end;
end; $$;
create or replace function ac_radar_private.calls_refs(p_refs jsonb,p_ids jsonb,p_required boolean default true) returns void
language plpgsql set search_path='' as $$
begin
  perform ac_radar_private.calls_assert(jsonb_typeof(p_refs)='array','references must be a list');
  perform ac_radar_private.calls_assert(not p_required or jsonb_array_length(p_refs)>0,'evidence required');
  perform ac_radar_private.calls_assert(not exists(select 1 from jsonb_array_elements(p_refs) r where jsonb_typeof(r)<>'string' or not(p_ids ? (r#>>'{}'))),'missing evidence reference');
  perform ac_radar_private.calls_assert(jsonb_array_length(p_refs)=(select count(distinct value) from jsonb_array_elements_text(p_refs)),'duplicate reference');
end; $$;
create or replace function ac_radar_private.calls_ids(p_rows jsonb,p_key text) returns jsonb
language plpgsql set search_path='' as $$
declare r jsonb; v text; result jsonb:='{}';
begin
  perform ac_radar_private.calls_assert(jsonb_typeof(p_rows)='array','expected collection');
  perform ac_radar_private.calls_assert(jsonb_array_length(p_rows)<=2000,'collection too large');
  for r in select value from jsonb_array_elements(p_rows) loop
    v:=r->>p_key;
    perform ac_radar_private.calls_assert(jsonb_typeof(r)='object' and jsonb_typeof(r->p_key)='string' and v ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,179}$' and not(result ? v),'invalid or duplicate identifier');
    result:=result||jsonb_build_object(v,true);
  end loop;
  return result;
end; $$;

-- Only IDs are retained in config; cleartext is exclusively in the Vault view.
create or replace function ac_radar_private.calls_secret(p_id uuid) returns text
language sql stable set search_path='' as $$ select decrypted_secret from vault.decrypted_secrets where id=p_id; $$;
create or replace function ac_radar_private.calls_ensure_secrets() returns void
language plpgsql set search_path='' as $$
declare c ac_radar_private.calls_config; v uuid;
begin
  select * into c from ac_radar_private.calls_config where singleton for update;
  if c.webhook_secret_id is null then
    v:=vault.create_secret(replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),'ac_calls_webhook_secret');
    update ac_radar_private.calls_config set webhook_secret_id=v where singleton;
  end if;
  if c.worker_secret_id is null then
    v:=vault.create_secret(replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),'ac_calls_worker_secret');
    update ac_radar_private.calls_config set worker_secret_id=v where singleton;
  end if;
end; $$;
create or replace function ac_radar_private.calls_ready() returns boolean
language sql stable set search_path='' as $$
  select coalesce((select c.expected_account_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    and c.webhook_url ~ '^https://[A-Za-z0-9.-]+(:443)?/[^[:space:]?#]*$'
    and nullif(ac_radar_private.calls_secret(c.fireflies_secret_id),'') is not null
    and nullif(ac_radar_private.calls_secret(c.openai_secret_id),'') is not null
    and nullif(ac_radar_private.calls_secret(c.webhook_secret_id),'') is not null
    and nullif(ac_radar_private.calls_secret(c.worker_secret_id),'') is not null
    and exists(select 1 from ac_radar_private.owner o join auth.users u on u.id=o.user_id join public.ac_members m on m.user_id=u.id
      where o.singleton and u.email_confirmed_at is not null and lower(trim(u.email))='viniciusberteloni@gmail.com' and m.active and m.role='admin')
    from ac_radar_private.calls_config c where singleton),false);
$$;
select ac_radar_private.calls_ensure_secrets();

create or replace function public.ac_radar_calls_save_credentials(p_fireflies_key text default null,p_openai_key text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c ac_radar_private.calls_config; v uuid; k text;
begin
  perform ac_radar_private.require_owner();
  foreach k in array array[p_fireflies_key,p_openai_key] loop
    if k is not null then perform ac_radar_private.calls_assert(length(trim(k)) between 8 and 8192 and k !~ '[[:space:][:cntrl:]]','invalid credential'); end if;
  end loop;
  select * into c from ac_radar_private.calls_config where singleton for update;
  if p_fireflies_key is not null then
    if c.fireflies_secret_id is null then v:=vault.create_secret(p_fireflies_key,'ac_calls_fireflies_api_key');
    else perform vault.update_secret(c.fireflies_secret_id,p_fireflies_key);v:=c.fireflies_secret_id;end if;
    update ac_radar_private.calls_config set fireflies_secret_id=v where singleton;
  end if;
  if p_openai_key is not null then
    if c.openai_secret_id is null then v:=vault.create_secret(p_openai_key,'ac_calls_openai_api_key');
    else perform vault.update_secret(c.openai_secret_id,p_openai_key);v:=c.openai_secret_id;end if;
    update ac_radar_private.calls_config set openai_secret_id=v where singleton;
  end if;
  update ac_radar_private.calls_config set updated_at=clock_timestamp() where singleton;
  return jsonb_build_object('saved',true);
end; $$;
create or replace function public.ac_radar_calls_webhook_setup() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c ac_radar_private.calls_config;
begin
  perform ac_radar_private.require_owner();perform ac_radar_private.calls_ensure_secrets();
  select * into c from ac_radar_private.calls_config where singleton;
  return jsonb_build_object('url',c.webhook_url,'signing_secret',ac_radar_private.calls_secret(c.webhook_secret_id),'event','meeting.transcribed');
end; $$;
create or replace function public.ac_radar_calls_set_enabled(p_enabled boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  perform ac_radar_private.require_owner();perform ac_radar_private.calls_assert(p_enabled is not null,'enabled required');
  perform 1 from ac_radar_private.calls_config where singleton for update;
  if p_enabled and not ac_radar_private.calls_ready() then raise exception 'CALLS_NOT_CONFIGURED';end if;
  update ac_radar_private.calls_config set enabled=p_enabled,updated_at=clock_timestamp() where singleton;
  return jsonb_build_object('enabled',p_enabled);
end; $$;
create or replace function public.ac_calls_service_secrets() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c ac_radar_private.calls_config;
begin
  perform ac_radar_private.calls_require_service();select * into c from ac_radar_private.calls_config where singleton;
  return jsonb_build_object('fireflies_api_key',ac_radar_private.calls_secret(c.fireflies_secret_id),'openai_api_key',ac_radar_private.calls_secret(c.openai_secret_id),'webhook_secret',ac_radar_private.calls_secret(c.webhook_secret_id),'worker_secret',ac_radar_private.calls_secret(c.worker_secret_id));
end; $$;
create or replace function public.ac_calls_worker_context() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c ac_radar_private.calls_config; s jsonb; w jsonb;
begin
  perform ac_radar_private.calls_require_service();select * into c from ac_radar_private.calls_config where singleton;
  select jsonb_build_object('version',version,'payload',payload) into s from public.ac_radar_settings where singleton;
  select payload into w from public.ac_radar_runs where status<>'blocked' order by generated_at desc,created_at desc,run_id desc limit 1;
  return jsonb_build_object('enabled',c.enabled and ac_radar_private.calls_ready(),'expected_account_email',c.expected_account_email,'settings',s,'whatsapp_run',w);
end; $$;

create or replace function public.ac_calls_enqueue(p_event jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j ac_radar_private.calls_jobs; duplicate boolean:=false; rev bigint; delivered bigint;
begin
  perform ac_radar_private.calls_require_service();
  perform ac_radar_private.calls_assert(p_event is not null and octet_length(p_event::text)<=65536,'invalid event size');
  perform ac_radar_private.calls_fields(p_event,array['meeting_id','event','revision','delivery_timestamp_ms']);
  perform ac_radar_private.calls_assert(jsonb_typeof(p_event->'meeting_id')='string' and (p_event->>'meeting_id') ~ '^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,255}$' and p_event->>'event'='meeting.transcribed','invalid event identity');
  perform ac_radar_private.calls_assert(jsonb_typeof(p_event->'revision')='number' and (p_event->>'revision') ~ '^[0-9]{1,15}$' and jsonb_typeof(p_event->'delivery_timestamp_ms')='number' and (p_event->>'delivery_timestamp_ms') ~ '^[0-9]{1,15}$','invalid event timestamps');
  rev:=(p_event->>'revision')::bigint;delivered:=(p_event->>'delivery_timestamp_ms')::bigint;
  perform ac_radar_private.calls_assert(delivered>0 and delivered<=253402300799999 and rev<=delivered,'invalid revision');
  insert into ac_radar_private.calls_jobs(meeting_id,event,revision,delivery_timestamp_ms)
    values(p_event->>'meeting_id','meeting.transcribed',rev,delivered) on conflict(meeting_id,event,revision) do nothing returning * into j;
  if not found then duplicate:=true;select * into j from ac_radar_private.calls_jobs where meeting_id=p_event->>'meeting_id' and event='meeting.transcribed' and revision=rev;end if;
  return jsonb_build_object('job_id',j.id,'status',j.status,'duplicate',duplicate);
end; $$;
create or replace function public.ac_calls_claim(p_lease_seconds integer default 180) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j ac_radar_private.calls_jobs;
begin
  perform ac_radar_private.calls_require_service();perform ac_radar_private.calls_assert(p_lease_seconds between 30 and 900,'invalid lease duration');
  if not coalesce((select enabled from ac_radar_private.calls_config where singleton),false) or not ac_radar_private.calls_ready() then return null;end if;
  update ac_radar_private.calls_jobs set status='failed',last_error='LEASE_ATTEMPTS_EXHAUSTED',lease_expires_at=null,updated_at=clock_timestamp()
    where status='processing' and lease_expires_at<=clock_timestamp() and attempts>=5;
  select * into j from ac_radar_private.calls_jobs where attempts<5 and
    ((status in('queued','retry') and next_attempt_at<=clock_timestamp()) or (status='processing' and lease_expires_at<=clock_timestamp()))
    order by next_attempt_at,created_at,id for update skip locked limit 1;
  if not found then return null;end if;
  update ac_radar_private.calls_jobs set status='processing',attempts=attempts+1,lease_token=gen_random_uuid(),lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds),updated_at=clock_timestamp()
    where id=j.id returning * into j;
  return jsonb_build_object('id',j.id,'meeting_id',j.meeting_id,'revision',j.revision,'lease_token',j.lease_token,'attempts',j.attempts,'lease_expires_at',j.lease_expires_at,'staged_transcript',j.staged_transcript,'content_hash',j.content_hash);
end; $$;

create or replace function ac_radar_private.calls_validate_transcript(p_transcript jsonb,p_meeting text,p_hash text) returns void
language plpgsql set search_path='' as $$
declare r jsonb; ord bigint; idx text; seen jsonb:='{}';
begin
  if p_transcript is null or octet_length(p_transcript::text)>16777216 then raise exception 'CALLS_TOO_LARGE: transcript limit 16 MiB';end if;
  perform ac_radar_private.calls_assert(jsonb_typeof(p_transcript)='object' and p_transcript->>'id'=p_meeting and p_hash ~ '^[0-9a-f]{64}$','transcript identity/hash');
  perform ac_radar_private.calls_assert(jsonb_typeof(p_transcript->'sentences')='array' and jsonb_array_length(p_transcript->'sentences')<=100000,'invalid sentences');
  for r,ord in select value,ordinality from jsonb_array_elements(p_transcript->'sentences') with ordinality loop
    idx:=coalesce(r->>'index',(ord-1)::text);
    perform ac_radar_private.calls_assert(jsonb_typeof(r)='object' and idx ~ '^[0-9]{1,8}$' and not(seen ? idx)
      and ((jsonb_typeof(r->'text')='string' and length(trim(r->>'text'))>0) or (jsonb_typeof(r->'raw_text')='string' and length(trim(r->>'raw_text'))>0)),'invalid sentence');
    perform ac_radar_private.calls_assert(not(r ? 'index') or r->'index'='null'::jsonb or jsonb_typeof(r->'index')='number','invalid segment index');
    seen:=seen||jsonb_build_object(idx,true);
  end loop;
end; $$;
create or replace function public.ac_calls_stage_transcript(p_job_id uuid,p_lease_token uuid,p_transcript jsonb,p_content_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j ac_radar_private.calls_jobs;
begin
  perform ac_radar_private.calls_require_service();select * into j from ac_radar_private.calls_jobs where id=p_job_id for update;
  if not found or j.status<>'processing' or j.lease_token is distinct from p_lease_token or j.lease_expires_at<=clock_timestamp() then raise exception 'CALLS_LEASE_INVALID';end if;
  perform ac_radar_private.calls_validate_transcript(p_transcript,j.meeting_id,p_content_hash);
  if j.staged_transcript is not null and (j.content_hash is distinct from p_content_hash or j.staged_transcript<>p_transcript) then raise exception 'CALLS_TRANSCRIPT_COLLISION: request a new provider revision';end if;
  update ac_radar_private.calls_jobs set staged_transcript=p_transcript,content_hash=p_content_hash,updated_at=clock_timestamp() where id=j.id;
  return jsonb_build_object('saved',true);
end; $$;

create or replace function ac_radar_private.calls_validate_analysis(p_analysis jsonb,p_transcript jsonb,p_meeting text) returns void
language plpgsql set search_path='' as $$
declare a jsonb:=p_analysis; r jsonb; c jsonb; source jsonb; eids jsonb; ignored jsonb; cids jsonb; seen jsonb; src_speaker text; ref text; key text; client text; settings jsonb; wa jsonb; current_id text; cursor_id text; next_id text; total integer; n integer; seg_count integer; source_created timestamptz;
begin
  if a is null or octet_length(a::text)>2097152 then raise exception 'CALLS_TOO_LARGE: analysis limit 2 MiB';end if;
  perform ac_radar_private.calls_fields(a,array['schema_version','meeting','mapping','coverage','items','communication_cases','observations','one_on_ones','evidence','limitations']);
  perform ac_radar_private.calls_assert(a->'schema_version'='1'::jsonb,'schema version');
  perform ac_radar_private.calls_fields(a->'meeting',array['id','title','url','provider_created_at','occurred_at','occurred_precision','occurred_basis']);
  perform ac_radar_private.calls_assert(a->'meeting'->>'id'=p_meeting,'meeting identity');
  perform ac_radar_private.calls_text(a->'meeting'->'title',false,10000);
  perform ac_radar_private.calls_assert(a->'meeting'->'url'='null'::jsonb or (jsonb_typeof(a->'meeting'->'url')='string' and (a->'meeting'->>'url') ~ '^https://app\.fireflies\.ai/[^[:space:]?#]*$'),'invalid transcript URL');
  perform ac_radar_private.calls_date(a->'meeting'->'provider_created_at',case when a->'meeting'->'provider_created_at'='null'::jsonb then 'null'::jsonb else '"datetime"'::jsonb end);
  begin
    if p_transcript->>'date' is not null then
      perform ac_radar_private.calls_assert(jsonb_typeof(p_transcript->'date')='number' and (p_transcript->>'date')::numeric between 0 and 253402300799999,'invalid provider creation time');
      source_created:=to_timestamp((p_transcript->>'date')::double precision/1000.0);
    elsif p_transcript->>'dateString' is not null then
      perform ac_radar_private.calls_date(p_transcript->'dateString','"datetime"'::jsonb);
      source_created:=(p_transcript->>'dateString')::timestamptz;
    end if;
    if source_created is not null then
      perform ac_radar_private.calls_assert(abs(extract(epoch from ((a->'meeting'->>'provider_created_at')::timestamptz-source_created)))<=0.001,'provider creation time differs from source');
    else
      perform ac_radar_private.calls_assert(a->'meeting'->'provider_created_at'='null'::jsonb,'creation time absent in source');
    end if;
  exception when others then raise exception using errcode='22023',message='CALLS_INVALID: provider creation time differs from source';end;
  perform ac_radar_private.calls_date(a->'meeting'->'occurred_at',a->'meeting'->'occurred_precision');
  perform ac_radar_private.calls_text(a->'meeting'->'occurred_basis',true);
  perform ac_radar_private.calls_assert(a->'meeting'->'occurred_at'='null'::jsonb or a->'meeting'->'occurred_basis'<>'null'::jsonb,'actual call date requires a basis');
  perform ac_radar_private.calls_fields(a->'mapping',array['status','client_id','client_name','account_display','basis']);
  perform ac_radar_private.calls_assert(a->'mapping'->>'status' in('confirmed','pending_mapping'),'mapping status');
  select payload into settings from public.ac_radar_settings where singleton;
  select payload into wa from public.ac_radar_runs where status<>'blocked' order by generated_at desc,created_at desc,run_id desc limit 1;
  if a->'mapping'->>'status'='pending_mapping' then
    perform ac_radar_private.calls_assert(a->'mapping'->'client_id'='null'::jsonb and a->'mapping'->'client_name'='null'::jsonb and a->'mapping'->'account_display'='null'::jsonb,'pending mapping cannot assign a client/account');
    perform ac_radar_private.calls_text(a->'mapping'->'basis',true);
  else
    client:=a->'mapping'->>'client_id';
    perform ac_radar_private.calls_text(a->'mapping'->'basis');
    perform ac_radar_private.calls_text(a->'mapping'->'account_display',true,200);
    perform ac_radar_private.calls_assert(exists(select 1 from jsonb_array_elements(coalesce(settings->'groups','[]')) g where g->>'client_id'=client and g->>'client_name'=a->'mapping'->>'client_name' and (settings->'monitoring_group_ids') ? (g->>'group_id')),'client not in current selection');
  end if;
  perform ac_radar_private.calls_fields(a->'coverage',array['transcript_complete','sentences_read','total_sentences','whatsapp_run_id','whatsapp_cutoff','limitations']);
  total:=jsonb_array_length(p_transcript->'sentences');
  perform ac_radar_private.calls_assert(jsonb_typeof(a->'coverage'->'transcript_complete')='boolean' and jsonb_typeof(a->'coverage'->'sentences_read')='number' and (a->'coverage'->>'sentences_read') ~ '^[0-9]{1,8}$' and a->'coverage'->'total_sentences'=to_jsonb(total),'invalid coverage counts');
  n:=(a->'coverage'->>'sentences_read')::integer;
  perform ac_radar_private.calls_assert(n<=total and (a->'coverage'->'transcript_complete'='false'::jsonb or (n=total and total>0)),'unsupported complete coverage');
  perform ac_radar_private.calls_strings(a->'coverage'->'limitations');perform ac_radar_private.calls_strings(a->'limitations');
  if a->'coverage'->'whatsapp_run_id'='null'::jsonb then
    perform ac_radar_private.calls_assert(a->'coverage'->'whatsapp_cutoff'='null'::jsonb,'WA cutoff without run');
  else
    perform ac_radar_private.calls_assert(a->'coverage'->>'whatsapp_run_id'=wa->>'run_id' and a->'coverage'->'whatsapp_cutoff'=wa->'analysis_cutoff','WA context is not the latest valid run');
  end if;
  eids:=ac_radar_private.calls_ids(a->'evidence','evidence_id');
  for r in select value from jsonb_array_elements(a->'evidence') loop
    perform ac_radar_private.calls_fields(r,array['evidence_id','segment_index','speaker','start_time','end_time','timing_unit','short_excerpt']);
    perform ac_radar_private.calls_assert(jsonb_typeof(r->'segment_index')='number' and (r->>'segment_index') ~ '^[0-9]{1,8}$','invalid evidence segment');
    select value into source from jsonb_array_elements(p_transcript->'sentences') with ordinality s where coalesce(value->>'index',(ordinality-1)::text)=r->>'segment_index';
    perform ac_radar_private.calls_assert(source is not null,'evidence segment not found');
    src_speaker:=source->>'speaker_name';
    if src_speaker is null and jsonb_typeof(p_transcript->'speakers')='array' then select value->>'name' into src_speaker from jsonb_array_elements(p_transcript->'speakers') where value->>'id'=source->>'speaker_id' limit 1;end if;
    perform ac_radar_private.calls_assert((r->>'speaker') is not distinct from src_speaker and r->'start_time'=coalesce(source->'start_time','null'::jsonb) and r->'end_time'=coalesce(source->'end_time','null'::jsonb) and r->>'timing_unit'='unknown','evidence differs from source speaker/timing');
    perform ac_radar_private.calls_text(r->'short_excerpt',false,4000);
    perform ac_radar_private.calls_assert(position(r->>'short_excerpt' in coalesce(source->>'text',''))>0 or position(r->>'short_excerpt' in coalesce(source->>'raw_text',''))>0,'excerpt not in source');
  end loop;
  select count(distinct value->>'segment_index') into seg_count from jsonb_array_elements(a->'evidence');
  perform ac_radar_private.calls_assert(seg_count<=n,'evidence exceeds examined coverage');
  ignored:=ac_radar_private.calls_ids(a->'items','item_id');
  for r in select value from jsonb_array_elements(a->'items') loop
    perform ac_radar_private.calls_fields(r,array['item_id','kind','summary','status','owner_display','requested_at','requested_precision','requested_text','requester_display','request_evidence_ids','delivery_commitments','current_commitment_id','priority','priority_reason','evidence_ids','suggested_next_step','related_whatsapp_item_ids'],array['completion_evidence_ids','cancellation_evidence_ids']);
    perform ac_radar_private.calls_assert(r->>'kind' in('request','commitment','question') and r->>'status' in('aberta','em_andamento','aguardando_cliente','aguardando_equipe','aguardando_direcao','concluida','cancelada') and r->>'priority' in('high','medium','low','unclassified'),'invalid item enum');
    perform ac_radar_private.calls_text(r->'summary');
    foreach key in array array['owner_display','requested_text','requester_display','priority_reason','suggested_next_step'] loop perform ac_radar_private.calls_text(r->key,true);end loop;
    perform ac_radar_private.calls_date(r->'requested_at',r->'requested_precision');
    perform ac_radar_private.calls_refs(r->'evidence_ids',eids);
    perform ac_radar_private.calls_refs(r->'request_evidence_ids',eids,r->'requested_at'<>'null'::jsonb);
    if r ? 'completion_evidence_ids' or r->>'status'='concluida' then perform ac_radar_private.calls_refs(r->'completion_evidence_ids',eids,r->>'status'='concluida');end if;
    if r ? 'cancellation_evidence_ids' or r->>'status'='cancelada' then perform ac_radar_private.calls_refs(r->'cancellation_evidence_ids',eids,r->>'status'='cancelada');end if;
    cids:=ac_radar_private.calls_ids(r->'delivery_commitments','commitment_id');
    for c in select value from jsonb_array_elements(r->'delivery_commitments') loop
      perform ac_radar_private.calls_fields(c,array['commitment_id','promised_due_at','promised_due_precision','promised_due_text','promised_at','promised_at_precision','promised_by_display','promised_by_person_id','promised_by_role','revision_kind','supersedes_commitment_id','scope','evidence_ids']);
      perform ac_radar_private.calls_date(c->'promised_due_at',c->'promised_due_precision');perform ac_radar_private.calls_date(c->'promised_at',c->'promised_at_precision');
      foreach key in array array['promised_due_text','promised_by_display','promised_by_person_id','promised_by_role','scope'] loop perform ac_radar_private.calls_text(c->key,true);end loop;
      perform ac_radar_private.calls_refs(c->'evidence_ids',eids);
      perform ac_radar_private.calls_assert(c->>'revision_kind' in('original','revised'),'invalid promise revision');
      if c->>'revision_kind'='original' then perform ac_radar_private.calls_assert(c->'supersedes_commitment_id'='null'::jsonb,'original promise supersedes another');
      elsif c->'supersedes_commitment_id'='null'::jsonb then perform ac_radar_private.calls_assert(jsonb_array_length(a->'limitations')>0,'missing original promise requires a recorded gap');
      else perform ac_radar_private.calls_assert(jsonb_typeof(c->'supersedes_commitment_id')='string' and cids ? (c->>'supersedes_commitment_id') and c->>'supersedes_commitment_id'<>c->>'commitment_id','invalid promise predecessor');end if;
      cursor_id:=c->>'commitment_id';seen:='{}';
      while cursor_id is not null loop
        perform ac_radar_private.calls_assert(not(seen ? cursor_id),'promise revision cycle');seen:=seen||jsonb_build_object(cursor_id,true);
        select value->>'supersedes_commitment_id' into next_id from jsonb_array_elements(r->'delivery_commitments') where value->>'commitment_id'=cursor_id;
        cursor_id:=next_id;
      end loop;
    end loop;
    current_id:=r->>'current_commitment_id';
    if current_id is not null then perform ac_radar_private.calls_assert(jsonb_typeof(r->'current_commitment_id')='string' and cids ? current_id and not exists(select 1 from jsonb_array_elements(r->'delivery_commitments') promise_row where promise_row->>'supersedes_commitment_id'=current_id),'current promise missing or superseded');end if;
    perform ac_radar_private.calls_strings(r->'related_whatsapp_item_ids');
    for ref in select value from jsonb_array_elements_text(r->'related_whatsapp_item_ids') loop
      perform ac_radar_private.calls_assert(client is not null and a->'coverage'->>'whatsapp_run_id'=wa->>'run_id' and exists(select 1 from jsonb_array_elements(coalesce(wa->'items','[]')) i where i->>'item_id'=ref and i->>'client_id'=client),'WA link absent or cross-client');
    end loop;
  end loop;
  ignored:=ac_radar_private.calls_ids(a->'communication_cases','case_id');
  for r in select value from jsonb_array_elements(a->'communication_cases') loop
    perform ac_radar_private.calls_fields(r,array['case_id','case_type','context_summary','response_author_display','specific_issue','suggested_reply','evidence_ids']);
    perform ac_radar_private.calls_assert(r->>'case_type' in('sem_resposta_observada','resposta_parcial','resposta_vaga','contradicao','duvida_factual','tom_desalinhado'),'invalid communication type');
    foreach key in array array['context_summary','specific_issue','suggested_reply'] loop perform ac_radar_private.calls_text(r->key);end loop;
    perform ac_radar_private.calls_text(r->'response_author_display',true);perform ac_radar_private.calls_refs(r->'evidence_ids',eids);
  end loop;
  ignored:=ac_radar_private.calls_ids(a->'observations','observation_id');
  for r in select value from jsonb_array_elements(a->'observations') loop
    perform ac_radar_private.calls_fields(r,array['observation_id','kind','summary','assessment_kind','evidence_ids','suggested_next_step']);
    perform ac_radar_private.calls_assert(r->>'kind' in('risk','dissatisfaction','positive','negative') and r->>'assessment_kind' in('fact','interpretation'),'invalid observation');
    perform ac_radar_private.calls_text(r->'summary');perform ac_radar_private.calls_text(r->'suggested_next_step',true);perform ac_radar_private.calls_refs(r->'evidence_ids',eids);
  end loop;
  ignored:=ac_radar_private.calls_ids(a->'one_on_ones','coaching_id');
  for r in select value from jsonb_array_elements(a->'one_on_ones') loop
    perform ac_radar_private.calls_fields(r,array['coaching_id','account_display','talking_point','impact','suggested_agreement','followup_question','evidence_ids']);
    perform ac_radar_private.calls_text(r->'account_display',true,200);
    foreach key in array array['talking_point','impact','suggested_agreement','followup_question'] loop perform ac_radar_private.calls_text(r->key);end loop;
    perform ac_radar_private.calls_refs(r->'evidence_ids',eids);
  end loop;
end; $$;

create or replace function public.ac_calls_finish(p_job_id uuid,p_lease_token uuid,p_analysis jsonb,p_transcript jsonb,p_content_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j ac_radar_private.calls_jobs; a ac_radar_private.call_analyses; did_publish boolean:=false;
begin
  perform ac_radar_private.calls_require_service();select * into j from ac_radar_private.calls_jobs where id=p_job_id for update;
  if not found or j.lease_token is distinct from p_lease_token then raise exception 'CALLS_LEASE_INVALID';end if;
  if j.status='completed' then
    select * into a from ac_radar_private.call_analyses where analysis_id=j.analysis_id;
    if a.payload is distinct from p_analysis or j.staged_transcript is distinct from p_transcript or j.content_hash is distinct from p_content_hash then raise exception 'CALLS_ANALYSIS_COLLISION';end if;
    return jsonb_build_object('analysis_id',a.analysis_id,'published',j.published);
  end if;
  if j.status<>'processing' or j.lease_expires_at<=clock_timestamp() then raise exception 'CALLS_LEASE_INVALID';end if;
  perform ac_radar_private.calls_assert(j.staged_transcript is not null,'transcript must be staged');
  perform ac_radar_private.calls_validate_transcript(p_transcript,j.meeting_id,p_content_hash);
  if j.staged_transcript<>p_transcript or j.content_hash is distinct from p_content_hash then raise exception 'CALLS_TRANSCRIPT_COLLISION';end if;
  -- Stabilize the current selection during validation, without changing WA.
  perform 1 from public.ac_radar_settings where singleton for share;
  perform ac_radar_private.calls_validate_analysis(p_analysis,p_transcript,j.meeting_id);
  insert into ac_radar_private.call_analyses(job_id,meeting_id,revision,content_hash,payload)
    values(j.id,j.meeting_id,j.revision,p_content_hash,p_analysis) returning * into a;
  insert into ac_radar_private.call_heads(meeting_id,revision,analysis_id) values(j.meeting_id,j.revision,a.analysis_id)
    on conflict(meeting_id) do update set revision=excluded.revision,analysis_id=excluded.analysis_id
    where ac_radar_private.call_heads.revision<excluded.revision;
  did_publish:=found;
  update ac_radar_private.calls_jobs set status='completed',analysis_id=a.analysis_id,published=did_publish,lease_expires_at=null,last_error=null,updated_at=clock_timestamp() where id=j.id;
  return jsonb_build_object('analysis_id',a.analysis_id,'published',did_publish);
end; $$;
create or replace function public.ac_calls_fail(p_job_id uuid,p_lease_token uuid,p_error text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j ac_radar_private.calls_jobs; safe_error text;
begin
  perform ac_radar_private.calls_require_service();select * into j from ac_radar_private.calls_jobs where id=p_job_id for update;
  if not found or j.status<>'processing' or j.lease_token is distinct from p_lease_token or j.lease_expires_at<=clock_timestamp() then raise exception 'CALLS_LEASE_INVALID';end if;
  -- Store only known diagnostic codes, never arbitrary provider text/URLs/tokens.
  safe_error:=case when p_error in('ANALYSIS_INVALID','TRANSCRIPT_INVALID','TRANSCRIPT_NOT_READY','TRANSCRIPT_COLLISION','FIREFLIES_AUTH','FIREFLIES_FORBIDDEN','FIREFLIES_RATE_LIMIT','FIREFLIES_UNAVAILABLE','OPENAI_AUTH','OPENAI_RATE_LIMIT','OPENAI_UNAVAILABLE','ACCOUNT_MISMATCH','CONFIGURATION_REQUIRED','FIREFLIES_GRAPHQL_ERROR','FIREFLIES_ACCOUNT_MISMATCH','FIREFLIES_TRANSCRIPT_MISMATCH','AI_INVALID_OUTPUT','AI_INCOMPLETE_OUTPUT','TRANSCRIPT_TOO_LONG_REQUIRES_REVIEW','INVALID_ANALYSIS','RESPONSE_TOO_LARGE','REMOTE_TIMEOUT','PROCESSING_FAILED')
    or p_error ~ '^(FIREFLIES|AI)_HTTP_[1-5][0-9]{2}$' then p_error else 'CALLS_PROCESSING_FAILED' end;
  update ac_radar_private.calls_jobs set status=case when attempts>=5 then 'failed' else 'retry' end,last_error=safe_error,
    next_attempt_at=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,attempts-1)::integer)),lease_expires_at=null,updated_at=clock_timestamp()
    where id=j.id returning * into j;
  return jsonb_build_object('status',j.status,'attempts',j.attempts,'next_attempt_at',j.next_attempt_at);
end; $$;
create or replace function public.ac_radar_calls_snapshot() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c ac_radar_private.calls_config; calls jsonb; jobs jsonb; limits jsonb:='[]'; call_count integer; job_count integer;
begin
  perform ac_radar_private.require_owner();select * into c from ac_radar_private.calls_config where singleton;
  select count(*) into call_count from ac_radar_private.call_heads;select count(*) into job_count from ac_radar_private.calls_jobs;
  select coalesce(jsonb_agg(jsonb_build_object('analysis_id',x.analysis_id,'meeting_id',x.meeting_id,'revision',x.revision,'analyzed_at',x.analyzed_at,'payload',x.payload) order by x.analyzed_at desc,x.analysis_id),'[]') into calls
    from(select a.* from ac_radar_private.call_heads h join ac_radar_private.call_analyses a on a.analysis_id=h.analysis_id order by a.analyzed_at desc,a.analysis_id limit 100)x;
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'meeting_id',x.meeting_id,'status',x.status,'attempts',x.attempts,'last_error',x.last_error,'updated_at',x.updated_at) order by x.updated_at desc,x.id),'[]') into jobs
    from(select * from ac_radar_private.calls_jobs order by updated_at desc,id limit 20)x;
  if call_count>100 then limits:=limits||jsonb_build_array('Exibidas as 100 calls mais recentes; há outras análises privadas.');end if;
  if job_count>20 then limits:=limits||jsonb_build_array('Exibidas as 20 tentativas mais recentes; há outras tentativas privadas.');end if;
  if not c.enabled then limits:=limits||jsonb_build_array('Processamento desabilitado. Configuração ou validação ainda pendente.');end if;
  return jsonb_build_object('configured',ac_radar_private.calls_ready(),'enabled',c.enabled,
    'credential_status',jsonb_build_object('fireflies',nullif(ac_radar_private.calls_secret(c.fireflies_secret_id),'') is not null,'openai',nullif(ac_radar_private.calls_secret(c.openai_secret_id),'') is not null),
    'webhook_url',c.webhook_url,'calls',calls,'jobs',jobs,'limitations',limits);
end; $$;

-- Helpers are never exposed, including to service_role. Definer RPCs alone call them.
revoke all on function ac_radar_private.calls_assert(boolean,text),ac_radar_private.calls_require_service(),ac_radar_private.calls_fields(jsonb,text[],text[]),ac_radar_private.calls_text(jsonb,boolean,integer),ac_radar_private.calls_strings(jsonb),ac_radar_private.calls_date(jsonb,jsonb),ac_radar_private.calls_refs(jsonb,jsonb,boolean),ac_radar_private.calls_ids(jsonb,text),ac_radar_private.calls_secret(uuid),ac_radar_private.calls_ensure_secrets(),ac_radar_private.calls_ready(),ac_radar_private.calls_validate_transcript(jsonb,text,text),ac_radar_private.calls_validate_analysis(jsonb,jsonb,text) from public,anon,authenticated,service_role;
revoke all on function public.ac_calls_enqueue(jsonb),public.ac_calls_claim(integer),public.ac_calls_stage_transcript(uuid,uuid,jsonb,text),public.ac_calls_finish(uuid,uuid,jsonb,jsonb,text),public.ac_calls_fail(uuid,uuid,text),public.ac_calls_worker_context(),public.ac_calls_service_secrets() from public,anon,authenticated,service_role;
grant execute on function public.ac_calls_enqueue(jsonb),public.ac_calls_claim(integer),public.ac_calls_stage_transcript(uuid,uuid,jsonb,text),public.ac_calls_finish(uuid,uuid,jsonb,jsonb,text),public.ac_calls_fail(uuid,uuid,text),public.ac_calls_worker_context(),public.ac_calls_service_secrets() to service_role;
revoke all on function public.ac_radar_calls_snapshot(),public.ac_radar_calls_save_credentials(text,text),public.ac_radar_calls_webhook_setup(),public.ac_radar_calls_set_enabled(boolean) from public,anon,authenticated,service_role;
grant execute on function public.ac_radar_calls_snapshot(),public.ac_radar_calls_save_credentials(text,text),public.ac_radar_calls_webhook_setup(),public.ac_radar_calls_set_enabled(boolean) to authenticated;
commit;
