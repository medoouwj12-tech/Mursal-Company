-- Private order photos and PDFs shared only with the order's team.
create table if not exists public.order_attachments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  uploaded_by uuid not null references public.profiles(id),
  object_path text not null unique,
  file_name text not null,
  mime_type text not null check (mime_type like 'image/%' or mime_type = 'application/pdf'),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 10485760),
  created_at timestamptz not null default now()
);
create index if not exists order_attachments_order_idx on public.order_attachments(order_id, created_at);
alter table public.order_attachments enable row level security;
grant select, insert on public.order_attachments to authenticated;
grant all on public.order_attachments to service_role;

create policy order_attachments_read on public.order_attachments for select to authenticated using (
  public.is_admin() or exists (
    select 1 from public.orders o where o.id = order_id
      and (o.created_by = auth.uid() or o.courier_id = auth.uid())
  )
);
create policy order_attachments_add on public.order_attachments for insert to authenticated with check (
  uploaded_by = auth.uid() and exists (
    select 1 from public.orders o where o.id = order_id
      and (public.is_admin() or (o.created_by = auth.uid() and o.status in ('pending','accepted')))
  )
);
create policy order_attachments_admin_delete on public.order_attachments for delete to authenticated using (public.is_admin());

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('order-attachments', 'order-attachments', false, 10485760, array['image/*','application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['image/*','application/pdf'];

create policy order_files_add on storage.objects for insert to authenticated with check (
  bucket_id = 'order-attachments' and exists (
    select 1 from public.orders o where o.id::text = (storage.foldername(name))[1]
      and (public.is_admin() or (o.created_by = auth.uid() and o.status in ('pending','accepted')))
  )
);
create policy order_files_read on storage.objects for select to authenticated using (
  bucket_id = 'order-attachments' and exists (
    select 1 from public.order_attachments a join public.orders o on o.id = a.order_id
    where a.object_path = name and (public.is_admin() or o.created_by = auth.uid() or o.courier_id = auth.uid())
  )
);
create policy order_files_admin_delete on storage.objects for delete to authenticated using (
  bucket_id = 'order-attachments' and public.is_admin()
);

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='order_attachments') then
    alter publication supabase_realtime add table public.order_attachments;
  end if;
end $$;
