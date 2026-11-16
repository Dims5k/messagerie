-- Mise à jour : liste des membres pour l'admin (à lancer une seule fois)
create or replace function public.admin_list_users()
returns table (
  id uuid, username text, email text, created_at timestamptz,
  email_confirmed_at timestamptz, last_sign_in_at timestamptz,
  banned boolean, is_admin boolean, rooms bigint, messages bigint
)
language sql stable security definer set search_path = public, auth as $$
  select u.id, p.username, u.email::text, u.created_at,
         u.email_confirmed_at, u.last_sign_in_at,
         coalesce(p.banned, false), coalesce(p.is_admin, false),
         (select count(*) from public.room_members m where m.user_id = u.id),
         (select count(*) from public.messages g where g.user_id = u.id)
  from auth.users u
  left join public.profiles p on p.id = u.id
  where public.is_admin()
  order by u.created_at desc;
$$;
revoke execute on function public.admin_list_users() from public, anon;
grant execute on function public.admin_list_users() to authenticated;
