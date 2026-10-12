-- 乾媽家庭銀行 1.0：獨立 fb_ 資料表，不修改 user_progress。
-- 在 Supabase SQL Editor 執行。整個安裝以單一交易完成。
begin;
create table public.fb_families (
 id uuid primary key default gen_random_uuid(), name text not null,
 capital bigint not null check(capital between 0 and 100000),
 code text not null unique default replace(gen_random_uuid()::text,'-',''),
 opened date not null default (now() at time zone 'Asia/Taipei')::date,
 closed date
);
create table public.fb_members (
 id uuid primary key references auth.users(id), family uuid not null references public.fb_families(id),
 role text check(role in ('father','mother','manager','child')), account text,
 unique(family,role), check((role is null and account is null) or
 (role in ('father','mother') and account='001') or (role='manager' and account='002') or (role='child' and account='003'))
);
create table public.fb_accounts (
 family uuid not null references public.fb_families(id), id text not null check(id in ('001','002','003')),
 name text not null, balance bigint not null default 0 check(balance>=0),
 goal text not null default '', target bigint not null default 0 check(target>=0),
 allowance bigint not null default 0 check(allowance>=0), primary key(family,id)
);
create table public.fb_rates (
 family uuid not null references public.fb_families(id), month date not null,
 rate numeric not null check(rate between 0 and .05), source_date date not null,
 primary key(family,month)
);
create table public.fb_requests (
 id uuid primary key default gen_random_uuid(), family uuid not null references public.fb_families(id),
 account text not null, kind text not null check(kind in ('deposit','withdraw','loan','repay')),
 amount bigint not null check(amount between 1 and 100000), note text not null check(length(note) between 1 and 200),
 days integer not null default 28 check(days between 1 and 28),
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 checked boolean not null default false, checked_by uuid references auth.users(id),
 votes text[] not null default '{}', effective_date date, created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(), foreign key(family,account) references public.fb_accounts(family,id)
);
create table public.fb_loans (
 id uuid primary key default gen_random_uuid(), family uuid not null references public.fb_families(id), account text not null,
 balance bigint not null check(balance>=0), opened date not null, due date not null,
 last_date date not null, accrued numeric not null default 0, foreign key(family,account) references public.fb_accounts(family,id)
);
create unique index fb_one_open_loan on public.fb_loans(family,account) where balance>0;
create table public.fb_entries (
 id bigint generated always as identity primary key, family uuid not null references public.fb_families(id),
 account text, date date not null, kind text not null, amount bigint not null,
 cash bigint not null default 0, loans bigint not null default 0, deposits bigint not null default 0, equity bigint not null default 0,
 note text not null default '', actor uuid not null references auth.users(id), request uuid unique references public.fb_requests(id),
 check(cash+loans=deposits+equity)
);
create index fb_entries_by_family on public.fb_entries(family,date);
create table public.fb_missions (
 family uuid not null references public.fb_families(id), member uuid not null references auth.users(id),
 week integer not null check(week between 0 and 3), completed_at timestamptz not null default now(), primary key(member,week)
);
create table public.fb_memories (
 id uuid primary key default gen_random_uuid(), family uuid not null references public.fb_families(id),
 member uuid not null references auth.users(id), name text not null, text text not null check(length(text) between 1 and 1000),
 date date not null default (now() at time zone 'Asia/Taipei')::date
);
-- 沒有直接讀寫的 grant/policy。所有查詢與交易走驗證身分的 RPC。
alter table public.fb_families enable row level security;
alter table public.fb_members enable row level security;
alter table public.fb_accounts enable row level security;
alter table public.fb_rates enable row level security;
alter table public.fb_requests enable row level security;
alter table public.fb_loans enable row level security;
alter table public.fb_entries enable row level security;
alter table public.fb_missions enable row level security;
alter table public.fb_memories enable row level security;
revoke all on public.fb_families,public.fb_members,public.fb_accounts,public.fb_rates,public.fb_requests,
 public.fb_loans,public.fb_entries,public.fb_missions,public.fb_memories from anon,authenticated;
revoke all on sequence public.fb_entries_id_seq from anon,authenticated;

create function public.fb_snapshot() returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.fb_members; f public.fb_families; r public.fb_rates; result jsonb; privileged boolean;
begin
 if auth.uid() is null then raise exception '請先登入'; end if;
 select * into m from public.fb_members where id=auth.uid();
 if not found then return null; end if;
 if m.role is null then return jsonb_build_object('member',to_jsonb(m)); end if;
 select * into f from public.fb_families where id=m.family;
 select * into r from public.fb_rates where family=m.family and month<=date_trunc('month',now() at time zone 'Asia/Taipei')::date order by month desc limit 1;
 privileged:=m.role in ('father','mother','manager');
 result:=jsonb_build_object('family',jsonb_build_object('id',f.id,'name',f.name,'capital',f.capital,'opened',f.opened,'closed',f.closed,'rate',r.rate,'rate_date',r.source_date,'code',case when m.role in ('father','mother') then f.code else null end),
 'member',to_jsonb(m),
 'members',coalesce((select jsonb_agg(jsonb_build_object('id',id,'role',role,'account',account,'name',case role when 'father' then '爸爸' when 'mother' then '媽媽' when 'manager' then '姐姐' when 'child' then '弟弟' else '等待分配' end)) from public.fb_members where family=m.family and (role is not null or m.role in ('father','mother'))),'[]'::jsonb),
 'accounts',coalesce((select jsonb_agg(to_jsonb(a) order by id) from public.fb_accounts a where family=m.family and (privileged or id=m.account)),'[]'::jsonb),
 'requests',coalesce((select jsonb_agg(to_jsonb(q) order by created_at desc) from public.fb_requests q where family=m.family and (privileged or account=m.account)),'[]'::jsonb),
 'loans',coalesce((select jsonb_agg(to_jsonb(l)) from public.fb_loans l where family=m.family and (privileged or account=m.account)),'[]'::jsonb),
 'entries',coalesce((select jsonb_agg(to_jsonb(e) order by date,id) from public.fb_entries e where family=m.family and (privileged or account=m.account)),'[]'::jsonb),
 'missions',coalesce((select jsonb_agg(to_jsonb(x)) from public.fb_missions x where family=m.family and (privileged or member=m.id)),'[]'::jsonb),
 'memories',coalesce((select jsonb_agg(to_jsonb(x) order by date desc) from public.fb_memories x where family=m.family),'[]'::jsonb));
 return result;
end $$;
revoke all on function public.fb_snapshot() from public,anon,authenticated;

create function public.fb_command(p_op text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 uid uuid:=auth.uid(); m public.fb_members; f public.fb_families; a public.fb_accounts; q public.fb_requests; l public.fb_loans;
 fid uuid; n bigint; d date; today date:=(now() at time zone 'Asia/Taipei')::date; mon date; lastday date; startday date;
 c bigint; dep bigint; lent bigint; eq bigint; i bigint; raw numeric; rate numeric; principal_days numeric; decision text; role_value text;
begin
 if uid is null then raise exception '請先登入'; end if;
 -- 同一個會員無法並行建立或加入兩個家庭。
 perform pg_advisory_xact_lock(hashtextextended(uid::text,0));
 select * into m from public.fb_members where id=uid;
 if p_op='state' then return public.fb_snapshot(); end if;
 if p_op='create' then
  if m.id is not null then raise exception '你已加入銀行'; end if;
  n:=(p_data->>'capital')::bigint;
  if n is null or n<0 or n>100000 or length(trim(p_data->>'name')) not between 1 and 30 then raise exception '請檢查銀行名稱與原始資本'; end if;
  insert into public.fb_families(name,capital) values(trim(p_data->>'name'),n) returning id into fid;
  insert into public.fb_members(id,family,role,account) values(uid,fid,'father','001');
  insert into public.fb_accounts(family,id,name) values(fid,'001','爸爸媽媽共同'),(fid,'002','姐姐'),(fid,'003','弟弟');
  insert into public.fb_rates values(fid,date_trunc('month',today)::date,.00825,'2026-10-12');
  insert into public.fb_entries(family,date,kind,amount,cash,equity,note,actor) values(fid,today,'capital',n,n,n,'乾媽紀念基金原始投入',uid);
  return public.fb_snapshot();
 end if;
 if p_op='join' then
  if m.id is not null then raise exception '你已加入或申請加入銀行'; end if;
  select id into fid from public.fb_families where code=p_data->>'code';
  if fid is null then raise exception '邀請碼無效'; end if;
  insert into public.fb_members(id,family) values(uid,fid);
  return public.fb_snapshot();
 end if;
 if m.role is null then raise exception '請等家長核准加入'; end if;
 select * into f from public.fb_families where id=m.family for update;
 fid:=m.family;
 select coalesce(sum(cash),0),coalesce(sum(deposits),0),coalesce(sum(loans),0),coalesce(sum(equity),0) into c,dep,lent,eq from public.fb_entries where family=fid;
 if c+lent<>dep+eq then raise exception '帳目不平衡，請暫停操作'; end if;
 if p_op='assign' then
  if m.role not in ('father','mother') then raise exception '只有家長可指定角色'; end if;
  role_value:=p_data->>'role';
  if role_value not in ('mother','manager','child') then raise exception '角色不適用'; end if;
  if role_value='mother' and m.role<>'father' then raise exception '媽媽角色由爸爸指定'; end if;
  update public.fb_members set role=role_value,account=case role_value when 'mother' then '001' when 'manager' then '002' else '003' end where id=(p_data->>'member')::uuid and family=fid and role is null;
  if not found then raise exception '只能核准本家庭的待加入成員'; end if;
 elsif p_op='goal' then
  n:=(p_data->>'target')::bigint;
  if n is null or n not between 1 and 100000 or length(trim(p_data->>'goal')) not between 1 and 60 then raise exception '請檢查目標'; end if;
  update public.fb_accounts set goal=trim(p_data->>'goal'),target=n where family=fid and id=m.account;
 elsif p_op='allowance' then
  if m.role not in ('father','mother') then raise exception '只有家長可設定零用錢基礎'; end if;
  n:=(p_data->>'amount')::bigint;
  if n is null or n not between 0 and 100000 then raise exception '金額不適用'; end if;
  update public.fb_accounts set allowance=n where family=fid and id=p_data->>'account';
 elsif p_op='mission' then
  insert into public.fb_missions(family,member,week) values(fid,uid,(p_data->>'week')::integer) on conflict(member,week) do nothing;
 elsif p_op='memory' then
  insert into public.fb_memories(family,member,name,text) values(fid,uid,case m.role when 'father' then '爸爸' when 'mother' then '媽媽' when 'manager' then '姐姐' else '弟弟' end,trim(p_data->>'text'));
 elsif p_op='topup' then
  if m.role not in ('father','mother') then raise exception '只有家長可投入追加資本'; end if;
  n:=(p_data->>'amount')::bigint;
  if n is null or n not between 1 and 100000 then raise exception '金額不適用'; end if;
  insert into public.fb_entries(family,date,kind,amount,cash,equity,note,actor) values(fid,today,'topup',n,n,n,'父母營運追加資本',uid);
 elsif p_op='request' then
  select * into a from public.fb_accounts where family=fid and id=m.account;
  n:=(p_data->>'amount')::bigint;
  if n is null or n not between 1 and 100000 then raise exception '金額不適用'; end if;
  if p_data->>'kind'='withdraw' and n>a.balance then raise exception '提款不能超過存款'; end if;
  if p_data->>'kind'='loan' and n>least(200,floor(a.allowance*.25)) then raise exception '超過個人借款上限，請先存錢'; end if;
  insert into public.fb_requests(family,account,kind,amount,note,days,created_by) values(fid,m.account,p_data->>'kind',n,trim(p_data->>'note'),coalesce((p_data->>'days')::integer,28),uid);
 elsif p_op='review' then
  select * into q from public.fb_requests where family=fid and id=(p_data->>'id')::uuid for update;
  if not found or q.status<>'pending' then raise exception '申請不存在或已處理'; end if;
  decision:=p_data->>'decision';
  if decision='check' then
   if m.role<>'manager' or q.account=m.account then raise exception '姐姐不能審核自己的申請'; end if;
   update public.fb_requests set checked=true,checked_by=uid where id=q.id;
  else
   if m.role not in ('father','mother') then raise exception '需要家長確認'; end if;
   if decision='reject' then update public.fb_requests set status='rejected' where id=q.id;
   elsif decision='approve' then
    if m.role=any(q.votes) then raise exception '你已確認過，請由另一位家長確認'; end if;
    d:=(p_data->>'date')::date;
    if d is null or d>today or d<f.opened or (f.closed is not null and d<=f.closed) then raise exception '不能回填已結算月份或未來日期'; end if;
    if d<(select max(date) from public.fb_entries where family=fid and kind<>'interest') then raise exception '請先依實際收付日期排序處理，不可回填較早交易'; end if;
    if q.effective_date is not null and d<>q.effective_date then raise exception '兩位家長確認的收付日期必須相同'; end if;
    update public.fb_requests set votes=array_append(votes,m.role),effective_date=d where id=q.id returning * into q;
    if (q.account='001' or q.kind='loan') and cardinality(q.votes)<2 then return public.fb_snapshot(); end if;
    select * into a from public.fb_accounts where family=fid and id=q.account for update;
    n:=q.amount;i:=0;
    if q.kind='deposit' then
     update public.fb_accounts set balance=balance+n where family=fid and id=a.id;
     insert into public.fb_entries(family,account,date,kind,amount,cash,deposits,note,actor,request) values(fid,a.id,d,q.kind,n,n,n,q.note,uid,q.id);
    elsif q.kind='withdraw' then
     if n>a.balance or n>c then raise exception '餘額或現金不足'; end if;
     update public.fb_accounts set balance=balance-n where family=fid and id=a.id;
     insert into public.fb_entries(family,account,date,kind,amount,cash,deposits,note,actor,request) values(fid,a.id,d,q.kind,n,-n,-n,q.note,uid,q.id);
    elsif q.kind='loan' then
     if n>greatest(0,least(200,floor(a.allowance*.25),c-dep-10,floor(f.capital*.1)-lent)) then raise exception '超過目前安全可貸上限'; end if;
     insert into public.fb_loans(family,account,balance,opened,due,last_date) values(fid,a.id,n,d,d+q.days,d);
     insert into public.fb_entries(family,account,date,kind,amount,cash,loans,note,actor,request) values(fid,a.id,d,q.kind,n,-n,n,q.note,uid,q.id);
    elsif q.kind='repay' then
     select * into l from public.fb_loans where family=fid and account=a.id and balance>0 for update;
     if not found or n>l.balance then raise exception '沒有適用貸款或還本超過未還本金'; end if;
     if d<l.last_date then raise exception '還款日期不適用'; end if;
     -- 到期後自動停息，父母協助處理；無罰息、無自動扣款。
     raw:=l.accrued+l.balance*.06*greatest(0,least(d,l.due)-l.last_date)/365;
     if n=l.balance then i:=round(raw); end if;
     if p_data->>'cash_received' is null or (p_data->>'cash_received')::bigint<>n+i then raise exception '實收現金與本金加結清利息不一致'; end if;
     update public.fb_loans set balance=balance-n,last_date=d,accrued=raw where id=l.id;
     insert into public.fb_entries(family,account,date,kind,amount,cash,loans,equity,note,actor,request) values(fid,a.id,d,q.kind,n,n+i,-n,i,q.note||'；現金利息 '||i||' 元',uid,q.id);
    end if;
    update public.fb_requests set status='approved' where id=q.id;
   else raise exception '不適用的審核動作'; end if;
  end if;
 elsif p_op='rate' then
  if m.role not in ('father','mother') then raise exception '只有家長可登記牌告'; end if;
  mon:=(date_trunc('month',today)+interval '1 month')::date;
  d:=(p_data->>'date')::date;rate:=(p_data->>'rate')::numeric;
  if d is null or d>today or rate is null or rate not between 0 and .05 then raise exception '請檢查來源日期與年利率'; end if;
  insert into public.fb_rates values(fid,mon,rate,d) on conflict(family,month) do update set rate=excluded.rate,source_date=excluded.source_date;
 elsif p_op='close' then
  if m.role not in ('father','mother') then raise exception '只有家長可月末入息'; end if;
  if (p_data->>'cash')::bigint<>c or p_data->>'cash' is null then raise exception '實點現金不一致'; end if;
  mon:=(p_data->>'month'||'-01')::date;lastday:=(mon+interval '1 month - 1 day')::date;
  startday:=coalesce(f.closed+1,f.opened);
  if mon<>date_trunc('month',startday)::date or lastday>=today then raise exception '須逐月結算，且當月已結束'; end if;
  if exists(select 1 from public.fb_requests where family=fid and status='pending') then raise exception '先完成或拒絕待處理申請，再月末入息'; end if;
  select r.rate into rate from public.fb_rates r where family=fid and month<=mon order by month desc limit 1;
  for a in select * from public.fb_accounts where family=fid order by id for update loop
   select coalesce(sum(deposits),0) into n from public.fb_entries where family=fid and account=a.id and date<startday;
   -- 利息入帳日為月末；其本金從次月才加入計息，特殊處理既有入息。
   select coalesce(sum(e.deposits*(lastday-greatest(startday,case when e.kind='interest' then e.date+1 else e.date end)+1)),0)
   into principal_days from public.fb_entries e where e.family=fid and e.account=a.id and
   (case when e.kind='interest' then e.date+1 else e.date end) between startday and lastday;
   principal_days:=principal_days+n*(lastday-startday+1);
   i:=round(principal_days*rate/365);
   if i<0 then raise exception '日餘額計算錯誤'; end if;
   update public.fb_accounts set balance=balance+i where family=fid and id=a.id;
   insert into public.fb_entries(family,account,date,kind,amount,deposits,equity,note,actor) values(fid,a.id,lastday,'interest',i,i,-i,'月末入息；原始利息 '||(principal_days*rate/365)::text,uid);
  end loop;
  update public.fb_families set closed=lastday where id=fid;
 else raise exception '不支援的操作';
 end if;
 return public.fb_snapshot();
end $$;
revoke all on function public.fb_command(text,jsonb) from public,anon;
grant execute on function public.fb_command(text,jsonb) to authenticated;
commit;
