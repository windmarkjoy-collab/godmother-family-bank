begin;
create or replace function public.fb_command_v2(p_op text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 uid uuid:=auth.uid(); m public.fb_members; f public.fb_families; a public.fb_accounts; q public.fb_requests;
 td public.fb_term_deposits; tr public.fb_term_rates; s jsonb;
 today date:=(now() at time zone 'Asia/Taipei')::date; d date; mon date; lastday date; firstday date;
 n bigint; locked bigint; c bigint; dep bigint; lent bigint; eq bigint; fee bigint; days integer;
 sum_days numeric; locked_days numeric; rate_value numeric; item jsonb; source_name text; decision text;
begin
 if uid is null then raise exception '請先登入'; end if;
 perform pg_advisory_xact_lock(hashtextextended(uid::text,0));
 if p_op='state' then return public.fb_snapshot(); end if;
 if p_op in ('create','join') then
  s:=public.fb_command_v1(p_op,p_data);
  if p_op='create' then
   insert into public.fb_term_rates(family,months,rate,source_date,source)
   select (s->'family'->>'id')::uuid,x.months,x.rate,'2026-10-14','臺灣銀行固定定期存款 2026/10/14'
   from (values(1,.01225),(3,.01290),(6,.01465),(12,.01700)) x(months,rate);
  end if;
  return public.fb_snapshot();
 end if;
 select * into m from public.fb_members where id=uid;
 if m.role is null then raise exception '請等家長核准加入'; end if;
 select * into f from public.fb_families where id=m.family for update;
 select coalesce(sum(cash),0),coalesce(sum(deposits),0),coalesce(sum(loans),0),coalesce(sum(equity),0)
 into c,dep,lent,eq from public.fb_entries where family=f.id;
 if c+lent<>dep+eq then raise exception '帳目不平衡，請先核對'; end if;
 if p_op in ('auto_rates','term_rate','live_rate','rate') then
  if m.role not in ('father','mother') then raise exception '只有家長可管理利率'; end if;
  if p_op='auto_rates' then
   if jsonb_typeof(p_data->'enabled')<>'boolean' then raise exception '請指定開關狀態'; end if;
   update public.fb_families set auto_rates=(p_data->>'enabled')::boolean where id=f.id;
  elsif p_op='term_rate' then
   if f.auto_rates then raise exception '請先關閉同步，再人工設定'; end if;
   d:=(p_data->>'date')::date;rate_value:=(p_data->>'rate')::numeric;
   if d is null or d>today or rate_value is null or rate_value not between 0 and .05 then raise exception '請檢查牌告日期與年利率'; end if;
   update public.fb_term_rates set rate=rate_value,source_date=d,source='人工設定' where family=f.id and months=(p_data->>'months')::integer;
   if not found then raise exception '定存期限須為 1、3、6、12 個月'; end if;
  elsif p_op='rate' then
   if f.auto_rates then raise exception '請先關閉同步，再人工設定'; end if;
   return public.fb_command_v1(p_op,p_data);
  else
   if not f.auto_rates then raise exception '即時同步已關閉'; end if;
   d:=(p_data->>'source_date')::date;rate_value:=(p_data->>'demand_rate')::numeric;
   if d is null or d>today or d<today-7 or rate_value is null or rate_value not between 0 and .05 or
    p_data->>'source'<>'臺灣銀行' or p_data->>'source_url'<>'https://rate.bot.com.tw/twd?Lang=zh-TW' then raise exception '同步資料不適用，保留原利率'; end if;
   if f.live_rate_source_date is not null and d<f.live_rate_source_date then raise exception '不可用較舊牌告覆寫'; end if;
   if jsonb_typeof(p_data->'terms')<>'array' or jsonb_array_length(p_data->'terms')<>4 then raise exception '定存牌告不完整'; end if;
   if (select count(distinct (x->>'months')::integer) from jsonb_array_elements(p_data->'terms') x)<>4 then raise exception '定存期限重複'; end if;
   for item in select * from jsonb_array_elements(p_data->'terms') loop
    if (item->>'months')::integer not in (1,3,6,12) or (item->>'rate')::numeric not between 0 and .05 or item->>'rate' is null then raise exception '定存牌告格式不符'; end if;
    update public.fb_term_rates set rate=(item->>'rate')::numeric,source_date=d,source='臺灣銀行即時牌告' where family=f.id and months=(item->>'months')::integer;
   end loop;
   mon:=(date_trunc('month',today)+interval '1 month')::date;
   insert into public.fb_rates values(f.id,mon,rate_value,d) on conflict(family,month) do update set rate=excluded.rate,source_date=excluded.source_date;
   update public.fb_families set last_rate_sync=now(),live_rate_source_date=d where id=f.id;
  end if;
 elsif p_op='request' and p_data->>'kind' in ('term_open','term_redeem') then
  select * into a from public.fb_accounts where family=f.id and id=m.account for update;
  select coalesce(sum(principal),0) into locked from public.fb_term_deposits where family=f.id and account=m.account and status='active';
  if p_data->>'kind'='term_open' then
   n:=(p_data->>'amount')::bigint;
   if n is null or n<1 or n>a.balance-locked then raise exception '可用活期餘額不足'; end if;
   select * into tr from public.fb_term_rates where family=f.id and months=(p_data->>'months')::integer;
   if not found then raise exception '定存期限不適用'; end if;
   insert into public.fb_requests(family,account,kind,amount,note,months,created_by)
   values(f.id,m.account,'term_open',n,trim(p_data->>'note'),tr.months,uid);
  else
   select * into td from public.fb_term_deposits where family=f.id and account=m.account and id=(p_data->>'term_id')::uuid and status='active';
   if not found then raise exception '沒有適用的定存'; end if;
   insert into public.fb_requests(family,account,kind,amount,note,term_id,created_by)
   values(f.id,m.account,'term_redeem',td.principal,trim(p_data->>'note'),td.id,uid);
  end if;
 elsif p_op='review' then
  select * into q from public.fb_requests where family=f.id and id=(p_data->>'id')::uuid for update;
  if not found or q.status<>'pending' then raise exception '申請不存在或已處理'; end if;
  if q.kind='withdraw' and p_data->>'decision'='approve' then
   select balance into n from public.fb_accounts where family=f.id and id=q.account;
   select coalesce(sum(principal),0) into locked from public.fb_term_deposits where family=f.id and account=q.account and status='active';
   if q.amount>n-locked then raise exception '定存本金已鎖定，不能直接提款'; end if;
  end if;
  if q.kind not in ('term_open','term_redeem') then return public.fb_command_v1(p_op,p_data); end if;
  if (q.account='002' and m.role not in ('father','mother')) or
     (q.account in ('001','003') and m.role<>'manager') or q.account not in ('001','002','003') then
   raise exception '此定存須由指定確認人處理'; end if;
  if p_data->>'decision'='reject' then
   update public.fb_requests set status='rejected' where id=q.id;
   return public.fb_snapshot();
  end if;
  if p_data->>'decision'<>'approve' then raise exception '定存請使用確認或不批准'; end if;
  if m.role=any(q.votes) then raise exception '你已確認過'; end if;
  d:=(p_data->>'date')::date;
  if d is null or d>today or d<f.opened or (f.closed is not null and d<=f.closed) or
   d<(select max(date) from public.fb_entries where family=f.id and kind<>'interest') then raise exception '日期不適用，不能回填已結算或較早交易'; end if;
  if q.kind='term_open' and d<>today then raise exception '定存須以今日牌告、今日核准開立，不能回填'; end if;
  update public.fb_requests set votes=array_append(votes,m.role),effective_date=d where id=q.id returning * into q;
  if q.kind='term_open' then
   select * into a from public.fb_accounts where family=f.id and id=q.account for update;
   select coalesce(sum(principal),0) into locked from public.fb_term_deposits where family=f.id and account=q.account and status='active';
   if q.amount>a.balance-locked then raise exception '可用活期餘額不足'; end if;
   select * into tr from public.fb_term_rates where family=f.id and months=q.months;
   -- 批准時凍結利率與來源，不受未來同步影響。
   insert into public.fb_term_deposits(family,account,principal,months,rate,source_date,source,opened,maturity)
   values(f.id,q.account,q.amount,q.months,tr.rate,tr.source_date,tr.source,d,(d+make_interval(months=>q.months))::date);
   insert into public.fb_entries(family,account,date,kind,amount,note,actor,request)
   values(f.id,q.account,d,q.kind,q.amount,q.note||'；固定年息 '||(tr.rate*100)::text||'%',uid,q.id);
  else
   select * into td from public.fb_term_deposits where family=f.id and account=q.account and id=q.term_id and status='active' for update;
   if not found or d<td.opened then raise exception '定存已處理或日期不適用'; end if;
   fee:=case when d>=td.maturity then round(td.principal*td.rate*(td.maturity-td.opened)/365) else 0 end;
   update public.fb_term_deposits set status='redeemed',redeemed=d,interest_paid=fee where id=td.id;
   update public.fb_accounts set balance=balance+fee where family=f.id and id=q.account;
   insert into public.fb_entries(family,account,date,kind,amount,deposits,equity,note,actor,request)
   values(f.id,q.account,d,q.kind,td.principal,fee,-fee,q.note||'；利息 '||fee||' 元；本金轉回活期',uid,q.id);
  end if;
  update public.fb_requests set status='approved' where id=q.id;
 elsif p_op='close' then
  if m.role not in ('father','mother') then raise exception '只有家長可月末入息'; end if;
  if p_data->>'cash' is null or (p_data->>'cash')::bigint<>c then raise exception '實點現金不一致'; end if;
  mon:=(p_data->>'month'||'-01')::date;lastday:=(mon+interval '1 month - 1 day')::date;firstday:=coalesce(f.closed+1,f.opened);
  if mon<>date_trunc('month',firstday)::date or lastday>=today then raise exception '須逐月結算，且當月已結束'; end if;
  if exists(select 1 from public.fb_requests where family=f.id and status='pending') then raise exception '先完成或拒絕申請，再入息'; end if;
  select r.rate into rate_value from public.fb_rates r where family=f.id and month<=mon order by month desc limit 1;
  for a in select * from public.fb_accounts where family=f.id order by id for update loop
   select coalesce(sum(deposits),0) into n from public.fb_entries where family=f.id and account=a.id and date<firstday;
   select coalesce(sum(e.deposits*(lastday-greatest(firstday,case when e.kind='interest' then e.date+1 else e.date end)+1)),0)
   into sum_days from public.fb_entries e where e.family=f.id and e.account=a.id and
   (case when e.kind='interest' then e.date+1 else e.date end) between firstday and lastday;
   sum_days:=sum_days+n*(lastday-firstday+1);
   select coalesce(sum(t.principal*greatest(0,least(lastday+1,coalesce(t.redeemed,lastday+1))-greatest(firstday,t.opened))),0)
   into locked_days from public.fb_term_deposits t where t.family=f.id and t.account=a.id;
   sum_days:=sum_days-locked_days;
   if sum_days<0 then raise exception '活期日餘額不適用'; end if;
   fee:=round(sum_days*rate_value/365);
   update public.fb_accounts set balance=balance+fee where family=f.id and id=a.id;
   insert into public.fb_entries(family,account,date,kind,amount,deposits,equity,note,actor)
   values(f.id,a.id,lastday,'interest',fee,fee,-fee,'月末活期入息；排除定存本金；原始利息 '||(sum_days*rate_value/365)::text,uid);
  end loop;
  update public.fb_families set closed=lastday where id=f.id;
 else
  if p_op='request' and p_data->>'kind'='withdraw' then
   select balance into n from public.fb_accounts where family=f.id and id=m.account;
   select coalesce(sum(principal),0) into locked from public.fb_term_deposits where family=f.id and account=m.account and status='active';
   if (p_data->>'amount')::bigint>n-locked then raise exception '超過可用活期餘額'; end if;
  end if;
  return public.fb_command_v1(p_op,p_data);
 end if;
 return public.fb_snapshot();
end $$;
revoke all on function public.fb_command_v2(text,jsonb) from public,anon,authenticated;
commit;
