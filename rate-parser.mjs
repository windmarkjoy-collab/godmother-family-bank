// 只解析臺灣銀行一般、小額新臺幣固定定期存款與活期儲蓄牌告。
export function parseBotRates(html, now = new Date()) {
 const clean = s => s.replace(/<[^>]*>/g,' ').replace(/&nbsp;|&#160;/g,' ').replace(/&amp;/g,'&').replace(/\s+/g,' ').trim();
 const text=clean(html),date=text.match(/掛牌(?:日期|時間)[：:]\s*(\d{4})\/(\d{2})\/(\d{2})/);
 if(!date)throw Error('官方來源缺少牌告日期');
 const source_date=`${date[1]}-${date[2]}-${date[3]}`;
 const current=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Taipei',year:'numeric',month:'2-digit',day:'2-digit'}).format(now);
 const age=(Date.parse(current)-Date.parse(source_date))/86400000;
 if(!Number.isFinite(age)||age<0||age>7)throw Error('來源日期不適用或資料超過七天，保留原利率');
 let section='',period='',savings=null;const terms={};
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

