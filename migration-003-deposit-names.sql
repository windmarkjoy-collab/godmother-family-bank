begin;
alter table public.fb_members add column name text check(name is null or char_length(trim(name)) between 1 and 30);
alter function public.fb_command(text,jsonb) rename to fb_command_v2;
revoke all on function public.fb_command_v2(text,jsonb) from public,anon,authenticated;
create function public.fb_command(p_op text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 uid uuid:=auth.uid(); m public.fb_members; f public.fb_families; q public.fb_requests;
 target public.fb_members; d date; today date:=(now() at time zone 'Asia/Taipei')::date;
 decision text; new_name text; c bigint; dep bigint; lent bigint; eq bigint;
begin
 if uid is null then raise exception '請先登入'; end if;
 if p_op not in ('review','member_name') then return public.fb_command_v2(p_op,p_data); end if;
 perform pg_advisory_xact_lock(hashtextextended(uid::text,0));
 select * into m from public.fb_members where id=uid;
 if m.role is null then raise exception '請等家長核准加入'; end if;
 select * into f from public.fb_families where id=m.family for update;
 if p_op='member_name' then
  if m.role<>'father' then raise exception '只有爸爸可以修改成員名稱'; end if;
  select * into target from public.fb_members where id=(p_data->>'member')::uuid and family=f.id for update;
  if not found then raise exception '找不到本家庭成員'; end if;
  new_name:=trim(p_data->>'name');
  if new_name is null or char_length(new_name) not between 1 and 30 then raise exception '名稱須為 1 至 30 個字'; end if;
  update public.fb_members set name=new_name where id=target.id;
  return public.fb_snapshot();
 end if;
 select * into q from public.fb_requests where id=(p_data->>'id')::uuid and family=f.id for update;
 if not found or q.status<>'pending' then raise exception '申請不存在或已處理'; end if;
 if q.kind<>'deposit' then return public.fb_command_v2(p_op,p_data); end if;
 decision:=p_data->>'decision';
 -- 002 姐姐存款交任一位家長；001 父母共同與 003 弟弟交姐姐。
 if (q.account='002' and m.role not in ('father','mother')) or
    (q.account in ('001','003') and m.role<>'manager') or
    q.account not in ('001','002','003') then raise exception '此存款須由指定確認人處理'; end if;
 if decision='reject' then
  update public.fb_requests set status='rejected' where id=q.id;
 elsif decision='approve' then
  d:=(p_data->>'date')::date;
  if d is null or d>today or d<f.opened or (f.closed is not null and d<=f.closed) or
     d<(select max(date) from public.fb_entries where family=f.id and kind<>'interest') then
   raise exception '不能回填已結算月份、較早交易或未來日期';
  end if;
  select coalesce(sum(cash),0),coalesce(sum(deposits),0),coalesce(sum(loans),0),coalesce(sum(equity),0)
  into c,dep,lent,eq from public.fb_entries where family=f.id;
  if c+lent<>dep+eq then raise exception '帳目不平衡，請先核對'; end if;
  update public.fb_accounts set balance=balance+q.amount where family=f.id and id=q.account;
  if not found then raise exception '存款帳戶不存在'; end if;
  insert into public.fb_entries(family,account,date,kind,amount,cash,deposits,note,actor,request)
  values(f.id,q.account,d,'deposit',q.amount,q.amount,q.amount,q.note,uid,q.id);
  update public.fb_requests set status='approved',checked=true,checked_by=uid,
   votes=array[m.role],effective_date=d where id=q.id;
 else raise exception '存款請使用確認入帳或不批准'; end if;
 return public.fb_snapshot();
end $$;
revoke all on function public.fb_command(text,jsonb) from public,anon;
grant execute on function public.fb_command(text,jsonb) to authenticated;
create or replace function public.fb_snapshot() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.fb_members; f public.fb_families; r public.fb_rates; result jsonb; privileged boolean;
begin
 if auth.uid() is null then raise exception '請先登入'; end if;
 select * into m from public.fb_members where id=auth.uid();
 if not found then return null; end if;
 if m.role is null then return jsonb_build_object('member',to_jsonb(m)); end if;
 select * into f from public.fb_families where id=m.family;
 select * into r from public.fb_rates where family=m.family and month<=date_trunc('month',now() at time zone 'Asia/Taipei')::date order by month desc limit 1;
 privileged:=m.role in ('father','mother','manager');
 result:=jsonb_build_object('family',jsonb_build_object('id',f.id,'name',f.name,'capital',f.capital,'opened',f.opened,'closed',f.closed,'auto_rates',f.auto_rates,'last_rate_sync',f.last_rate_sync,'live_rate_source_date',f.live_rate_source_date,'next_rate',(select to_jsonb(nr) from public.fb_rates nr where nr.family=m.family and nr.month=(date_trunc('month',now() at time zone 'Asia/Taipei')+interval '1 month')::date),'rate',r.rate,'rate_date',r.source_date,'code',case when m.role in ('father','mother') then f.code else null end),
 'member',to_jsonb(m),
 'members',coalesce((select jsonb_agg(jsonb_build_object('id',id,'role',role,'account',account,'name',coalesce(name,case role when 'father' then '爸爸' when 'mother' then '媽媽' when 'manager' then '姐姐' when 'child' then '弟弟' else '等待分配' end))) from public.fb_members where family=m.family and (role is not null or m.role in ('father','mother'))),'[]'::jsonb),
 'accounts',coalesce((select jsonb_agg((to_jsonb(a)||jsonb_build_object('locked',coalesce((select sum(t.principal) from public.fb_term_deposits t where t.family=a.family and t.account=a.id and t.status='active'),0),'available',a.balance-coalesce((select sum(t.principal) from public.fb_term_deposits t where t.family=a.family and t.account=a.id and t.status='active'),0))) order by a.id) from public.fb_accounts a where family=m.family and (privileged or id=m.account)),'[]'::jsonb),
 'term_rates',coalesce((select jsonb_agg(to_jsonb(t) order by months) from public.fb_term_rates t where family=m.family),'[]'::jsonb),
 'term_deposits',coalesce((select jsonb_agg(to_jsonb(t) order by opened,id) from public.fb_term_deposits t where family=m.family and (privileged or account=m.account)),'[]'::jsonb),
 'requests',coalesce((select jsonb_agg(to_jsonb(q) order by created_at desc) from public.fb_requests q where family=m.family and (privileged or account=m.account)),'[]'::jsonb),
 'loans',coalesce((select jsonb_agg(to_jsonb(l)) from public.fb_loans l where family=m.family and (privileged or account=m.account)),'[]'::jsonb),
 'entries',coalesce((select jsonb_agg(to_jsonb(e) order by date,id) from public.fb_entries e where family=m.family and (privileged or account=m.account)),'[]'::jsonb),
 'missions',coalesce((select jsonb_agg(to_jsonb(x)) from public.fb_missions x where family=m.family and (privileged or member=m.id)),'[]'::jsonb),
 'memories',coalesce((select jsonb_agg(to_jsonb(x) order by date desc) from public.fb_memories x where family=m.family),'[]'::jsonb));
 return result;
end $$;


commit;
