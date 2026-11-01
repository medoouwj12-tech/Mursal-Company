-- Mersal order management schema. Apply with `supabase db push`.
create extension if not exists pgcrypto;

create type public.app_role as enum ('admin', 'call_center', 'courier');
create type public.order_status as enum ('pending', 'accepted', 'delivered', 'cancelled');
create type public.order_source as enum ('whatsapp', 'phone');
create type public.order_priority as enum ('normal', 'urgent');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  full_name text not null,
  role public.app_role not null,
  phone text,
  is_active boolean not null default true,
  is_available boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  customer_phone text not null check (customer_phone ~ '^01[0125][0-9]{8}$'),
  governorate text not null,
  area text not null,
  address text not null,
  service_id uuid not null references public.services(id),
  details text not null,
  source public.order_source not null,
  collection_amount numeric(12,2) not null default 0 check (collection_amount >= 0),
  delivery_fee numeric(12,2) not null default 0 check (delivery_fee >= 0),
  notes text,
  priority public.order_priority not null default 'normal',
  status public.order_status not null default 'pending',
  created_by uuid not null references public.profiles(id),
  courier_id uuid references public.profiles(id),
  cancel_reason text,
  cancelled_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint accepted_has_courier check (status not in ('accepted','delivered') or courier_id is not null)
);

create index orders_pending_created_idx on public.orders (created_at desc) where status = 'pending';
create index orders_creator_created_idx on public.orders (created_by, created_at desc);
create index orders_courier_status_idx on public.orders (courier_id, status, created_at desc);
create index orders_status_created_idx on public.orders (status, created_at desc);

create table public.order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  actor_id uuid references public.profiles(id),
  event_type text not null,
  from_status public.order_status,
  to_status public.order_status,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index order_events_order_created_idx on public.order_events (order_id, created_at);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  order_id uuid references public.orders(id) on delete cascade,
  title text not null,
  body text not null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  subscription jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;

create table public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
insert into public.app_settings(key,value) values
  ('max_active_orders_per_courier','1'::jsonb), ('sound_enabled','true'::jsonb)
on conflict (key) do nothing;

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public
as $$ begin new.updated_at = now(); return new; end; $$;
create trigger orders_touch_updated_at before update on public.orders for each row execute function public.touch_updated_at();
create trigger profiles_touch_updated_at before update on public.profiles for each row execute function public.touch_updated_at();

create or replace function public.current_role()
returns public.app_role language sql stable security definer set search_path = public
as $$ select role from public.profiles where id = auth.uid() and is_active $$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.current_role() = 'admin', false) $$;

create policy push_subscriptions_owner on public.push_subscriptions for select to authenticated using (user_id=auth.uid() or public.is_admin());
create policy push_subscriptions_admin on public.push_subscriptions for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Atomic claim: conditional UPDATE serializes concurrent claims on the same row.
create or replace function public.claim_order(p_order_id uuid)
returns public.orders language plpgsql security definer set search_path = public
as $$
declare
  v_order public.orders;
  v_limit integer;
begin
  if auth.uid() is null or public.current_role() <> 'courier' then
    raise exception 'غير مصرح باستلام الطلب' using errcode = '42501';
  end if;
  select coalesce((value #>> '{}')::integer, 1) into v_limit
    from public.app_settings where key = 'max_active_orders_per_courier';
  -- Serialize claims made by this same courier so the active-order cap cannot race.
  perform 1 from public.profiles where id=auth.uid() for update;
  if (select count(*) from public.orders where courier_id = auth.uid() and status = 'accepted') >= coalesce(v_limit,1) then
    raise exception 'وصلت للحد الأقصى من الطلبات النشطة' using errcode = 'P0001';
  end if;
  update public.orders o set status = 'accepted', courier_id = auth.uid(), accepted_at = now(), updated_at = now()
   where o.id = p_order_id and o.status = 'pending'
     and exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_active and p.is_available)
  returning * into v_order;
  if not found then
    raise exception 'الطلب اتاخد من مندوب تاني أو لم يعد متاحًا' using errcode = 'P0001';
  end if;
  return v_order;
end;
$$;

create or replace function public.finish_order(p_order_id uuid, p_delivered boolean, p_reason text default null)
returns public.orders language plpgsql security definer set search_path = public
as $$
declare v_order public.orders; v_next public.order_status;
begin
  if auth.uid() is null then raise exception 'غير مصرح' using errcode='42501'; end if;
  if p_delivered then
    v_next := 'delivered';
  else
    if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'اكتب سبب المشكلة'; end if;
    v_next := 'cancelled';
  end if;
  update public.orders o set status=v_next, delivered_at=case when p_delivered then now() else null end,
    cancelled_at=case when not p_delivered then now() else null end,
    cancel_reason=case when not p_delivered then trim(p_reason) else null end,
    cancelled_by=case when not p_delivered then auth.uid() else null end, updated_at=now()
  where o.id=p_order_id and o.status='accepted'
    and (public.is_admin() or o.courier_id=auth.uid()) returning * into v_order;
  if not found then raise exception 'الطلب غير متاح للتحديث' using errcode='P0001'; end if;
  return v_order;
end;
$$;

create or replace function public.log_order_event()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.order_events(order_id,actor_id,event_type,to_status) values(new.id,auth.uid(),'created',new.status);
  elsif old.status is distinct from new.status then
    insert into public.order_events(order_id,actor_id,event_type,from_status,to_status,details)
    values(new.id,auth.uid(),new.status::text,old.status,new.status,jsonb_build_object('reason',new.cancel_reason));
  elsif to_jsonb(old) is distinct from to_jsonb(new) then
    insert into public.order_events(order_id,actor_id,event_type,from_status,to_status,details)
    values(new.id,auth.uid(),'updated',old.status,new.status,jsonb_build_object('admin_edit',public.is_admin()));
  end if;
  return new;
end;
$$;
create trigger orders_log_event after insert or update on public.orders for each row execute function public.log_order_event();

alter table public.profiles enable row level security;
alter table public.services enable row level security;
alter table public.orders enable row level security;
alter table public.order_events enable row level security;
alter table public.notifications enable row level security;
alter table public.app_settings enable row level security;

create policy profiles_read on public.profiles for select to authenticated
using (public.is_admin() or id = auth.uid());
create policy profiles_admin_all on public.profiles for all to authenticated
using (public.is_admin()) with check (public.is_admin());
create policy courier_presence_update on public.profiles for update to authenticated
using (id=auth.uid() and role='courier') with check (id=auth.uid() and role='courier');
revoke update on public.profiles from authenticated;
grant update (is_available) on public.profiles to authenticated;

create policy services_read on public.services for select to authenticated
using (is_active or public.is_admin());
create policy services_admin_all on public.services for all to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy orders_read on public.orders for select to authenticated using (
  public.is_admin() or created_by=auth.uid() or courier_id=auth.uid() or
  (status='pending' and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='courier' and p.is_active and p.is_available))
);
create policy orders_call_center_insert on public.orders for insert to authenticated
with check (created_by=auth.uid() and public.current_role()='call_center' and status='pending' and courier_id is null);
create policy orders_call_center_update on public.orders for update to authenticated
using (created_by=auth.uid() and public.current_role()='call_center' and status='pending')
with check (created_by=auth.uid() and status in ('pending','cancelled') and courier_id is null);
create policy orders_admin_all on public.orders for all to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy events_read on public.order_events for select to authenticated using (
 public.is_admin() or exists(select 1 from public.orders o where o.id=order_id and (o.created_by=auth.uid() or o.courier_id=auth.uid()))
);
create policy notifications_read on public.notifications for select to authenticated using (user_id=auth.uid() or public.is_admin());
create policy notifications_update on public.notifications for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
create policy settings_read on public.app_settings for select to authenticated using (true);
create policy settings_admin_all on public.app_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on function public.current_role() from public, anon;
revoke all on function public.is_admin() from public, anon;
revoke all on function public.claim_order(uuid) from public, anon;
revoke all on function public.finish_order(uuid,boolean,text) from public, anon;
grant execute on function public.current_role() to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.claim_order(uuid) to authenticated;
grant execute on function public.finish_order(uuid,boolean,text) to authenticated;

-- Realtime publishes status/claim changes so other couriers remove claimed cards immediately.
alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.order_events;
alter publication supabase_realtime add table public.notifications;
