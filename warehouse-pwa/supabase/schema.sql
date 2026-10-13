-- Run once in Supabase SQL Editor. Single warehouse, 2-5 users.
create extension if not exists pgcrypto;
create table if not exists public.profiles(id uuid primary key references auth.users(id) on delete cascade, display_name text not null default '', role text not null default 'staff' check(role in ('staff','manager','admin')), active boolean not null default true, created_at timestamptz not null default now());
create table if not exists public.products(id uuid primary key default gen_random_uuid(), sku text not null unique, name text not null, base_unit text not null check(base_unit in ('kg','个','包','件','箱','斤')), warning_qty numeric(18,3) not null default 0 check(warning_qty>=0), active boolean not null default true, created_at timestamptz not null default now());
create table if not exists public.product_units(id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id), unit text not null, factor numeric(18,6) not null check(factor>0), unique(product_id,unit));
create table if not exists public.stock_balances(product_id uuid primary key references public.products(id), qty numeric(18,3) not null default 0 check(qty>=0), updated_at timestamptz not null default now());
create table if not exists public.stock_transactions(id uuid primary key default gen_random_uuid(), doc_no text not null unique, product_id uuid not null references public.products(id), kind text not null check(kind in ('opening','in','out','count_adjust','reversal')), unit text not null, entered_qty numeric(18,3) not null check(entered_qty>0), factor numeric(18,6) not null, delta numeric(18,3) not null, before_qty numeric(18,3) not null, after_qty numeric(18,3) not null, operator_id uuid not null references public.profiles(id), responsible_name text not null, note text not null default '', reference_id uuid references public.stock_transactions(id), created_at timestamptz not null default now());
create table if not exists public.stock_counts(id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id), observed_qty numeric(18,3) not null check(observed_qty>=0), snapshot_qty numeric(18,3) not null, reason text not null, status text not null default 'pending' check(status in ('pending','approved','rejected')), submitted_by uuid not null references public.profiles(id), reviewed_by uuid references public.profiles(id), reviewed_at timestamptz, created_at timestamptz not null default now());
create table if not exists public.audit_logs(id bigint generated always as identity primary key, actor_id uuid, action text not null, entity text not null, entity_id text, old_data jsonb, new_data jsonb, created_at timestamptz not null default now());
create index if not exists tx_product_time on public.stock_transactions(product_id,created_at desc);
create index if not exists tx_time on public.stock_transactions(created_at desc);
create index if not exists audit_time on public.audit_logs(created_at desc);
create index if not exists count_status on public.stock_counts(status,created_at desc);
create or replace function public.my_role() returns text language sql stable security definer set search_path=public as $$select role from public.profiles where id=auth.uid() and active=true$$;
create or replace function public.is_manager() returns boolean language sql stable security definer set search_path=public as $$select coalesce(public.my_role() in ('manager','admin'),false)$$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$select coalesce(public.my_role()='admin',false)$$;
-- Profiles are created automatically. Set the FIRST admin manually in SQL Editor (see README).
create or replace function public.on_user_created() returns trigger language plpgsql security definer set search_path=public as $$begin insert into public.profiles(id,display_name) values(new.id,coalesce(new.raw_user_meta_data->>'display_name','员工')) on conflict do nothing;return new;end$$;
drop trigger if exists auth_user_profile on auth.users;
create trigger auth_user_profile after insert on auth.users for each row execute function public.on_user_created();
create or replace function public.audit_row() returns trigger language plpgsql security definer set search_path=public as $$begin insert into public.audit_logs(actor_id,action,entity,entity_id,old_data,new_data) values(auth.uid(),TG_OP,TG_TABLE_NAME,coalesce(new.id::text,old.id::text),case when TG_OP='INSERT' then null else to_jsonb(old) end,case when TG_OP='DELETE' then null else to_jsonb(new) end);return coalesce(new,old);end$$;
-- All business mutations occur through controlled RPCs. No direct client write grants.
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.product_units enable row level security;
alter table public.stock_balances enable row level security;
alter table public.stock_transactions enable row level security;
alter table public.stock_counts enable row level security;
alter table public.audit_logs enable row level security;
create policy "profile read" on public.profiles for select to authenticated using(public.my_role() is not null);
create policy "products read" on public.products for select to authenticated using(public.my_role() is not null);
create policy "units read" on public.product_units for select to authenticated using(public.my_role() is not null);
create policy "balance read" on public.stock_balances for select to authenticated using(public.my_role() is not null);
create policy "tx read" on public.stock_transactions for select to authenticated using(public.my_role() is not null);
create policy "counts read" on public.stock_counts for select to authenticated using(public.my_role() is not null);
create policy "audit managers read" on public.audit_logs for select to authenticated using(public.is_manager());
revoke all on public.profiles,public.products,public.product_units,public.stock_balances,public.stock_transactions,public.stock_counts,public.audit_logs from anon,authenticated;
grant select on public.profiles,public.products,public.product_units,public.stock_balances,public.stock_transactions,public.stock_counts to authenticated;
grant select on public.audit_logs to authenticated;
create or replace function public.save_product(p_sku text,p_name text,p_base_unit text,p_warning numeric,p_units jsonb,p_id uuid default null) returns uuid language plpgsql security definer set search_path=public as $$declare v_id uuid;u jsonb;begin
 if not public.is_manager() then raise exception '无商品管理权限';end if;
 if nullif(trim(p_sku),'') is null or nullif(trim(p_name),'') is null or p_warning<0 or p_base_unit not in ('kg','个','包','件','箱','斤') then raise exception '商品信息不合法';end if;
 if p_id is null then insert into public.products(sku,name,base_unit,warning_qty) values(trim(p_sku),trim(p_name),p_base_unit,p_warning) returning id into v_id;
 else update public.products set sku=trim(p_sku),name=trim(p_name),warning_qty=p_warning where id=p_id and base_unit=p_base_unit returning id into v_id; if v_id is null then raise exception '基础单位不可更改或商品不存在';end if;end if;
 insert into public.product_units(product_id,unit,factor) values(v_id,p_base_unit,1) on conflict(product_id,unit) do update set factor=excluded.factor;
 for u in select * from jsonb_array_elements(coalesce(p_units,'[]'::jsonb)) loop
 if nullif(u->>'unit','') is null or (u->>'factor')::numeric<=0 then raise exception '单位换算错误';end if;
 if u->>'unit'=p_base_unit and (u->>'factor')::numeric<>1 then raise exception '基础单位换算必须为1';end if;
 insert into public.product_units(product_id,unit,factor) values(v_id,u->>'unit',(u->>'factor')::numeric) on conflict(product_id,unit) do update set factor=excluded.factor;
 end loop;
 insert into public.stock_balances(product_id) values(v_id) on conflict do nothing;
 return v_id;end$$;
create or replace function public.move_stock(p_product uuid,p_kind text,p_qty numeric,p_unit text,p_responsible text,p_note text default '',p_reference uuid default null) returns uuid language plpgsql security definer set search_path=public as $$declare v_factor numeric;v_before numeric;v_delta numeric;v_after numeric;v_id uuid;v_role text;v_ref record;begin
 v_role:=public.my_role();if v_role is null then raise exception '账号无权限';end if;
 if p_kind not in ('opening','in','out','reversal') or p_qty is null or p_qty<=0 or nullif(trim(p_responsible),'') is null then raise exception '出入库参数不合法';end if;
 if p_kind='opening' and v_role<>'admin' then raise exception '期初库存仅管理员可录入';end if;
 if p_kind='reversal' and v_role not in ('manager','admin') then raise exception '冲销需要主管审核';end if;
 select factor into v_factor from public.product_units where product_id=p_product and unit=p_unit;
 if v_factor is null then raise exception '商品单位未配置';end if;
 if p_kind='reversal' then
  if p_reference is null then raise exception '必须关联原单';end if;
  select * into v_ref from public.stock_transactions where id=p_reference;
  if not found or v_ref.kind not in ('in','out','opening') or v_ref.product_id<>p_product or exists(select 1 from public.stock_transactions where reference_id=p_reference and kind='reversal') then raise exception '原单不存在、商品不匹配或已冲销';end if;
  if p_qty<>v_ref.entered_qty or p_unit<>v_ref.unit then raise exception '冲销数量与单位必须和原单一致';end if;
  v_delta:=-v_ref.delta;
 else v_delta:=round(p_qty*v_factor,3)*case when p_kind='out' then -1 else 1 end;end if;
 insert into public.stock_balances(product_id) values(p_product) on conflict do nothing;
 select qty into v_before from public.stock_balances where product_id=p_product for update;
 if p_kind='opening' and exists(select 1 from public.stock_transactions where product_id=p_product and kind='opening') then raise exception '该商品已有期初库存';end if;
 v_after:=v_before+v_delta;if v_after<0 then raise exception '库存不足';end if;
 update public.stock_balances set qty=v_after,updated_at=now() where product_id=p_product;
 insert into public.stock_transactions(doc_no,product_id,kind,unit,entered_qty,factor,delta,before_qty,after_qty,operator_id,responsible_name,note,reference_id) values('WH-'||replace(gen_random_uuid()::text,'-',''),p_product,p_kind,p_unit,p_qty,v_factor,v_delta,v_before,v_after,auth.uid(),trim(p_responsible),coalesce(p_note,''),p_reference) returning id into v_id;
 return v_id;end$$;
create or replace function public.submit_count(p_product uuid,p_observed numeric,p_reason text) returns uuid language plpgsql security definer set search_path=public as $$declare v_qty numeric;v_id uuid;begin
 if public.my_role() is null then raise exception '账号无权限';end if;
 if p_observed is null or p_observed<0 or nullif(trim(p_reason),'') is null then raise exception '盘点数据不合法';end if;
 select qty into v_qty from public.stock_balances where product_id=p_product;
 if v_qty is null then raise exception '商品不存在';end if;
 insert into public.stock_counts(product_id,observed_qty,snapshot_qty,reason,submitted_by) values(p_product,p_observed,v_qty,trim(p_reason),auth.uid()) returning id into v_id;return v_id;end$$;
create or replace function public.review_count(p_id uuid,p_approve boolean) returns void language plpgsql security definer set search_path=public as $$declare c record;v_qty numeric;v_delta numeric;v_unit text;begin
 if not public.is_manager() then raise exception '无审核权限';end if;
 select * into c from public.stock_counts where id=p_id for update;
 if not found or c.status<>'pending' then raise exception '盘点单不存在或已审核';end if;
 if p_approve then
 select qty into v_qty from public.stock_balances where product_id=c.product_id for update;
 if v_qty<>c.snapshot_qty then raise exception '盘点后库存发生变化，请重新盘点';end if;
 select base_unit into v_unit from public.products where id=c.product_id;
 v_delta:=c.observed_qty-v_qty;
 if v_delta<>0 then insert into public.stock_transactions(doc_no,product_id,kind,unit,entered_qty,factor,delta,before_qty,after_qty,operator_id,responsible_name,note) values('WH-'||replace(gen_random_uuid()::text,'-',''),c.product_id,'count_adjust',v_unit,abs(v_delta),1,v_delta,v_qty,c.observed_qty,auth.uid(),(select display_name from public.profiles where id=c.submitted_by),'盘点调整：'||c.reason);end if;
 update public.stock_balances set qty=c.observed_qty,updated_at=now() where product_id=c.product_id;
 end if;
 update public.stock_counts set status=case when p_approve then 'approved' else 'rejected' end,reviewed_by=auth.uid(),reviewed_at=now() where id=p_id;
 end$$;
create or replace function public.set_user_role(p_user uuid,p_role text,p_active boolean) returns void language plpgsql security definer set search_path=public as $$begin if not public.is_admin() then raise exception '仅老板可操作';end if;if p_role not in ('staff','manager','admin') then raise exception '角色错误';end if;if p_user=auth.uid() and (p_role<>'admin' or not p_active) then raise exception '不能取消自己的管理员权限';end if;update public.profiles set role=p_role,active=p_active where id=p_user;if not found then raise exception '账号不存在';end if;end$$;
-- Triggers protect against accidental server-side modifications and record before/after values.
do $$declare t text;begin foreach t in array array['profiles','products','product_units','stock_balances','stock_transactions','stock_counts'] loop execute format('drop trigger if exists audit_%I on public.%I',t,t);execute format('create trigger audit_%I after insert or update or delete on public.%I for each row execute function public.audit_row()',t,t);end loop;end$$;
revoke all on function public.save_product(text,text,text,numeric,jsonb,uuid),public.move_stock(uuid,text,numeric,text,text,text,uuid),public.submit_count(uuid,numeric,text),public.review_count(uuid,boolean),public.set_user_role(uuid,text,boolean) from public,anon;
grant execute on function public.save_product(text,text,text,numeric,jsonb,uuid),public.move_stock(uuid,text,numeric,text,text,text,uuid),public.submit_count(uuid,numeric,text),public.review_count(uuid,boolean),public.set_user_role(uuid,text,boolean) to authenticated;
