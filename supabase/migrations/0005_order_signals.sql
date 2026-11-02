-- Realtime does not emit an event when a row stops matching a subscriber's RLS policy.
-- So when a courier claims a pending order, every *other* courier keeps the stale card
-- until they refresh. This table is a tiny broadcast log: a trigger writes one signal per
-- status change and every signed-in user can subscribe to it. Clients then re-read the
-- single order (RLS decides what they may see) and drop or update the card.
create table if not exists public.order_signals (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  kind text not null,
  courier_id uuid,
  created_at timestamptz not null default now()
);

create index if not exists order_signals_created_at_idx on public.order_signals(created_at desc);
create index if not exists order_signals_order_id_idx on public.order_signals(order_id);

alter table public.order_signals enable row level security;

drop policy if exists order_signals_read on public.order_signals;
create policy order_signals_read on public.order_signals for select to authenticated using (true);

revoke all on public.order_signals from anon;
grant select on public.order_signals to authenticated;

create or replace function public.signal_order_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and old.status is distinct from new.status then
    if old.status = 'pending' and new.status = 'accepted' then
      insert into public.order_signals(order_id, kind, courier_id) values (new.id, 'claimed', new.courier_id);
    elsif new.status = 'pending' then
      insert into public.order_signals(order_id, kind, courier_id) values (new.id, 'released', null);
    elsif new.status in ('cancelled', 'delivered') then
      insert into public.order_signals(order_id, kind, courier_id) values (new.id, 'removed', null);
    end if;
    -- cheap retention: only occasionally prune old signals
    if random() < 0.02 then
      delete from public.order_signals where created_at < now() - interval '2 days';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_signal_change on public.orders;
create trigger orders_signal_change
after update on public.orders
for each row execute function public.signal_order_change();

revoke all on function public.signal_order_change() from public, anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_signals'
  ) then
    alter publication supabase_realtime add table public.order_signals;
  end if;
end $$;
