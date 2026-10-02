-- =============================================================================
-- SociaLearn — Row Level Security policy migration
-- =============================================================================
-- Run THIS when the app refuses to write. The symptom is a red error under the
-- form saying:
--
--     new row violates row-level security policy for table "classes"
--
-- which is what a teacher sees when they press "Create class", and the same thing
-- for anything else the browser writes directly.
--
-- Safe on a live database, and safe to run twice:
--   * it touches policies only — no table is dropped, no row is read or written
--   * the whole thing is one transaction, so if a single statement fails nothing
--     changes at all
--
-- Why it exists
-- --------------
-- The policies are defined in supabase-schema.sql, which cannot be re-run once
-- there is data (it opens with `drop table ... cascade`). So a project that was
-- set up before those policies were written — or that only ever ran
-- supabase-role-migration.sql, which replaces just one of them — kept the older
-- read-only rules. Postgres then refuses every client-side INSERT/UPDATE/DELETE,
-- while the SECURITY DEFINER pieces kept working, because they bypass RLS:
--
--   * signing up                -> handle_user_sync() trigger, SECURITY DEFINER
--   * choosing Teacher/Student  -> set_my_role() RPC,          SECURITY DEFINER
--   * joining a class by code   -> join_class() RPC,           SECURITY DEFINER
--
-- That is exactly why the role could be stored but a class could not be created.
--
-- Rather than dropping policies one by one by name — the stale ones are not
-- guaranteed to be named what this project expects — this drops EVERY policy on
-- the thirteen tables and then recreates the intended set, which is a copy of
-- section 4 of supabase-schema.sql. If you change a policy there, change it here.
-- =============================================================================

begin;


-- -----------------------------------------------------------------------------
-- 0. Drop every existing policy, whatever it is called.
--    pg_policies is a view over pg_catalog, so this works on any Supabase
--    project without extra privileges.
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
  p record;
begin
  foreach t in array array[
    'profiles', 'classes', 'class_members', 'posts', 'post_likes',
    'comments', 'assignments', 'submissions', 'announcements',
    'announcement_reads', 'conversations', 'conversation_participants', 'messages'
  ] loop
    for p in
      select policyname from pg_policies
      where schemaname = 'public' and tablename = t
    loop
      execute format('drop policy %I on public.%I', p.policyname, t);
      raise notice 'dropped policy "%" on %', p.policyname, t;
    end loop;

    -- RLS itself: cheap to re-assert, and it repairs a table that somehow lost it.
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;


-- -----------------------------------------------------------------------------
-- 1. The helpers the policies call.
--    Re-created with `create or replace` so this file stands on its own. They
--    are SECURITY DEFINER + stable so a policy can ask them without recursing
--    through RLS, and they read the stored profile rather than anything the
--    browser sends.
-- -----------------------------------------------------------------------------
create or replace function public.is_class_teacher(p_class_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.classes
                 where id = p_class_id and teacher_id = auth.uid());
$$;

create or replace function public.is_class_member(p_class_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.classes
                 where id = p_class_id and teacher_id = auth.uid())
      or exists (select 1 from public.class_members
                 where class_id = p_class_id and student_id = auth.uid());
$$;

create or replace function public.in_conversation(p_conversation_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.conversation_participants
                 where conversation_id = p_conversation_id
                   and user_id = auth.uid());
$$;

-- These three answer a question about the caller only, and for a signed-out
-- caller auth.uid() is NULL so they can only ever return false. They are still
-- revoked from anon and PUBLIC for consistency with is_teacher() and the RPCs
-- below. GRANT to authenticated is required: a policy expression is evaluated
-- with the calling user's privileges, so revoking from PUBLIC without granting
-- back to authenticated would break every rule below.
revoke execute on function public.is_class_teacher(uuid) from public, anon;
revoke execute on function public.is_class_member(uuid) from public, anon;
revoke execute on function public.in_conversation(text) from public, anon;
grant  execute on function public.is_class_teacher(uuid) to authenticated;
grant  execute on function public.is_class_member(uuid) to authenticated;
grant  execute on function public.in_conversation(text) to authenticated;


-- -----------------------------------------------------------------------------
-- 2. profiles
--    Everyone signed in can read names and avatars, because the feed has to label
--    posts. You can only edit your own row. The role column is not protected by
--    these rules but by the profiles_lock_role trigger, which refuses any change
--    that did not come from set_my_role() or the sign-up trigger.
-- -----------------------------------------------------------------------------
create policy "profiles are readable by signed-in users"
  on public.profiles for select to authenticated using (true);
create policy "users edit own profile"
  on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy "users insert own profile"
  on public.profiles for insert to authenticated
  with check (id = auth.uid());


-- -----------------------------------------------------------------------------
-- 3. classes
--    Readable only if you teach it or take it, which is why joining by code has
--    to go through the join_class() RPC rather than a plain select. Creating one
--    is gated on is_teacher(), so a student pressing the button is refused by
--    Postgres even if they edit the page.
-- -----------------------------------------------------------------------------
create policy "members read classes"
  on public.classes for select to authenticated using (is_class_member(id));
create policy "teachers create classes"
  on public.classes for insert to authenticated
  with check (teacher_id = auth.uid() and is_teacher());
create policy "teachers update classes"
  on public.classes for update to authenticated
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());
create policy "teachers delete classes"
  on public.classes for delete to authenticated using (teacher_id = auth.uid());


-- -----------------------------------------------------------------------------
-- 4. class_members
--    There is deliberately NO insert policy. Enrolment only happens through
--    join_class(), which checks the class code server-side. Adding one here would
--    let any signed-in user add themselves to any class by guessing its UUID.
-- -----------------------------------------------------------------------------
create policy "members read class_members"
  on public.class_members for select to authenticated using (is_class_member(class_id));
create policy "teachers manage enrolment"
  on public.class_members for delete to authenticated using (is_class_teacher(class_id));


-- -----------------------------------------------------------------------------
-- 5. posts / post_likes / comments
-- -----------------------------------------------------------------------------
create policy "members read posts"
  on public.posts for select to authenticated using (is_class_member(class_id));
create policy "members create posts"
  on public.posts for insert to authenticated
  with check (author_id = auth.uid() and is_class_member(class_id));
create policy "authors delete own posts"
  on public.posts for delete to authenticated using (author_id = auth.uid());

create policy "members read likes"
  on public.post_likes for select to authenticated
  using (exists (select 1 from posts p
                 where p.id = post_likes.post_id and is_class_member(p.class_id)));
create policy "users like posts"
  on public.post_likes for insert to authenticated with check (user_id = auth.uid());
create policy "users unlike posts"
  on public.post_likes for delete to authenticated using (user_id = auth.uid());

create policy "members read comments"
  on public.comments for select to authenticated
  using (exists (select 1 from posts p
                 where p.id = comments.post_id and is_class_member(p.class_id)));
create policy "members create comments"
  on public.comments for insert to authenticated
  with check (author_id = auth.uid()
              and exists (select 1 from posts p
                          where p.id = comments.post_id and is_class_member(p.class_id)));
create policy "authors delete own comments"
  on public.comments for delete to authenticated using (author_id = auth.uid());


-- -----------------------------------------------------------------------------
-- 6. assignments / submissions
--    Students see and overwrite only their own submission; the unique
--    (assignment_id, student_id) constraint is what makes "resubmit" an
--    overwrite. Teachers see every submission in their own class.
-- -----------------------------------------------------------------------------
create policy "members read assignments"
  on public.assignments for select to authenticated using (is_class_member(class_id));
create policy "teachers create assignments"
  on public.assignments for insert to authenticated
  with check (is_class_teacher(class_id));
create policy "teachers update assignments"
  on public.assignments for update to authenticated using (is_class_teacher(class_id));
create policy "teachers delete assignments"
  on public.assignments for delete to authenticated using (is_class_teacher(class_id));

create policy "read relevant submissions"
  on public.submissions for select to authenticated
  using (
    student_id = auth.uid()
    or exists (select 1 from assignments a
               where a.id = submissions.assignment_id
                 and is_class_teacher(a.class_id))
  );
create policy "students submit own work"
  on public.submissions for insert to authenticated
  with check (student_id = auth.uid()
              and exists (select 1 from assignments a
                          where a.id = submissions.assignment_id
                            and is_class_member(a.class_id)));
create policy "students resubmit"
  on public.submissions for update to authenticated
  with check (student_id = auth.uid());
create policy "teachers delete submissions"
  on public.submissions for delete to authenticated
  using (exists (select 1 from assignments a
                 where a.id = submissions.assignment_id
                   and is_class_teacher(a.class_id)));


-- -----------------------------------------------------------------------------
-- 7. announcements / announcement_reads
-- -----------------------------------------------------------------------------
create policy "members read announcements"
  on public.announcements for select to authenticated using (is_class_member(class_id));
create policy "teachers create announcements"
  on public.announcements for insert to authenticated
  with check (author_id = auth.uid() and is_class_teacher(class_id));
create policy "teachers update announcements"
  on public.announcements for update to authenticated using (is_class_teacher(class_id));
create policy "teachers delete announcements"
  on public.announcements for delete to authenticated using (is_class_teacher(class_id));

create policy "users read own announcement receipts"
  on public.announcement_reads for select to authenticated using (user_id = auth.uid());
create policy "members read receipts"
  on public.announcement_reads for select to authenticated
  using (exists (select 1 from announcements a
                 where a.id = announcement_reads.announcement_id
                   and is_class_member(a.class_id)));
create policy "users mark announcements read"
  on public.announcement_reads for insert to authenticated with check (user_id = auth.uid());


-- -----------------------------------------------------------------------------
-- 8. conversations / conversation_participants / messages
--    You may start a chat and add yourself, but you may only add somebody else if
--    you are already in that chat — otherwise a signed-in user could pull an
--    uninvolved person into a DM by guessing its id.
-- -----------------------------------------------------------------------------
create policy "participants read conversations"
  on public.conversations for select to authenticated using (in_conversation(id));
create policy "signed-in users start conversations"
  on public.conversations for insert to authenticated with check (true);
create policy "participants read participant lists"
  on public.conversation_participants for select to authenticated using (in_conversation(conversation_id));
create policy "add yourself to a new conversation"
  on public.conversation_participants for insert to authenticated
  with check (user_id = auth.uid() or in_conversation(conversation_id));
create policy "participants remove themselves"
  on public.conversation_participants for delete to authenticated using (user_id = auth.uid());

create policy "participants read messages"
  on public.messages for select to authenticated using (in_conversation(conversation_id));
create policy "participants send messages"
  on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and in_conversation(conversation_id));
create policy "senders delete own messages"
  on public.messages for delete to authenticated using (sender_id = auth.uid());

commit;


-- -----------------------------------------------------------------------------
-- 9. Show what is in place now.
--    Expect one row per rule above, and NO insert rule on class_members.
-- -----------------------------------------------------------------------------
select tablename, cmd, policyname
from pg_policies
where schemaname = 'public'
order by tablename, cmd, policyname;