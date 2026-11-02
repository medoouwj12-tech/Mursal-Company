-- 0002 tightened the call-center UPDATE policy to pending/accepted, which also blocked
-- cancelling a pending order (the new row is 'cancelled'). The guard trigger already
-- validates real transitions, so the WITH CHECK only needs to allow the cancel state.
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
  and status in ('pending', 'accepted', 'cancelled')
);
