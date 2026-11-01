import { createClient } from '@supabase/supabase-js';

const url=process.env.NEXT_PUBLIC_SUPABASE_URL,anon=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,service=process.env.SUPABASE_SERVICE_ROLE_KEY;
if(!url||!anon||!service)throw new Error('Set the Supabase URL, anon key, and service role key.');
const admin=createClient(url,service,{auth:{persistSession:false}});
const cc=createClient(url,anon,{auth:{persistSession:false}});
const {data:services,error:se}=await admin.from('services').select('id').limit(1);if(se||!services?.length)throw se||new Error('Seed services first.');
const {data:callers,error:ce}=await admin.from('profiles').select('id').eq('role','call_center').limit(1);if(ce||!callers?.length)throw ce||new Error('Seed demo accounts first.');
const users=[];
const {data:{users:found}}=await admin.auth.admin.listUsers({page:1,perPage:1000});
for(let i=1;i<=20;i++){const username=`courier${String(i).padStart(2,'0')}`,email=`${username}@mursal.app`;const u=found.find(x=>x.email===email);if(!u)throw new Error(`Missing ${username}; run db:seed first.`);await admin.from('profiles').update({is_available:true}).eq('id',u.id);const client=createClient(url,anon,{auth:{persistSession:false}});const {error}=await client.auth.signInWithPassword({email,password:'Courier2026!'});if(error)throw error;users.push({client,username});}
const {data:order,error:oe}=await admin.from('orders').insert({customer_name:'اختبار التزامن',customer_phone:'01000000000',governorate:'القاهرة',area:'اختبار',address:'طلب تجريبي للاختبار فقط',service_id:services[0].id,details:'حذف تلقائي بعد الاختبار',source:'phone',created_by:callers[0].id}).select('id').single();if(oe)throw oe;
try{const results=await Promise.all(users.map(async({client,username})=>({username,...await client.rpc('claim_order',{p_order_id:order.id})})));const winners=results.filter(r=>!r.error);console.log(`Simultaneous claim attempts: ${results.length}`);console.log(`Successful claims: ${winners.length}`);console.log(`Winner: ${winners[0]?.username||'none'}`);if(winners.length!==1)throw new Error(`Expected exactly one successful claim, observed ${winners.length}`);console.log('PASS: atomic claim allowed exactly one courier.');}finally{await admin.from('orders').delete().eq('id',order.id);await Promise.all(users.map(({client})=>client.auth.signOut()));}
