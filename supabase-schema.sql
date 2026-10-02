-- =========================================================
-- SociaLearn — Supabase (Postgres) schema
-- Run this ONCE in the Supabase SQL Editor.
-- Supabase dashboard > SQL Editor > New query > paste > Run.
-- =========================================================
-- This is a full rewrite of the old Firebase Realtime Database
-- model. Every Firebase "map key = true" collection becomes a
-- real join table, so the app can query it with SQL:
--
--   classes/studentIds  -> class_members
--   posts/likes         -> post_likes
--   posts/comments      -> comments
--   announcements/readBy-> announcement_reads
--   conversations/participantIds -> conversation_participants
--   chats/<id>/messages -> messages
--
-- IDs that must be computable by every client without a round
-- trip (group chats, DMs) stay TEXT: 'group-<classId>' and
-- 'dm-<sortedUids>'.
-- =========================================================

-- -------------------------------------------------------------
-- 0. Clean slate (safe to re-run while developing)
-- -------------------------------------------------------------
drop table if exists messages            cascade;
drop view  if exists conversation_last_message;
drop table if exists conversation_participants cascade;
drop table if exists conversations        cascade;
drop table if exists announcement_reads   cascade;
drop table if exists announcements        cascade;
drop table if exists submissions          cascade;
drop table if exists assignments          cascade;
drop table if exists comments             cascade;
drop table if exists post_likes           cascade;
drop table if exists posts                cascade;
drop table if exists class_members        cascade;
drop table if exists classes              cascade;
drop table if exists profiles             cascade;

-- Every function this script creates has to be dropped here, or a
-- re-run dies with 42723 "function already exists". The two RPCs
-- at the bottom used to be missed, which broke re-running.
drop function if exists handle_new_user() cascade;
drop function if exists handle_user_sync() cascade;
drop function if exists find_class_by_code(text) cascade;
drop function if exists join_class(text) cascade;
drop function if exists set_my_role(text) cascade;
drop function if exists is_class_teacher(uuid) cascade;
drop function if exists is_class_member(uuid) cascade;
drop function if exists is_teacher() cascade;
drop function if exists protect_profile_role() cascade;
drop function if exists in_conversation(text) cascade;
drop function if exists make_initials(text) cascade;

-- The auth triggers live on auth.users, which this script never
-- drops, so they have to be removed by hand or a re-run dies with
-- 42710 "trigger already exists".
drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists on_auth_user_updated on auth.users;


-- -------------------------------------------------------------
-- 1. Tables
-- -------------------------------------------------------------

-- Public mirror of auth.users. One row per account, created
-- automatically on first sign-up.
create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default 'New User',
  username   text not null default '',
  initials   text not null default '?',
  avatar_url text not null default '',
  -- Which kind of account this is, Google Classroom style. NULL
  -- means "has not chosen yet" · a Google user lands here with no
  -- role because Google only hands back a name and a photo, so the
  -- app asks. Once set it is permanent: set_my_role() refuses a
  -- second change, and every policy below reads this column rather
  -- than anything the client claims.
  role       text check (role in ('teacher', 'student')),
  created_at timestamptz not null default now()
);
create index on profiles (role);

create table classes (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  section    text not null,
  code       text not null unique,
  teacher_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index on classes (teacher_id);
create index on classes (code);

-- Which students are enrolled. The teacher is deliberately NOT
-- a row here — classes.teacher_id is the teacher's membership.
create table class_members (
  class_id   uuid not null references classes(id) on delete cascade,
  student_id uuid not null references profiles(id) on delete cascade,
  joined_at  timestamptz not null default now(),
  primary key (class_id, student_id)
);
create index on class_members (student_id);

create table posts (
  id         uuid primary key default gen_random_uuid(),
  class_id   uuid not null references classes(id) on delete cascade,
  author_id  uuid not null references profiles(id) on delete cascade,
  content    text not null,
  attachment boolean not null default false,
  created_at timestamptz not null default now()
);
create index on posts (class_id, created_at desc);

create table post_likes (
  post_id    uuid not null references posts(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create index on post_likes (user_id);

create table comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references posts(id) on delete cascade,
  author_id  uuid not null references profiles(id) on delete cascade,
  text       text not null,
  created_at timestamptz not null default now()
);
create index on comments (post_id, created_at);

create table assignments (
  id           uuid primary key default gen_random_uuid(),
  class_id     uuid not null references classes(id) on delete cascade,
  title        text not null,
  instructions text not null default '',
  deadline     date not null,
  points       integer,
  created_at   timestamptz not null default now()
);
create index on assignments (class_id, deadline);

-- One submission per (assignment, student). Re-submitting
-- overwrites, which is what the old .set() on a deterministic
-- id did.
create table submissions (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id) on delete cascade,
  student_id    uuid not null references profiles(id) on delete cascade,
  filename      text not null,
  created_at    timestamptz not null default now(),
  unique (assignment_id, student_id)
);
create index on submissions (assignment_id);
create index on submissions (student_id);

create table announcements (
  id         uuid primary key default gen_random_uuid(),
  class_id   uuid not null references classes(id) on delete cascade,
  author_id  uuid not null references profiles(id) on delete cascade,
  title      text not null,
  body       text not null default '',
  created_at timestamptz not null default now()
);
create index on announcements (class_id, created_at desc);

create table announcement_reads (
  announcement_id uuid not null references announcements(id) on delete cascade,
  user_id         uuid not null references profiles(id) on delete cascade,
  read_at         timestamptz not null default now(),
  primary key (announcement_id, user_id)
);
create index on announcement_reads (user_id);

-- id stays TEXT on purpose: 'group-<classId>' / 'dm-<a>_<b>' are
-- computed the same way on every device, so no lookup is needed
-- to find the conversation for a class or a pair of people.
create table conversations (
  id         text primary key,
  type       text not null check (type in ('group', 'dm')),
  class_id   uuid references classes(id) on delete cascade,
  name       text not null default '',
  created_at timestamptz not null default now()
);

create table conversation_participants (
  conversation_id text not null references conversations(id) on delete cascade,
  user_id         uuid not null references profiles(id) on delete cascade,
  primary key (conversation_id, user_id)
);
create index on conversation_participants (user_id);

create table messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id text not null references conversations(id) on delete cascade,
  sender_id       uuid not null references profiles(id) on delete cascade,
  text            text not null,
  created_at      timestamptz not null default now()
);
create index on messages (conversation_id, created_at);


-- Last message per conversation, for the chat list preview.
-- One query instead of one "limitToLast(1)" listener per chat.
-- security_invoker makes it run with the caller's permissions, so
-- RLS on messages still applies and you only ever see previews
-- for chats you are actually in.
create view conversation_last_message
with (security_invoker = true) as
  select distinct on (conversation_id)
         conversation_id, text, created_at
  from messages
  order by conversation_id, created_at desc;

grant select on conversation_last_message to authenticated;


-- -------------------------------------------------------------
-- 2. Helpers used by the RLS policies
-- -------------------------------------------------------------

-- "Is X the teacher of this class?"
create or replace function is_class_teacher(p_class_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from classes
                 where id = p_class_id and teacher_id = auth.uid());
$$;

-- "Did I sign up as a teacher?" This is the authority for who may
-- create a class. It reads the stored profile, never a value sent by
-- the browser, so a student cannot promote themselves by editing the
-- page or by replaying a request with role=teacher.
create or replace function is_teacher()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles
                 where id = auth.uid() and role = 'teacher');
$$;

-- "Am I the teacher or an enrolled student of this class?"
create or replace function is_class_member(p_class_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from classes
                 where id = p_class_id and teacher_id = auth.uid())
      or exists (select 1 from class_members
                 where class_id = p_class_id and student_id = auth.uid());
$$;

create or replace function in_conversation(p_conversation_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversation_participants
                 where conversation_id = p_conversation_id
                   and user_id = auth.uid());
$$;

create or replace function make_initials(p_name text)
returns text language sql immutable as $$
  select coalesce(nullif(upper(left(string_agg(w, ''), 2)), ''), '?')
  from (select left(word, 1) as w
        from unnest(regexp_split_to_array(trim(coalesce(p_name, '')), '\s+')) as word
        where word <> '') as t;
$$;


-- -------------------------------------------------------------
-- 3. Create the profile automatically on first sign-up
--    Two different providers put their details in different
--    metadata keys, so both are accepted:
--      email/password -> the app sends name and role
--      Google         -> Supabase sends full_name, picture
--    Either way the row ends up with a real name and photo, so
--    the profile looks the same as Google Classroom.
-- -------------------------------------------------------------
create or replace function handle_user_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_meta    jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_name    text := coalesce(v_meta ->> 'full_name', v_meta ->> 'name',
                             split_part(new.email, '@', 1), 'New User');
  v_avatar  text := coalesce(v_meta ->> 'picture', v_meta ->> 'avatar_url', '');
  v_role    text := nullif(lower(trim(coalesce(v_meta ->> 'role', ''))), '');
begin
  -- Only trust a role the client actually sent, and only the two
  -- words we recognise. Anything else leaves the account "unassigned"
  -- so the app can ask instead of silently guessing.
  if v_role not in ('teacher', 'student') then
    v_role := null;
  end if;

  -- This insert is the sign-up path, so it is allowed to write the role
  -- even though profiles_lock_role would otherwise block the update.
  perform set_config('socialearn.allow_role_change', 'on', true);

  insert into profiles (id, name, username, initials, avatar_url, role)
  values (
    new.id,
    v_name,
    coalesce(split_part(new.email, '@', 1), lower(regexp_replace(v_name, '\s+', '.', 'g'))),
    make_initials(v_name),
    v_avatar,
    v_role
  )
  on conflict (id) do update
    -- Only ever overwrite fields Google actually supplied, so a
    -- name someone typed on the email/password form is never lost.
    set name       = case when coalesce(v_meta ->> 'full_name', v_meta ->> 'name', '') <> ''
                          then excluded.name else profiles.name end,
        avatar_url = case when v_avatar <> '' then excluded.avatar_url
                          else profiles.avatar_url end,
        initials   = case when coalesce(v_meta ->> 'full_name', v_meta ->> 'name', '') <> ''
                          then excluded.initials else profiles.initials end,
        -- A later Google sign-in also fires this trigger, and Google
        -- metadata carries no role. So the role is only ever written
        -- while it is still unset: re-signing in can never demote a
        -- teacher or re-open a choice that was already locked.
        role       = case when profiles.role is null and v_role is not null
                          then v_role else profiles.role end;
  return new;
end;
$$;

-- Fires on sign-up AND on every later sign-in, so a Google user
-- who changes their profile picture gets the new one here too.
-- Google users only — a plain email account has no picture to sync.
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_user_sync();

create trigger on_auth_user_updated
  after update on auth.users
  for each row
  when (new.raw_user_meta_data is distinct from old.raw_user_meta_data)
  execute function handle_user_sync();


-- -------------------------------------------------------------
-- 4. Row Level Security
--    Everyone must be signed in, then you only see/touch rows
--    belonging to classes you are in (or chats you are in).
-- -------------------------------------------------------------
alter table profiles             enable row level security;
alter table classes              enable row level security;
alter table class_members        enable row level security;
alter table posts                enable row level security;
alter table post_likes           enable row level security;
alter table comments             enable row level security;
alter table assignments          enable row level security;
alter table submissions          enable row level security;
alter table announcements        enable row level security;
alter table announcement_reads   enable row level security;
alter table conversations        enable row level security;
alter table conversation_participants enable row level security;
alter table messages             enable row level security;

-- profiles: everyone signed in can see names/avatars (the feed
-- needs to label posts); you can only edit your own row.
create policy "profiles are readable by signed-in users"
  on profiles for select to authenticated using (true);
create policy "users edit own profile"
  on profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy "users insert own profile"
  on profiles for insert to authenticated
  with check (id = auth.uid());

-- A profile row must not be able to rewrite its own role through the
-- generic update policy, otherwise anyone could UPDATE their own row
-- and promote themselves to teacher. Role is set exactly once, by the
-- signup trigger or by set_my_role() below.
create or replace function public.protect_profile_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- set_my_role() and handle_user_sync() set this GUC immediately before
  -- their UPDATE, so those are the only two paths allowed to write the column.
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

create trigger profiles_lock_role
  before update on profiles
  for each row execute function protect_profile_role();
revoke execute on function public.protect_profile_role() from public, anon;

-- classes: readable only if you teach or take it. Joining by
-- code therefore CANNOT go through a normal select — the class
-- row is invisible to a non-member. Instead we expose two
-- narrow RPCs at the bottom of this file (find_class_by_code
-- and join_class), which are the only way to see or join a
-- class you are not already in.
create policy "members read classes"
  on classes for select to authenticated using (is_class_member(id));
-- is_teacher() reads the stored profile, so this is enforced by the
-- database and not by the button in the browser.
create policy "teachers create classes"
  on classes for insert to authenticated
  with check (teacher_id = auth.uid() and is_teacher());
create policy "teachers update classes"
  on classes for update to authenticated
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());
create policy "teachers delete classes"
  on classes for delete to authenticated using (teacher_id = auth.uid());

create policy "members read class_members"
  on class_members for select to authenticated using (is_class_member(class_id));
-- There is deliberately NO insert policy here. Enrolment only
-- happens through the join_class() RPC below, which checks the
-- class code server-side. Without this policy a signed-in user
-- could add themselves to any class by guessing its UUID.
-- Only the teacher of a class can remove a student.
create policy "teachers manage enrolment"
  on class_members for delete to authenticated using (is_class_teacher(class_id));

create policy "members read posts"
  on posts for select to authenticated using (is_class_member(class_id));
create policy "members create posts"
  on posts for insert to authenticated
  with check (author_id = auth.uid() and is_class_member(class_id));
create policy "authors delete own posts"
  on posts for delete to authenticated using (author_id = auth.uid());

create policy "members read likes"
  on post_likes for select to authenticated
  using (exists (select 1 from posts p
                 where p.id = post_likes.post_id and is_class_member(p.class_id)));
create policy "users like posts"
  on post_likes for insert to authenticated with check (user_id = auth.uid());
create policy "users unlike posts"
  on post_likes for delete to authenticated using (user_id = auth.uid());

create policy "members read comments"
  on comments for select to authenticated
  using (exists (select 1 from posts p
                 where p.id = comments.post_id and is_class_member(p.class_id)));
create policy "members create comments"
  on comments for insert to authenticated
  with check (author_id = auth.uid()
              and exists (select 1 from posts p
                          where p.id = comments.post_id and is_class_member(p.class_id)));
create policy "authors delete own comments"
  on comments for delete to authenticated using (author_id = auth.uid());

create policy "members read assignments"
  on assignments for select to authenticated using (is_class_member(class_id));
create policy "teachers create assignments"
  on assignments for insert to authenticated
  with check (is_class_teacher(class_id));
create policy "teachers update assignments"
  on assignments for update to authenticated using (is_class_teacher(class_id));
create policy "teachers delete assignments"
  on assignments for delete to authenticated using (is_class_teacher(class_id));

-- Students see their own submissions; teachers see every
-- submission in their class.
create policy "read relevant submissions"
  on submissions for select to authenticated
  using (
    student_id = auth.uid()
    or exists (select 1 from assignments a
               where a.id = submissions.assignment_id
                 and is_class_teacher(a.class_id))
  );
create policy "students submit own work"
  on submissions for insert to authenticated
  with check (student_id = auth.uid()
              and exists (select 1 from assignments a
                          where a.id = submissions.assignment_id
                            and is_class_member(a.class_id)));
create policy "students resubmit"
  on submissions for update to authenticated
  with check (student_id = auth.uid());
create policy "teachers delete submissions"
  on submissions for delete to authenticated
  using (exists (select 1 from assignments a
                 where a.id = submissions.assignment_id
                   and is_class_teacher(a.class_id)));

create policy "members read announcements"
  on announcements for select to authenticated using (is_class_member(class_id));
create policy "teachers create announcements"
  on announcements for insert to authenticated
  with check (author_id = auth.uid() and is_class_teacher(class_id));
create policy "teachers update announcements"
  on announcements for update to authenticated using (is_class_teacher(class_id));
create policy "teachers delete announcements"
  on announcements for delete to authenticated using (is_class_teacher(class_id));

create policy "users read own announcement receipts"
  on announcement_reads for select to authenticated using (user_id = auth.uid());
create policy "members read receipts"
  on announcement_reads for select to authenticated
  using (exists (select 1 from announcements a
                 where a.id = announcement_reads.announcement_id
                   and is_class_member(a.class_id)));
create policy "users mark announcements read"
  on announcement_reads for insert to authenticated with check (user_id = auth.uid());

create policy "participants read conversations"
  on conversations for select to authenticated using (in_conversation(id));
create policy "signed-in users start conversations"
  on conversations for insert to authenticated with check (true);
create policy "participants read participant lists"
  on conversation_participants for select to authenticated using (in_conversation(conversation_id));
-- You may add yourself to a brand-new chat, or add someone else
-- only if you are already in that chat. This stops a signed-in
-- user from pulling an uninvolved person into a DM by guessing
-- its id.
create policy "add yourself to a new conversation"
  on conversation_participants for insert to authenticated
  with check (user_id = auth.uid() or in_conversation(conversation_id));
create policy "participants remove themselves"
  on conversation_participants for delete to authenticated using (user_id = auth.uid());

create policy "participants read messages"
  on messages for select to authenticated using (in_conversation(conversation_id));
create policy "participants send messages"
  on messages for insert to authenticated
  with check (sender_id = auth.uid() and in_conversation(conversation_id));
create policy "senders delete own messages"
  on messages for delete to authenticated using (sender_id = auth.uid());


-- -------------------------------------------------------------
-- 5. RPCs for "join a class with a code"
--    A non-member cannot SELECT the class row (see the classes
--    policy above), so these SECURITY DEFINER functions are the
--    only bridge between a class code and enrolment. They also
--    collapse what used to be three separate client-side writes
--    into one atomic call, so a student can never end up
--    enrolled without their group chat.
-- -------------------------------------------------------------

-- Look up a class without joining it (used to show "class
-- found: NAME — SECTION" before confirming).
create or replace function find_class_by_code(p_code text)
returns table (id uuid, name text, section text, teacher_id uuid)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  return query
    select c.id, c.name, c.section, c.teacher_id
    from classes c
    where upper(c.code) = upper(trim(p_code));
end;
$$;

-- Enrol the caller, and make sure the class group chat exists
-- with both the teacher and the student in it.
create or replace function join_class(p_code text)
returns table (id uuid, name text, section text, teacher_id uuid, already_joined boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_class classes;
  v_already boolean;
  v_conv_id text;
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

  select * into v_class from classes
  where upper(code) = upper(trim(p_code));

  if v_class.id is null then
    raise exception 'no class with that code' using errcode = 'P0002';
  end if;

  select exists (select 1 from class_members
                 where class_id = v_class.id and student_id = auth.uid())
    into v_already;

  if not v_already then
    insert into class_members (class_id, student_id)
    values (v_class.id, auth.uid())
    on conflict do nothing;
  end if;

  v_conv_id := 'group-' || v_class.id;

  insert into conversations (id, type, class_id, name)
  values (v_conv_id, 'group', v_class.id, v_class.name || ' — ' || v_class.section)
  on conflict (id) do nothing;

  insert into conversation_participants (conversation_id, user_id)
  values (v_conv_id, v_class.teacher_id), (v_conv_id, auth.uid())
  on conflict do nothing;

  return query
    select v_class.id, v_class.name, v_class.section, v_class.teacher_id, v_already;
end;
$$;

-- Only signed-in users may call these; anon must not.
revoke execute on function find_class_by_code(text) from public, anon;
revoke execute on function join_class(text) from public, anon;
grant execute on function find_class_by_code(text) to authenticated;
grant execute on function join_class(text) to authenticated;


-- -------------------------------------------------------------
-- 5b. Choosing the Teacher / Student role
--    The email sign-up form sends its picker as user metadata, so
--    handle_user_sync() already recorded the role. A Google user
--    lands with no role at all (Google only returns a name and a
--    photo), so the app calls this once after their first sign-in.
--    It is deliberately one-shot: after this succeeds the
--    profiles_lock_role trigger blocks every other write, so an
--    account cannot flip between teacher and student later.
-- -------------------------------------------------------------
create or replace function set_my_role(p_role text)
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

  select role into v_have from profiles where id = auth.uid();
  if not found then
    raise exception 'profile not ready yet' using errcode = 'P0002';
  end if;

  if v_have is not null then
    raise exception 'you already chose the % role', v_have using errcode = '42501';
  end if;

  -- Stored value is already validated against the enum above, so the
  -- check constraint on profiles cannot fire here.
  perform set_config('socialearn.allow_role_change', 'on', true);

  update profiles set role = v_want where id = auth.uid();
  return v_want;
end;
$$;

revoke execute on function set_my_role(text) from public, anon;
grant execute on function set_my_role(text) to authenticated;


-- -------------------------------------------------------------
-- 6. Realtime
--    The app subscribes to postgres_changes on these tables to
--    re-render, the same way it used to listen to .on('value').
--    RLS applies to realtime too, so a client only ever
--    receives changes it is allowed to see.
-- -------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'profiles', 'classes', 'class_members', 'posts', 'post_likes',
    'comments', 'assignments', 'submissions', 'announcements',
    'announcement_reads', 'conversations',
    'conversation_participants', 'messages'
  ] loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
