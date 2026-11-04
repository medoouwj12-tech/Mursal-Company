import { NextRequest, NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';

export const runtime = 'nodejs';

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function POST(req: NextRequest) {
  try {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if (!url || !serviceKey || !anonKey) throw new Error('إعداد الاتصال بقاعدة البيانات غير مكتمل');

    const token = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
    if (!token) return NextResponse.json({ error: 'يلزم تسجيل الدخول' }, { status: 401 });

    const auth = createClient(url, anonKey, { auth: { persistSession: false } });
    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
    const { data: authData, error: authError } = await auth.auth.getUser(token);
    if (authError || !authData.user) return NextResponse.json({ error: 'جلسة الدخول غير صالحة' }, { status: 401 });

    const { data: actor, error: actorError } = await admin.from('profiles').select('role,is_active').eq('id', authData.user.id).single();
    if (actorError || !actor?.is_active || !['admin', 'call_center'].includes(actor.role)) {
      return NextResponse.json({ error: 'غير مصرح' }, { status: 403 });
    }

    const body = await req.json();
    const orderIds = Array.isArray(body.order_ids) ? [...new Set(body.order_ids.filter((id: unknown): id is string => typeof id === 'string' && uuidPattern.test(id)))].slice(0, 500) : [];
    if (!orderIds.length) return NextResponse.json({ contacts: [] });

    let query = admin.from('orders').select('id,created_by,courier_id,status').in('id', orderIds).in('status', ['accepted', 'delivered']).not('courier_id', 'is', null);
    if (actor.role === 'call_center') query = query.eq('created_by', authData.user.id);
    const { data: orders, error: ordersError } = await query;
    if (ordersError) throw ordersError;

    const courierIds = [...new Set((orders || []).map(order => order.courier_id).filter((id): id is string => Boolean(id)))];
    if (!courierIds.length) return NextResponse.json({ contacts: [] });
    const { data: couriers, error: couriersError } = await admin.from('profiles').select('id,full_name,phone').in('id', courierIds);
    if (couriersError) throw couriersError;

    const byId = new Map((couriers || []).map(courier => [courier.id, courier]));
    const contacts = (orders || []).flatMap(order => {
      const courier = order.courier_id ? byId.get(order.courier_id) : null;
      return courier ? [{ order_id: order.id, courier_id: courier.id, full_name: courier.full_name, phone: courier.phone }] : [];
    });
    return NextResponse.json({ contacts });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : 'تعذر تحميل بيانات المندوب' }, { status: 500 });
  }
}
