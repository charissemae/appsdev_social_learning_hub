-- =============================================================================
-- SociaLearn — class background images migration
-- =============================================================================
-- Safe on a live database, and safe to run twice:
--   * adds classes.background_url without touching existing rows
--   * creates/reuses a public "class-backgrounds" storage bucket
--   * recreates only the three class-background storage policies
--
-- Run this once in the Supabase SQL Editor for an existing project.
-- Fresh projects already get all of this from supabase-schema.sql.
-- =============================================================================

begin;

alter table public.classes
  add column if not exists background_url text not null default '';

insert into storage.buckets (id, name, public, file_size_limit)
values ('class-backgrounds', 'class-backgrounds', true, 5242880) -- 5 MB per image
on conflict (id) do update set public         = excluded.public,
                                file_size_limit = excluded.file_size_limit;

drop policy if exists "teachers upload class backgrounds" on storage.objects;
create policy "teachers upload class backgrounds"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'class-backgrounds'
    and public.is_teacher()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "teachers update class backgrounds" on storage.objects;
create policy "teachers update class backgrounds"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'class-backgrounds'
    and public.is_teacher()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "teachers delete class backgrounds" on storage.objects;
create policy "teachers delete class backgrounds"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'class-backgrounds'
    and public.is_teacher()
    and (storage.foldername(name))[1] = auth.uid()::text
  );

commit;
