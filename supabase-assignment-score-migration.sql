-- -------------------------------------------------------------
-- Assignment scores (Google-Classroom style grading)
--
-- Run this ONCE in the Supabase SQL editor of an existing
-- project. Fresh projects only need supabase-schema.sql, which
-- already contains all of the statements below.
--
-- What it does:
--   1. submissions gains a "score" column (null = not graded yet)
--   2. an UPDATE policy so the class teacher may grade a
--      student's submission. It only adds a policy; the
--      student's own "students resubmit" policy is untouched.
--
-- Additive and non-destructive: existing rows keep a null
-- score, and nothing is changed or deleted. Safe to re-run.
-- -------------------------------------------------------------

-- 1. Column ----------------------------------------------------
alter table public.submissions
  add column if not exists score integer;

alter table public.submissions
  drop constraint if exists submissions_score_nonnegative;
alter table public.submissions
  add constraint submissions_score_nonnegative
  check (score is null or score >= 0);

comment on column public.submissions.score is
  'Points awarded by the class teacher. Null means the work has not been graded yet.';

-- 2. Teacher grading policy ------------------------------------
-- Policies for the same command are OR'd together, so this adds
-- the teacher alongside the existing "students resubmit" policy.
drop policy if exists "teachers grade submissions" on public.submissions;
create policy "teachers grade submissions"
  on public.submissions for update to authenticated
  using (exists (select 1 from public.assignments a
                 where a.id = submissions.assignment_id
                   and is_class_teacher(a.class_id)))
  with check (exists (select 1 from public.assignments a
                      where a.id = submissions.assignment_id
                        and is_class_teacher(a.class_id)));
