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
