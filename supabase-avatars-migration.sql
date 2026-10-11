-- =========================================================
-- SociaLearn — Profile photo (avatar) storage migration
-- Run this ONCE in the Supabase SQL Editor (as postgres).
--
-- Adds a public "avatars" bucket and lets each signed-in user write
-- only inside their own folder (avatars/<uid>/...). Because the
-- bucket is public, a profile photo can be shown from its public
-- URL anywhere in the app without a signed-link round trip.
--
-- Safe to re-run: the bucket upsert and the policy drops/recreates
-- make it idempotent, and it drops no tables.
-- =========================================================

insert into storage.buckets (id, name, public, file_size_limit)
values ('avatars', 'avatars', true, 5242880) -- 5 MB per photo
on conflict (id) do update set public         = excluded.public,
                               file_size_limit = excluded.file_size_limit;

-- Only your own folder: storage.foldername('a/b.png') returns {a},
-- so index 1 must be your uid. Public buckets already allow reads.
drop policy if exists "users upload own avatar" on storage.objects;
create policy "users upload own avatar"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "users update own avatar" on storage.objects;
create policy "users update own avatar"
  on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "users delete own avatar" on storage.objects;
create policy "users delete own avatar"
  on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
