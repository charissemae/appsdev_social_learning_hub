-- Backfill: give every existing post made by a class teacher its own
-- announcement, so older teacher posts show up on the Announcements page
-- exactly like new ones (new posts are mirrored automatically by script.js).
--
-- Safe to run more than once: a post is skipped if an announcement with the
-- same class, author and body already exists. Run this in the Supabase
-- SQL editor (as postgres, which bypasses RLS).

insert into public.announcements (class_id, author_id, title, body, created_at)
select p.class_id,
       p.author_id,
       coalesce(nullif(left(btrim(split_part(p.content, E'\n', 1)), 80), ''),
                left(btrim(p.content), 80)) as title,
       p.content as body,
       p.created_at
from public.posts p
join public.classes c on c.id = p.class_id and c.teacher_id = p.author_id
where not exists (
  select 1
  from public.announcements a
  where a.class_id = p.class_id
    and a.author_id = p.author_id
    and a.body = p.content
);
