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

create policy "voir les sondages" on public.polls for select to authenticated
  using (is_member(room_id) or is_admin());
create policy "voir les options" on public.poll_options for select to authenticated
  using (can_see_poll(poll_id));
create policy "voir les votes" on public.poll_votes for select to authenticated
  using (can_see_poll(poll_id));
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
alter publication supabase_realtime add table public.polls;
alter publication supabase_realtime add table public.poll_votes;
