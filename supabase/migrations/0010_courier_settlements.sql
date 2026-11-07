-- Persist courier balance closures and make settlement atomic.
create table public.courier_settlements (
  id uuid primary key default gen_random_uuid(),
  courier_id uuid not null references public.profiles(id),
  branch text not null check (branch in ('bagour', 'ashmoun')),
  orders_count integer not null check (orders_count > 0),
  gross_delivery_fees numeric(12,2) not null check (gross_delivery_fees >= 0),
  commission_percent numeric(5,2) not null check (commission_percent between 0 and 100),
  office_share numeric(12,2) not null check (office_share >= 0),
  courier_net numeric(12,2) not null check (courier_net >= 0),
  settled_by uuid not null references public.profiles(id),
  settled_at timestamptz not null default now()
);

create index courier_settlements_courier_date_idx
  on public.courier_settlements (courier_id, settled_at desc);
create index courier_settlements_date_idx on public.courier_settlements (settled_at desc);

alter table public.orders
  add column settlement_id uuid references public.courier_settlements(id);
create index orders_unsettled_delivered_idx
  on public.orders (courier_id, delivered_at)
  where status = 'delivered' and settlement_id is null;

alter table public.courier_settlements enable row level security;
create policy courier_settlements_read on public.courier_settlements
  for select to authenticated
  using (public.is_admin() or courier_id = auth.uid());
grant select on public.courier_settlements to authenticated;
grant all on public.courier_settlements to service_role;

create or replace function public.get_courier_balance()
returns table (
  orders_count bigint,
  gross_delivery_fees numeric,
  commission_percent numeric,
  office_share numeric,
  courier_net numeric
)
language plpgsql stable security definer set search_path = public
as $$
declare
  v_percent numeric(5,2);
begin
  if auth.uid() is null or public.current_role() <> 'courier' then
    raise exception 'عرض الرصيد متاح للمندوب فقط' using errcode = '42501';
  end if;

  select least(100::numeric, greatest(0::numeric,
      coalesce((s.value #>> '{}')::numeric, 0)))::numeric(5,2)
    into v_percent
    from public.app_settings s where s.key = 'courier_commission_percent';
  v_percent := coalesce(v_percent, 0);

  return query
    with balance as (
      select count(*)::bigint as orders_count,
             coalesce(sum(o.delivery_fee), 0)::numeric(12,2) as gross
        from public.orders o
       where o.courier_id = auth.uid()
         and o.status = 'delivered'
         and o.settlement_id is null
    )
    select b.orders_count, b.gross, v_percent,
           round(b.gross * v_percent / 100, 2)::numeric(12,2),
           (b.gross - round(b.gross * v_percent / 100, 2))::numeric(12,2)
      from balance b;
end;
$$;

create or replace function public.settle_courier_balance()
returns public.courier_settlements
language plpgsql security definer set search_path = public
as $$
declare
  v_profile public.profiles;
  v_count integer;
  v_gross numeric(12,2);
  v_percent numeric(5,2);
  v_office numeric(12,2);
  v_settlement public.courier_settlements;
begin
  if auth.uid() is null or public.current_role() <> 'courier' then
    raise exception 'تصفية الرصيد متاحة للمندوب فقط' using errcode = '42501';
  end if;

  -- Serialize repeated taps and concurrent settlement requests for this courier.
  select * into v_profile from public.profiles
   where id = auth.uid() and is_active and role = 'courier' for update;
  if not found then
    raise exception 'الحساب غير نشط' using errcode = '42501';
  end if;

  -- Lock both unsettled deliveries and active orders so a simultaneous delivery
  -- cannot be included in the settlement after its amount/count were calculated.
  perform 1 from public.orders o
   where o.courier_id = auth.uid()
     and (o.status = 'accepted' or (o.status = 'delivered' and o.settlement_id is null))
   for update;

  select count(*)::integer, coalesce(sum(o.delivery_fee), 0)::numeric(12,2)
    into v_count, v_gross
    from public.orders o
   where o.courier_id = auth.uid()
     and o.status = 'delivered'
     and o.settlement_id is null;
  if v_count = 0 then
    raise exception 'مفيش رصيد مستحق للتصفية حاليًا' using errcode = 'P0001';
  end if;

  select least(100::numeric, greatest(0::numeric,
      coalesce((s.value #>> '{}')::numeric, 0)))::numeric(5,2)
    into v_percent
    from public.app_settings s where s.key = 'courier_commission_percent';
  v_percent := coalesce(v_percent, 0);
  v_office := round(v_gross * v_percent / 100, 2);

  insert into public.courier_settlements (
    courier_id, branch, orders_count, gross_delivery_fees,
    commission_percent, office_share, courier_net, settled_by
  ) values (
    auth.uid(), coalesce(v_profile.branch, 'bagour'), v_count, v_gross,
    v_percent, v_office, v_gross - v_office, auth.uid()
  ) returning * into v_settlement;

  update public.orders
     set settlement_id = v_settlement.id
   where courier_id = auth.uid()
     and status = 'delivered'
     and settlement_id is null;

  return v_settlement;
end;
$$;

revoke all on function public.get_courier_balance() from public, anon;
revoke all on function public.settle_courier_balance() from public, anon;
grant execute on function public.get_courier_balance() to authenticated;
grant execute on function public.settle_courier_balance() to authenticated;
