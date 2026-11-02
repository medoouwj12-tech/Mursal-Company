-- Allow call center to edit their own orders after a courier has accepted them.
-- The order stays with the same courier; only that courier (plus admin and the creator) sees the update.
drop policy if exists orders_call_center_update on public.orders;
create policy orders_call_center_update on public.orders for update to authenticated
using (
  created_by = auth.uid()
  and public.current_role() = 'call_center'
  and status in ('pending', 'accepted')
)
with check (
  created_by = auth.uid()
  and public.current_role() = 'call_center'
  and status in ('pending', 'accepted')
);

create or replace function public.guard_call_center_order_update()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if public.current_role() = 'call_center' then
    if new.created_by is distinct from old.created_by then
      raise exception 'غير مسموح بتغيير منشئ الطلب' using errcode = '42501';
    end if;
    if new.courier_id is distinct from old.courier_id then
      raise exception 'غير مسموح بتغيير المندوب من شاشة الكول سنتر' using errcode = '42501';
    end if;
    if old.status = 'accepted' then
      if new.status <> 'accepted' then
        raise exception 'الطلب مستلم بالفعل ولا يمكن تغيير حالته من شاشة الكول سنتر' using errcode = '42501';
      end if;
      if new.accepted_at is distinct from old.accepted_at then
        raise exception 'غير مسموح بتغيير وقت استلام الطلب' using errcode = '42501';
      end if;
    elsif old.status = 'pending' then
      if new.status not in ('pending', 'cancelled') then
        raise exception 'حالة الطلب غير مسموحة' using errcode = '42501';
      end if;
    else
      raise exception 'لا يمكن تعديل طلب في حالته الحالية' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists orders_guard_call_center_update on public.orders;
create trigger orders_guard_call_center_update
before update on public.orders
for each row execute function public.guard_call_center_order_update();

revoke all on function public.guard_call_center_order_update() from public, anon, authenticated;

-- Make sure Realtime publishes the tables the UI listens to.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table public.orders;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_events'
  ) then
    alter publication supabase_realtime add table public.order_events;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;
