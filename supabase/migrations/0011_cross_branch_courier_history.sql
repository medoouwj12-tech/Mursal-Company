-- A courier may move branches after completing orders. Existing assignment
-- history must remain writable for settlement and completion timestamps.
alter table public.courier_settlements alter column branch drop not null;
alter table public.courier_settlements
  drop constraint if exists courier_settlements_branch_check;
alter table public.courier_settlements
  add constraint courier_settlements_branch_check
  check (branch is null or branch in ('bagour', 'ashmoun'));

create or replace function public.enforce_order_branch()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_courier_branch text;
  v_creator_branch text;
  v_assignment_changed boolean := false;
begin
  if tg_op = 'INSERT' and new.branch is null then
    raise exception 'الفرع مطلوب للطلب' using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and public.current_role() = 'call_center'
     and new.branch is distinct from old.branch then
    raise exception 'لا يمكن نقل الطلب إلى فرع آخر' using errcode = '42501';
  end if;

  if tg_op = 'INSERT' and public.current_role() = 'call_center' then
    select branch into v_creator_branch from public.profiles where id = new.created_by;
    if new.branch is distinct from v_creator_branch then
      raise exception 'الطلب يجب أن يتبع فرعك' using errcode = '42501';
    end if;
  end if;

  if tg_op = 'INSERT' then
    v_assignment_changed := new.courier_id is not null;
  elsif tg_op = 'UPDATE' then
    v_assignment_changed := new.courier_id is distinct from old.courier_id
      or new.branch is distinct from old.branch;
  end if;

  -- Validate only a new courier/branch assignment. Do not block completion,
  -- cancellation, or settlement when a courier's profile branch later changes.
  if v_assignment_changed and new.courier_id is not null then
    select branch into v_courier_branch
      from public.profiles
     where id = new.courier_id and role = 'courier' and is_active;
    if v_courier_branch is null or new.branch is distinct from v_courier_branch then
      raise exception 'المندوب والطلب يجب أن يكونا من نفس الفرع' using errcode = '23514';
    end if;
  end if;
  return new;
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
  v_branch_count integer;
  v_settlement_branch text;
  v_percent numeric(5,2);
  v_office numeric(12,2);
  v_settlement public.courier_settlements;
begin
  if auth.uid() is null or public.current_role() <> 'courier' then
    raise exception 'تصفية الرصيد متاحة للمندوب فقط' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles
   where id = auth.uid() and is_active and role = 'courier' for update;
  if not found then
    raise exception 'الحساب غير نشط' using errcode = '42501';
  end if;

  -- Lock accepted orders too, so a delivery cannot race the totals calculation.
  perform 1 from public.orders o
   where o.courier_id = auth.uid()
     and (o.status = 'accepted' or (o.status = 'delivered' and o.settlement_id is null))
   for update;

  select count(*)::integer,
         coalesce(sum(o.delivery_fee), 0)::numeric(12,2),
         count(distinct coalesce(o.branch, '__unknown__'))::integer,
         case when count(distinct coalesce(o.branch, '__unknown__')) = 1
              then max(o.branch) else null end
    into v_count, v_gross, v_branch_count, v_settlement_branch
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
    auth.uid(), v_settlement_branch, v_count, v_gross,
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
