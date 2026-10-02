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

Thirteen tables, replacing the old Firebase key-per-record structure. Every
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

Group chat and DM ids stay **text**, not uuid — `group-<classId>` and
`dm-<sortedUids>` are computed the same way on every device, so any client
can find a conversation for a class or a pair of people without a lookup.
That's what keeps real-time sync lining up.

### Access control

RLS is enabled on all 13 tables, and the rules are per-role rather than
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
  chat. "Student view" / "Teacher view" is a real filter — classes you're
  enrolled in vs. classes you created, since one account can be both.
- **Assignments** — teachers create assignments with a deadline and points;
  students see live status badges (Upcoming / Due soon / Missing /
  Submitted) and submit with a simulated file picker.
- **Chats** — real-time direct messages and class group chats. Use
  **"+ New message"** on the Chats page to start a DM with any classmate.
- **Announcements & To-Do** — teachers post announcements per class;
  students see unread announcements, upcoming deadlines, and a daily to-do
  list (the to-do checkboxes are personal/`localStorage`, not shared).
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
- File uploads are still simulated: selecting a file only stores its
  filename, not the file itself. If you want real uploads, Supabase Storage
  is the natural next step.
- The color palette (Linen background, Seafoam brand color, Blush accents,
  Terracotta highlights, Pine text) and the two-typeface system (Fraunces
  for display, Work Sans for interface text) come directly from the project's
  visual identity brief.
- This goes beyond the original brief's "no authentication needed for this
  prototype" scope — worth flagging to your instructor if the assignment
  expected the simpler localStorage-only version.
