-- Establish a hard data boundary between the Bagour and Ashmoun branches.
alter table public.profiles add column if not exists branch text;
alter table public.profiles drop constraint if exists profiles_branch_check;
alter table public.profiles add constraint profiles_branch_check check (branch is null or branch in ('bagour','ashmoun'));

alter table public.orders add column if not exists branch text;
alter table public.orders drop constraint if exists orders_branch_check;
alter table public.orders add constraint orders_branch_check check (branch is null or branch in ('bagour','ashmoun'));
create index if not exists orders_branch_status_created_idx on public.orders(branch,status,created_at desc);

-- Keep the lightweight realtime invalidation feed inside each branch as well.
alter table public.order_signals add column if not exists branch text;
update public.order_signals s set branch=o.branch from public.orders o where o.id=s.order_id and s.branch is null;
delete from public.order_signals where branch is null;
alter table public.order_signals drop constraint if exists order_signals_branch_check;
alter table public.order_signals add constraint order_signals_branch_check check (branch is null or branch in ('bagour','ashmoun'));
drop policy if exists order_signals_read on public.order_signals;

create or replace function public.signal_order_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op='DELETE' then
    insert into public.order_signals(order_id,kind,courier_id,branch) values(old.id,'removed',null,old.branch);
    return old;
  end if;
  if tg_op='UPDATE' and old.status is distinct from new.status then
    if old.status='pending' and new.status='accepted' then
      insert into public.order_signals(order_id,kind,courier_id,branch) values(new.id,'claimed',new.courier_id,new.branch);
    elsif new.status='pending' then
      insert into public.order_signals(order_id,kind,courier_id,branch) values(new.id,'released',null,new.branch);
    elsif new.status in ('cancelled','delivered') then
      insert into public.order_signals(order_id,kind,courier_id,branch) values(new.id,'removed',null,new.branch);
    end if;
    if random()<0.02 then delete from public.order_signals where created_at<now()-interval '2 days'; end if;
  end if;
  return new;
end;
$$;
revoke all on function public.signal_order_change() from public,anon,authenticated;

-- Backfill legacy orders where a creator or assigned courier already has a branch.
update public.orders o set branch=coalesce(
  (select c.branch from public.profiles c where c.id=o.created_by),
  (select r.branch from public.profiles r where r.id=o.courier_id)
)
where o.branch is null and coalesce(
  (select c.branch from public.profiles c where c.id=o.created_by),
  (select r.branch from public.profiles r where r.id=o.courier_id)
) is not null;

create or replace function public.current_branch()
returns text language sql stable security definer set search_path = public
as $$ select branch from public.profiles where id=auth.uid() and is_active $$;

revoke all on function public.current_branch() from public, anon;
grant execute on function public.current_branch() to authenticated;
create policy order_signals_read on public.order_signals for select to authenticated using (public.is_admin() or branch=public.current_branch());

create or replace function public.enforce_order_branch()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_courier_branch text; v_creator_branch text;
begin
  if tg_op='INSERT' and new.branch is null then raise exception 'الفرع مطلوب للطلب' using errcode='23514'; end if;
  if tg_op='UPDATE' and public.current_role()='call_center' and new.branch is distinct from old.branch then
    raise exception 'لا يمكن نقل الطلب إلى فرع آخر' using errcode='42501';
  end if;
  if tg_op='INSERT' and public.current_role()='call_center' then
    select branch into v_creator_branch from public.profiles where id=new.created_by;
    if new.branch is distinct from v_creator_branch then raise exception 'الطلب يجب أن يتبع فرعك' using errcode='42501'; end if;
  end if;
  if new.courier_id is not null then
    select branch into v_courier_branch from public.profiles where id=new.courier_id and role='courier' and is_active;
    if v_courier_branch is null or new.branch is distinct from v_courier_branch then
      raise exception 'المندوب والطلب يجب أن يكونا من نفس الفرع' using errcode='23514';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists orders_enforce_branch on public.orders;
create trigger orders_enforce_branch before insert or update on public.orders for each row execute function public.enforce_order_branch();
revoke all on function public.enforce_order_branch() from public, anon, authenticated;

drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders for select to authenticated using (
  public.is_admin() or created_by=auth.uid() or courier_id=auth.uid() or
  (status='pending' and branch is not null and branch=public.current_branch()
   and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='courier' and p.is_active and p.is_available))
);

drop policy if exists orders_call_center_insert on public.orders;
create policy orders_call_center_insert on public.orders for insert to authenticated
with check (created_by=auth.uid() and public.current_role()='call_center' and status='pending' and courier_id is null and branch=public.current_branch());

create or replace function public.claim_order(p_order_id uuid)
returns public.orders language plpgsql security definer set search_path = public
as $$
declare v_order public.orders; v_limit integer; v_branch text;
begin
  if auth.uid() is null or public.current_role() <> 'courier' then
    raise exception 'غير مصرح باستلام الطلب' using errcode = '42501';
  end if;
  select coalesce((value #>> '{}')::integer,1) into v_limit from public.app_settings where key='max_active_orders_per_courier';
  perform 1 from public.profiles where id=auth.uid() for update;
  select branch into v_branch from public.profiles where id=auth.uid() and is_active and is_available;
  if v_branch is null then raise exception 'حسابك غير مربوط بفرع، تواصل مع المدير' using errcode='P0001'; end if;
  if (select count(*) from public.orders where courier_id=auth.uid() and status='accepted') >= coalesce(v_limit,1) then
    raise exception 'وصلت للحد الأقصى من الطلبات النشطة' using errcode='P0001';
  end if;
  update public.orders o set status='accepted',courier_id=auth.uid(),accepted_at=now(),updated_at=now()
   where o.id=p_order_id and o.status='pending' and o.branch=v_branch
     and exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_active and p.is_available and p.branch=v_branch)
  returning * into v_order;
  if not found then raise exception 'الطلب اتاخد من مندوب تاني أو تابع لفرع آخر' using errcode='P0001'; end if;
  return v_order;
end;
$$;

revoke all on function public.claim_order(uuid) from public, anon;
grant execute on function public.claim_order(uuid) to authenticated;

-- Couriers may preview attachments on available orders from their own branch.
drop policy if exists order_attachments_read on public.order_attachments;
create policy order_attachments_read on public.order_attachments for select to authenticated using (
  public.is_admin() or exists (
    select 1 from public.orders o where o.id=order_id and (
      o.created_by=auth.uid() or o.courier_id=auth.uid() or
      (o.status='pending' and o.branch=public.current_branch() and public.current_role()='courier'
       and exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_active and p.is_available))
    )
  )
);
drop policy if exists order_files_read on storage.objects;
create policy order_files_read on storage.objects for select to authenticated using (
  bucket_id='order-attachments' and exists (
    select 1 from public.order_attachments a join public.orders o on o.id=a.order_id
    where a.object_path=name and (
      public.is_admin() or o.created_by=auth.uid() or o.courier_id=auth.uid() or
      (o.status='pending' and o.branch=public.current_branch() and public.current_role()='courier'
       and exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_active and p.is_available))
    )
  )
);
