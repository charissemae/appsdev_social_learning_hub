-- =========================================================
-- SociaLearn — Chat attachments migration
-- Run this ONCE in the Supabase SQL Editor on a database that
-- already has the main schema applied.
-- Supabase dashboard > SQL Editor > New query > paste > Run.
-- =========================================================
-- Lets a chat message carry a photo or a video. The bytes live in
-- a private "chat-attachments" bucket; the messages row keeps the
-- path plus the original name, type and size, the same shape the
-- assignment submissions use.
--
--   <conversationId>/<senderId>/<unique>-<filename>
--
-- Storage RLS reads that path: only members of the conversation can
-- read a file, and only the sender can write into their own folder.
-- Rows sent before this migration have a null attachment_path and
-- still render as plain text.
--
-- Safe to re-run: columns use IF NOT EXISTS, the bucket is upserted
-- and every policy is dropped before it is recreated.
-- =========================================================

-- -------------------------------------------------------------
-- 1. Messages gain attachment metadata
-- -------------------------------------------------------------
alter table public.messages
  add column if not exists attachment_path text,
  add column if not exists attachment_name text,
  add column if not exists mime_type       text,
  add column if not exists size_bytes      bigint;

-- -------------------------------------------------------------
-- 2. Private bucket for chat files (25 MB per file)
-- -------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('chat-attachments', 'chat-attachments', false, 26214400)
on conflict (id) do update set file_size_limit = excluded.file_size_limit,
                                public         = excluded.public;

-- -------------------------------------------------------------
-- 3. Storage policies
--    storage.foldername('a/b/c.png') returns {a,b,c}: index 1 is
--    the conversation id and index 2 the sender. in_conversation()
--    is the same helper the messages policies use.
-- -------------------------------------------------------------

-- You may only write into your own folder inside a chat you are in.
drop policy if exists "conversation members upload chat files" on storage.objects;
create policy "conversation members upload chat files"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'chat-attachments'
    and array_length(storage.foldername(name), 1) = 2
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.in_conversation((storage.foldername(name))[1])
  );

-- Anyone in the conversation may read its files.
drop policy if exists "conversation members read chat files" on storage.objects;
create policy "conversation members read chat files"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'chat-attachments'
    and public.in_conversation((storage.foldername(name))[1])
  );

-- The sender can remove their own upload (used to clean up a file
-- whose metadata row failed to insert).
drop policy if exists "senders delete chat files" on storage.objects;
create policy "senders delete chat files"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'chat-attachments'
    and (storage.foldername(name))[2] = auth.uid()::text
  );
