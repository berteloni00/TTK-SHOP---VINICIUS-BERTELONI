-- Radar privado do proprietário. Migração aditiva e reaplicável.
-- Não contém nomes de clientes, relatórios, credenciais nem UID de produção.
-- Após aplicar, configure ac_radar_private.owner pelo SQL Editor com o UID
-- confirmado do proprietário. Sem essa linha, todo acesso falha fechado.
begin;

create schema if not exists ac_radar_private;
revoke all on schema ac_radar_private from public, anon, authenticated;

create table if not exists ac_radar_private.owner (
  singleton boolean primary key default true check (singleton),
  user_id uuid not null unique references auth.users(id) on delete restrict,
  configured_at timestamptz not null default now()
);
alter table ac_radar_private.owner enable row level security;
revoke all on ac_radar_private.owner from public, anon, authenticated;

create or replace function public.ac_radar_is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from ac_radar_private.owner o
    join auth.users u on u.id=o.user_id
    join public.ac_members m on m.user_id=u.id
    where o.singleton and u.id=auth.uid()
      and lower(trim(u.email))='viniciusberteloni@gmail.com'
      and u.email_confirmed_at is not null
      and m.active and m.role='admin'
  );
$$;
revoke all on function public.ac_radar_is_owner() from public, anon, authenticated;
grant execute on function public.ac_radar_is_owner() to authenticated;

create table if not exists public.ac_radar_settings (
  singleton boolean primary key default true check (singleton),
  version integer not null default 0 check (version>=0),
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload)='object'),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
insert into public.ac_radar_settings(singleton) values(true) on conflict do nothing;

create table if not exists public.ac_radar_runs (
  run_id text primary key,
  report_date date not null,
  generated_at timestamptz not null,
  analysis_cutoff timestamptz,
  status text not null check (status in ('completed','partial','blocked')),
  settings_version integer not null check (settings_version>0),
  settings_payload jsonb not null check (jsonb_typeof(settings_payload)='object'),
  payload jsonb not null check (jsonb_typeof(payload)='object' and octet_length(payload::text)<=2097152),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id)
);
create index if not exists ac_radar_runs_history on public.ac_radar_runs(generated_at desc,created_at desc,run_id);
alter table public.ac_radar_settings enable row level security;
alter table public.ac_radar_runs enable row level security;
revoke all on public.ac_radar_settings, public.ac_radar_runs from public, anon, authenticated;
grant select on public.ac_radar_settings, public.ac_radar_runs to authenticated;
drop policy if exists ac_radar_settings_owner_read on public.ac_radar_settings;
create policy ac_radar_settings_owner_read on public.ac_radar_settings for select to authenticated using (public.ac_radar_is_owner());
drop policy if exists ac_radar_runs_owner_read on public.ac_radar_runs;
create policy ac_radar_runs_owner_read on public.ac_radar_runs for select to authenticated using (public.ac_radar_is_owner());

-- Helpers are in an unexposed schema; only the definer RPCs can invoke them.
create or replace function ac_radar_private.require_owner() returns void
language plpgsql set search_path = '' as $$
begin
  if not public.ac_radar_is_owner() then
    raise exception using errcode='42501',message='RADAR_FORBIDDEN: acesso exclusivo ao proprietário confirmado.';
  end if;
end; $$;

create or replace function ac_radar_private.id_map(p_rows jsonb,p_key text,p_groups text[] default null)
returns jsonb language plpgsql set search_path = '' as $$
declare row_data jsonb; result jsonb:='{}'; id_text text; group_text text; scope_ids text[];
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'RADAR_INVALID: % deve ser uma lista.',p_key; end if;
  for row_data in select value from jsonb_array_elements(p_rows) loop
    id_text:=row_data->>p_key; group_text:=row_data->>'group_id';
    if jsonb_typeof(row_data) is distinct from 'object' or jsonb_typeof(row_data->p_key) is distinct from 'string'
      or id_text !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,179}$' or result ? id_text then
      raise exception 'RADAR_INVALID: identificador % ausente, inválido ou repetido.',p_key;
    end if;
    if p_key='item_id' and row_data ? 'group_ids' then
      if jsonb_typeof(row_data->'group_ids') is distinct from 'array' then raise exception 'RADAR_INVALID: group_ids deve ser uma lista.'; end if;
      if exists(select 1 from jsonb_array_elements(row_data->'group_ids') r where jsonb_typeof(r.value)<>'string') then
        raise exception 'RADAR_INVALID: group_ids deve conter identificadores.';
      end if;
      select coalesce(array_agg(value),'{}'::text[]) into scope_ids from jsonb_array_elements_text(row_data->'group_ids');
      if cardinality(scope_ids)=0 or cardinality(scope_ids)<>(select count(distinct x) from unnest(scope_ids) x)
        or (p_groups is not null and not (p_groups @> scope_ids)) then raise exception 'RADAR_INVALID: grupos do item fora do escopo ou repetidos.'; end if;
      if row_data ? 'group_id' and (jsonb_typeof(row_data->'group_id') is distinct from 'string' or cardinality(scope_ids)<>1 or group_text<>scope_ids[1]) then
        raise exception 'RADAR_INVALID: group_id contradiz group_ids.';
      end if;
      result:=result||jsonb_build_object(id_text,row_data->'group_ids');
    else
      if p_groups is not null and (jsonb_typeof(row_data->'group_id') is distinct from 'string' or not (group_text=any(p_groups))) then
        raise exception 'RADAR_INVALID: grupo fora do escopo em %.',p_key;
      end if;
      result:=result||jsonb_build_object(id_text,group_text);
    end if;
  end loop;
  return result;
end; $$;

create or replace function ac_radar_private.assert_refs(p_refs jsonb,p_targets jsonb,p_group text default null)
returns void language plpgsql set search_path = '' as $$
declare ref jsonb; id_text text;
begin
  if jsonb_typeof(p_refs) is distinct from 'array' then raise exception 'RADAR_INVALID: referências devem ser listas.'; end if;
  for ref in select value from jsonb_array_elements(p_refs) loop
    id_text:=ref#>>'{}';
    if jsonb_typeof(ref) is distinct from 'string' or not (p_targets ? id_text)
      or (p_group is not null and not (
        (jsonb_typeof(p_targets->id_text)='array' and (p_targets->id_text) ? p_group)
        or (jsonb_typeof(p_targets->id_text)='string' and (p_targets->>id_text)=p_group)
      )) then
      raise exception 'RADAR_INVALID: referência ausente ou fora do grupo.';
    end if;
  end loop;
end; $$;

create or replace function ac_radar_private.assert_scoped_refs(p_refs jsonb,p_targets jsonb,p_groups text[])
returns void language plpgsql set search_path = '' as $$
declare ref text;
begin
  perform ac_radar_private.assert_refs(p_refs,p_targets);
  for ref in select value from jsonb_array_elements_text(p_refs) loop
    if not coalesce((p_targets->>ref)=any(p_groups),false) then raise exception 'RADAR_INVALID: evidência fora dos grupos do item.'; end if;
  end loop;
end; $$;

create or replace function ac_radar_private.validate_settings(p_settings jsonb) returns void
language plpgsql set search_path = '' as $$
declare catalog jsonb; selected text[]; row_data jsonb;
begin
  if p_settings is null or octet_length(p_settings::text)>2097152 then raise exception 'RADAR_TOO_LARGE: limite 2 MiB.'; end if;
  if jsonb_typeof(p_settings) is distinct from 'object' or p_settings->'schema_version' is distinct from '1'::jsonb
    or p_settings->>'profile_label' is distinct from 'SPHYNX'
    or p_settings->>'timezone' is distinct from 'America/Sao_Paulo'
    or jsonb_typeof(p_settings->'schedule_time') is distinct from 'string'
    or (p_settings->>'schedule_time') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    or jsonb_typeof(p_settings->'review_notes') is distinct from 'string' then
    raise exception 'RADAR_INVALID: configurações inválidas.';
  end if;
  catalog:=ac_radar_private.id_map(p_settings->'groups','group_id');
  if jsonb_array_length(p_settings->'groups')>500 then raise exception 'RADAR_INVALID: catálogo excede 500 grupos.'; end if;
  for row_data in select value from jsonb_array_elements(p_settings->'groups') loop
    if jsonb_typeof(row_data->'client_name') is distinct from 'string' or length(trim(row_data->>'client_name'))=0
      or jsonb_typeof(row_data->'group_title') is distinct from 'string' or length(trim(row_data->>'group_title'))=0 then
      raise exception 'RADAR_INVALID: nome de cliente e título do grupo obrigatórios.';
    end if;
  end loop;
  perform ac_radar_private.assert_refs(p_settings->'monitoring_group_ids',catalog);
  select coalesce(array_agg(value),'{}'::text[]) into selected from jsonb_array_elements_text(p_settings->'monitoring_group_ids');
  if cardinality(selected)<>(select count(distinct x) from unnest(selected) x) then raise exception 'RADAR_INVALID: seleção repetida.'; end if;
end; $$;

create or replace function public.ac_radar_save_settings(p_settings jsonb,p_expected_version integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare current_row public.ac_radar_settings;
begin
  perform ac_radar_private.require_owner();
  perform ac_radar_private.validate_settings(p_settings);
  select * into current_row from public.ac_radar_settings where singleton for update;
  if p_expected_version is null or current_row.version<>p_expected_version then
    raise exception 'RADAR_SETTINGS_CONFLICT: configuração alterada; atualize antes de salvar.';
  end if;
  update public.ac_radar_settings set payload=p_settings,version=version+1,updated_at=now(),updated_by=auth.uid()
    where singleton returning * into current_row;
  return jsonb_build_object('version',current_row.version,'payload',current_row.payload);
end; $$;

create or replace function ac_radar_private.validate_run(p_run jsonb,p_settings jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  selected text[]; group_ids text[]; group_map jsonb; evidence_map jsonb; item_map jsonb; people_map jsonb; ignored_map jsonb;
  row_data jsonb; pair record; group_text text; item_scope text[]; scope_json jsonb; client_count integer; stamp timestamptz; cutoff timestamptz; day date;
  blocked boolean:=p_run->>'status'='blocked';
begin
  if jsonb_typeof(p_run) is distinct from 'object' or p_run->'schema_version' is distinct from '1'::jsonb
    or jsonb_typeof(p_run->'run_id') is distinct from 'string' or (p_run->>'run_id') !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,179}$'
    or coalesce(p_run->>'status','') not in ('completed','partial','blocked')
    or jsonb_typeof(p_run->'summary') is distinct from 'object' or jsonb_typeof(p_run->'limitations') is distinct from 'array'
    or jsonb_typeof(p_run->'report_date') is distinct from 'string' or (p_run->>'report_date') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or jsonb_typeof(p_run->'generated_at') is distinct from 'string'
    or (p_run->>'generated_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*(Z|[+-][0-9]{2}:[0-9]{2})$' then
    raise exception 'RADAR_INVALID: envelope de relatório inválido.';
  end if;
  if not blocked and jsonb_typeof(p_run->'analysis_cutoff') is distinct from 'string' then raise exception 'RADAR_INVALID: leitura precisa de data de corte.'; end if;
  if p_run->>'analysis_cutoff' is not null and (p_run->>'analysis_cutoff') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*(Z|[+-][0-9]{2}:[0-9]{2})$' then
    raise exception 'RADAR_INVALID: data de corte inválida.';
  end if;
  begin
    stamp:=(p_run->>'generated_at')::timestamptz; cutoff:=(p_run->>'analysis_cutoff')::timestamptz; day:=(p_run->>'report_date')::date;
  exception when others then raise exception 'RADAR_INVALID: data inválida.'; end;
  if not isfinite(stamp) or (cutoff is not null and (not isfinite(cutoff) or cutoff>stamp)) then raise exception 'RADAR_INVALID: corte posterior à geração.'; end if;
  select coalesce(array_agg(value),'{}'::text[]) into selected from jsonb_array_elements_text(p_settings->'monitoring_group_ids');
  group_map:=ac_radar_private.id_map(p_run->'groups','group_id');
  select coalesce(array_agg(key),'{}'::text[]) into group_ids from jsonb_object_keys(group_map) key;
  if blocked then
    if cardinality(group_ids)<>0 then raise exception 'RADAR_INVALID: tentativa bloqueada não contém análise nova.'; end if;
  elsif not (group_ids @> selected and selected @> group_ids) then
    raise exception 'RADAR_INVALID: grupos do relatório diferem da seleção.';
  end if;
  for row_data in select value from jsonb_array_elements(p_run->'groups') loop
    if jsonb_typeof(row_data->'client_name') is distinct from 'string' or length(trim(row_data->>'client_name'))=0
      or jsonb_typeof(row_data->'group_title') is distinct from 'string' or length(trim(row_data->>'group_title'))=0
      or jsonb_typeof(row_data->'coverage') is distinct from 'object' or jsonb_typeof(row_data->'pending_media') is distinct from 'array' then
      raise exception 'RADAR_INVALID: grupo sem identificação ou cobertura.';
    end if;
  end loop;
  evidence_map:=ac_radar_private.id_map(p_run->'evidence','evidence_id',group_ids);
  item_map:=ac_radar_private.id_map(p_run->'items','item_id',group_ids);
  ignored_map:=ac_radar_private.id_map(p_run->'communication_cases','case_id',group_ids);
  people_map:=ac_radar_private.id_map(coalesce(p_run->'people','[]'::jsonb),'person_id');
  ignored_map:=ac_radar_private.id_map(coalesce(p_run->'events','[]'::jsonb),'event_id');
  if blocked and (jsonb_array_length(p_run->'evidence')+jsonb_array_length(p_run->'items')+jsonb_array_length(p_run->'communication_cases')
    +jsonb_array_length(coalesce(p_run->'people','[]'::jsonb))+jsonb_array_length(coalesce(p_run->'events','[]'::jsonb)))<>0 then
    raise exception 'RADAR_INVALID: tentativa bloqueada não contém análise nova.';
  end if;
  for row_data in select value from jsonb_array_elements(p_run->'items') loop
    group_text:=row_data->>'group_id';
    scope_json:=item_map->(row_data->>'item_id');
    if jsonb_typeof(scope_json)<>'array' then scope_json:=jsonb_build_array(scope_json); end if;
    select array_agg(value) into item_scope from jsonb_array_elements_text(scope_json);
    select count(distinct g.value->>'client_id') into client_count from jsonb_array_elements(p_settings->'groups') g where g.value->>'group_id'=any(item_scope);
    if (cardinality(item_scope)>1 and client_count<>1) or exists(
      select 1 from jsonb_array_elements(p_settings->'groups') g where g.value->>'group_id'=any(item_scope)
        and row_data->>'client_id' is not null and g.value->>'client_id' is not null and row_data->>'client_id'<>g.value->>'client_id'
    ) then raise exception 'RADAR_INVALID: item não pode atravessar clientes.'; end if;
    if jsonb_typeof(row_data->'summary') is distinct from 'string' or length(trim(row_data->>'summary'))=0
      or coalesce(row_data->>'status','') not in ('aberta','em_andamento','aguardando_cliente','aguardando_equipe','aguardando_direcao','concluida','cancelada') then
      raise exception 'RADAR_INVALID: item sem resumo ou estado válido.';
    end if;
    perform ac_radar_private.assert_scoped_refs(row_data->'evidence_ids',evidence_map,item_scope);
    if jsonb_array_length(row_data->'evidence_ids')=0 then raise exception 'RADAR_INVALID: item sem evidência.'; end if;
    if row_data->>'status'='concluida' then
      perform ac_radar_private.assert_scoped_refs(row_data->'completion_evidence_ids',evidence_map,item_scope);
      if jsonb_array_length(row_data->'completion_evidence_ids')=0 then raise exception 'RADAR_INVALID: conclusão sem evidência posterior.'; end if;
    end if;
    for pair in select key,value from jsonb_each(row_data) loop
      if pair.key like '%\_evidence_ids' escape '\' then perform ac_radar_private.assert_scoped_refs(pair.value,evidence_map,item_scope); end if;
    end loop;
    if jsonb_typeof(row_data->'owner_basis')='array' then perform ac_radar_private.assert_scoped_refs(row_data->'owner_basis',evidence_map,item_scope); end if;
    if row_data ? 'owner_person_ids' then perform ac_radar_private.assert_refs(row_data->'owner_person_ids',people_map); end if;
  end loop;
  for row_data in select value from jsonb_array_elements(p_run->'communication_cases') loop
    group_text:=row_data->>'group_id';
    if coalesce(row_data->>'status','') not in ('open','corrected','not_assessable') then raise exception 'RADAR_INVALID: estado de comunicação inválido.'; end if;
    if row_data ? 'evidence_ids' then perform ac_radar_private.assert_refs(row_data->'evidence_ids',evidence_map,group_text); end if;
    for pair in select key,value from jsonb_each(row_data) loop
      if pair.key like '%\_evidence_ids' escape '\' then perform ac_radar_private.assert_refs(pair.value,evidence_map,group_text); end if;
    end loop;
    if row_data ? 'related_item_ids' then perform ac_radar_private.assert_refs(row_data->'related_item_ids',item_map,group_text); end if;
    if row_data->>'response_author_person_id' is not null then
      perform ac_radar_private.assert_refs(jsonb_build_array(row_data->'response_author_person_id'),people_map);
    end if;
    if row_data ? 'other_response_author_person_ids' then perform ac_radar_private.assert_refs(row_data->'other_response_author_person_ids',people_map); end if;
  end loop;
  for row_data in select value from jsonb_array_elements(coalesce(p_run->'people','[]'::jsonb)) loop
    if jsonb_typeof(row_data->'role_evidence')='array' then perform ac_radar_private.assert_refs(row_data->'role_evidence',evidence_map); end if;
  end loop;
  for row_data in select value from jsonb_array_elements(coalesce(p_run->'events','[]'::jsonb)) loop
    perform ac_radar_private.assert_refs(jsonb_build_array(row_data->'item_id'),item_map);
    scope_json:=item_map->(row_data->>'item_id');
    if jsonb_typeof(scope_json)<>'array' then scope_json:=jsonb_build_array(scope_json); end if;
    select array_agg(value) into item_scope from jsonb_array_elements_text(scope_json);
    perform ac_radar_private.assert_scoped_refs(row_data->'evidence_ids',evidence_map,item_scope);
  end loop;
end; $$;

create or replace function public.ac_radar_publish(p_run jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare settings_row public.ac_radar_settings; previous jsonb; id_text text;
begin
  perform ac_radar_private.require_owner();
  if p_run is null or octet_length(p_run::text)>2097152 then raise exception 'RADAR_TOO_LARGE: limite 2 MiB.'; end if;
  id_text:=p_run->>'run_id';
  -- Shared lock serializes configuration changes and competing publications.
  select * into settings_row from public.ac_radar_settings where singleton for update;
  select payload into previous from public.ac_radar_runs where run_id=id_text;
  if found then
    if previous=p_run then return jsonb_build_object('run_id',id_text,'idempotent',true); end if;
    raise exception 'RADAR_RUN_COLLISION: run_id já usado com conteúdo diferente.';
  end if;
  if settings_row.version=0 or p_run->'settings_version' is distinct from to_jsonb(settings_row.version) then
    raise exception 'RADAR_SETTINGS_CONFLICT: relatório não corresponde à versão vigente.';
  end if;
  perform ac_radar_private.validate_run(p_run,settings_row.payload);
  insert into public.ac_radar_runs(run_id,report_date,generated_at,analysis_cutoff,status,settings_version,settings_payload,payload,created_by)
    values(id_text,(p_run->>'report_date')::date,(p_run->>'generated_at')::timestamptz,(p_run->>'analysis_cutoff')::timestamptz,
      p_run->>'status',settings_row.version,settings_row.payload,p_run,auth.uid());
  return jsonb_build_object('run_id',id_text,'idempotent',false);
end; $$;

create or replace function public.ac_radar_snapshot(p_run_id text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare settings_json jsonb; history_json jsonb; selected_run jsonb; latest_json jsonb;
begin
  perform ac_radar_private.require_owner();
  select jsonb_build_object('version',version,'payload',payload) into settings_json from public.ac_radar_settings where singleton;
  select coalesce(jsonb_agg(jsonb_build_object('run_id',run_id,'report_date',report_date,'generated_at',generated_at,
    'analysis_cutoff',analysis_cutoff,'status',status,'settings_version',settings_version,'summary',payload->'summary',
    'group_count',jsonb_array_length(payload->'groups')) order by generated_at desc,created_at desc,run_id desc),'[]'::jsonb)
    into history_json from public.ac_radar_runs;
  select payload into latest_json from public.ac_radar_runs order by generated_at desc,created_at desc,run_id desc limit 1;
  if p_run_id is not null then
    select payload into selected_run from public.ac_radar_runs where run_id=p_run_id;
    if not found then raise exception 'RADAR_NOT_FOUND: relatório não encontrado.'; end if;
  else
    select payload into selected_run from public.ac_radar_runs where status<>'blocked' order by generated_at desc,created_at desc,run_id desc limit 1;
  end if;
  return jsonb_build_object('settings',settings_json,'history',history_json,'run',selected_run,'latest_attempt',latest_json);
end; $$;

revoke all on all functions in schema ac_radar_private from public, anon, authenticated;
revoke all on function public.ac_radar_save_settings(jsonb,integer), public.ac_radar_publish(jsonb), public.ac_radar_snapshot(text) from public, anon, authenticated;
grant execute on function public.ac_radar_save_settings(jsonb,integer), public.ac_radar_publish(jsonb), public.ac_radar_snapshot(text) to authenticated;

commit;

-- Provisionamento separado, pelo administrador do banco, após confirmar o UID:
-- insert into ac_radar_private.owner(singleton,user_id)
-- select true,u.id from auth.users u join public.ac_members m on m.user_id=u.id
-- where u.id = 'UID_CONFIRMADO'::uuid
--   and lower(trim(u.email))='viniciusberteloni@gmail.com'
--   and u.email_confirmed_at is not null and m.active and m.role='admin'
-- on conflict(singleton) do nothing;
-- Verifique uma linha. Não há RPC para outro administrador se nomear proprietário.
