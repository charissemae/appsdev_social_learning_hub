# SociaLearn — Social Learning, Simplified.

A social-learning hub for college classes — a Google Classroom-style feed,
assignment tracking, messaging, and announcements in one interface. Built
with plain HTML, CSS, and JavaScript (no frontend framework), backed by
**Supabase**: **Auth** for real accounts (email/password or Google Sign-In)
and **Postgres** for the data, with **Realtime** subscriptions so every
class, post, assignment, submission, chat, and announcement syncs live
across every signed-in device.

## Running it

There's no build step, but unlike the old Firebase version this app should
be served over `http://` rather than opened as a `file://` path — Google
Sign-In has to redirect the whole page out to Google and back, which needs a
real origin. Any static server works:

```bash
npx serve .          # or: python -m http.server 8080
```

Then open the printed `http://localhost:PORT`.

## Required setup (one teammate does this once, then shares the values)

**1. Create the Supabase project**

1. Go to [supabase.com](https://supabase.com) and create a free project.
2. Wait for the database to finish provisioning (~2 minutes).

**2. Create the tables**

Open `supabase-schema.sql` in this folder, paste it into
**SQL Editor → New query**, and hit **Run**. It creates all 13 tables, the
row-level-security policies, the sign-up trigger, the `join_class` and
`set_my_role` RPCs, and adds every table to the `supabase_realtime`
publication. It's idempotent — re-running it drops and rebuilds everything
(which **deletes all data**).

> **Already have data? Run `supabase-role-migration.sql` instead.** It adds
> the Teacher/Student role to a live database without dropping anything, and
> is safe to run twice. It also back-fills: every existing profile gets
> `role = NULL`, so each of those accounts is asked for a role once, the next
> time they open the app.

> **Seeing `new row violates row-level security policy`?** You are on a
> database set up before the write policies existed. Run
> `supabase-policies-migration.sql`. It replaces the read-only policies with
> the intended per-role set, in a single transaction, and drops no tables �?"
> so it is safe on a live database and safe to run twice.

> **Want the real notification bell?** Run
> `supabase-notifications-migration.sql`. It adds the `notifications` table
> plus a set of database triggers that decide exactly who gets pinged:
> students when a teacher posts/sets an assignment, the teacher when a
> student submits or when someone likes/comments on their post, everyone in
> a chat when a message lands, and anyone whose comment got a reply. Run it
> as postgres in the SQL editor; it is safe to re-run.

> **Want to edit or delete chats?** Run
> `supabase-chat-edit-migration.sql`. It adds the `messages.edited_at` column
> and the UPDATE policy that lets a sender edit their own message (delete
> already worked, and teachers could already edit/delete their own classes).
> It only adds — no existing message is changed — and it is safe to re-run.

> **Want to grade submissions?** Run
> `supabase-assignment-score-migration.sql`. It adds the `submissions.score`
> column and the UPDATE policy that lets the class teacher score a student's
> work, so the student can see their score. It only adds — existing rows keep
> a null (ungraded) score — and it is safe to re-run.

**2b. Teacher or Student?**

The role is chosen once and then belongs to the account, the same way Google
Classroom works:

| | Teacher | Student |
| --- | --- | --- |
| Picks at sign-up | yes | yes |
| Creates a class and gets a class code | yes | no |
| Joins a class with a code | no | yes |
| Can change their own role later | no | no |

Details worth knowing before you touch the SQL:

- The role lives in `profiles.role`, **not** in the browser. Postgres decides
  who may create a class (the `is_teacher()` policy on `classes`), so hiding
  a button is only tidiness — a student calling the API directly is refused.
- A `profiles_lock_role` trigger rejects any later change to the column, which
  is what stops a student promoting themselves by editing the page.
- A Google sign-in carries no role, because Google only returns a name, an
  email and a photo. So a new Google account lands with no role and the app
  asks once, then calls the one-shot `set_my_role()` RPC.
- `join_class()` refuses a teacher. In Classroom a teacher runs the class
  rather than joining one with a code, and this keeps that true server-side.

**3. Fill in `supabase-config.js`**

**Project Settings → API**, copy two values in:

| Field | Source |
| --- | --- |
| `supabaseUrl` | Project URL |
| `supabaseAnonKey` | Project URL → `anon` `public` key |

Both are safe to ship in a static site: every read and write is gated by the
RLS policies, and the anon key grants nothing more than "logged in as
nobody". **Never** put the `service_role` key in this file — it bypasses RLS
entirely.

**4. Turn on sign-in methods** — **Authentication → Providers**

- **Email**: enable it, and turn **off** "Confirm email" while you're
  testing, otherwise new accounts can't sign in until they click the link.
- **Google**: enable it, set a support email, and copy the **Client ID**
  and **Client Secret** Google gives you into the provider settings.

**5. Allow the redirect URL** — **Authentication → URL Configuration**

Google sign-in bounces you out to `accounts.google.com` and back, so
Supabase has to be told which addresses are allowed:

- **Site URL** — set this to where the app actually runs.
- **Redirect URLs** — add every origin you use, e.g. `http://localhost:3000`
  and `http://localhost:8080`. A `file://` path can never be allowed,
  which is why the app must be served over http.

If you serve the app from a different port than the ones listed, set
`redirectUrl` in `supabase-config.js` to match exactly — a mismatch here
is the most common reason Google sign-in is rejected.

**6. Re-run the schema**

The Google profile picture needs a new `avatar_url` column on `profiles`
and a new trigger, so paste `supabase-schema.sql` into the SQL editor and
**Run** it again. Re-running rebuilds every table — safe right now because
the database is empty, but it **deletes all data** if you ever have some.

**7. Open the app**

Refresh, and sign in with Google. Your real name and profile photo should
appear in the top-right, on your Profile page, and next to anything you
post.

## The data model

Fourteen tables, replacing the old Firebase key-per-record structure. Every
Firebase collection that stored membership as a map of `uid: true` became a
real join table, so the app can query it with SQL:

| Firebase | Postgres |
| --- | --- |
| `classes/studentIds` | `class_members` |
| `posts/likes` | `post_likes` |
| `posts/comments` | `comments` |
| `announcements/readBy` | `announcement_reads` |
| `conversations/participantIds` | `conversation_participants` |
| `chats/<id>/messages` | `messages` |
| `users` | `profiles` |
| (new) bell notifications | `notifications` |

Group chat and DM ids stay **text**, not uuid — `group-<classId>` and
`dm-<sortedUids>` are computed the same way on every device, so any client
can find a conversation for a class or a pair of people without a lookup.
That's what keeps real-time sync lining up.

### Access control

RLS is enabled on all 14 tables, and the rules are per-role rather than
"anyone signed in can do anything" like the old Firebase setup:

- Students only see posts, assignments, and announcements for classes they're
  enrolled in.
- A student can read and overwrite **only their own** submission (enforced by
  a `unique (assignment_id, student_id)` constraint).
- Only a class's teacher can create assignments and announcements, or see
  who submitted what.
- Messages are readable only by conversation participants.

**Joining a class by code is the one case that can't be done with a plain
select**, because a non-member can't read the class row in the first place.
It's handled by the `join_class()` RPC: a `security definer` function that
checks the code server-side, enrols the caller, and creates the group chat —
all in one atomic call, so a student can never end up enrolled without their
chat. That collapses what used to be three separate client-side writes.

## What's included

- **Accounts** — real sign-up/sign-in with email+password or Google, backed
  by Supabase Auth. A database trigger creates your `profiles` row the
  moment you sign up. When you sign in with Google, the row is filled from
  your Google account — real name, real email, real profile photo — the same
  way Google Classroom shows who posted, so avatars are actual pictures
  rather than initials. An `after update` trigger on `auth.users` keeps that
  in sync if you later change your Google name or photo.
- **Feed** — a live stream of classroom posts with likes and comments.
- **Classroom** — teachers create classes and get a unique class code;
  students join with that code, which auto-links them to the class's group
  chat. Teachers can also rename a class (the code stays the same) or delete
  one they own — deleting a class also removes its group chat, assignments,
  announcements and posts, after a confirmation. A teacher's account always
  shows the classes they teach, and a student's always shows the classes
  they're enrolled in — there is no view toggle.
- **Assignments** — teachers create assignments with a deadline and points;
  students see live status badges (Upcoming / Due soon / Missing /
  Submitted) and submit a real attached file (PDF, image, doc, zip —
  25 MB max) stored in Supabase Storage. Teachers open the assignment to
  see every submission and click **View work** to read the actual file.
- **Chats** — real-time direct messages and class group chats. Use
  **"+ New message"** on the Chats page to start a DM with any classmate.
  Hover your own message to edit or delete it (edited messages are marked);
  deleting a message also removes its attachment. (Needs
  `supabase-chat-edit-migration.sql`.)
- **Announcements & To-Do** — teachers post announcements per class;
  students see unread announcements, upcoming deadlines, and a daily to-do
  list (the to-do checkboxes are personal/`localStorage`, not shared).
  Every post a teacher publishes is also mirrored into Announcements
  (title = first line of the post, body = full content), so teacher posts
  land in "Unread announcements", the feed widget, and the bell badge.
- **Notifications** — the bell in the header drops down the latest
  notifications for your account, generated by database triggers so the
  targeting is exact: a teacher posts or sets an assignment -> every student
  of that class (never the teacher's own account); a student submits work,
  likes a post, or comments -> the teacher/post author; a chat message ->
  everyone in the conversation except the sender; a comment on a post you
  commented on -> you. Unread ones are dotted and bold, clicking one jumps
  you to the right place (feed, assignments, announcements, or the chat
  itself), there's a "Mark all read" shortcut, and a clickable toast pops up
  live the moment one arrives.
- **Profile** — your real account info and a sign-out button.

## File structure

```
socialearn/
├── index.html           structure, auth screen, all screens/modals
├── style.css            design tokens, layout, responsive rules
├── script.js            auth, data loading, realtime subscriptions, rendering
├── supabase-config.js   your project's URL + anon key (fill this in)
├── supabase-schema.sql  tables, RLS policies, trigger, RPCs, realtime
├── supabase-role-migration.sql  adds the Teacher/Student role to a live DB
├── supabase-policies-migration.sql  refreshes RLS policies on a live DB
├── supabase-submission-files-migration.sql  adds real file uploads to a live DB
├── supabase-assignment-score-migration.sql  adds submission scoring to a live DB
├── supabase-announcement-backfill.sql  mirrors existing teacher posts into announcements
├── README.md
```

## Notes for the team

- `firebase-config.js` has been **deleted**; nothing references it. The old
  Firebase project still exists and still holds the previous data — nothing
  was migrated across. It was test data, and the uids in it don't correspond
  to any Supabase account, so it can't be imported directly; the database
  starts empty until someone creates a class.
- The role prompt reads `profiles.role` straight from Postgres rather than from
  the `db.users` mirror. The mirror is a cache that can be empty, mid-refresh,
  or still hold the previous sign-in, and that gap is the only reason an account
  with no role was ever skipped.
- `script.js` keeps the same in-memory `db` mirror the render functions have
  always read from. Rows are loaded from Postgres and mapped back to the old
  field names (`created_at` → `timestamp`, joined tables → `studentIds` /
  `likes` / `readBy` arrays), so the rendering layer is unchanged.
- Realtime uses one `postgres_changes` channel for the app plus a second,
  conversation-filtered channel for the open chat — so a new message in one
  DM doesn't cause the whole page to re-render.
- The `conversation_last_message` view exists so the chat list can show a
  preview for every conversation in one query, instead of the old approach of
  attaching a separate `limitToLast(1)` listener per conversation.
- Assignment submissions carry a real file: the bytes go to the private
  `submissions` bucket at `<assignmentId>/<studentId>/<unique>-<name>` and
  the `submissions` row stores `filename`, `file_path`, `mime_type` and
  `size_bytes`. Storage RLS is keyed on that path — only the owner can
  write into their folder, and only the owner and the class teacher can
  read it. Files are opened with a 1-hour signed URL, so the bucket stays
  private. An existing database needs `supabase-submission-files-migration.sql`
  run once; `supabase-schema.sql` already includes it for fresh setups.
  Rows created before this have `file_path = null` and show as "No file".
- The color palette (Linen background, Seafoam brand color, Blush accents,
  Terracotta highlights, Pine text) and the two-typeface system (Fraunces
  for display, Work Sans for interface text) come directly from the project's
  visual identity brief.
- This goes beyond the original brief's "no authentication needed for this
  prototype" scope — worth flagging to your instructor if the assignment
  expected the simpler localStorage-only version.

## Team

- ALFEREZ, CHERRY JOY
- MENDOZA, CHARISSE MAE
- NIERE, MARILYN
- TORRES, CARL JAY
