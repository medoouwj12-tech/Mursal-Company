import { NextRequest, NextResponse } from 'next/server';
import { createClient, SupabaseClient } from '@supabase/supabase-js';

export const runtime = 'nodejs';

const ROLES = ['admin', 'call_center', 'courier'];

function clients() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL, service = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !service) throw new Error('إعداد مفتاح الخدمة غير مكتمل');
  return { admin: createClient(url, service, { auth: { persistSession: false } }), url };
}

async function guard(req: NextRequest) {
  const token = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
  if (!token) throw new Error('يلزم تسجيل الدخول');
  const { admin, url } = clients();
  const auth = createClient(url, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || '');
  const { data, error } = await auth.auth.getUser(token);
  if (error || !data.user) throw new Error('جلسة الدخول غير صالحة');
  const { data: p } = await admin.from('profiles').select('role,is_active').eq('id', data.user.id).single();
  if (p?.role !== 'admin' || !p.is_active) throw new Error('هذه العملية للمدير فقط');
  return { admin, uid: data.user.id };
}

async function otherActiveAdmins(admin: SupabaseClient, excludeId: string) {
  const { data } = await admin.from('profiles').select('id').eq('role', 'admin').eq('is_active', true).neq('id', excludeId);
  return data?.length || 0;
}

function fail(message: string, status = 400) {
  return NextResponse.json({ error: message }, { status });
}

export async function POST(req: NextRequest) {
  try {
    const { admin } = await guard(req);
    const b = await req.json();
    const username = String(b.username || '').trim().toLowerCase();
    const name = String(b.full_name || '').trim();
    const password = String(b.password || '');
    if (!/^[a-z0-9._-]{3,32}$/.test(username)) return fail('اسم المستخدم يجب أن يكون 3 إلى 32 حرفًا إنجليزيًا أو رقمًا');
    if (name.length < 2) return fail('الاسم مطلوب');
    if (password.length < 8) return fail('كلمة المرور 8 أحرف على الأقل');
    if (!ROLES.includes(b.role)) return fail('الدور غير صحيح');

    const { data: exists } = await admin.from('profiles').select('id').eq('username', username).maybeSingle();
    if (exists) return fail('اسم المستخدم مستخدم بالفعل، اختار اسمًا آخر');

    const { data, error } = await admin.auth.admin.createUser({ email: `${username}@mursal.app`, password, email_confirm: true, user_metadata: { username } });
    if (error) {
      if (/already/i.test(error.message)) return fail('اسم المستخدم مستخدم بالفعل، اختار اسمًا آخر');
      throw error;
    }
    const { error: pe } = await admin.from('profiles').insert({ id: data.user.id, username, full_name: name, role: b.role, phone: b.phone || null, is_active: true, is_available: false });
    if (pe) {
      await admin.auth.admin.deleteUser(data.user.id);
      throw pe;
    }
    return NextResponse.json({ ok: true });
  } catch (e: any) {
    return fail(e.message || 'تعذر تنفيذ العملية');
  }
}

export async function PATCH(req: NextRequest) {
  try {
    const { admin, uid } = await guard(req);
    const b = await req.json();
    if (!b.id) return fail('معرف المستخدم مطلوب');

    const { data: target } = await admin.from('profiles').select('id,role,is_active,username').eq('id', b.id).single();
    if (!target) return fail('المستخدم غير موجود');

    const nextRole = 'role' in b ? b.role : target.role;
    const nextActive = 'is_active' in b ? Boolean(b.is_active) : target.is_active;
    if (!ROLES.includes(nextRole)) return fail('الدور غير صحيح');
    if (b.id === uid && (nextRole !== 'admin' || !nextActive)) return fail('مش مسموح تغيّر دور حسابك أو توقفه');

    const losingAdmin = target.role === 'admin' && target.is_active && (nextRole !== 'admin' || !nextActive);
    if (losingAdmin && (await otherActiveAdmins(admin, target.id)) === 0) return fail('لازم يفضل مدير واحد نشط على الأقل');

    if (b.password) {
      if (String(b.password).length < 8) return fail('كلمة المرور 8 أحرف على الأقل');
      const { error } = await admin.auth.admin.updateUserById(b.id, { password: b.password });
      if (error) throw error;
    }

    const updates: Record<string, unknown> = {};
    for (const k of ['full_name', 'phone', 'is_active', 'is_available']) if (k in b) updates[k] = b[k];
    if ('role' in b) updates.role = nextRole;
    if (!nextActive) updates.is_available = false;

    if ('username' in b && String(b.username).trim().toLowerCase() !== target.username) {
      const username = String(b.username).trim().toLowerCase();
      if (!/^[a-z0-9._-]{3,32}$/.test(username)) return fail('اسم المستخدم غير صحيح');
      const { data: taken } = await admin.from('profiles').select('id').eq('username', username).maybeSingle();
      if (taken && taken.id !== b.id) return fail('اسم المستخدم مستخدم بالفعل، اختار اسمًا آخر');
      const { error: pe } = await admin.from('profiles').update({ username }).eq('id', b.id);
      if (pe) throw pe;
      const { error: ae } = await admin.auth.admin.updateUserById(b.id, { email: `${username}@mursal.app`, email_confirm: true });
      if (ae) {
        await admin.from('profiles').update({ username: target.username }).eq('id', b.id);
        throw ae;
      }
    }

    if (Object.keys(updates).length) {
      const { error } = await admin.from('profiles').update(updates).eq('id', b.id);
      if (error) throw error;
    }
    return NextResponse.json({ ok: true });
  } catch (e: any) {
    return fail(e.message || 'تعذر تنفيذ العملية');
  }
}

export async function DELETE(req: NextRequest) {
  try {
    const { admin, uid } = await guard(req);
    const id = new URL(req.url).searchParams.get('id');
    if (!id) return fail('معرف المستخدم مطلوب');
    if (id === uid) return fail('مش مسموح تحذف حسابك');

    const { data: p } = await admin.from('profiles').select('role,is_active').eq('id', id).single();
    if (!p) return fail('المستخدم غير موجود');
    if (p.role === 'admin' && (await otherActiveAdmins(admin, id)) === 0) return fail('لازم يفضل مدير واحد نشط على الأقل');

    // Accounts with history stay in place (orders keep pointing at them) but lose access.
    const [{ count: orderCount }, { count: eventCount }] = await Promise.all([
      admin.from('orders').select('id', { count: 'exact', head: true }).or(`created_by.eq.${id},courier_id.eq.${id}`),
      admin.from('order_events').select('id', { count: 'exact', head: true }).eq('actor_id', id),
    ]);
    if ((orderCount || 0) + (eventCount || 0) > 0) {
      const { error } = await admin.from('profiles').update({ is_active: false, is_available: false }).eq('id', id);
      if (error) throw error;
      return NextResponse.json({ ok: true, softDeleted: true });
    }

    const { error } = await admin.auth.admin.deleteUser(id);
    if (error) throw error;
    return NextResponse.json({ ok: true, softDeleted: false });
  } catch (e: any) {
    return fail(e.message || 'تعذر تنفيذ العملية');
  }
}
