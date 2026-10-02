/* =========================================================
   SUPABASE CONFIG — fill this in with YOUR project's values
   =========================================================

   1. Go to https://supabase.com and create a free project.
   2. Wait for the database to finish provisioning (~2 min).
   3. Open supabase-schema.sql in this folder, paste it into
      Supabase dashboard > SQL Editor > New query, and Run it.
      This creates every table, the row-level-security rules,
      and turns on realtime.
   4. Project Settings > API. Copy two values into the object
      below:
        - "Project URL"                  -> supabaseUrl
        - "Project URL" > anon "public"  -> supabaseAnonKey

      Both are safe to ship in a static site — every read/write
      is gated by the RLS policies in the schema, and the anon
      key only grants "logged in as nobody". Never put the
      `service_role` key in here; it bypasses RLS entirely.

   5. Authentication > Providers:
        - Email: turn ON, and turn OFF "Confirm email" for
          easy testing (otherwise new accounts can't sign in
          until they click the emailed link).
        - Google: turn ON, add a support email, and add your
          redirect URL (see the note in README.md — Google
          sign-in needs a real http(s) origin, it will not work
          from a file:// path).

   Save this file, then open the app.
   ========================================================= */

const supabaseConfig = {
  supabaseUrl: "https://mvxisjjmpbixlbyvcfvx.supabase.co",
  supabaseAnonKey: "sb_publishable_GCxrRmjawwZF23NPbRJBtg_pdlAFulA",

  // Where Google sign-in sends you back to. Leave as "" to use
  // whatever address you're viewing the app from, but it MUST
  // exactly match one of the Redirect URLs listed in
  // Supabase > Authentication > URL Configuration, or Google
  // sign-in will be rejected. Localhost example: "http://localhost:3000"
  redirectUrl: ""
};
