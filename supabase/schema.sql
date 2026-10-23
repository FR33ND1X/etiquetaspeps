create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 80),
  username text,
  role text not null default 'staff',
  created_at timestamptz not null default now()
);

alter table public.profiles
add column if not exists role text not null default 'staff';

alter table public.profiles
add column if not exists username text;

do $$
declare
  profile_row record;
  candidate_username text;
  username_suffix text;
begin
  for profile_row in
    select p.id, p.username, u.email
    from public.profiles p
    left join auth.users u on u.id = p.id
    where p.username is null
    order by p.created_at, p.id
  loop
    candidate_username := lower(regexp_replace(
      left(split_part(coalesce(profile_row.email, ''), '@', 1), 23),
      '[^a-z0-9._-]', '', 'g'
    ));

    if candidate_username !~ '^[a-z0-9][a-z0-9._-]{2,22}$' then
      candidate_username := 'user-' || left(replace(profile_row.id::text, '-', ''), 12);
    end if;

    if exists (
      select 1 from public.profiles p
      where lower(p.username) = candidate_username
    ) then
      username_suffix := left(replace(profile_row.id::text, '-', ''), 8);
      candidate_username := left(candidate_username, 23) || '-' || username_suffix;
    end if;

    update public.profiles
    set username = candidate_username
    where id = profile_row.id;
  end loop;
end;
$$;

do $$
begin
  if exists (
    select 1
    from public.profiles p
    join auth.users existing_user
      on lower(existing_user.email) = lower(p.username || '@accounts.peps.invalid')
      and existing_user.id <> p.id
  ) then
    raise exception 'No se pudieron asignar los usuarios internos: una dirección técnica ya está en uso.';
  end if;
end;
$$;

update auth.users u
set email = p.username || '@accounts.peps.invalid',
    email_confirmed_at = coalesce(u.email_confirmed_at, now()),
    raw_user_meta_data = jsonb_set(
      coalesce(u.raw_user_meta_data, '{}'::jsonb),
      '{username}',
      to_jsonb(p.username),
      true
    ),
    updated_at = now()
from public.profiles p
where p.id = u.id
  and u.email is distinct from p.username || '@accounts.peps.invalid';

alter table public.profiles
alter column username set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_username_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
    add constraint profiles_username_check
    check (username ~ '^[a-z0-9][a-z0-9._-]{2,31}$');
  end if;
end;
$$;

create unique index if not exists profiles_username_lower_idx
on public.profiles (lower(username));

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_role_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
    add constraint profiles_role_check check (role in ('admin', 'staff'));
  end if;
end;
$$;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  new_username text;
begin
  new_username := lower(coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'username'), ''),
    split_part(coalesce(new.email, ''), '@', 1)
  ));

  if new_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then
    new_username := 'user-' || left(replace(new.id::text, '-', ''), 12);
  end if;

  insert into public.profiles (id, display_name, username)
  values (
    new.id,
    coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
      new_username,
      'Usuario'
    ),
    new_username
  )
  on conflict (id) do update
  set username = excluded.username;
  return new;
end;
$$;

drop trigger if exists create_profile_after_signup on auth.users;
create trigger create_profile_after_signup
after insert on auth.users
for each row execute function public.create_profile_for_new_user();

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;

drop policy if exists "Authenticated users can view profiles" on public.profiles;
create policy "Authenticated users can view profiles"
on public.profiles for select to authenticated
using (auth.uid() is not null);

drop policy if exists "Users can update their own display name" on public.profiles;
create policy "Users can update their own display name"
on public.profiles for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

create table if not exists public.label_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id),
  actor_name text not null check (char_length(trim(actor_name)) between 1 and 80),
  label_type text not null check (label_type in ('preparation', 'store_entry')),
  product text not null check (char_length(trim(product)) between 1 and 120),
  fields jsonb not null default '{}'::jsonb check (jsonb_typeof(fields) = 'object'),
  created_at timestamptz not null default now()
);

create index if not exists label_events_created_at_idx
on public.label_events (created_at desc);

alter table public.label_events enable row level security;
revoke all on public.label_events from anon, authenticated;
grant select on public.label_events to authenticated;

drop policy if exists "Authenticated users can view label history" on public.label_events;
create policy "Authenticated users can view label history"
on public.label_events for select to authenticated
using (auth.uid() is not null);

create or replace function public.reject_label_event_change()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  raise exception 'El historial de etiquetas es de solo anexado y no se puede modificar.';
end;
$$;

drop trigger if exists label_events_are_append_only on public.label_events;
create trigger label_events_are_append_only
before update or delete on public.label_events
for each row execute function public.reject_label_event_change();

create or replace function public.record_label_event(
  p_label_type text,
  p_product text,
  p_fields jsonb
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_user_id uuid := auth.uid();
  current_actor_name text;
  new_event_id bigint;
begin
  if current_user_id is null then
    raise exception 'Debes iniciar sesión para registrar una etiqueta.';
  end if;

  if p_label_type is null or p_label_type not in ('preparation', 'store_entry') then
    raise exception 'Tipo de etiqueta no válido.';
  end if;

  if p_product is null or char_length(trim(p_product)) not between 1 and 120 then
    raise exception 'El producto es obligatorio y debe tener como máximo 120 caracteres.';
  end if;

  if p_fields is null
    or jsonb_typeof(p_fields) <> 'object'
    or octet_length(p_fields::text) > 8192 then
    raise exception 'Los datos de la etiqueta no son válidos.';
  end if;

  select display_name into current_actor_name
  from public.profiles
  where id = current_user_id;

  if current_actor_name is null then
    raise exception 'No se encontró el perfil de la persona que registra la etiqueta.';
  end if;

  insert into public.label_events (user_id, actor_name, label_type, product, fields)
  values (current_user_id, current_actor_name, p_label_type, trim(p_product), p_fields)
  returning id into new_event_id;

  return new_event_id;
end;
$$;

revoke all on function public.record_label_event(text, text, jsonb) from public, anon;
grant execute on function public.record_label_event(text, text, jsonb) to authenticated;

revoke all on function public.reject_label_event_change() from public, anon, authenticated;
revoke all on function public.create_profile_for_new_user() from public, anon, authenticated;
