-- =========================================================
-- SociaLearn — Message edit migration
-- Run this ONCE in the Supabase SQL Editor on a database that
-- already has the main schema applied.
-- Supabase dashboard > SQL Editor > New query > paste > Run.
-- =========================================================
-- Lets a sender edit one of their own chat messages. Nothing is
-- rewritten or deleted by this file: it only ADDS a column and an
-- UPDATE policy, so every existing message keeps its text, sender
-- and timestamp exactly as it is.
--
-- messages already had a SELECT, an INSERT and a DELETE policy for
-- the sender; editing needs an UPDATE policy too, which Supabase
-- does not create on its own. Without it an edit is refused at the
-- database with
--   new row violates row-level security policy for table "messages"
-- and the edit is rolled back.
--
-- Safe to re-run: the column uses IF NOT EXISTS and the policy is
-- dropped before it is recreated.
-- =========================================================

-- -------------------------------------------------------------
-- 1. Messages remember when they were last edited
-- -------------------------------------------------------------
-- Null for every row that has never been edited, so old messages
-- render exactly as before. The app shows " · edited" when set.
alter table public.messages
  add column if not exists edited_at timestamptz;

-- -------------------------------------------------------------
-- 2. Senders may edit their own messages
-- -------------------------------------------------------------
-- USING controls which rows you may target (your own), and
-- WITH CHECK stops an edit from handing a message to someone else.
drop policy if exists "senders update own messages" on public.messages;
create policy "senders update own messages"
  on public.messages for update to authenticated
  using (sender_id = auth.uid())
  with check (sender_id = auth.uid());
