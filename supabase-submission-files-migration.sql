-- -------------------------------------------------------------
-- Submission file attachments (Google-Classroom style uploads)
--
-- Run this ONCE in the Supabase SQL editor of an existing
-- project. Fresh projects only need supabase-schema.sql, which
-- already contains all of the statements below.
--
-- What it does:
--   1. submissions gains file_path / mime_type / size_bytes
--   2. a private "submissions" storage bucket (25 MB per file)
--   3. storage RLS policies keyed on the object path:
--        <assignment_id>/<student_id>/<unique>-<filename>
--      -> a student may only write into their own folder of an
--         assignment they belong to
--      -> the owner and the class teacher may read the file
-- -------------------------------------------------------------

-- 1. Columns ---------------------------------------------------
alter table public.submissions
  add column if not exists file_path  text,
  add column if not exists mime_type  text,
  add column if not exists size_bytes bigint;

comment on column public.submissions.file_path is
  'Object path inside the "submissions" storage bucket; null for rows created before uploads were real.';

-- 2. Helpers used by the storage policies ---------------------
create or replace function public.is_assignment_member(p_assignment_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from assignments a
                 where a.id = p_assignment_id and is_class_member(a.class_id));
$$;

create or replace function public.is_assignment_teacher(p_assignment_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from assignments a
                 where a.id = p_assignment_id and is_class_teacher(a.class_id));
$$;

-- 3. The bucket ------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('submissions', 'submissions', false, 26214400) -- 25 MB
on conflict (id) do update set file_size_limit = excluded.file_size_limit,
                                public         = excluded.public;

-- 4. Storage policies -----------------------------------------
-- storage.foldername('a/b/c.txt') returns {a,b} — so index 1 is
-- the assignment id and index 2 is the student id. The uuid
-- guard runs first so a junk path fails the policy instead of
-- erroring on the cast.
--
-- NOTE: storage policies are additive. If this project already
-- has a broad one (e.g. "authenticated users can read/write all
-- files", often added from the Dashboard templates), it would
-- override the scoping below — Storage Policies → check for it
-- and remove it.

drop policy if exists "students upload submission files" on storage.objects;
create policy "students upload submission files"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'submissions'
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] ~* '^[0-9a-f-]{36}$'
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.is_assignment_member(((storage.foldername(name))[1])::uuid)
  );

drop policy if exists "owner and teacher read submission files" on storage.objects;
create policy "owner and teacher read submission files"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'submissions'
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] ~* '^[0-9a-f-]{36}$'
    and ( (storage.foldername(name))[2] = auth.uid()::text
          or public.is_assignment_teacher(((storage.foldername(name))[1])::uuid) )
  );

-- A student replacing their work, and the teacher clearing a
-- submission, must be able to delete the old object too.
drop policy if exists "delete submission files" on storage.objects;
create policy "delete submission files"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'submissions'
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[1] ~* '^[0-9a-f-]{36}$'
    and ( (storage.foldername(name))[2] = auth.uid()::text
          or public.is_assignment_teacher(((storage.foldername(name))[1])::uuid) )
  );
