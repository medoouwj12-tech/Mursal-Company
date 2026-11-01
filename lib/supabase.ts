'use client';
import { createClient } from '@supabase/supabase-js';

const url = process.env.NEXT_PUBLIC_SUPABASE_URL || 'https://placeholder.supabase.co';
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || 'placeholder-anon-key';
export const hasSupabaseEnv = Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY);
export const supabase = createClient(url, key, { auth: { persistSession: true, autoRefreshToken: true } });

export type Profile = { id:string; username:string; full_name:string; role:'admin'|'call_center'|'courier'; phone:string|null; is_active:boolean; is_available:boolean };
export type Order = {
  id:string; customer_name:string; customer_phone:string; governorate:string; area:string; address:string;
  service_id:string; details:string; source:'whatsapp'|'phone'; collection_amount:number; delivery_fee:number;
  notes:string|null; priority:'normal'|'urgent'; status:'pending'|'accepted'|'delivered'|'cancelled';
  created_by:string; courier_id:string|null; created_at:string; accepted_at:string|null; delivered_at:string|null;
  cancel_reason:string|null; service?:{name:string}; creator?:{full_name:string}; courier?:{full_name:string};
};
