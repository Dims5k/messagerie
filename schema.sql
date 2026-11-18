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
alter publication supabase_realtime add table public.room_members;

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
-- =====================================================================
-- MISE À JOUR : SONDAGES (à lancer une seule fois)
-- Supabase > SQL Editor > New query > coller tout > Run
-- =====================================================================

create table if not exists public.polls (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  question text not null check (char_length(question) between 1 and 200),
  closed boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.polls(id) on delete cascade,
  label text not null check (char_length(label) between 1 and 100),
  position int not null default 0
);

create table if not exists public.poll_votes (
  poll_id uuid not null references public.polls(id) on delete cascade,
  option_id uuid not null references public.poll_options(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (poll_id, user_id)          -- un seul vote par personne et par sondage
);

-- Peut-on voir ce sondage ? (membre du salon ou admin)
create or replace function public.can_see_poll(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from polls where id = p and (is_member(room_id) or is_admin()));
$$;

alter table public.polls        enable row level security;
alter table public.poll_options enable row level security;
alter table public.poll_votes   enable row level security;

drop policy if exists "voir les sondages" on public.polls;
create policy "voir les sondages" on public.polls for select to authenticated
  using (is_member(room_id) or is_admin());
drop policy if exists "voir les options" on public.poll_options;
create policy "voir les options" on public.poll_options for select to authenticated
  using (can_see_poll(poll_id));
drop policy if exists "voir les votes" on public.poll_votes;
create policy "voir les votes" on public.poll_votes for select to authenticated
  using (can_see_poll(poll_id));
drop policy if exists "supprimer un sondage" on public.polls;
create policy "supprimer un sondage" on public.polls for delete to authenticated
  using (user_id = auth.uid() or is_admin()
     or exists (select 1 from rooms where id = room_id and owner = auth.uid()));
-- Création / vote / clôture passent uniquement par les fonctions ci-dessous

-- Créer un sondage (2 à 10 propositions)
create or replace function public.create_poll(r uuid, q text, opts text[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare pid uuid; o text; i int := 0; n int;
begin
  if not is_active() or not is_member(r) then raise exception 'Non autorisé'; end if;
  if not (is_admin() or exists (select 1 from rooms where id = r and owner = auth.uid())) then
    raise exception 'Seuls l''admin et le propriétaire du salon peuvent créer un sondage';
  end if;
  q := trim(coalesce(q, ''));
  if q = '' then raise exception 'La question est vide'; end if;
  select count(*) into n from unnest(opts) x where trim(x) <> '';
  if n < 2 or n > 10 then raise exception 'Il faut entre 2 et 10 propositions'; end if;
  insert into polls (room_id, user_id, question) values (r, auth.uid(), left(q, 200)) returning id into pid;
  foreach o in array opts loop
    if trim(o) <> '' then
      insert into poll_options (poll_id, label, position) values (pid, left(trim(o), 100), i);
      i := i + 1;
    end if;
  end loop;
  return pid;
end $$;

-- Voter (re-cliquer sur son choix = retirer son vote, cliquer ailleurs = changer)
create or replace function public.vote_poll(p uuid, o uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r uuid; cl boolean; cur uuid;
begin
  select room_id, closed into r, cl from polls where id = p;
  if r is null or not is_member(r) or not is_active() then raise exception 'Non autorisé'; end if;
  if cl then raise exception 'Ce sondage est terminé'; end if;
  if not exists (select 1 from poll_options where id = o and poll_id = p) then raise exception 'Option invalide'; end if;
  select option_id into cur from poll_votes where poll_id = p and user_id = auth.uid();
  delete from poll_votes where poll_id = p and user_id = auth.uid();
  if cur is distinct from o then
    insert into poll_votes (poll_id, option_id, user_id) values (p, o, auth.uid());
  end if;
end $$;

-- Clore un sondage (créateur, propriétaire du salon ou admin)
create or replace function public.close_poll(p uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update polls set closed = true
  where id = p and (user_id = auth.uid() or is_admin()
        or exists (select 1 from rooms where id = polls.room_id and owner = auth.uid()));
  if not found then raise exception 'Non autorisé'; end if;
end $$;

revoke execute on function public.create_poll(uuid, text, text[]) from public, anon;
revoke execute on function public.vote_poll(uuid, uuid) from public, anon;
revoke execute on function public.close_poll(uuid) from public, anon;
grant execute on function public.create_poll(uuid, text, text[]) to authenticated;
grant execute on function public.vote_poll(uuid, uuid) to authenticated;
grant execute on function public.close_poll(uuid) to authenticated;

-- Temps réel
do $$ begin
  begin alter publication supabase_realtime add table public.polls; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.poll_votes; exception when duplicate_object then null; end;
end $$;
-- =====================================================================
-- MISE À JOUR : NOTIFICATIONS PUSH (à lancer une seule fois, relançable sans risque)
-- Supabase > SQL Editor > New query > coller tout > Run
-- =====================================================================

-- Abonnements push (un par appareil)
create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;
-- Aucun accès direct : tout passe par les fonctions ci-dessous

create or replace function public.save_push_sub(ep text, k_p256dh text, k_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into push_subs (endpoint, user_id, p256dh, auth) values (ep, auth.uid(), k_p256dh, k_auth)
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function public.delete_push_sub(ep text) returns void
language sql security definer set search_path = public as $$
  delete from push_subs where endpoint = ep and user_id = auth.uid();
$$;

revoke execute on function public.save_push_sub(text, text, text) from public, anon;
revoke execute on function public.delete_push_sub(text) from public, anon;
grant execute on function public.save_push_sub(text, text, text) to authenticated;
grant execute on function public.delete_push_sub(text) to authenticated;

-- Salons en sourdine
create table if not exists public.room_mutes (
  room_id uuid references public.rooms(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  primary key (room_id, user_id)
);
alter table public.room_mutes enable row level security;
drop policy if exists "mes sourdines" on public.room_mutes;
create policy "mes sourdines" on public.room_mutes for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Chaque nouveau message déclenche la fonction « notify »
create extension if not exists pg_net;
alter table public.messages add column if not exists notified boolean not null default false;

create or replace function public.notify_new_message() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://yliagjukekpislgrcdrs.supabase.co/functions/v1/notify',
    body := jsonb_build_object('id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  return new;
end $$;

drop trigger if exists messages_notify on public.messages;
create trigger messages_notify after insert on public.messages
for each row execute function public.notify_new_message();
