-- =============================================================================
-- SociaLearn — "Teacher or Student?" role migration
-- =============================================================================
-- Google Classroom style roles, added to a database that is ALREADY running.
--
-- Run THIS, not supabase-schema.sql. The main schema script starts with
-- "drop table ... cascade", so re-running it wipes every class, post and
-- message. This file only adds a column and swaps a few functions, so it is
-- safe to run on a live project and safe to run twice.
--
-- What changes:
--   1. profiles gains a role column ('teacher' | 'student', or NULL = not
--      chosen yet).
--   2. Only a stored teacher may create a class. This is enforced by a
--      row-level policy, not by the button in the browser.
--   3. A teacher cannot join a class with a code -- in Classroom a teacher
--      runs the class, so join_class() now refuses.
--   4. New set_my_role() RPC, for a Google user who has no role because
--      Google only sends back a name and a photo. One-shot by design.
--
-- Every existing profile gets role = NULL, which means the app will ask each
-- of them once for a role the next time they load it. That is intended: we
-- cannot know what they are, and guessing would silently make every existing
-- account a student.
-- =============================================================================

begin;


-- -----------------------------------------------------------------------------
-- 1. The role column
-- -----------------------------------------------------------------------------
-- Nullable on purpose. NULL means "has not chosen yet", which is how a Google
-- account that skipped the sign-up form is recognised. A default of 'student'
-- would hide that state and make the prompt impossible to trigger.
alter table public.profiles
  add column if not exists role text check (role in ('teacher', 'student'));

create index if not exists profiles_role_idx on public.profiles (role);


-- -----------------------------------------------------------------------------
-- 2. is_teacher(): the single source of truth for "may this person create
--    a class?". Reads the stored profile, never anything the browser sends.
-- -----------------------------------------------------------------------------
create or replace function public.is_teacher()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'teacher');
$$;
revoke execute on function public.is_teacher() from public, anon;


-- -----------------------------------------------------------------------------
-- 3. Lock the role down.
--    The generic "users edit own profile" policy already lets a user UPDATE
--    their own row, which would otherwise include the role column -- i.e.
--    anyone could promote themselves to teacher by opening devtools. This
--    trigger refuses any role change that did not come from set_my_role()
--    or the sign-up trigger. It is also SECURITY DEFINER, and a trigger
--    still fires for it, so it needs an escape hatch: both set_my_role()
--    and handle_user_sync() set the GUC below immediately before their
--    UPDATE, and those are the only two paths allowed through.
-- -----------------------------------------------------------------------------
create or replace function public.protect_profile_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- set_my_role() sets this GUC immediately before its UPDATE, so it is the
  -- one path allowed to change the column.
  if current_setting('socialearn.allow_role_change', true) = 'on' then
    return new;
  end if;
  if new.role is distinct from old.role then
    raise exception 'role can only be set once, via set_my_role()'
      using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function public.protect_profile_role() from public, anon;

drop trigger if exists profiles_lock_role on public.profiles;
create trigger profiles_lock_role
  before update on public.profiles
  for each row execute function public.protect_profile_role();


-- -----------------------------------------------------------------------------
-- 4. set_my_role(): one-shot role assignment, used after a Google sign-in.
-- -----------------------------------------------------------------------------
create or replace function public.set_my_role(p_role text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_want text := lower(trim(coalesce(p_role, '')));
  v_have text;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  if v_want not in ('teacher', 'student') then
    raise exception 'role must be teacher or student' using errcode = '22023';
  end if;

  select role into v_have from public.profiles where id = auth.uid();
  if not found then
    raise exception 'profile not ready yet' using errcode = 'P0002';
  end if;

  if v_have is not null then
    raise exception 'you already chose the % role', v_have using errcode = '42501';
  end if;

  -- Unlock the column for exactly this statement.
  perform set_config('socialearn.allow_role_change', 'on', true);

  update public.profiles set role = v_want where id = auth.uid();
  return v_want;
end;
$$;

revoke execute on function public.set_my_role(text) from public, anon;
grant execute on function public.set_my_role(text) to authenticated;


-- -----------------------------------------------------------------------------
-- 5. The sign-up trigger has to read the role off the sign-up form.
--    handle_user_sync() runs on sign-up AND on every later Google sign-in,
--    so it must never overwrite a role that has already been chosen.
-- -----------------------------------------------------------------------------
create or replace function public.handle_user_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_meta    jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_name    text := coalesce(v_meta ->> 'full_name', v_meta ->> 'name',
                             split_part(new.email, '@', 1), 'New User');
  v_avatar  text := coalesce(v_meta ->> 'picture', v_meta ->> 'avatar_url', '');
  v_role    text := nullif(lower(trim(coalesce(v_meta ->> 'role', ''))), '');
begin
  -- Only the two words we recognise. Anything else stays unassigned so the
  -- app asks rather than guessing.
  if v_role not in ('teacher', 'student') then
    v_role := null;
  end if;

  -- The insert below is the sign-up path, so it is allowed to set the role
  -- even though the trigger above would otherwise block the update.
  perform set_config('socialearn.allow_role_change', 'on', true);

  insert into public.profiles (id, name, username, initials, avatar_url, role)
  values (
    new.id,
    v_name,
    coalesce(split_part(new.email, '@', 1), lower(regexp_replace(v_name, '\s+', '.', 'g'))),
    public.make_initials(v_name),
    v_avatar,
    v_role
  )
  on conflict (id) do update
    set name       = case when coalesce(v_meta ->> 'full_name', v_meta ->> 'name', '') <> ''
                          then excluded.name else public.profiles.name end,
        avatar_url = case when v_avatar <> '' then excluded.avatar_url
                          else public.profiles.avatar_url end,
        initials   = case when coalesce(v_meta ->> 'full_name', v_meta ->> 'name', '') <> ''
                          then excluded.initials else public.profiles.initials end,
        -- Google metadata carries no role, and this trigger also fires on
        -- every later sign-in. So the role is written only while it is still
        -- NULL: re-signing in can never demote a teacher, nor re-open a
        -- choice that was already locked.
        role       = case when public.profiles.role is null and v_role is not null
                          then v_role else public.profiles.role end;
  return new;
end;
$$;

-- Rebuild the auth triggers too: they are defined on auth.users, which this
-- migration never drops, and a trigger that is already there would fail the
-- run with 42710.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_user_sync();

drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
  after update on auth.users
  for each row
  when (new.raw_user_meta_data is distinct from old.raw_user_meta_data)
  execute function public.handle_user_sync();


-- -----------------------------------------------------------------------------
-- Enrol the caller, and make sure the class group chat exists
-- with both the teacher and the student in it.
--
-- Returns SETOF jsonb rather than TABLE(...), and that is load-bearing. The
-- OUT parameters of a TABLE return are named id, name, section and
-- teacher_id -- the same names as real columns of conversations -- and plpgsql
-- resolves an INSERT target list too, so
--   insert into conversations (id, type, class_id, name)
-- matched an OUT parameter *and* a column and died with
-- 42702 "column reference id is ambiguous". Those OUT names cannot simply be
-- changed: PostgREST derives the JSON keys from them and script.js reads
-- data[0].name and data[0].already_joined. With no OUT parameters in scope
-- there is nothing for a column name to be ambiguous with, and
-- jsonb_build_object() puts the same keys back so the client is unaffected.
--
-- Every local below is prefixed for the same reason, and the class lookup
-- qualifies each column instead of selecting `*`.
create or replace function public.join_class(p_code text)
returns setof jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id         uuid;
  v_name       text;
  v_section    text;
  v_teacher_id uuid;
  v_already    boolean;
  v_conv_id    text;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  -- Google Classroom does not let a teacher join a class with a code;
  -- a teacher runs the class instead. Refusing here keeps the role
  -- meaning honest instead of quietly enrolling a teacher as a student.
  if is_teacher() then
    raise exception 'teachers do not join classes with a code -- create a class instead'
      using errcode = '42501';
  end if;

  select c.id, c.name, c.section, c.teacher_id
    into v_id, v_name, v_section, v_teacher_id
    from classes c
   where upper(c.code) = upper(trim(p_code));

  if v_id is null then
    raise exception 'no class with that code' using errcode = 'P0002';
  end if;

  select exists (select 1 from class_members
                 where class_id = v_id and student_id = auth.uid())
    into v_already;

  if not v_already then
    insert into class_members (class_id, student_id)
    values (v_id, auth.uid())
    on conflict do nothing;
  end if;

  v_conv_id := 'group-' || v_id;

  insert into conversations (id, type, class_id, name)
  values (v_conv_id, 'group', v_id, v_name || ' - ' || v_section)
  on conflict do nothing;

  insert into conversation_participants (conversation_id, user_id)
  values (v_conv_id, v_teacher_id), (v_conv_id, auth.uid())
  on conflict do nothing;

  return query
    select jsonb_build_object(
      'id',             v_id,
      'name',           v_name,
      'section',        v_section,
      'teacher_id',     v_teacher_id,
      'already_joined', v_already);
end;
$$;

revoke execute on function public.join_class(text) from public, anon;
grant execute on function public.join_class(text) to authenticated;


-- -----------------------------------------------------------------------------
-- 7. Class creation is now a teacher-only operation, enforced by Postgres.
-- -----------------------------------------------------------------------------
drop policy if exists "teachers create classes" on public.classes;
create policy "teachers create classes"
  on public.classes for insert to authenticated
  with check (teacher_id = auth.uid() and public.is_teacher());


-- -----------------------------------------------------------------------------
-- 8. Report what the app will ask about next time each user loads.
-- -----------------------------------------------------------------------------
commit;

select role, count(*) as accounts
from public.profiles
group by role
order by role nulls first;