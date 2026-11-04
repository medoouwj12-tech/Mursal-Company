import { NextRequest, NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';

export const runtime = 'nodejs';

export async function GET(req: NextRequest) {
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

    const { data: couriers, error } = await admin.from('profiles').select('id,full_name').eq('role', 'courier').eq('is_active', true).eq('is_available', true).order('full_name');
    if (error) throw error;
    return NextResponse.json({ couriers: couriers || [] });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : 'تعذر تحميل قائمة المناديب' }, { status: 500 });
  }
}
