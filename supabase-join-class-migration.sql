-- ============================================================================
-- supabase-join-class-migration.sql
--
-- Replaces join_class(), which could not run.
--
-- SYMPTOM
--   A student entering a valid class code got
--     {"code":"42702","message":"column reference \"id\" is ambiguous"}
--   and was never enrolled. Teachers were unaffected: the teacher guard sits
--   above the broken statement and raised first.
--
-- THE ACTUAL CAUSE  (three bugs, stacked — fixing one still left it broken)
--
--   1. `select * into v_class from classes`
--      `*` expands to unqualified column names, and `id`/`name`/`section`/
--      `teacher_id` are OUT parameters of this function. Ambiguous.
--
--   2. `insert into conversations (id, type, class_id, name)`
--      This is the one that survived the first fix. plpgsql resolves the
--      target-list names too, so `id` and `name` again matched both an OUT
--      parameter and a real column of conversations. Verified by narrowing it
--      down: a code that matches nothing returns 'no class with that code'
--      (so the class lookup is fine), and only a real code reaches the insert
--      and fails.
--
--   3. There is no way to patch this from inside the function while keeping the
--      signature, because the OUT parameter names are also the JSON keys the
--      app reads back: script.js uses data[0].name and data[0].already_joined.
--      Renaming them would rename the keys.
--
-- THE FIX
--   Return SETOF jsonb and keep every value in a local variable whose name
--   matches no column anywhere. With no OUT parameters in scope there is
--   nothing left for a column name to be ambiguous *with*, so `id` and `name`
--   in that INSERT can only ever mean the columns.
--
--   The client is unaffected: jsonb_build_object() puts the same keys back, so
--   data[0].name and data[0].already_joined read exactly as before.
--
--   This needs DROP FUNCTION, not CREATE OR REPLACE, because PostgreSQL refuses
--   to change an existing function's return type. Everything runs in one
--   transaction, so a failed paste leaves the old function in place rather than
--   no function at all.
--
-- SAFE TO RE-RUN
--   Drops and rebuilds one function. No table is touched, no policy is dropped.
-- ============================================================================

begin;

drop function if exists public.join_class(text);

create function public.join_class(p_code text)
returns setof jsonb
language plpgsql security definer set search_path = public as $$
declare
  -- Every name here is deliberately prefixed. None of them matches a column in
  -- classes, class_members, conversations or conversation_participants, which
  -- is what makes the INSERT statements below unambiguous.
  v_id         uuid;
  v_name       text;
  v_section    text;
  v_teacher_id uuid;
  v_already    boolean;
  v_conv_id    text;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  -- Google Classroom does not let a teacher join a class with a code; a teacher
  -- runs the class instead.
  if public.is_teacher() then
    raise exception 'teachers do not join classes with a code -- create a class instead'
      using errcode = '42501';
  end if;

  -- Every column qualified. `select *` here is what made `id` ambiguous in the
  -- first place, because the OUT parameters shadowed the table's columns.
  select c.id, c.name, c.section, c.teacher_id
    into v_id, v_name, v_section, v_teacher_id
    from classes c
   where upper(c.code) = upper(trim(p_code));

  if v_id is null then
    raise exception 'no class with that code' using errcode = 'P0002';
  end if;

  select exists (select 1 from class_members
                 where class_id = v_id and student_id = auth.uid())
    into v_already;

  if not v_already then
    insert into class_members (class_id, student_id)
    values (v_id, auth.uid())
    on conflict do nothing;
  end if;

  v_conv_id := 'group-' || v_id;

  -- The statement that used to fail. `id` and `name` are plain columns now:
  -- there is no OUT parameter for either to collide with.
  insert into conversations (id, type, class_id, name)
  values (v_conv_id, 'group', v_id, v_name || ' - ' || v_section)
  on conflict do nothing;

  insert into conversation_participants (conversation_id, user_id)
  values (v_conv_id, v_teacher_id), (v_conv_id, auth.uid())
  on conflict do nothing;

  return query
    select jsonb_build_object(
      'id',             v_id,
      'name',           v_name,
      'section',        v_section,
      'teacher_id',     v_teacher_id,
      'already_joined', v_already);
end;
$$;

revoke execute on function public.join_class(text) from public, anon;
grant execute on function public.join_class(text) to authenticated;

commit;

-- ============================================================================
-- Verify, in a SEPARATE query after the run above, signed in as a student:
--
--   select * from public.join_class('PUT-A-REAL-CODE-HERE');
--
-- Expect the class as {"id":...,"name":...,"section":...,"teacher_id":...,
-- "already_joined":false}. Not a 42702.
--
-- One more thing, found while fixing this, and it has nothing to do with the
-- RPC. Creating a class must NOT be done with .insert(...).select(...) from the
-- browser. That sends `Prefer: return=representation`, so PostgREST emits
-- INSERT ... RETURNING, and Postgres applies the table's SELECT policy to the
-- rows RETURNING hands back. That policy is `using (is_class_member(id))`, and
-- is_class_member() is STABLE, so it reads the snapshot taken when the statement
-- began — which does not contain the class that same statement is inserting. It
-- answers false and Postgres raises
--   new row violates row-level security policy for table "classes"
-- and rolls the insert back. Every teacher, every time. Insert plainly, then
-- read the id back off the UNIQUE code column in a second request. script.js
-- already does this.
-- ============================================================================