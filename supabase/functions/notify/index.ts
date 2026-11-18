// Fonction Supabase « notify » : envoie une notification push aux membres d'un salon
// quand un message est posté. Appelée automatiquement par la base (voir maj-notifications.sql).
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2';

const VAPID_PUBLIC_KEY = 'BHQKyCe02F1NKPXMDFPi5mY3FvYyUqLwJ-ciFX1ovzWEpvJXlJPHHMKrwwYs_Fud_t5_FClOxMvrNsg0jzjTa1g';
const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY')!;
webpush.setVapidDetails('https://dims5k.github.io', VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

Deno.serve(async (req) => {
  const { id } = await req.json().catch(() => ({}));
  if (!id) return new Response('id manquant', { status: 400 });

  // On « réserve » le message : une seule notif par message, impossible de spammer
  const { data: m } = await sb.from('messages').update({ notified: true })
    .eq('id', id).eq('notified', false)
    .select('id, room_id, user_id, content, image_path, created_at').maybeSingle();
  if (!m) return new Response('déjà traité');
  if (Date.now() - new Date(m.created_at).getTime() > 120_000) return new Response('trop ancien');

  const [{ data: room }, { data: author }, { data: members }, { data: mutes }] = await Promise.all([
    sb.from('rooms').select('name').eq('id', m.room_id).single(),
    sb.from('profiles').select('username, is_admin').eq('id', m.user_id).single(),
    sb.from('room_members').select('user_id').eq('room_id', m.room_id),
    sb.from('room_mutes').select('user_id').eq('room_id', m.room_id),
  ]);
  const muted = new Set((mutes || []).map(x => x.user_id));
  const targets = (members || []).map(x => x.user_id).filter(u => u !== m.user_id && !muted.has(u));
  if (!targets.length) return new Response('personne à notifier');

  const { data: subs } = await sb.from('push_subs').select('endpoint, p256dh, auth').in('user_id', targets);
  const who = (author?.username || '?') + (author?.is_admin ? ' (admin)' : '');
  const text = m.content ? m.content : '📷 Photo';
  const payload = JSON.stringify({
    title: room?.name || 'Messagerie',
    body: (who + ' : ' + text).slice(0, 200),
    room: m.room_id,
  });

  let sent = 0;
  await Promise.all((subs || []).map(async s => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload, { TTL: 86400, urgency: 'high' });
      sent++;
    } catch (e) {
      // Abonnement mort (appli désinstallée, notifs coupées…) → on le supprime
      if (e?.statusCode === 404 || e?.statusCode === 410) await sb.from('push_subs').delete().eq('endpoint', s.endpoint);
    }
  }));
  return new Response('envoyé : ' + sent);
});
