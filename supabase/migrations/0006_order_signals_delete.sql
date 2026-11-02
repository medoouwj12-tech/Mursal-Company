-- Keep couriers' lists accurate when an order row is deleted (admin cleanup).
create or replace function public.signal_order_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    insert into public.order_signals(order_id, kind, courier_id) values (old.id, 'removed', null);
    return old;
  end if;
  if tg_op = 'UPDATE' and old.status is distinct from new.status then
    if old.status = 'pending' and new.status = 'accepted' then
      insert into public.order_signals(order_id, kind, courier_id) values (new.id, 'claimed', new.courier_id);
    elsif new.status = 'pending' then
      insert into public.order_signals(order_id, kind, courier_id) values (new.id, 'released', null);
    elsif new.status in ('cancelled', 'delivered') then
      insert into public.order_signals(order_id, kind, courier_id) values (new.id, 'removed', null);
    end if;
    if random() < 0.02 then
      delete from public.order_signals where created_at < now() - interval '2 days';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_signal_change on public.orders;
create trigger orders_signal_change
after update or delete on public.orders
for each row execute function public.signal_order_change();

revoke all on function public.signal_order_change() from public, anon, authenticated;
