import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4';
// 只解析臺灣銀行一般、小額新臺幣固定定期存款與活期儲蓄牌告。
function parseBotRates(html: string, now = new Date()) {
 const clean = (s: string) => s.replace(/<[^>]*>/g,' ').replace(/&nbsp;|&#160;/g,' ').replace(/&amp;/g,'&').replace(/\s+/g,' ').trim();
 const text=clean(html),date=text.match(/掛牌(?:日期|時間)[：:]\s*(\d{4})\/(\d{2})\/(\d{2})/);
 if(!date)throw Error('官方來源缺少牌告日期');
 const source_date=`${date[1]}-${date[2]}-${date[3]}`;
 const current=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Taipei',year:'numeric',month:'2-digit',day:'2-digit'}).format(now);
 const age=(Date.parse(current)-Date.parse(source_date))/86400000;
 if(!Number.isFinite(age)||age<0||age>7)throw Error('來源日期不適用或資料超過七天，保留原利率');
 let section='',period='',savings: number | null=null;const terms: Record<number,number>={};
 for(const row of html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)){
  const cells=[...row[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(x=>clean(x[1]));
  if(!cells.length)continue;
  const joined=cells.join(' ');
  if(cells.some(c=>c==='定期儲蓄存款'))section='savings';
  if(cells.some(c=>c==='定期存款'))section='time';
  if(cells.some(c=>c==='類別'))section='';
  if(cells.some(c=>c==='活期儲蓄存款利率')){
   const number=cells.find(c=>/^\d+(?:\.\d+)?$/.test(c));if(number)savings=Number((Number(number)/100).toFixed(8));
  }
  if(section!=='time'||joined.includes('五百萬元'))continue;
  const candidate=cells.find(c=>/^(?:一|三|六)個月|^一年/.test(c));
  if(candidate)period=candidate;
  const numbers=cells.filter(c=>/^\d+(?:\.\d+)?$/.test(c));
  if(numbers.length<2)continue;
  const months=/^一個月/.test(period)?1:/^三個月/.test(period)?3:/^六個月/.test(period)?6:/^一年/.test(period)?12:null;
  if(months&&!terms[months])terms[months]=Number((Number(numbers.at(-1))/100).toFixed(8));
 }
 if(savings===null||![1,3,6,12].every(m=>Number.isFinite(terms[m])))throw Error('官方表格格式改變，未找到完整活儲與定存資料');
 if([savings,...Object.values(terms)].some(r=>r<0||r>.05))throw Error('官方利率超出合理範圍');
 return {source:'臺灣銀行',source_url:'https://rate.bot.com.tw/twd?Lang=zh-TW',source_date,demand_rate:savings,terms:[1,3,6,12].map(months=>({months,rate:terms[months]})),fetched_at:now.toISOString()};
}

const origin='https://windmarkjoy-collab.github.io';
const cors={'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'GET, POST, OPTIONS','Vary':'Origin','Cache-Control':'no-store'};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json; charset=utf-8'}});
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(!['GET','POST'].includes(req.method))return reply({error:'不支援的請求方式'},405);
 let userClient;
 try{
  if(req.method==='POST'){
   const auth=req.headers.get('Authorization');if(!auth)return reply({error:'請先登入'},401);
   userClient=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:auth}},auth:{persistSession:false}});
   const {data:user,error:authError}=await userClient.auth.getUser();if(authError||!user.user)return reply({error:'登入已失效'},401);
   const {data:state,error}=await userClient.rpc('fb_command',{p_op:'state',p_data:{}});
   if(error||!['father','mother'].includes(state?.member?.role))return reply({error:'只有家長可同步利率'},403);
   if(!state?.family?.auto_rates)return reply({error:'即時同步已關閉'},409);
  }
  const response=await fetch('https://rate.bot.com.tw/twd?Lang=zh-TW',{signal:AbortSignal.timeout(10000),headers:{'Accept':'text/html','User-Agent':'FamilyBankRateSync/1.0'},redirect:'error'});
  if(!response.ok)throw Error('官方網站暫時無法讀取');
  const html=await response.text();if(html.length>1000000)throw Error('官方回應超出預期大小');
  const rates=parseBotRates(html);
  // GET 只回傳公開牌告，供官方來源連線檢查，不讀寫家庭資料。
  if(req.method==='GET')return reply(rates);
  const {data,error}=await userClient!.rpc('fb_command',{p_op:'live_rate',p_data:rates});
  if(error)return reply({error:error.message},400);
  return reply({rates,state:data});
 }catch(error){return reply({error:error instanceof Error?error.message:'未取得最新牌告；保留原利率'},502)}
});

