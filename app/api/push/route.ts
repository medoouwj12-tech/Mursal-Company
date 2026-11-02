import { NextRequest, NextResponse } from 'next/server';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import webpush from 'web-push';
export const runtime='nodejs';

function clients(){const url=process.env.NEXT_PUBLIC_SUPABASE_URL!,service=process.env.SUPABASE_SERVICE_ROLE_KEY!;return {admin:createClient(url,service,{auth:{persistSession:false}}),url};}

async function actor(req:NextRequest){const token=req.headers.get('authorization')?.replace(/^Bearer\s+/i,'');if(!token)throw new Error('يلزم تسجيل الدخول');const {admin,url}=clients();const auth=createClient(url,process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY||'');const {data,error}=await auth.auth.getUser(token);if(error||!data.user)throw new Error('جلسة غير صالحة');return {admin,id:data.user.id};}

function vapid(){
  const pub=process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY,priv=process.env.VAPID_PRIVATE_KEY;
  if(!pub||!priv)throw new Error('مفاتيح إشعارات الويب غير مضبوطة على السيرفر');
  webpush.setVapidDetails(process.env.VAPID_SUBJECT||'mailto:admin@mursal.app',pub,priv);
}

async function sendToUsers(admin:SupabaseClient,ids:string[],title:string,body:string,orderId?:string){
  const result={subscribers:0,sent:0,failed:0};
  if(!ids.length)return result;
  const {data:subs}=await admin.from('push_subscriptions').select('user_id,endpoint,subscription').in('user_id',ids);
  result.subscribers=subs?.length||0;
  if(!subs?.length)return result;
  vapid();
  await Promise.allSettled(subs.map(async(s:any)=>{
    try{
      await webpush.sendNotification(s.subscription,JSON.stringify({title,body,url:'/',orderId}));
      result.sent++;
    }catch(e:any){
      result.failed++;
      if(e.statusCode===404||e.statusCode===410)await admin.from('push_subscriptions').delete().eq('endpoint',s.endpoint);
    }
  }));
  return result;
}

export async function POST(req:NextRequest){
  try{
    const {admin,id}=await actor(req);
    const b=await req.json();
    if(b.action==='subscribe'){
      if(!b?.subscription?.endpoint)throw new Error('بيانات الاشتراك غير صحيحة');
      const {error}=await admin.from('push_subscriptions').upsert({user_id:id,endpoint:b.subscription.endpoint,subscription:b.subscription},{onConflict:'endpoint'});
      if(error)throw error;
      return NextResponse.json({ok:true});
    }
    if(b.action==='test'){
      const result=await sendToUsers(admin,[id],'مرسال · تجربة إشعار','لو وصلتك الرسالة دي يبقى الإشعارات شغالة تمام 👌');
      return NextResponse.json({ok:true,...result});
    }
    if(b.action==='new_order'||b.action==='order_updated'){
      const {data:p}=await admin.from('profiles').select('role,is_active').eq('id',id).single();
      if(!p?.is_active||!['admin','call_center'].includes(p.role))throw new Error('غير مصرح');
      const {data:o}=await admin.from('orders').select('id,area,priority,status,courier_id,service:services(name)').eq('id',b.order_id).single();
      if(!o)throw new Error('الطلب غير موجود');
      const service=(o as any).service?.name||'خدمة';
      if(b.action==='new_order'){
        const {data:users}=await admin.from('profiles').select('id').eq('role','courier').eq('is_available',true).eq('is_active',true);
        const result=await sendToUsers(admin,(users||[]).map(x=>x.id),'طلب جديد على مرسال',`${service} · ${o.area}${o.priority==='urgent'?' · مستعجل':''}`,o.id);
        return NextResponse.json({ok:true,...result});
      }
      if(o.courier_id){
        const result=await sendToUsers(admin,[o.courier_id],'تم تعديل طلب مستلم',`راجع تفاصيل الطلب المحدثة: ${service} · ${o.area}`,o.id);
        return NextResponse.json({ok:true,...result});
      }
      return NextResponse.json({ok:true,subscribers:0,sent:0,failed:0});
    }
    return NextResponse.json({error:'إجراء غير معروف'},{status:400});
  }catch(e:any){return NextResponse.json({error:e.message||'تعذر إرسال الإشعار'},{status:400});}
}
