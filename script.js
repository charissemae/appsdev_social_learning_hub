/* =========================================================
   SociaLearn — Application Logic (Supabase Auth + Postgres)
   =========================================================
   Every table (profiles, classes, class_members, posts,
   post_likes, comments, assignments, submissions,
   announcements, announcement_reads, conversations,
   conversation_participants, messages) lives in Supabase
   Postgres. The rows are loaded into the `db` mirror below,
   which the render functions read from.

   The mirror keeps exactly the shape the UI has always
   expected — classes carry a `studentIds` array, posts carry
   `likes`/`comments` arrays, rows carry a `timestamp` field —
   so the rendering layer is unchanged. Only `loadX()` reads
   from Supabase and `timestamp` is mapped back from
   `created_at`.
   ========================================================= */

/* ---------------------------------------------------------
   1. SUPABASE INIT
   --------------------------------------------------------- */
let sbEnabled = false;
let sb = null;

(function initSupabase() {
  if (typeof supabaseConfig === 'undefined' ||
      !supabaseConfig.supabaseUrl ||
      supabaseConfig.supabaseUrl.indexOf('YOUR_') === 0) {
    console.warn('SociaLearn: supabase-config.js still has placeholder values. Fill it in — see README.md.');
    return;
  }
  if (typeof supabase === 'undefined') {
    console.warn('SociaLearn: Supabase SDK failed to load — check your internet connection.');
    return;
  }
  sb = supabase.createClient(supabaseConfig.supabaseUrl, supabaseConfig.supabaseAnonKey);
  sbEnabled = true;
})();

/* ---------------------------------------------------------
   2. SMALL HELPERS
   --------------------------------------------------------- */
function uid(prefix) { return prefix + '-' + Math.random().toString(36).slice(2, 9); }
function daysFromNow(n) { const d = new Date(); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); }
function groupConvId(classId) { return 'group-' + classId; }
function dmConvId(userA, userB) { return 'dm-' + [userA, userB].sort().join('_'); }

function initialsFromName(name) {
  const parts = (name || '').trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return '?';
  return parts.slice(0, 2).map(w => w[0].toUpperCase()).join('');
}

function escapeHTML(str) {
  const div = document.createElement('div');
  div.textContent = str == null ? '' : str;
  return div.innerHTML;
}

/* Avatars. Google sign-in puts a real profile picture on the
   account, so use that when we have it and fall back to initials
   for email-only accounts (or if the image fails to load). */
function avatarHTML(user) {
  if (user && user.avatar_url) {
    return `<img class="avatar__img" src="${escapeHTML(user.avatar_url)}" alt="" referrerpolicy="no-referrer" data-fallback="${escapeHTML(user.initials || '?')}">`;
  }
  return escapeHTML(user && user.initials ? user.initials : (user ? initialsFromName(user.name) : '?'));
}

function setAvatar(el, user) {
  if (!el) return;
  el.innerHTML = avatarHTML(user);
}

// Image load errors don't bubble, so catch them in the capture phase
// and swap the broken image for the initials it was standing in for.
document.addEventListener('error', e => {
  const img = e.target;
  if (img && img.tagName === 'IMG' && img.dataset && img.dataset.fallback) {
    img.replaceWith(document.createTextNode(img.dataset.fallback));
  }
}, true);

function generateClassCode(name) {
  const letters = name.replace(/[^A-Za-z]/g, '').slice(0, 4).toUpperCase() || 'CLSS';
  const rand = Math.random().toString(36).slice(2, 6).toUpperCase();
  return letters + '-' + rand;
}

function showToast(message, type) {
  const stack = document.getElementById('toast-stack');
  const el = document.createElement('div');
  el.className = 'toast' + (type === 'error' ? ' toast--error' : '');
  el.textContent = message;
  stack.appendChild(el);
  setTimeout(() => el.remove(), 3200);
}

function timeAgo(iso) {
  if (!iso) return '';
  const then = new Date(iso).getTime();
  const diffMin = Math.round((Date.now() - then) / 60000);
  if (diffMin < 1) return 'just now';
  if (diffMin < 60) return diffMin + 'm ago';
  const diffHr = Math.round(diffMin / 60);
  if (diffHr < 24) return diffHr + 'h ago';
  const diffDay = Math.round(diffHr / 24);
  if (diffDay < 7) return diffDay + 'd ago';
  return new Date(iso).toLocaleDateString('en-PH', { month: 'short', day: 'numeric' });
}

function formatDeadline(dateStr) {
  return new Date(dateStr + 'T00:00').toLocaleDateString('en-PH', { month: 'short', day: 'numeric', year: 'numeric' });
}

function daysUntil(dateStr) {
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const target = new Date(dateStr + 'T00:00');
  return Math.round((target - today) / 86400000);
}

/* ---------------------------------------------------------
   3. DATA MIRROR + LOADERS
   ---------------------------------------------------------
   Row mappers translate Postgres snake_case rows into the
   field names the UI already uses.
   --------------------------------------------------------- */
let db = emptyDb();

/* True only once the profiles table has actually come back.
   myRole() answers "does my row have a role?" by looking me up in
   db.users — and an empty db.users would make that look like "no
   role" when the truth is "have not checked yet". Anything that acts
   on the role waits for this. */
let profilesLoaded = false;
let chatPreviews = {};
let realtimeChannel = null;
let messageChannel = null;
let refreshTimer = null;
let pendingCollections = new Set();
let renderScheduled = false;

function emptyDb() {
  return { users: [], classes: [], posts: [], assignments: [], submissions: [], conversations: [], announcements: [] };
}

function mapProfile(r) { return r; }
function mapClass(r) {
  return Object.assign({}, r, {
    studentIds: (r.class_members || []).map(m => m.student_id)
  });
}
function mapPost(r) {
  return Object.assign({}, r, {
    timestamp: r.created_at,
    likes: (r.post_likes || []).map(l => l.user_id),
    comments: (r.comments || [])
      .map(c => ({ id: c.id, authorId: c.author_id, text: c.text, timestamp: c.created_at }))
      .sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp))
  });
}
function mapAssignment(r) { return r; }
function mapSubmission(r) {
  return Object.assign({}, r, {
    assignmentId: r.assignment_id,
    studentId: r.student_id,
    timestamp: r.created_at
  });
}
function mapConversation(r) {
  return Object.assign({}, r, {
    participantIds: (r.conversation_participants || []).map(p => p.user_id)
  });
}
function mapAnnouncement(r) {
  return Object.assign({}, r, {
    timestamp: r.created_at,
    readBy: (r.announcement_reads || []).map(x => x.user_id)
  });
}
function mapMessage(r) {
  return { id: r.id, senderId: r.sender_id, text: r.text, timestamp: r.created_at };
}

const LOADERS = {
  users: {
    collections: ['users'],
    run: async () => {
      const { data, error } = await sb.from('profiles').select('*').order('name');
      if (error) throw error;
      db.users = data.map(mapProfile);
      profilesLoaded = true;
    }
  },
  classes: {
    collections: ['classes'],
    run: async () => {
      const { data, error } = await sb.from('classes')
        .select('*, class_members(student_id)')
        .order('created_at');
      if (error) throw error;
      db.classes = data.map(mapClass);
    }
  },
  posts: {
    collections: ['posts'],
    run: async () => {
      const { data, error } = await sb.from('posts')
        .select('*, post_likes(user_id), comments(id, author_id, text, created_at)')
        .order('created_at');
      if (error) throw error;
      db.posts = data.map(mapPost);
    }
  },
  assignments: {
    collections: ['assignments'],
    run: async () => {
      const { data, error } = await sb.from('assignments').select('*').order('deadline');
      if (error) throw error;
      db.assignments = data.map(mapAssignment);
    }
  },
  submissions: {
    collections: ['submissions'],
    run: async () => {
      const { data, error } = await sb.from('submissions').select('*');
      if (error) throw error;
      db.submissions = data.map(mapSubmission);
    }
  },
  conversations: {
    collections: ['conversations', 'chatPreviews'],
    run: async () => {
      const { data, error } = await sb.from('conversations')
        .select('*, conversation_participants(user_id)')
        .order('created_at');
      if (error) throw error;
      db.conversations = data.map(mapConversation);
      const previews = await sb.from('conversation_last_message').select('*');
      chatPreviews = {};
      if (!previews.error) {
        previews.data.forEach(p => {
          chatPreviews[p.conversation_id] = { text: p.text, timestamp: p.created_at };
        });
      }
    }
  },
  announcements: {
    collections: ['announcements'],
    run: async () => {
      const { data, error } = await sb.from('announcements')
        .select('*, announcement_reads(user_id)')
        .order('created_at');
      if (error) throw error;
      db.announcements = data.map(mapAnnouncement);
    }
  }
};

const ALL_COLLECTIONS = Object.keys(LOADERS);

function dbError(err) {
     const msg = (err && (err.message || err)) || String(err);
     console.error('SociaLearn: data load failed ·', err);
     showToast('Could not load data: ' + msg, 'error');
     }

async function loadCollections(names) {
   const list = (names && names.length) ? names : ALL_COLLECTIONS;
   await Promise.all(list.map(name => LOADERS[name].run().catch(dbError)));
   scheduleRender();
   // The profiles have just landed, so this is the earliest moment a role
   // can honestly be judged. renderAll() reaches settleRole() too, but
   // leaning on a 30ms render debounce to notice that an account has no
   // role is how the prompt went missing for a Google sign-in.
   settleRole();
 }

function scheduleRefresh(names) {
  (names || ALL_COLLECTIONS).forEach(n => pendingCollections.add(n));
  if (refreshTimer) clearTimeout(refreshTimer);
  refreshTimer = setTimeout(() => {
    const names = Array.from(pendingCollections);
    pendingCollections = new Set();
    refreshTimer = null;
    if (currentUser) loadCollections(names);
  }, 250);
}

function scheduleRender() {
  if (!currentUser || renderScheduled) return;
  renderScheduled = true;
  setTimeout(() => { renderScheduled = false; renderAll(); }, 30);
}

function invalidateProfileCache() {
   // The loaded profiles belong to one specific account. Reusing them after
   // a sign-out, or after signing in as somebody else, is what makes a new
   // account look like it has no role.
   profilesLoaded = false;
   db.users = [];
   roleCheck = { uid: null, value: undefined };
}

function startDataListeners() {
  db = emptyDb();
  profilesLoaded = false;
  chatPreviews = {};
  loadCollections();

  realtimeChannel = sb.channel('socialearn')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'profiles' }, () => scheduleRefresh(['users']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'classes' }, () => scheduleRefresh(['classes']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'class_members' }, () => scheduleRefresh(['classes']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'posts' }, () => scheduleRefresh(['posts']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'post_likes' }, () => scheduleRefresh(['posts']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'comments' }, () => scheduleRefresh(['posts']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'assignments' }, () => scheduleRefresh(['assignments']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'submissions' }, () => scheduleRefresh(['submissions']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'announcements' }, () => scheduleRefresh(['announcements']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'announcement_reads' }, () => scheduleRefresh(['announcements']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'conversations' }, () => scheduleRefresh(['conversations']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'conversation_participants' }, () => scheduleRefresh(['conversations']))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'messages' }, () => scheduleRefresh(['conversations']))
    .subscribe();
}

function stopDataListeners() {
  if (refreshTimer) { clearTimeout(refreshTimer); refreshTimer = null; }
  if (realtimeChannel) { sb.removeChannel(realtimeChannel); realtimeChannel = null; }
  if (messageChannel) { sb.removeChannel(messageChannel); messageChannel = null; }
  activeConversationId = null;
  pendingCollections = new Set();
  chatPreviews = {};
  db = emptyDb();
  profilesLoaded = false;
}

/* ---------------------------------------------------------
   4. AUTH — sign up, sign in, Google, sign out
   --------------------------------------------------------- */
let currentUser = null;         // Supabase auth user object
let authMode = 'signin';

function friendlyAuthError(e) {
  const msg = (e && e.message) || '';
  const lower = msg.toLowerCase();
  if (lower.includes('already registered') || lower.includes('already been registered')) {
    return 'That email is already registered — try signing in instead.';
  }
  if (lower.includes('password should be at least')) {
    return 'Password must be at least 6 characters.';
  }
  if (lower.includes('invalid login credentials')) {
    return 'Incorrect email or password.';
  }
  if (lower.includes('email not confirmed')) {
    return 'Confirm your email address first — check your inbox.';
  }
  if (lower.includes('failed to fetch') || lower.includes('network')) {
    return 'Network error — check your connection.';
  }
  if (lower.includes('rate limit') || lower.includes('too many')) {
    return 'Too many attempts. Wait a moment and try again.';
  }
  return msg || 'Something went wrong. Please try again.';
}

function setAuthMode(mode) {
  authMode = mode;
  const isSignup = mode === 'signup';
  document.getElementById('auth-signup-fields').hidden = !isSignup;
  document.getElementById('auth-title').textContent = isSignup ? 'Create your account' : 'Welcome back';
  document.getElementById('auth-sub').textContent = isSignup ? 'Join your class on SociaLearn.' : 'Sign in to your class feed, chats, and assignments.';
  document.getElementById('auth-submit-btn').textContent = isSignup ? 'Create account' : 'Sign in';
  const toggle = document.getElementById('auth-toggle');
  toggle.innerHTML = isSignup
    ? `Already have an account? <button type="button" id="auth-toggle-btn">Sign in</button>`
    : `Don't have an account? <button type="button" id="auth-toggle-btn">Create one</button>`;
  document.getElementById('auth-toggle-btn').addEventListener('click', () => setAuthMode(isSignup ? 'signin' : 'signup'));
  document.getElementById('auth-error').hidden = true;
}

if (document.getElementById('auth-toggle-btn')) {
  document.getElementById('auth-toggle-btn').addEventListener('click', () => setAuthMode('signup'));
}

/* The Teacher/Student cards. There are two copies of this markup —
   one in the sign-up form, one in the post-Google-login modal — so
   both are wired the same way and share one piece of state. */
let signupRole = 'teacher';
let modalRoleChoice = 'teacher';

function pickRole(container, value) {
  container.querySelectorAll('.role-pick__opt').forEach(btn => {
    const on = btn.dataset.role === value;
    btn.classList.toggle('is-active', on);
    btn.setAttribute('aria-checked', on ? 'true' : 'false');
  });
}

function wireRolePicker(containerId, read, write) {
  const container = document.getElementById(containerId);
  if (!container) return;
  container.addEventListener('click', e => {
    const btn = e.target.closest('.role-pick__opt');
    if (!btn) return;
    pickRole(container, btn.dataset.role);
    write(btn.dataset.role);
  });
  pickRole(container, read());
}

wireRolePicker('auth-role-pick', () => signupRole, r => { signupRole = r; });
wireRolePicker('role-choose-pick', () => modalRoleChoice, r => { modalRoleChoice = r; });

document.getElementById('auth-submit-btn').addEventListener('click', async () => {
  if (!sbEnabled) { showAuthConfigError(); return; }
  const email = document.getElementById('auth-email').value.trim();
  const password = document.getElementById('auth-password').value;
  const errorEl = document.getElementById('auth-error');
  errorEl.hidden = true;
  if (!email || !password) { errorEl.textContent = 'Please fill in email and password.'; errorEl.hidden = false; return; }
  if (password.length < 6) { errorEl.textContent = 'Password must be at least 6 characters.'; errorEl.hidden = false; return; }

  const btn = document.getElementById('auth-submit-btn');
  btn.disabled = true;
  try {
    if (authMode === 'signup') {
      const name = document.getElementById('auth-name').value.trim();
      if (!name) {
        errorEl.textContent = 'Please enter your full name.'; errorEl.hidden = false; btn.disabled = false; return;
      }
      // These metadata fields are read by the handle_user_sync()
      // trigger to build the profile row on sign-up. `role` comes
      // from the Teacher/Student picker and is stored server-side,
      // where it can never be changed afterwards. Because it travels
      // with the sign-up, the app never has to ask again.
      const { error } = await sb.auth.signUp({
        email,
        password,
        options: {
          data: {
            name,
            role: signupRole
          }
        }
      });
      if (error) throw error;
      const { data: { session: newSession } } = await sb.auth.getSession();
      if (!newSession) {
        // Confirmation emails are on: no session until they click.
        errorEl.textContent = 'Account created. Check your email to confirm, then sign in.';
        errorEl.hidden = false;
        btn.disabled = false;
        return;
      }
    } else {
      const { error } = await sb.auth.signInWithPassword({ email, password });
      if (error) throw error;
    }
  } catch (e) {
    errorEl.textContent = friendlyAuthError(e);
    errorEl.hidden = false;
  }
  btn.disabled = false;
});

/* Google sign-in bounces the whole page out to accounts.google.com
   and back, so it needs a real http(s) origin. Opened as a
   file:// path there is no origin to return to, and the redirect
   silently fails — which looks exactly like "sign-in is broken". */
function oauthRedirectUrl() {
  if (supabaseConfig.redirectUrl) return supabaseConfig.redirectUrl;
  if (window.location.protocol === 'file:') return null;
  return window.location.origin + window.location.pathname;
}

document.getElementById('auth-google-btn').addEventListener('click', async () => {
  if (!sbEnabled) { showAuthConfigError(); return; }
  const errorEl = document.getElementById('auth-error');
  errorEl.hidden = true;

  const redirectTo = oauthRedirectUrl();
  if (!redirectTo) {
    errorEl.textContent = 'Google sign-in needs the app served over http://, not opened as a file. Start a server in this folder (npx serve . or python -m http.server 8080) and open the http:// address it prints.';
    errorEl.hidden = false;
    return;
  }

  const { error } = await sb.auth.signInWithOAuth({
    provider: 'google',
    options: { redirectTo }
  });
  if (error) {
    errorEl.textContent = friendlyAuthError(error);
    errorEl.hidden = false;
  }
});

function showAuthConfigError() {
  const errorEl = document.getElementById('auth-error');
  errorEl.textContent = 'Supabase is not configured yet. Fill in supabase-config.js with your project URL and anon key, and run supabase-schema.sql in the SQL editor. See README.md.';
  errorEl.hidden = false;
}

async function signOut() {
   if (sbEnabled) await sb.auth.signOut();
   // Signing out is the exact moment the loaded profiles stop belonging to
   // anyone. Clear them here as well as in the auth callback, so the next
   // sign-in cannot read the previous account's rows as its own.
   invalidateProfileCache();
   }
document.getElementById('signout-btn').addEventListener('click', signOut);
document.getElementById('signout-btn-2').addEventListener('click', signOut);

function gateApp(signedIn) {
  document.getElementById('auth-screen').hidden = !!signedIn;
  document.getElementById('app-root').hidden = !signedIn;
}

/* Mirrors what the handle_user_sync() trigger does server-side, but
   immediately on sign-in — so the header switching to a Google photo
   never lags behind the login. Only fields Google actually supplied
   are written, so a name typed on the signup form survives. */
async function syncProfileFromSession(user) {
  const meta = (user && user.user_metadata) || {};
  const name = meta.full_name || meta.name || '';
  const avatarUrl = meta.picture || meta.avatar_url || '';
  if (!name && !avatarUrl && !meta.role) return;

  const patch = {};
  if (name) { patch.name = name; patch.initials = initialsFromName(name); }
  if (avatarUrl) patch.avatar_url = avatarUrl;

// An UPDATE, deliberately not an upsert. profiles_lock_role refuses a
   // second role, so re-writing `role` on the way in would break every
   // returning account. This only ever touches the name and the photo.
   const { data, error } = await sb.from('profiles').update(patch).eq('id', user.uid).select();
   if (error) { console.warn('SociaLearn: could not sync profile', error.message); return; }
   if (data && data.length) return;

   // Zero rows matched, which means the sign-up trigger never created one.
   // An update cannot insert, so without this the account is stuck with no
   // profile at all: myRole() keeps reporting "no role", the role prompt
   // keeps reappearing, and set_my_role() keeps refusing with
   // "profile not ready yet". Create it here instead · and this is the one
   // safe moment to write the role, because the row does not exist yet, so
   // there is no earlier choice to overwrite.
   const fallbackName = (user.email || '').split('@')[0] || 'New User';
   const seed = {
      id: user.uid,
      name: patch.name || fallbackName,
      initials: patch.initials || initialsFromName(fallbackName),
      role: meta.role || null
   };
   if (patch.avatar_url) seed.avatar_url = patch.avatar_url;
   const { error: insErr } = await sb.from('profiles').insert(seed);
   if (insErr) { console.warn('SociaLearn: could not create profile', insErr.message); return; }
   // The initial select ran before this row existed, so pull the profile
   // collection again · otherwise db.users stays empty and the role prompt
   // fires for an account that already answered.
   await loadCollections(['users']);
   }

if (sbEnabled) {
  // Supabase v2 calls this with (event, session) — TWO arguments.
  // The first is the event NAME, so reading .user off it is always
  // undefined, which bounced every sign-in back to the login page.
  sb.auth.onAuthStateChange((event, session) => {
    const user = session ? session.user : null;
    // db.users and profilesLoaded describe whoever is signed in *right now*.
    // The instant that person changes, those rows stop being true: the new
    // account is not in them yet. Read before startDataListeners() resets
    // them and myRole() reports "no role" for an account the sign-up trigger
    // already answered, which pops the role prompt on a fresh account.
    // Dropping them here makes settleRole()'s profilesLoaded guard hold the
    // prompt until the new profiles have actually loaded.
    const nextUid = user ? user.uid : null;
    const prevUid = currentUser ? currentUser.uid : null;
    if (prevUid !== nextUid) invalidateProfileCache();

    if (user) {
      currentUser = user;
      gateApp(true);
      renderAll();
      // Deliberately not awaited: this callback runs while Supabase
      // holds an internal auth lock, and awaiting another Supabase
      // call inside it can deadlock.
      setTimeout(() => {
        syncProfileFromSession(user).catch(e => console.error('SociaLearn: profile sync failed', e));
      }, 0);
      startDataListeners();
      startRoleWatchdog();
    } else {
      currentUser = null;
      stopDataListeners();
      gateApp(false);
    }
  });
} else {
  gateApp(false);
  showAuthConfigError();
}

/* ---------------------------------------------------------
   5. IDENTITY / MEMBERSHIP HELPERS
   --------------------------------------------------------- */
function findUser(id) { return db.users.find(u => u.id === id); }
function findClass(id) { return db.classes.find(c => c.id === id); }
function me() {
  const meta = (currentUser && currentUser.user_metadata) || {};
  const name = meta.full_name || meta.name || currentUser.email || 'You';
  return findUser(currentUser.uid) || {
    id: currentUser.uid,
    name,
    username: (currentUser.email || '').split('@')[0],
    initials: initialsFromName(name),
    avatar_url: meta.picture || meta.avatar_url || ''
  };
}
function isTeacherOf(classId) { const c = findClass(classId); return c && c.teacher_id === currentUser.uid; }
function isMemberOf(classId) {
  const c = findClass(classId);
  return c && (c.teacher_id === currentUser.uid || c.studentIds.includes(currentUser.uid));
}
function myClasses() { return db.classes.filter(c => isMemberOf(c.id)); }
function myTaughtClasses() { return db.classes.filter(c => c.teacher_id === currentUser.uid); }
function myJoinedClasses() { return db.classes.filter(c => c.studentIds.includes(currentUser.uid)); }

/* ---------------------------------------------------------
   6. ASSIGNMENT STATUS
   --------------------------------------------------------- */
function findSubmission(assignmentId, studentId) {
  return db.submissions.find(s => s.assignmentId === assignmentId && s.studentId === studentId);
}
function getAssignmentStatus(assignment, studentId) {
  if (findSubmission(assignment.id, studentId)) return 'submitted';
  const days = daysUntil(assignment.deadline);
  if (days < 0) return 'missing';
  if (days <= 2) return 'due-soon';
  return 'upcoming';
}
const STATUS_LABEL = { submitted: 'Submitted', missing: 'Missing', 'due-soon': 'Due soon', upcoming: 'Upcoming' };
const STATUS_CLASS = { submitted: 'status--submitted', missing: 'status--missing', 'due-soon': 'status--due-soon', upcoming: 'status--upcoming' };

/* ---------------------------------------------------------
   7. PER-DEVICE TODO CHECKLIST (kept local — personal, not shared)
   --------------------------------------------------------- */
function getTodoDone() {
  try { return JSON.parse(localStorage.getItem('socialearn:todoDone:' + currentUser.uid) || '[]'); }
  catch (e) { return []; }
}
function setTodoDone(arr) {
  localStorage.setItem('socialearn:todoDone:' + currentUser.uid, JSON.stringify(arr));
}

/* ---------------------------------------------------------
   8. NAVIGATION
   --------------------------------------------------------- */
function goToSection(section) {
  document.querySelectorAll('.view').forEach(v => v.hidden = (v.dataset.view !== section));
  document.querySelectorAll('[data-section-target]').forEach(btn => {
    btn.classList.toggle('is-active', btn.dataset.sectionTarget === section);
  });
  window.scrollTo({ top: 0 });
}
document.querySelectorAll('[data-section-target]').forEach(btn => {
  btn.addEventListener('click', () => goToSection(btn.dataset.sectionTarget));
});

/* ---------------------------------------------------------
   9. WHO AM I — teacher or student?
   ---------------------------------------------------------
   The role is NOT a localStorage flag and NOT something the
   browser gets to decide. It lives in profiles.role, is written
   once at sign-up (or once via set_my_role() after a Google
   login), and Postgres refuses any later change. Everything
   below reads that stored value.

   localStorage is still used for one thing only: remembering
   which of the two side-by-side views you were last looking at,
   which is harmless because the teacher view renders nothing for
   someone who is not a teacher. */
let viewMode = localStorage.getItem('socialearn:view') || 'auto';

/* 'teacher' | 'student' | null (has not chosen yet) */
function myRole() {
  if (!currentUser) return null;
  const me = db.users.find(u => u.id === currentUser.uid);
  return me ? (me.role || null) : null;
}

function setViewMode(mode) {
  viewMode = mode;
  localStorage.setItem('socialearn:view', mode);
  renderAll();
}

/* Every teacher-only capability in the UI asks this one function, and
   behind it is a stored profile.role that Postgres enforces. Hiding a
   button is only tidiness · the row-level policy is what actually
   stops a student creating a class. */
function isTeacher() { return myRole() === 'teacher'; }

function roleLabel() {
  const r = myRole();
  return r === 'teacher' ? 'Teacher' : r === 'student' ? 'Student' : 'No role yet';
}

/* Which list the Classroom page shows. A teacher only ever teaches, so
   "Teacher view" is not offered to a student at all. */
function activeView() {
  return viewMode === 'teacher' && isTeacher() ? 'teacher' : 'student';
}

document.querySelectorAll('.role-switch__opt').forEach(btn => {
  btn.addEventListener('click', () => setViewMode(btn.dataset.role));
});

/* ---------------------------------------------------------
   10. MODALS
   --------------------------------------------------------- */
function openModal(id) {
  document.getElementById('modal-backdrop').hidden = false;
  document.querySelectorAll('.modal').forEach(m => m.hidden = (m.id !== id));
}
function closeModal() {
  document.getElementById('modal-backdrop').hidden = true;
  document.querySelectorAll('.modal').forEach(m => m.hidden = true);
}
/* The role modal is marked data-modal-lock because there is no way
   around it: until a role is stored, the account cannot create or
   join anything, and set_my_role() only works once. Clicking the
   backdrop must not be a way out. */
function roleModalIsOpen() {
  return !document.getElementById('modal-role').hidden;
}
document.getElementById('modal-backdrop').addEventListener('click', e => {
  if (e.target.id === 'modal-backdrop' && !roleModalIsOpen()) closeModal();
});
document.querySelectorAll('[data-close]').forEach(btn => btn.addEventListener('click', closeModal));

/* ---------------------------------------------------------
   11. FEED
   --------------------------------------------------------- */
function renderFeed() {
  const classIds = myClasses().map(c => c.id);
  const posts = db.posts.filter(p => classIds.includes(p.class_id)).sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
  const list = document.getElementById('feed-list');

  document.getElementById('composer').hidden = !isTeacher() || myTaughtClasses().length === 0;

  if (posts.length === 0) {
    list.innerHTML = `<div class="empty-state"><p>No posts yet. Join a class to see updates from your instructors.</p>
      <button class="btn btn--primary" onclick="goToSection('classroom')">Go to Classroom</button></div>`;
  } else {
    list.innerHTML = posts.map(renderPostCard).join('');
  }

  const deadlineWidget = document.getElementById('widget-deadlines');
  const upcoming = db.assignments
    .filter(a => classIds.includes(a.class_id) && getAssignmentStatus(a, currentUser.uid) !== 'submitted')
    .sort((a, b) => new Date(a.deadline) - new Date(b.deadline)).slice(0, 4);
  deadlineWidget.innerHTML = upcoming.length
    ? upcoming.map(a => `<li><span>${escapeHTML(a.title)}</span><strong>${formatDeadline(a.deadline)}</strong></li>`).join('')
    : `<li class="widget__empty">You're all caught up!</li>`;

  const annWidget = document.getElementById('widget-announcements');
  const unread = db.announcements.filter(a => classIds.includes(a.class_id) && !a.readBy.includes(currentUser.uid));
  annWidget.innerHTML = unread.length
    ? unread.slice(0, 4).map(a => `<li><span>${escapeHTML(a.title)}</span></li>`).join('')
    : `<li class="widget__empty">No unread announcements.</li>`;

  const classWidget = document.getElementById('widget-classes');
  const mine = myClasses();
  classWidget.innerHTML = mine.length
    ? mine.map(c => `<li><span>${escapeHTML(c.name)}</span><strong>${escapeHTML(c.section)}</strong></li>`).join('')
    : `<li class="widget__empty">You haven't joined any classes yet.</li>`;
}

function renderPostCard(post) {
  const author = findUser(post.author_id);
  const cls = findClass(post.class_id);
  const role = (cls && cls.teacher_id === post.author_id) ? 'teacher' : 'student';
  const liked = post.likes.includes(currentUser.uid);
  return `
  <article class="post" data-post-id="${post.id}">
    <div class="post__head">
      <span class="avatar avatar--sm">${avatarHTML(author)}</span>
      <div class="post__meta">
        <div class="post__name-row">
          <span class="post__name">${author ? escapeHTML(author.name) : 'Unknown'}</span>
          <span class="post__role-chip ${role}">${role === 'teacher' ? 'Instructor' : 'Student'}</span>
        </div>
        <p class="post__sub">${cls ? escapeHTML(cls.name) : ''} · ${timeAgo(post.timestamp)}</p>
      </div>
      <button class="post__more" aria-label="More options">⋯</button>
    </div>
    <p class="post__content">${escapeHTML(post.content)}</p>
    ${post.attachment ? `<div class="post__attachment">📎 attachment.pdf</div>` : ''}
    <div class="post__actions">
      <button class="post__action ${liked ? 'is-liked' : ''}" data-action="like" data-post="${post.id}">👍 Like (${post.likes.length})</button>
      <button class="post__action" data-action="comment-focus" data-post="${post.id}">💬 Comment (${post.comments.length})</button>
    </div>
    <div class="post__comments">
      ${post.comments.map(c => {
        const cu = findUser(c.author_id);
        return `<div class="post__comment"><span class="avatar avatar--sm" style="width:26px;height:26px;font-size:.7rem">${avatarHTML(cu)}</span>
          <div class="post__comment-bubble"><strong>${cu ? escapeHTML(cu.name) : 'Unknown'}</strong>${escapeHTML(c.text)}</div></div>`;
      }).join('')}
      <form class="post__comment-form" data-post="${post.id}">
        <input type="text" placeholder="Write a comment…" maxlength="240">
        <button type="submit">Send</button>
      </form>
    </div>
  </article>`;
}

document.getElementById('feed-list').addEventListener('click', async e => {
  const likeBtn = e.target.closest('[data-action="like"]');
  if (likeBtn) {
    const postId = likeBtn.dataset.post;
    const post = db.posts.find(p => p.id === postId);
    if (!post) return;
    if (post.likes.includes(currentUser.uid)) {
      const { error } = await sb.from('post_likes').delete()
        .eq('post_id', postId).eq('user_id', currentUser.uid);
      if (error) showToast('Could not unlike: ' + error.message, 'error');
    } else {
      const { error } = await sb.from('post_likes')
        .insert({ post_id: postId, user_id: currentUser.uid });
      if (error) showToast('Could not like: ' + error.message, 'error');
    }
    return;
  }
  const commentFocus = e.target.closest('[data-action="comment-focus"]');
  if (commentFocus) {
    const input = document.querySelector(`.post__comment-form[data-post="${commentFocus.dataset.post}"] input`);
    if (input) input.focus();
  }
});

document.getElementById('feed-list').addEventListener('submit', async e => {
  if (!e.target.classList.contains('post__comment-form')) return;
  e.preventDefault();
  const input = e.target.querySelector('input');
  const text = input.value.trim();
  if (!text) return;
  const postId = e.target.dataset.post;
  input.value = '';
  const { error } = await sb.from('comments')
    .insert({ post_id: postId, author_id: currentUser.uid, text });
  if (error) showToast('Could not comment: ' + error.message, 'error');
});

document.getElementById('composer-open').addEventListener('click', () => {
  const select = document.getElementById('post-class');
  select.innerHTML = myTaughtClasses().map(c => `<option value="${c.id}">${escapeHTML(c.name)} (${escapeHTML(c.section)})</option>`).join('');
  document.getElementById('post-content').value = '';
  document.getElementById('post-attachment').checked = false;
  document.getElementById('post-error').hidden = true;
  openModal('modal-post');
});

document.getElementById('post-submit').addEventListener('click', async () => {
  const classId = document.getElementById('post-class').value;
  const content = document.getElementById('post-content').value.trim();
  const errorEl = document.getElementById('post-error');
  if (!content) { errorEl.textContent = 'Post content cannot be empty.'; errorEl.hidden = false; return; }
  const attachment = document.getElementById('post-attachment').checked;
  const { error } = await sb.from('posts')
    .insert({ class_id: classId, author_id: currentUser.uid, content, attachment });
  if (error) {
    errorEl.textContent = 'Failed to post: ' + error.message;
    errorEl.hidden = false;
    return;
  }
  closeModal();
  showToast('Post published to the class feed.');
});

/* ---------------------------------------------------------
   12. CLASSROOM
   --------------------------------------------------------- */
function renderClassroom() {
  const grid = document.getElementById('class-grid');
  const teaching = isTeacher();
  document.getElementById('create-class-btn').hidden = !teaching;
  document.getElementById('join-class-btn').hidden = teaching;
  document.getElementById('classroom-sub').textContent = teaching ? 'Classes you are teaching.' : 'Your enrolled classes, all in one place.';

  const list = teaching ? myTaughtClasses() : myJoinedClasses();

  if (list.length === 0) {
    grid.innerHTML = teaching
      ? `<div class="empty-state"><p>You haven't created a class yet.</p><button class="btn btn--primary" onclick="document.getElementById('create-class-btn').click()">Create class</button></div>`
      : `<div class="empty-state"><p>You haven't joined any classes yet.</p><button class="btn btn--primary" onclick="document.getElementById('join-class-btn').click()">Join a class</button></div>`;
    return;
  }

  grid.innerHTML = list.map(c => {
    const memberCount = c.studentIds.length;
    if (teaching) {
      return `
      <div class="class-card">
        <div class="class-card__banner"></div>
        <div class="class-card__body">
          <span class="class-card__name">${escapeHTML(c.name)}</span>
          <span class="class-card__section">${escapeHTML(c.section)}</span>
          <div class="class-card__meta"><span>${memberCount} student${memberCount === 1 ? '' : 's'}</span><span class="class-card__code">${c.code}</span></div>
        </div>
        <div class="class-card__footer">
          <button class="btn btn--ghost btn--sm" data-open-chat-class="${c.id}">Group chat</button>
          <button class="btn btn--ghost btn--sm" data-view-assignments-class="${c.id}">Assignments</button>
        </div>
      </div>`;
    }
    const teacher = findUser(c.teacher_id);
    return `
      <div class="class-card">
        <div class="class-card__banner"></div>
        <div class="class-card__body">
          <span class="class-card__name">${escapeHTML(c.name)}</span>
          <span class="class-card__section">${escapeHTML(c.section)} · ${teacher ? escapeHTML(teacher.name) : ''}</span>
          <div class="class-card__meta"><span>${memberCount} classmate${memberCount === 1 ? '' : 's'}</span></div>
        </div>
        <div class="class-card__footer">
          <button class="btn btn--ghost btn--sm" data-open-chat-class="${c.id}">Group chat</button>
          <button class="btn btn--ghost btn--sm" data-view-assignments-class="${c.id}">Assignments</button>
        </div>
      </div>`;
  }).join('');
}

document.getElementById('class-grid').addEventListener('click', e => {
  const chatBtn = e.target.closest('[data-open-chat-class]');
  if (chatBtn) {
    const convId = groupConvId(chatBtn.dataset.openChatClass);
    goToSection('chats');
    openConversation(convId);
    return;
  }
  const asgBtn = e.target.closest('[data-view-assignments-class]');
  if (asgBtn) {
    goToSection('assignments');
    document.getElementById('assignment-filter').value = asgBtn.dataset.viewAssignmentsClass;
    renderAssignments();
  }
});

document.getElementById('join-class-btn').addEventListener('click', () => {
  document.getElementById('join-code-input').value = '';
  document.getElementById('join-error').hidden = true;
  openModal('modal-join');
});

document.getElementById('join-submit').addEventListener('click', async () => {
  const codeRaw = document.getElementById('join-code-input').value.trim().toUpperCase();
  const errorEl = document.getElementById('join-error');
  if (!codeRaw) { errorEl.textContent = 'Please enter a class code.'; errorEl.hidden = false; return; }

  const btn = document.getElementById('join-submit');
  btn.disabled = true;
  // One atomic call: enrols the student and makes sure the group
  // chat exists with both teacher and student in it.
  const { data, error } = await sb.rpc('join_class', { p_code: codeRaw });
  btn.disabled = false;
  if (error) {
    errorEl.textContent = /no class with that code/i.test(error.message)
      ? 'That class code was not found. Double-check with your instructor.'
      : 'Failed to join: ' + error.message;
    errorEl.hidden = false;
    return;
  }
  if (data && data[0] && data[0].already_joined) {
    errorEl.textContent = 'You are already enrolled in this class.';
    errorEl.hidden = false;
    return;
  }
  closeModal();
  showToast(`Joined ${data[0].name}. The class group chat has been linked.`);
});

document.getElementById('create-class-btn').addEventListener('click', () => {
  document.getElementById('cc-name').value = '';
  document.getElementById('cc-section').value = '';
  document.getElementById('cc-error').hidden = true;
  openModal('modal-create-class');
});

document.getElementById('cc-submit').addEventListener('click', async () => {
  const name = document.getElementById('cc-name').value.trim();
  const section = document.getElementById('cc-section').value.trim();
  const errorEl = document.getElementById('cc-error');
  if (!name || !section) { errorEl.textContent = 'Please fill in both the class name and section.'; errorEl.hidden = false; return; }

  let code;
  do { code = generateClassCode(name); } while (db.classes.some(c => c.code === code));

  const { data: created, error } = await sb.from('classes')
    .insert({ name, section, code, teacher_id: currentUser.uid })
    .select('id').single();
  if (error) {
    errorEl.textContent = 'Failed to create class: ' + error.message;
    errorEl.hidden = false;
    return;
  }

  const { error: convErr } = await sb.from('conversations').insert({
    id: groupConvId(created.id),
    type: 'group',
    class_id: created.id,
    name: `${name} — ${section}`
  });
  if (convErr) {
    errorEl.textContent = 'Class created, but its group chat failed: ' + convErr.message;
    errorEl.hidden = false;
    return;
  }
  const { error: partErr } = await sb.from('conversation_participants')
    .insert({ conversation_id: groupConvId(created.id), user_id: currentUser.uid });
  if (partErr) {
    errorEl.textContent = 'Class created, but its group chat failed: ' + partErr.message;
    errorEl.hidden = false;
    return;
  }

  closeModal();
  showToast(`Class created. Share the code ${code} with your students.`);
});

/* ---------------------------------------------------------
   13. ASSIGNMENTS
   --------------------------------------------------------- */
let currentAssignmentId = null;
let adSelectedFilename = null;

function renderAssignments() {
  const teaching = isTeacher();
  document.getElementById('create-assignment-btn').hidden = !teaching;

  const classes = teaching ? myTaughtClasses() : myJoinedClasses();
  const filterSelect = document.getElementById('assignment-filter');
  const prevValue = filterSelect.value || 'all';
  filterSelect.innerHTML = `<option value="all">All classes</option>` + classes.map(c => `<option value="${c.id}">${escapeHTML(c.name)}</option>`).join('');
  filterSelect.value = classes.some(c => c.id === prevValue) ? prevValue : 'all';

  const classIds = classes.map(c => c.id);
  let assignments = db.assignments.filter(a => classIds.includes(a.class_id));
  if (filterSelect.value !== 'all') assignments = assignments.filter(a => a.class_id === filterSelect.value);
  assignments = assignments.sort((a, b) => new Date(a.deadline) - new Date(b.deadline));

  const list = document.getElementById('assignment-list');
  if (assignments.length === 0) { list.innerHTML = `<div class="empty-state"><p>No assignments available.</p></div>`; return; }

  list.innerHTML = assignments.map(a => {
    const cls = findClass(a.class_id);
    if (!cls) return '';
    if (teaching) {
      const count = db.submissions.filter(s => s.assignmentId === a.id).length;
      const total = cls.studentIds.length;
      return `
      <div class="assignment-row" data-assignment="${a.id}">
        <div class="assignment-row__icon">📄</div>
        <div class="assignment-row__main">
          <div class="assignment-row__title">${escapeHTML(a.title)}</div>
          <div class="assignment-row__sub">${escapeHTML(cls.name)} · Due ${formatDeadline(a.deadline)}</div>
        </div>
        <span class="assignment-row__points">${count}/${total} submitted</span>
      </div>`;
    }
    const status = getAssignmentStatus(a, currentUser.uid);
    return `
      <div class="assignment-row" data-assignment="${a.id}">
        <div class="assignment-row__icon">📄</div>
        <div class="assignment-row__main">
          <div class="assignment-row__title">${escapeHTML(a.title)}</div>
          <div class="assignment-row__sub">${escapeHTML(cls.name)} · Due ${formatDeadline(a.deadline)}${a.points ? ' · ' + a.points + ' pts' : ''}</div>
        </div>
        <span class="status ${STATUS_CLASS[status]}">${STATUS_LABEL[status]}</span>
      </div>`;
  }).join('');
}

document.getElementById('assignment-filter').addEventListener('change', renderAssignments);
document.getElementById('assignment-list').addEventListener('click', e => {
  const row = e.target.closest('[data-assignment]');
  if (row) openAssignmentDetail(row.dataset.assignment);
});

function openAssignmentDetail(assignmentId) {
  currentAssignmentId = assignmentId;
  adSelectedFilename = null;
  const a = db.assignments.find(x => x.id === assignmentId);
  if (!a) return;
  const cls = findClass(a.class_id);
  const teaching = isTeacher();

  document.getElementById('ad-title').textContent = a.title;
  document.getElementById('ad-meta').textContent = `${cls.name} · Due ${formatDeadline(a.deadline)}${a.points ? ' · ' + a.points + ' pts' : ''}`;
  document.getElementById('ad-instructions').textContent = a.instructions;
  document.getElementById('ad-error').hidden = true;
  document.getElementById('ad-filename').textContent = '';
  document.getElementById('ad-file-input').value = '';

  document.getElementById('ad-student-area').hidden = teaching;
  document.getElementById('ad-teacher-area').hidden = !teaching;
  document.getElementById('ad-submit-btn').hidden = teaching;

  if (teaching) {
    const subs = db.submissions.filter(s => s.assignmentId === assignmentId);
    const listEl = document.getElementById('ad-submission-list');
    listEl.innerHTML = subs.length
      ? subs.map(s => {
          const u = findUser(s.student_id);
          return `<li class="submission-row"><span>${u ? escapeHTML(u.name) : 'Unknown'} — ${escapeHTML(s.filename)}</span><span>${timeAgo(s.timestamp)}</span></li>`;
        }).join('')
      : `<li class="submission-row">No submissions yet.</li>`;
  } else {
    const existing = findSubmission(assignmentId, currentUser.uid);
    const btn = document.getElementById('ad-submit-btn');
    if (existing) {
      document.getElementById('ad-filename').textContent = `Submitted: ${existing.filename} (${timeAgo(existing.timestamp)})`;
      btn.textContent = 'Resubmit';
    } else {
      btn.textContent = 'Submit assignment';
    }
  }
  openModal('modal-assignment-detail');
}

document.getElementById('ad-file-input').addEventListener('change', e => {
  const file = e.target.files[0];
  adSelectedFilename = file ? file.name : null;
  document.getElementById('ad-filename').textContent = file ? `Selected file: ${file.name}` : '';
});

document.getElementById('ad-submit-btn').addEventListener('click', async () => {
  const errorEl = document.getElementById('ad-error');
  if (!adSelectedFilename) { errorEl.textContent = 'Please choose a file before submitting.'; errorEl.hidden = false; return; }
  // The unique (assignment_id, student_id) constraint means this
  // replaces any previous submission — same as the old .set().
  const { error } = await sb.from('submissions').upsert({
    assignment_id: currentAssignmentId,
    student_id: currentUser.uid,
    filename: adSelectedFilename
  }, { onConflict: 'assignment_id,student_id' });
  if (error) {
    errorEl.textContent = 'Failed to submit: ' + error.message;
    errorEl.hidden = false;
    return;
  }
  closeModal();
  showToast('Assignment submitted.');
});

document.getElementById('create-assignment-btn').addEventListener('click', () => {
  const select = document.getElementById('a-class');
  select.innerHTML = myTaughtClasses().map(c => `<option value="${c.id}">${escapeHTML(c.name)} (${escapeHTML(c.section)})</option>`).join('');
  document.getElementById('a-title').value = '';
  document.getElementById('a-instructions').value = '';
  document.getElementById('a-deadline').value = daysFromNow(7);
  document.getElementById('a-points').value = '';
  document.getElementById('a-error').hidden = true;
  openModal('modal-assignment');
});

document.getElementById('a-submit').addEventListener('click', async () => {
  const classId = document.getElementById('a-class').value;
  const title = document.getElementById('a-title').value.trim();
  const instructions = document.getElementById('a-instructions').value.trim();
  const deadline = document.getElementById('a-deadline').value;
  const points = document.getElementById('a-points').value;
  const errorEl = document.getElementById('a-error');

  if (!title) { errorEl.textContent = 'Please give the assignment a title.'; errorEl.hidden = false; return; }
  if (!deadline) { errorEl.textContent = 'Please set a deadline.'; errorEl.hidden = false; return; }

  const { error } = await sb.from('assignments').insert({
    class_id: classId,
    title,
    instructions,
    deadline,
    points: points ? Number(points) : null
  });
  if (error) {
    errorEl.textContent = 'Failed to create assignment: ' + error.message;
    errorEl.hidden = false;
    return;
  }
  closeModal();
  showToast('Assignment created.');
});

/* ---------------------------------------------------------
   14. CHATS — live via Supabase Realtime, deterministic
       conversation IDs (group-<classId>, dm-<sorted uids>)
   --------------------------------------------------------- */
let activeConversationId = null;

function myConversations() {
  const classIds = myClasses().map(c => c.id);
  return db.conversations.filter(c => {
    if (c.type === 'group') return classIds.includes(c.class_id);
    return c.participantIds.includes(currentUser.uid);
  });
}

function conversationDisplayName(conv) {
  if (conv.type === 'group') return conv.name;
  const otherId = conv.participantIds.find(id => id !== currentUser.uid);
  const other = findUser(otherId);
  return other ? other.name : 'Unknown';
}

function renderChatListOnly() {
  const list = document.getElementById('chat-list');
  const convs = myConversations().sort((a, b) => {
    const av = chatPreviews[a.id]; const bv = chatPreviews[b.id];
    return new Date(bv ? bv.timestamp : 0) - new Date(av ? av.timestamp : 0);
  });

  if (convs.length === 0) {
    list.innerHTML = `<div class="empty-state" style="margin:16px;"><p>Start a conversation with a classmate.</p></div>`;
    return;
  }

  list.innerHTML = convs.map(c => {
    const last = chatPreviews[c.id];
    const name = conversationDisplayName(c);
    const face = c.type === 'group'
      ? '#'
      : avatarHTML(findUser(c.participantIds.find(id => id !== currentUser.uid)));
    return `
    <div class="chat-item ${c.id === activeConversationId ? 'is-active' : ''}" data-conv="${c.id}">
      <span class="avatar avatar--sm">${face}</span>
      <div class="chat-item__meta">
        <div class="chat-item__name">${escapeHTML(name)}</div>
        <div class="chat-item__preview">${last ? escapeHTML(last.text) : 'No messages yet'}</div>
      </div>
      <span class="chat-item__time">${last ? timeAgo(last.timestamp) : ''}</span>
    </div>`;
  }).join('');
}

function renderChats() {
  document.getElementById('chat-status').textContent = sbEnabled
    ? 'Live — messages sync in real time across devices.'
    : 'Supabase not configured — see README.md.';
  renderChatListOnly();

  if (activeConversationId && myConversations().some(c => c.id === activeConversationId)) {
    renderChatWindow(activeConversationId);
  } else if (!activeConversationId) {
    document.getElementById('chat-window').innerHTML = `<div class="chat-window__empty"><p>Select a conversation to start chatting.</p></div>`;
  }
}

function openConversation(convId, fallbackConv) {
  activeConversationId = convId;
  renderChatListOnly();
  renderChatWindow(convId, fallbackConv);
}

document.getElementById('chat-list').addEventListener('click', e => {
  const item = e.target.closest('[data-conv]');
  if (item) openConversation(item.dataset.conv);
});

function renderMessages(messages, conv) {
  const msgBox = document.getElementById('chat-messages');
  if (!msgBox) return;
  const wasAtBottom = msgBox.scrollHeight - msgBox.scrollTop - msgBox.clientHeight < 60;
  msgBox.innerHTML = messages.map(m => {
    const mine = m.senderId === currentUser.uid;
    const sender = findUser(m.senderId);
    return `<div class="msg ${mine ? 'mine' : 'theirs'}">${!mine && conv.type === 'group' ? `<strong style="display:block;font-size:.72rem;opacity:.8;margin-bottom:2px;">${escapeHTML(sender ? sender.name : '')}</strong>` : ''}${escapeHTML(m.text)}<span class="msg__time">${timeAgo(m.timestamp)}</span></div>`;
  }).join('');
  // Only auto-scroll if the reader was already at the bottom, so
  // scrolling back through history isn't yanked away.
  if (wasAtBottom || messages.length <= 1) msgBox.scrollTop = msgBox.scrollHeight;
}

async function loadMessages(convId) {
  const { data, error } = await sb.from('messages')
    .select('*')
    .eq('conversation_id', convId)
    .order('created_at');
  if (error) { console.error('SociaLearn: message load failed', error); return; }
  const conv = db.conversations.find(c => c.id === convId);
  if (!conv) return;
  renderMessages(data.map(mapMessage), conv);
}

function renderChatWindow(convId, fallbackConv) {
  const conv = db.conversations.find(c => c.id === convId) || fallbackConv;
  const win = document.getElementById('chat-window');
  if (!conv) { win.innerHTML = `<div class="chat-window__empty"><p>Loading conversation…</p></div>`; return; }

  const name = conversationDisplayName(conv);
  const sub = conv.type === 'group' ? `${conv.participantIds.length} members` : 'Direct message';

  if (messageChannel) { sb.removeChannel(messageChannel); messageChannel = null; }

  win.innerHTML = `
    <div class="chat-window__head"><div><strong>${escapeHTML(name)}</strong><span>${sub}</span></div></div>
    <div class="chat-window__messages" id="chat-messages"></div>
    <form class="chat-window__composer" id="chat-send-form">
      <input type="text" id="chat-input" placeholder="Type a message…" autocomplete="off">
      <button type="submit">Send</button>
    </form>`;

  loadMessages(convId);

  // A per-conversation channel, so only this chat's new messages
  // trigger a re-read instead of the whole window reloading.
  messageChannel = sb.channel('conv:' + convId)
    .on('postgres_changes', {
      event: '*',
      schema: 'public',
      table: 'messages',
      filter: 'conversation_id=eq.' + convId
    }, () => loadMessages(convId))
    .subscribe();

  document.getElementById('chat-send-form').addEventListener('submit', async e => {
    e.preventDefault();
    const input = document.getElementById('chat-input');
    const text = input.value.trim();
    if (!text) return;
    input.value = '';
    const { error } = await sb.from('messages')
      .insert({ conversation_id: convId, sender_id: currentUser.uid, text });
    if (error) {
      input.value = text;
      showToast('Message failed: ' + error.message, 'error');
    }
  });
}

/* New DM */
document.getElementById('new-dm-btn').addEventListener('click', () => {
  const select = document.getElementById('dm-user-select');
  const errorEl = document.getElementById('dm-error');
  const peers = new Map();
  myClasses().forEach(c => {
    [c.teacher_id, ...c.studentIds].forEach(id => {
      if (id !== currentUser.uid) { const u = findUser(id); if (u) peers.set(id, u); }
    });
  });
  const list = Array.from(peers.values());
  if (list.length === 0) {
    select.innerHTML = '';
    errorEl.textContent = 'Join a class first to find classmates to message.';
    errorEl.hidden = false;
  } else {
    errorEl.hidden = true;
    select.innerHTML = list.map(u => `<option value="${u.id}">${escapeHTML(u.name)}</option>`).join('');
  }
  openModal('modal-new-dm');
});

document.getElementById('dm-start-btn').addEventListener('click', async () => {
  const select = document.getElementById('dm-user-select');
  const errorEl = document.getElementById('dm-error');
  const otherId = select.value;
  if (!otherId) { errorEl.textContent = 'Pick someone to message.'; errorEl.hidden = false; return; }

  const convId = dmConvId(currentUser.uid, otherId);

  // The id is derived from the pair of uids, so re-opening a DM
  // that already exists is a no-op insert.
  const { error: convErr } = await sb.from('conversations')
    .insert({ id: convId, type: 'dm' });
  if (convErr) {
    errorEl.textContent = 'Failed to start chat: ' + convErr.message;
    errorEl.hidden = false;
    return;
  }

  const { error: partErr } = await sb.from('conversation_participants')
    .upsert([
      { conversation_id: convId, user_id: currentUser.uid },
      { conversation_id: convId, user_id: otherId }
    ], { onConflict: 'conversation_id,user_id' });
  if (partErr) {
    errorEl.textContent = 'Failed to start chat: ' + partErr.message;
    errorEl.hidden = false;
    return;
  }

  closeModal();
  goToSection('chats');
  openConversation(convId, { id: convId, type: 'dm', participantIds: [currentUser.uid, otherId] });
});

/* ---------------------------------------------------------
   15. ANNOUNCEMENTS
   --------------------------------------------------------- */
function renderAnnouncements() {
  const teaching = isTeacher();
  document.getElementById('create-announcement-btn').hidden = !teaching || myTaughtClasses().length === 0;

  const classIds = myClasses().map(c => c.id);
  const relevant = db.announcements.filter(a => classIds.includes(a.class_id));

  const unread = relevant.filter(a => !a.readBy.includes(currentUser.uid));
  const unreadEl = document.getElementById('announce-unread');
  unreadEl.innerHTML = unread.length ? unread.map(a => `
    <div class="announce-item" data-ann="${a.id}">
      <div class="announce-item__top"><span class="announce-item__title">${escapeHTML(a.title)}</span></div>
      <p class="announce-item__sub">${escapeHTML((findClass(a.class_id) || {}).name || '')} · ${timeAgo(a.timestamp)}</p>
      <button class="announce-item__action" data-mark-read="${a.id}">Mark as read</button>
    </div>`).join('') : `<p class="widget__empty">You're all caught up!</p>`;

  const upcoming = db.assignments
    .filter(a => classIds.includes(a.class_id) && getAssignmentStatus(a, currentUser.uid) !== 'submitted' && daysUntil(a.deadline) >= 0)
    .sort((a, b) => new Date(a.deadline) - new Date(b.deadline));
  document.getElementById('announce-deadlines').innerHTML = upcoming.length ? upcoming.map(a => {
    const status = getAssignmentStatus(a, currentUser.uid);
    return `<div class="announce-item">
      <div class="announce-item__top"><span class="announce-item__title">${escapeHTML(a.title)}</span><span class="status ${STATUS_CLASS[status]}">${STATUS_LABEL[status]}</span></div>
      <p class="announce-item__sub">${escapeHTML((findClass(a.class_id) || {}).name || '')} · Due ${formatDeadline(a.deadline)}</p>
    </div>`;
  }).join('') : `<p class="widget__empty">No upcoming deadlines.</p>`;

  const overdue = db.assignments.filter(a => classIds.includes(a.class_id) && getAssignmentStatus(a, currentUser.uid) === 'missing');
  const todoItems = [...unread.map(a => ({ key: 'ann-' + a.id, label: 'Read: ' + a.title })), ...overdue.map(a => ({ key: 'asg-' + a.id, label: 'Submit: ' + a.title }))];
  const done = getTodoDone();
  const todoEl = document.getElementById('announce-todo');
  todoEl.innerHTML = todoItems.length ? todoItems.map(t => {
    const isDone = done.includes(t.key);
    return `<div class="announce-item">
      <label class="checkbox" style="margin:0 !important;">
        <input type="checkbox" data-todo="${t.key}" ${isDone ? 'checked' : ''}>
        <span style="${isDone ? 'text-decoration:line-through;color:var(--pine-faint);' : ''}">${escapeHTML(t.label)}</span>
      </label>
    </div>`;
  }).join('') : `<p class="widget__empty">Nothing needs your attention today.</p>`;
}

document.getElementById('announce-unread').addEventListener('click', async e => {
  const btn = e.target.closest('[data-mark-read]');
  if (!btn) return;
  const { error } = await sb.from('announcement_reads')
    .upsert({ announcement_id: btn.dataset.markRead, user_id: currentUser.uid },
            { onConflict: 'announcement_id,user_id' });
  if (error) showToast('Could not mark as read: ' + error.message, 'error');
});

document.getElementById('announce-todo').addEventListener('change', e => {
  const box = e.target.closest('[data-todo]');
  if (!box) return;
  const done = getTodoDone();
  const idx = done.indexOf(box.dataset.todo);
  if (box.checked && idx === -1) done.push(box.dataset.todo);
  if (!box.checked && idx >= 0) done.splice(idx, 1);
  setTodoDone(done);
  renderAnnouncements();
});

document.getElementById('create-announcement-btn').addEventListener('click', () => {
  const select = document.getElementById('an-class');
  select.innerHTML = myTaughtClasses().map(c => `<option value="${c.id}">${escapeHTML(c.name)} (${escapeHTML(c.section)})</option>`).join('');
  document.getElementById('an-title').value = '';
  document.getElementById('an-body').value = '';
  document.getElementById('an-error').hidden = true;
  openModal('modal-announcement');
});

document.getElementById('an-submit').addEventListener('click', async () => {
  const classId = document.getElementById('an-class').value;
  const title = document.getElementById('an-title').value.trim();
  const body = document.getElementById('an-body').value.trim();
  const errorEl = document.getElementById('an-error');
  if (!title) { errorEl.textContent = 'Please give the announcement a title.'; errorEl.hidden = false; return; }
  const { error } = await sb.from('announcements')
    .insert({ class_id: classId, author_id: currentUser.uid, title, body });
  if (error) {
    errorEl.textContent = 'Failed to post: ' + error.message;
    errorEl.hidden = false;
    return;
  }
  closeModal();
  showToast('Announcement posted.');
});

/* ---------------------------------------------------------
   16. PROFILE
   --------------------------------------------------------- */
function renderProfile() {
  const u = me();
  document.getElementById('profile-name').textContent = u.name;
  document.getElementById('profile-username').textContent = '@' + u.username;
  document.getElementById('profile-role').textContent = roleLabel();
  document.getElementById('profile-classcount').textContent = myClasses().length;
  document.getElementById('profile-submitcount').textContent = db.submissions.filter(s => s.student_id === currentUser.uid).length;
  setAvatar(document.getElementById('profile-avatar'), u);
  document.querySelectorAll('#role-switch-2 .role-switch__opt').forEach(btn => {
    btn.classList.toggle('is-active', btn.dataset.role === activeView());
  });
}

/* ---------------------------------------------------------
   16b. ASKING FOR A ROLE ONLY WHEN THERE IS NONE
   ---------------------------------------------------------
   One rule, and everything else follows from it:

     an account that already has a stored role is never asked again.

   There are exactly two ways to end up without one:

   - "Continue with Google". OAuth only ever hands back a name, an
     email and a photo, so there is no role to read and no form to
     carry one. Those accounts get asked once, right here, after the
     redirect lands.

   - The create-account form, which sends the role as sign-up
     metadata. The trigger stores it before the browser ever gets a
     session, so those accounts arrive here already answered.

   A previous version remembered the choice in localStorage to spare
   Google users this prompt. That was the wrong call: localStorage
   does not survive on a different browser or a cleared cache, and a
   stale value left over from a previous visit made the app call
   set_my_role() on an account that had already answered, which the
   database correctly refused. One source of truth · profiles.role ·
   is both simpler and harder to get wrong. */

/* set_my_role() is one-shot by design, so a second call is a normal
   thing to hit rather than a failure. The database is the authority on
   which role it holds, so that answer is taken and re-read instead of
   being shown as an error. */
function isAlreadyChosen(error) {
  return /already chose/i.test((error && error.message) || '');
}

async function writeRole(choice) {
   const { error } = await sb.rpc('set_my_role', { p_role: choice });
   if (error && !isAlreadyChosen(error)) throw error;
   // Forget the answer we were holding, then let the database be re-read:
   // the row it returns may hold a different role than the one requested.
   roleCheck = { uid: null, value: undefined };
   await loadCollections(['users']);
   const stored = await readMyRole();
   if (roleWatchdogTimer) { clearTimeout(roleWatchdogTimer); roleWatchdogTimer = null; }
   return isAlreadyChosen(error) ? 'already' : (stored === choice ? 'saved' : 'already');
}

// The role decision is made from one field, read straight from Postgres
// instead of inferred from the profiles mirror. The mirror is a cache: it
// can be empty, mid-refresh, or still hold the previous sign-in, and that
// gap is where every version of "the prompt never showed up" came from.
//   null      -> the database knows this account has no role, ask
//   'teacher' -> answered, never ask again
//   undefined -> unknown right now, so say nothing and let the watchdog retry
let roleCheck = { uid: null, value: undefined };

async function readMyRole() {
   const uid = currentUser && currentUser.uid;
   if (!uid) return null;
   if (roleCheck.uid === uid) return roleCheck.value;
   const { data, error } = await sb.from('profiles').select('role').eq('id', uid).maybeSingle();
   if (error) {
      console.error('SociaLearn: could not read role', error);
      roleCheck = { uid: null, value: undefined };
      return undefined;
   }
   roleCheck = { uid, value: data ? (data.role || null) : null };
   return roleCheck.value;
}

// A prompt that silently fails to appear is worse than one that shows up a
// little late: the account is stuck with no role and no way to choose one.
// So the prompt gets a few more chances for a bounded while, and quits the
// moment a role is stored or the tries run out. Nothing here can nag.
let roleWatchdogTries = 0;
let roleWatchdogTimer = null;
function startRoleWatchdog() {
   if (roleWatchdogTimer) { clearTimeout(roleWatchdogTimer); roleWatchdogTimer = null; }
   roleWatchdogTries = 0;
   const tick = async () => {
      roleWatchdogTimer = null;
      if (!sbEnabled || !currentUser) return;
      const role = await readMyRole();
      if (role === undefined) {
         // Still cannot tell. Only an unreadable answer earns more tries, so
         // a stored role stops everything immediately.
         if (roleWatchdogTries++ < 6) roleWatchdogTimer = setTimeout(tick, 1500);
         return;
      }
      if (role !== null) return;
      settleRole();
      if (roleWatchdogTries++ < 6) roleWatchdogTimer = setTimeout(tick, 1500);
   };
   roleWatchdogTimer = setTimeout(tick, 600);
}

async function settleRole() {
   if (!sbEnabled || !currentUser) return;
   let role;
   try { role = await readMyRole(); } catch (e) { return; }
   if (role === undefined) return;                 // no answer yet, stay quiet
   if (role !== null) {                            // answered, never ask again
      if (roleModalIsOpen()) closeModal();
      return;
   }
   if (roleModalIsOpen()) return;
   if (!document.getElementById('modal-backdrop').hidden) return;
   document.getElementById('role-error').hidden = true;
   openModal('modal-role');
}

document.getElementById('role-submit').addEventListener('click', async () => {
  const btn = document.getElementById('role-submit');
  const errorEl = document.getElementById('role-error');
  errorEl.hidden = true;
  btn.disabled = true;
  try {
    const result = await writeRole(modalRoleChoice);
    closeModal();
    const actual = myRole() || modalRoleChoice;
    showToast(result === 'already'
      ? `You are already set as a ${actual}.`
      : `You are all set as a ${actual}.`);
  } catch (e) {
    errorEl.textContent = e.message || 'Could not save your role.';
    errorEl.hidden = false;
  } finally {
    btn.disabled = false;
  }
});

/* ---------------------------------------------------------
   17. GLOBAL HEADER / BADGES
   --------------------------------------------------------- */
function renderChrome() {
  const u = me();
  setAvatar(document.getElementById('avatar-initials'), u);
  setAvatar(document.getElementById('composer-avatar'), u);
  document.getElementById('sidenav-name').textContent = u.name;
  document.getElementById('sidenav-role').textContent = roleLabel();

  const classIds = myClasses().map(c => c.id);
  const unreadCount = db.announcements.filter(a => classIds.includes(a.class_id) && !a.readBy.includes(currentUser.uid)).length;
  const announceBadge = document.getElementById('announce-badge');
  announceBadge.hidden = unreadCount === 0;
  announceBadge.textContent = unreadCount;
  document.getElementById('notif-dot').hidden = unreadCount === 0;

  document.querySelectorAll('.role-switch__opt').forEach(btn => {
    // A student has nothing to switch to, so the option is not offered
    // at all rather than shown and made to do nothing.
    btn.hidden = btn.dataset.role === 'teacher' && !isTeacher();
    btn.classList.toggle('is-active', btn.dataset.role === activeView());
  });
}

/* ---------------------------------------------------------
   18. SEARCH (light filter on Feed + Classroom)
   --------------------------------------------------------- */
document.getElementById('global-search').addEventListener('input', e => {
  const q = e.target.value.trim().toLowerCase();
  document.querySelectorAll('.post').forEach(card => {
    card.style.display = !q || card.textContent.toLowerCase().includes(q) ? '' : 'none';
  });
  document.querySelectorAll('.class-card').forEach(card => {
    card.style.display = !q || card.textContent.toLowerCase().includes(q) ? '' : 'none';
  });
});

/* ---------------------------------------------------------
   19. RENDER ALL
   --------------------------------------------------------- */
function renderAll() {
  if (!currentUser) return;
  // Each panel is isolated on purpose. settleRole() is the last thing that
  // runs here, so a single renderer throwing on an unexpected shape · a
  // classless account, a fresh profile · used to skip it entirely and leave
  // the account staring at a half-drawn app with no role prompt at all.
  // One broken panel must never be able to swallow the prompt.
  ['renderChrome', 'renderFeed', 'renderClassroom', 'renderAssignments',
   'renderChats', 'renderAnnouncements', 'renderProfile'].forEach(fn => {
      try {
         window[fn]();
      } catch (e) {
         console.error('SociaLearn: ' + fn + ' failed to render', e);
      }
   });
  try {
      settleRole();
  } catch (e) {
      console.error('SociaLearn: role prompt failed', e);
  }
}

setAuthMode('signin');
