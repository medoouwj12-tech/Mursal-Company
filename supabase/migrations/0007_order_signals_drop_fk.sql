-- Signal rows are ephemeral broadcasts; they must be insertable from an AFTER DELETE
-- trigger, so the order may no longer exist. Drop the foreign key (rows are pruned).
alter table public.order_signals drop constraint if exists order_signals_order_id_fkey;
