-- Realtime needs the previous row image to evaluate RLS on UPDATE/DELETE events.
-- Without a full replica identity Supabase only ships the primary key, so RLS-protected
-- UPDATE events (courier claim, call-center edit) never reach subscribed clients.
alter table public.orders replica identity full;
