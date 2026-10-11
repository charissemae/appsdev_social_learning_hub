-- =========================================================
-- SociaLearn — Notifications migration
-- Run this ONCE in the Supabase SQL Editor (as postgres).
--
-- Adds a per-user `notifications` table filled by database
-- triggers, so the bell shows exactly the right notifications
-- and nothing a user should not see:
--
--   * a teacher posts/announces  -> every STUDENT of that class
--     (the teacher's own account is never included)
--   * a teacher sets an assignment -> every student of that class
--   * a student submits work      -> the class teacher
--   * someone likes your post     -> the post author
--   * someone comments            -> the post author + everyone who
--     already commented on it ("replied to my comment")
--   * anyone sends a chat message -> everyone in the chat except
--     the sender
--
-- Safe to re-run (drop + recreate). Row-level security means a
-- user only ever reads/writes their own rows.
-- =========================================================

-- -------------------------------------------------------------
-- 1. Table
-- -------------------------------------------------------------
drop table if exists public.notifications cascade;

create table public.notifications (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  type            text not null check (type in
                    ('announcement', 'assignment', 'submission',
                     'like', 'comment', 'message')),
  body            text not null default '',
  class_id        uuid references public.classes(id) on delete cascade,
  actor_id        uuid references public.profiles(id) on delete set null,
  conversation_id text references public.conversations(id) on delete cascade,
  post_id         uuid references public.posts(id) on delete cascade,
  read_at         timestamptz,
  created_at      timestamptz not null default now()
);
create index on public.notifications (user_id, read_at, created_at desc);

-- -------------------------------------------------------------
-- 2. Generating triggers (SECURITY DEFINER, so RLS never blocks
--    the inserts — a user can only read their own rows).
-- -------------------------------------------------------------

-- A teacher's announcement / feed post -> the students of that class.
-- The join on classes.teacher_id means a *student's* mirrored post
-- never raises a bell, and the teacher never sees their own post.
create or replace function public.notify_announcement()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, type, body, class_id, actor_id, created_at)
  select cm.student_id,
         'announcement',
         coalesce(nullif(new.title, ''), left(new.body, 120)),
         new.class_id,
         new.author_id,
         new.created_at
  from public.class_members cm
  join public.classes c on c.id = new.class_id
                       and c.teacher_id = new.author_id
  where cm.class_id = new.class_id;
  return new;
end;
$$;

create trigger notifications_on_announcement
  after insert on public.announcements
  for each row execute function public.notify_announcement();

-- A teacher sets an assignment -> the students of that class.
create or replace function public.notify_assignment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, type, body, class_id, created_at)
  select cm.student_id, 'assignment', new.title, new.class_id, new.created_at
  from public.class_members cm
  where cm.class_id = new.class_id;
  return new;
end;
$$;

create trigger notifications_on_assignment
  after insert on public.assignments
  for each row execute function public.notify_assignment();

-- A student submits work -> the teacher who made the assignment.
create or replace function public.notify_submission()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, type, body, class_id, actor_id, created_at)
  select c.teacher_id, 'submission', a.title, a.class_id, new.student_id, new.created_at
  from public.assignments a
  join public.classes c on c.id = a.class_id
  where a.id = new.assignment_id;
  return new;
end;
$$;

create trigger notifications_on_submission
  after insert on public.submissions
  for each row execute function public.notify_submission();

-- A like on your post -> you (never the liker liking themselves).
create or replace function public.notify_like()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, type, body, class_id, actor_id, post_id, created_at)
  select p.author_id, 'like', '', p.class_id, new.user_id, new.post_id, new.created_at
  from public.posts p
  where p.id = new.post_id
    and p.author_id <> new.user_id;
  return new;
end;
$$;

create trigger notifications_on_like
  after insert on public.post_likes
  for each row execute function public.notify_like();

-- A comment -> the post author plus everyone who already commented
-- on that post (so a student hears when someone replies to their
-- comment). The poster never pings themselves.
create or replace function public.notify_comment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, type, body, class_id, actor_id, post_id, created_at)
  select distinct x.author_id, 'comment', left(new.text, 200), p.class_id,
         new.author_id, new.post_id, new.created_at
  from public.posts p
  join (
    select author_id from public.comments where post_id = new.post_id and author_id <> new.author_id
    union
    select author_id from public.posts   where id = new.post_id and author_id <> new.author_id
  ) x on true
  where p.id = new.post_id;
  return new;
end;
$$;

create trigger notifications_on_comment
  after insert on public.comments
  for each row execute function public.notify_comment();

-- A chat message -> everyone in the conversation except the sender.
create or replace function public.notify_message()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, type, body, conversation_id, actor_id, created_at)
  select cp.user_id, 'message', left(new.text, 200), new.conversation_id,
         new.sender_id, new.created_at
  from public.conversation_participants cp
  where cp.conversation_id = new.conversation_id
    and cp.user_id <> new.sender_id;
  return new;
end;
$$;

create trigger notifications_on_message
  after insert on public.messages
  for each row execute function public.notify_message();

revoke execute on function public.notify_announcement() from public, anon;
revoke execute on function public.notify_assignment() from public, anon;
revoke execute on function public.notify_submission() from public, anon;
revoke execute on function public.notify_like() from public, anon;
revoke execute on function public.notify_comment() from public, anon;
revoke execute on function public.notify_message() from public, anon;

-- -------------------------------------------------------------
-- 3. Row Level Security — you only ever see/read your own rows.
--    No insert/delete policies: new rows come only from the
--    triggers above, and only read_at can be touched by the app.
-- -------------------------------------------------------------
alter table public.notifications enable row level security;

create policy "users read own notifications"
  on public.notifications for select to authenticated
  using (user_id = auth.uid());

create policy "users mark notifications read"
  on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -------------------------------------------------------------
-- 4. Realtime — a fresh notification refreshes the bell and
--    raises a live toast on the recipient's screen.
-- -------------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.notifications;
  exception when duplicate_object then null;
  end;
end $$;

-- -------------------------------------------------------------
-- 5. Backfill — one-time snapshot so the bell is not empty for
--    things that already happened. Each block skips rows that
--    already exist, so re-running duplicates nothing.
-- -------------------------------------------------------------

-- announcements by the class teacher -> students
insert into public.notifications (user_id, type, body, class_id, actor_id, created_at)
select cm.student_id, 'announcement',
       coalesce(nullif(a.title, ''), left(a.body, 120)),
       a.class_id, a.author_id, a.created_at
from public.announcements a
join public.classes c on c.id = a.class_id and c.teacher_id = a.author_id
join public.class_members cm on cm.class_id = a.class_id
where not exists (
  select 1 from public.notifications n
  where n.user_id = cm.student_id and n.type = 'announcement'
    and n.class_id = a.class_id and n.actor_id = a.author_id
    and n.created_at = a.created_at
);

-- assignments -> students
insert into public.notifications (user_id, type, body, class_id, created_at)
select cm.student_id, 'assignment', a.title, a.class_id, a.created_at
from public.assignments a
join public.class_members cm on cm.class_id = a.class_id
where not exists (
  select 1 from public.notifications n
  where n.user_id = cm.student_id and n.type = 'assignment'
    and n.class_id = a.class_id and n.created_at = a.created_at
);

-- submissions -> class teacher
insert into public.notifications (user_id, type, body, class_id, actor_id, created_at)
select c.teacher_id, 'submission', a.title, a.class_id, s.student_id, s.created_at
from public.submissions s
join public.assignments a on a.id = s.assignment_id
join public.classes c on c.id = a.class_id
where not exists (
  select 1 from public.notifications n
  where n.user_id = c.teacher_id and n.type = 'submission'
    and n.actor_id = s.student_id and n.created_at = s.created_at
);

-- chat messages -> participants (except the sender)
insert into public.notifications (user_id, type, body, conversation_id, actor_id, created_at)
select cp.user_id, 'message', left(m.text, 200), m.conversation_id, m.sender_id, m.created_at
from public.messages m
join public.conversation_participants cp
  on cp.conversation_id = m.conversation_id and cp.user_id <> m.sender_id
where not exists (
  select 1 from public.notifications n
  where n.user_id = cp.user_id and n.type = 'message'
    and n.conversation_id = m.conversation_id and n.created_at = m.created_at
);