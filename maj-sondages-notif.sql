-- =====================================================================
-- MISE À JOUR : message + notification quand un sondage est lancé
-- Supabase > SQL Editor > New query > coller tout > Run
-- =====================================================================

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
  -- Message automatique dans le salon (déclenche aussi la notification push)
  insert into messages (room_id, user_id, content) values (r, auth.uid(), '📊 Nouveau sondage : ' || left(q, 200));
  return pid;
end $$;
