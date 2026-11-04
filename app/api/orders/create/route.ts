import { NextRequest, NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';

export const runtime = 'nodejs';

const egyptMobile = /^01[0125]\d{8}$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const fail = (error: string, status = 400) => NextResponse.json({ error }, { status });

export async function POST(req: NextRequest) {
  try {
    const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if (!url || !serviceKey || !anonKey) return fail('إعداد الاتصال بقاعدة البيانات غير مكتمل', 500);

    const token = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
    if (!token) return fail('يلزم تسجيل الدخول', 401);
    const auth = createClient(url, anonKey, { auth: { persistSession: false } });
    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
    const { data: authData, error: authError } = await auth.auth.getUser(token);
    if (authError || !authData.user) return fail('جلسة الدخول غير صالحة', 401);
    const { data: actor, error: actorError } = await admin.from('profiles').select('role,is_active').eq('id', authData.user.id).single();
    if (actorError || !actor?.is_active || !['admin', 'call_center'].includes(actor.role)) return fail('إنشاء الطلب متاح لموظف الكول سنتر أو المدير فقط', 403);

    const body = await req.json();
    const phone = String(body.customer_phone || '').replace(/\s/g, '');
    const name = String(body.customer_name || '').trim();
    const serviceId = String(body.service_id || '');
    const courierId = body.courier_id ? String(body.courier_id) : null;
    const amount = Number(body.collection_amount ?? 0);
    const fee = Number(body.delivery_fee ?? 0);
    if (name.length < 2) return fail('اسم العميل مطلوب');
    if (!egyptMobile.test(phone)) return fail('رقم الموبايل المصري غير صحيح');
    if (!uuidPattern.test(serviceId)) return fail('نوع الخدمة غير صحيح');
    if (courierId && !uuidPattern.test(courierId)) return fail('المندوب المختار غير صحيح');
    if (!Number.isFinite(amount) || amount < 0 || !Number.isFinite(fee) || fee < 0) return fail('المبالغ يجب أن تكون صفرًا أو أكثر');
    if (!['whatsapp', 'phone'].includes(body.source)) return fail('مصدر الطلب غير صحيح');
    if (!['normal', 'urgent'].includes(body.priority)) return fail('أولوية الطلب غير صحيحة');
    for (const field of ['governorate', 'area', 'address', 'details']) if (!String(body[field] || '').trim()) return fail('يرجى استكمال بيانات العنوان وتفاصيل الطلب');

    const { data: service, error: serviceError } = await admin.from('services').select('id').eq('id', serviceId).eq('is_active', true).maybeSingle();
    if (serviceError) throw serviceError;
    if (!service) return fail('الخدمة المختارة غير متاحة');

    let courier: { id: string; full_name: string } | null = null;
    if (courierId) {
      const { data, error } = await admin.from('profiles').select('id,full_name').eq('id', courierId).eq('role', 'courier').eq('is_active', true).eq('is_available', true).maybeSingle();
      if (error) throw error;
      if (!data) return fail('المندوب لم يعد متاحًا، حدّث القائمة أو اترك الطلب للمناديب المتاحين');
      const [{ data: setting, error: settingError }, { count, error: countError }] = await Promise.all([
        admin.from('app_settings').select('value').eq('key', 'max_active_orders_per_courier').maybeSingle(),
        admin.from('orders').select('id', { count: 'exact', head: true }).eq('courier_id', courierId).eq('status', 'accepted'),
      ]);
      if (settingError) throw settingError;
      if (countError) throw countError;
      const maxActive = Number(setting?.value ?? 1) || 1;
      if ((count || 0) >= maxActive) return fail('المندوب وصل للحد الأقصى من الطلبات النشطة، اختار مندوبًا آخر');
      courier = data;
    }

    const order = {
      customer_name: name,
      customer_phone: phone,
      governorate: String(body.governorate).trim(),
      area: String(body.area).trim(),
      address: String(body.address).trim(),
      service_id: serviceId,
      details: String(body.details).trim(),
      source: body.source,
      collection_amount: amount,
      delivery_fee: fee,
      notes: String(body.notes || '').trim() || null,
      priority: body.priority,
      created_by: authData.user.id,
      courier_id: courier?.id || null,
      status: courier ? 'accepted' : 'pending',
      accepted_at: courier ? new Date().toISOString() : null,
    };
    const { data: created, error: insertError } = await admin.from('orders').insert(order).select('*').single();
    if (insertError) throw insertError;
    if (courier) {
      const { error } = await admin.from('order_events').insert({ order_id: created.id, actor_id: authData.user.id, event_type: 'assigned', to_status: 'accepted', details: { courier_name: courier.full_name, source: `${actor.role}_assignment` } });
      if (error) console.error('Could not record courier assignment event:', error.message);
    }
    return NextResponse.json({ order: created, assigned_courier: courier?.full_name || null });
  } catch (error) {
    console.error('Order creation failed:', error);
    return fail(error instanceof Error ? error.message : 'تعذر تسجيل الطلب', 500);
  }
}
