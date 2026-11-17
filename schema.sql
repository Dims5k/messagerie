-- =====================================================================
-- MESSAGERIE — schéma Supabase
-- À coller en entier dans Supabase > SQL Editor > New query > Run
-- =====================================================================

-- ---------- Tables ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (char_length(username) between 3 and 20),
  is_admin boolean not null default false,
  banned boolean not null default false,
  accepted_rules_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  invite_code text unique not null default upper(substr(md5(random()::text), 1, 8)),
  owner uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.room_members (
  room_id uuid references public.rooms(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create table public.messages (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  content text check (char_length(content) <= 2000),
  image_path text,
  created_at timestamptz not null default now(),
  check (content is not null or image_path is not null)
);
create index on public.messages (room_id, created_at desc);

create table public.reports (
  id bigint generated always as identity primary key,
  message_id bigint references public.messages(id) on delete set null,
  reported_user uuid references public.profiles(id) on delete cascade,
  reporter uuid not null references public.profiles(id) on delete cascade,
  reason text check (char_length(reason) <= 300),
  snapshot text,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---------- Fonctions utilitaires ----------
create or replace function public.is_member(r uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from room_members where room_id = r and user_id = auth.uid());
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$$;

create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and not banned);
$$;

-- Le créateur d'un salon en devient membre automatiquement
create or replace function public.add_owner_as_member() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into room_members (room_id, user_id) values (new.id, new.owner);
  return new;
end $$;
create trigger rooms_add_owner after insert on public.rooms
for each row execute function public.add_owner_as_member();

-- Rejoindre un salon avec son code d'invitation
create or replace function public.join_room(code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare r uuid;
begin
  if not is_active() then raise exception 'Compte inactif ou banni'; end if;
  select id into r from rooms where invite_code = upper(trim(code));
  if r is null then raise exception 'Code invalide'; end if;
  insert into room_members (room_id, user_id) values (r, auth.uid()) on conflict do nothing;
  return r;
end $$;

-- Nouveau code d'invitation (propriétaire du salon uniquement)
create or replace function public.reset_invite(r uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c text := upper(substr(md5(random()::text), 1, 8));
begin
  update rooms set invite_code = c where id = r and owner = auth.uid();
  if not found then raise exception 'Non autorisé'; end if;
  return c;
end $$;

-- Bannir / débannir (admin uniquement)
create or replace function public.set_ban(target uuid, value boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Non autorisé'; end if;
  update profiles set banned = value where id = target;
end $$;

-- ---------- Sécurité (RLS) ----------
alter table public.profiles     enable row level security;
alter table public.rooms        enable row level security;
alter table public.room_members enable row level security;
alter table public.messages     enable row level security;
alter table public.reports      enable row level security;

create policy "profils visibles" on public.profiles for select to authenticated using (true);
create policy "créer son profil" on public.profiles for insert to authenticated
  with check (id = auth.uid() and is_admin = false and banned = false);
create policy "modifier son profil" on public.profiles for update to authenticated
  using (id = auth.uid());
-- on ne peut modifier que son pseudo (pas is_admin / banned)
revoke update on public.profiles from authenticated;
grant update (username) on public.profiles to authenticated;

create policy "voir ses salons" on public.rooms for select to authenticated using (owner = auth.uid() or is_member(id));
create policy "créer un salon" on public.rooms for insert to authenticated
  with check (owner = auth.uid() and is_active());
create policy "supprimer son salon" on public.rooms for delete to authenticated
  using (owner = auth.uid() or is_admin());

create policy "voir les membres" on public.room_members for select to authenticated using (is_member(room_id));
create policy "quitter un salon" on public.room_members for delete to authenticated
  using (user_id = auth.uid()
     or exists (select 1 from rooms where id = room_id and owner = auth.uid()));

create policy "lire les messages" on public.messages for select to authenticated
  using (is_member(room_id) or is_admin());
create policy "écrire" on public.messages for insert to authenticated
  with check (user_id = auth.uid() and is_member(room_id) and is_active());
create policy "supprimer" on public.messages for delete to authenticated
  using (user_id = auth.uid() or is_admin()
     or exists (select 1 from rooms where id = room_id and owner = auth.uid()));

create policy "signaler" on public.reports for insert to authenticated with check (reporter = auth.uid());
create policy "admin lit les signalements" on public.reports for select to authenticated using (is_admin());
create policy "admin traite les signalements" on public.reports for update to authenticated using (is_admin());

-- ---------- Photos (stockage privé) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy "envoyer une photo" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and is_active()
              and is_member(((storage.foldername(name))[1])::uuid));
create policy "voir les photos" on storage.objects for select to authenticated
  using (bucket_id = 'photos'
         and (is_member(((storage.foldername(name))[1])::uuid) or is_admin()));
create policy "supprimer ses photos" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (owner = auth.uid() or is_admin()));

-- ---------- Temps réel ----------
alter publication supabase_realtime add table public.messages;

-- =====================================================================
-- APRÈS ton inscription dans l'app, deviens admin avec :
--   update public.profiles set is_admin = true where username = 'TON_PSEUDO';
-- =====================================================================

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
