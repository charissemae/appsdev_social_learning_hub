-- ============================================================================
-- supabase-class-join-notification-migration.sql
--
-- Teachers were never told when a student joined their class.
--
-- WHY
--   Not a frontend bug and not a join_class() bug. The notifications table is
--   filled entirely by database triggers, and
--   supabase-notifications-migration.sql defines one per event -- announcement,
--   assignment, submission, like, comment, message -- but none on class_members.
--   A student joining inserts a row into class_members and nothing watches that
--   table, so no notification row is ever written and the bell stays quiet.
--
-- THE FIX
--   Add the missing trigger: AFTER INSERT ON class_members, write one
--   'class_join' notification for the class teacher.
--
-- TWO THINGS THIS HAS TO WORK AROUND
--   1. The existing notifications.type CHECK only allows
--      announcement/assignment/submission/like/comment/message. A 'class_join'
--      insert would violate it and, because the trigger runs inside the join
--      transaction, would roll the student's enrollment back too. So the check
--      is widened to include 'class_join'. Existing rows hold only the old
--      values, so the re-validated constraint passes -- no row is touched.
--   2. This file may be run more than once; every statement below is written to
--      be safe to re-run.
--
-- SAFE TO RE-RUN / NO DATA LOSS
--   No table is dropped. No row is deleted or updated. Only the type CHECK is
--   replaced and the trigger is (re)created.
--
-- NOTE
--   Do NOT re-run supabase-notifications-migration.sql after this. That script
--   drops the whole notifications table and would remove the widened check and
--   this trigger along with it. Re-run this file instead if the schema is reset.
-- ============================================================================

begin;

-- 1. Widen the type CHECK to admit 'class_join'. Discover every check
--    constraint that mentions the type column, so this works regardless of the
--    generated constraint name, then re-add one that includes class_join.
do $$
declare
  r record;
begin
  for r in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
    where nsp.nspname = 'public'
      and rel.relname = 'notifications'
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%type%'
  loop
    execute format('alter table public.notifications drop constraint %I', r.conname);
  end loop;
end $$;

alter table public.notifications
  add constraint notifications_type_check
  check (type in ('announcement', 'assignment', 'submission',
                  'like', 'comment', 'message', 'class_join'));

-- 2. The missing trigger: a student joins -> the class teacher is told.
--    SECURITY DEFINER, matching the other notification triggers, so the insert
--    never trips RLS. The recipient is always the teacher, never the student
--    who joined, and never themselves (teachers cannot join by code anyway).
create or replace function public.notify_class_join()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_teacher_id uuid;
begin
  select c.teacher_id into v_teacher_id
  from public.classes c
  where c.id = new.class_id;

  if v_teacher_id is null
     or new.student_id is null
     or v_teacher_id = new.student_id then
    return new;
  end if;

  insert into public.notifications (user_id, type, body, class_id, actor_id)
  values (v_teacher_id, 'class_join', '', new.class_id, new.student_id);

  return new;
end;
$$;

drop trigger if exists notifications_on_class_join on public.class_members;
create trigger notifications_on_class_join
  after insert on public.class_members
  for each row execute function public.notify_class_join();

revoke execute on function public.notify_class_join() from public, anon;

commit;
