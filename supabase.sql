-- COURTSIDE v1 · Run the complete script in Supabase SQL Editor.
-- No service_role key is used in the browser. All client writes go through RPCs.
begin;

create table if not exists public.court_rooms (
  id uuid primary key default gen_random_uuid(),
  view_key uuid not null default gen_random_uuid(),
  owner_id uuid not null references auth.users(id),
  state jsonb not null,
  version bigint not null default 1,
  last_operation uuid,
  holder_id uuid references auth.users(id),
  holder_device uuid,
  holder_label text,
  lease_until timestamptz,
  updated_at timestamptz not null default clock_timestamp()
);
create table if not exists public.court_editors (
  room_id uuid not null references public.court_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (room_id, user_id)
);
alter table public.court_rooms enable row level security;
alter table public.court_editors enable row level security;
-- No table policies: even authenticated clients must use the checked RPCs below.
revoke all on table public.court_rooms from anon, authenticated;
revoke all on table public.court_editors from anon, authenticated;

create or replace function public.court_validate_state(p_state jsonb)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_state is null or jsonb_typeof(p_state) <> 'object'
    or p_state->>'schema' is distinct from '1'
    or jsonb_typeof(p_state->'players') is distinct from 'array'
    or jsonb_typeof(p_state->'history') is distinct from 'array'
    or jsonb_typeof(p_state->'archives') is distinct from 'array'
    or jsonb_typeof(p_state->'today') is distinct from 'object'
    or jsonb_typeof(p_state->'today'->'entries') is distinct from 'object'
    or jsonb_typeof(p_state->'today'->'fees') is distinct from 'object'
    or coalesce(p_state->'today'->>'courtCount','') not in ('1','2')
    or jsonb_typeof(p_state->'today'->'courts') is distinct from 'array'
  then raise exception 'INVALID_STATE'; end if;
  if jsonb_array_length(p_state->'players') > 500
    or jsonb_array_length(p_state->'history') > 50000
    or jsonb_array_length(p_state->'today'->'courts') <> 2
    or octet_length(p_state::text) > 10485760
  then raise exception 'STATE_TOO_LARGE'; end if;
end;
$$;

-- Internal helper. Never executable by public API callers.
create or replace function public.court_snapshot(p_room uuid, p_device uuid)
returns jsonb language sql volatile security definer set search_path = '' as $$
  select jsonb_build_object(
    'room', r.id,
    'state', r.state,
    'version', r.version,
    'last_operation', r.last_operation,
    'server_time', clock_timestamp(),
    'can_edit', exists(select 1 from public.court_editors e where e.room_id=r.id and e.user_id=auth.uid()),
    'is_owner', coalesce(r.owner_id=auth.uid(),false),
    'editable', coalesce(r.holder_id=auth.uid() and r.holder_device=p_device and r.lease_until>clock_timestamp(),false),
    'holder_label', case when r.lease_until>clock_timestamp() then r.holder_label else null end,
    'lease_until', r.lease_until
  ) from public.court_rooms r where r.id=p_room;
$$;

create or replace function public.court_create(p_state jsonb, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.court_rooms;
begin
  if auth.uid() is null then raise exception 'LOGIN_REQUIRED'; end if;
  perform public.court_validate_state(p_state);
  -- Creation is deliberately for pre-created organizer accounts. Disable public
  -- signup in Supabase Auth if this installation is for your private group.
  insert into public.court_rooms(owner_id,state) values(auth.uid(),p_state) returning * into r;
  insert into public.court_editors(room_id,user_id) values(r.id,auth.uid());
  return public.court_snapshot(r.id,null) || jsonb_build_object('view',r.view_key);
end;
$$;

create or replace function public.court_read(p_room uuid, p_view uuid, p_device uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.court_rooms;
begin
  select * into r from public.court_rooms where id=p_room;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if r.view_key is distinct from p_view and not exists(
    select 1 from public.court_editors where room_id=p_room and user_id=auth.uid()
  ) then raise exception 'ROOM_NOT_FOUND'; end if;
  return public.court_snapshot(p_room,p_device);
end;
$$;

create or replace function public.court_acquire(p_room uuid, p_device uuid, p_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.court_rooms;
begin
  if auth.uid() is null or not exists(
    select 1 from public.court_editors where room_id=p_room and user_id=auth.uid()
  ) then raise exception 'NOT_EDITOR'; end if;
  if p_device is null then raise exception 'DEVICE_REQUIRED'; end if;
  select * into r from public.court_rooms where id=p_room for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if r.lease_until>clock_timestamp() and
    (r.holder_id is distinct from auth.uid() or r.holder_device is distinct from p_device)
  then raise exception 'LOCKED'; end if;
  update public.court_rooms set holder_id=auth.uid(),holder_device=p_device,
    holder_label=left(coalesce(nullif(trim(p_label),''),'组织者'),40),
    lease_until=clock_timestamp()+interval '90 seconds'
    where id=p_room;
  return public.court_snapshot(p_room,p_device);
end;
$$;

create or replace function public.court_release(p_room uuid, p_device uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  -- A stale tab cannot release a newer holder's lock.
  update public.court_rooms set holder_id=null,holder_device=null,
    holder_label=null,lease_until=null
    where id=p_room and holder_id=auth.uid() and holder_device=p_device;
  if auth.uid() is null or not exists(
    select 1 from public.court_editors where room_id=p_room and user_id=auth.uid()
  ) then raise exception 'NOT_EDITOR'; end if;
  return public.court_snapshot(p_room,p_device);
end;
$$;

-- Heartbeats may extend an existing lease, but must never reacquire a released
-- or expired lease. This prevents a delayed background tab from stealing it.
create or replace function public.court_renew(p_room uuid, p_device uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists(
    select 1 from public.court_editors where room_id=p_room and user_id=auth.uid()
  ) then raise exception 'NOT_EDITOR'; end if;
  update public.court_rooms set lease_until=clock_timestamp()+interval '90 seconds'
    where id=p_room and holder_id=auth.uid() and holder_device=p_device
      and lease_until>clock_timestamp();
  if not found then raise exception 'LEASE_EXPIRED'; end if;
  return public.court_snapshot(p_room,p_device);
end;
$$;

create or replace function public.court_save(
  p_room uuid, p_device uuid, p_version bigint, p_state jsonb, p_operation uuid
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.court_rooms;
begin
  if auth.uid() is null or not exists(
    select 1 from public.court_editors where room_id=p_room and user_id=auth.uid()
  ) then raise exception 'NOT_EDITOR'; end if;
  select * into r from public.court_rooms where id=p_room for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if r.holder_id is distinct from auth.uid() or r.holder_device is distinct from p_device
    or r.lease_until is null or r.lease_until<=clock_timestamp()
  then raise exception 'LEASE_EXPIRED'; end if;
  if p_operation is null then raise exception 'OPERATION_REQUIRED'; end if;
  -- Retry of an already-committed request returns its current snapshot.
  if r.last_operation=p_operation then return public.court_snapshot(p_room,p_device); end if;
  if r.version is distinct from p_version then raise exception 'VERSION_CONFLICT'; end if;
  perform public.court_validate_state(p_state);
  update public.court_rooms set state=p_state,version=version+1,
    last_operation=p_operation,updated_at=clock_timestamp(),
    lease_until=clock_timestamp()+interval '90 seconds'
    where id=p_room;
  return public.court_snapshot(p_room,p_device);
end;
$$;

create or replace function public.court_grant_editor(p_room uuid, p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare target_id uuid;
begin
  if auth.uid() is null or not exists(
    select 1 from public.court_rooms where id=p_room and owner_id=auth.uid()
  ) then raise exception 'NOT_OWNER'; end if;
  select id into target_id from auth.users where lower(email)=lower(trim(p_email));
  if target_id is null then raise exception 'USER_NOT_FOUND'; end if;
  insert into public.court_editors(room_id,user_id) values(p_room,target_id) on conflict do nothing;
  return jsonb_build_object('ok',true);
end;
$$;

-- Explicit grants: SECURITY DEFINER functions have no implicit public execute.
revoke all on function public.court_validate_state(jsonb) from public,anon,authenticated;
revoke all on function public.court_snapshot(uuid,uuid) from public,anon,authenticated;
revoke all on function public.court_create(jsonb,text) from public,anon,authenticated;
revoke all on function public.court_read(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.court_acquire(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.court_release(uuid,uuid) from public,anon,authenticated;
revoke all on function public.court_renew(uuid,uuid) from public,anon,authenticated;
revoke all on function public.court_save(uuid,uuid,bigint,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.court_grant_editor(uuid,text) from public,anon,authenticated;
grant execute on function public.court_read(uuid,uuid,uuid) to anon,authenticated;
grant execute on function public.court_create(jsonb,text) to authenticated;
grant execute on function public.court_acquire(uuid,uuid,text) to authenticated;
grant execute on function public.court_release(uuid,uuid) to authenticated;
grant execute on function public.court_renew(uuid,uuid) to authenticated;
grant execute on function public.court_save(uuid,uuid,bigint,jsonb,uuid) to authenticated;
grant execute on function public.court_grant_editor(uuid,text) to authenticated;

notify pgrst, 'reload schema';
commit;
