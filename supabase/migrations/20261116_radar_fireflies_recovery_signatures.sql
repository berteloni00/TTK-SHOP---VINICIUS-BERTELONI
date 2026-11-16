-- Recovery only: signed Fireflies webhooks remain the primary trigger.
-- No provider credentials or service-role key are stored in cron commands.
begin;
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- Do not rely on revoking pg_net queue access: managed extension ownership may
-- retain PUBLIC grants. Queue only a short-lived signed recovery request, never
-- the worker secret, a bearer, provider credentials or a service-role key.
-- The receiver verifies raw UTF8 bytes, scope and timestamp within 90 seconds.

create or replace function ac_radar_private.calls_dispatch_recovery() returns bigint
language plpgsql security definer set search_path='' as $$
declare c ac_radar_private.calls_config; signing_key text; request_body jsonb; signature text; request_id bigint;
begin
  select * into c from ac_radar_private.calls_config where singleton;
  if not coalesce(c.enabled,false) or not ac_radar_private.calls_ready() then return null;end if;
  if c.webhook_url !~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/fireflies-radar/webhook$' then return null;end if;
  if not exists(select 1 from ac_radar_private.calls_jobs where
    (status in('queued','retry') and next_attempt_at<=clock_timestamp() and attempts<5)
    or (status='processing' and lease_expires_at<=clock_timestamp())) then return null;end if;
  signing_key:=ac_radar_private.calls_secret(c.worker_secret_id);
  if nullif(signing_key,'') is null then return null;end if;
  request_body:=jsonb_build_object('scope','radar.calls.recovery','timestamp',floor(extract(epoch from clock_timestamp())*1000)::bigint);
  signature:='sha256='||encode(extensions.hmac(convert_to(request_body::text,'UTF8'),convert_to(signing_key,'UTF8'),'sha256'),'hex');
  select net.http_post(
    url:=regexp_replace(c.webhook_url,'/webhook$','/worker'),
    headers:=jsonb_build_object('Content-Type','application/json','X-Radar-Worker-Signature',signature),
    body:=request_body,
    timeout_milliseconds:=200000
  ) into request_id;
  return request_id;
end; $$;
revoke all on function ac_radar_private.calls_dispatch_recovery() from public,anon,authenticated,service_role;
-- Named schedule is idempotent; unrelated cron jobs are untouched.
select cron.schedule('ac-fireflies-radar-recovery','* * * * *','select ac_radar_private.calls_dispatch_recovery();');
commit;
