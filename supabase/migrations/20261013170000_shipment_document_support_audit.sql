alter table public.shipment_events add column if not exists details jsonb not null default '{}'::jsonb;
alter table public.shipment_events drop constraint if exists shipment_events_event_type_check;
alter table public.shipment_events add constraint shipment_events_event_type_check check (event_type in ('shipment_created','status_changed','shipment_updated','document_uploaded','document_deleted'));

create or replace function public.record_shipment_event()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  current_actor_id uuid := (select auth.uid());
  current_actor_name text;
  changed_fields jsonb := '[]'::jsonb;
begin
  select nullif(btrim(profile.full_name), '') into current_actor_name from public.profiles profile where profile.id = current_actor_id;
  if tg_op = 'INSERT' then
    insert into public.shipment_events (organization_id,customer_id,shipment_id,event_type,old_status,new_status,actor_id,actor_name,details)
    values (new.organization_id,new.customer_id,new.id,'shipment_created',null,new.status,current_actor_id,current_actor_name,'{}'::jsonb);
    return new;
  end if;
  if new.status is distinct from old.status then
    insert into public.shipment_events (organization_id,customer_id,shipment_id,event_type,old_status,new_status,actor_id,actor_name,details)
    values (new.organization_id,new.customer_id,new.id,'status_changed',old.status,new.status,current_actor_id,current_actor_name,'{}'::jsonb);
  end if;
  if new.route is distinct from old.route then changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field','route','old',old.route,'new',new.route)); end if;
  if new.cargo is distinct from old.cargo then changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field','cargo','old',old.cargo,'new',new.cargo)); end if;
  if new.incoterm is distinct from old.incoterm then changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field','incoterm','old',old.incoterm,'new',new.incoterm)); end if;
  if new.eta is distinct from old.eta then changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field','eta','old',old.eta,'new',new.eta)); end if;
  if jsonb_array_length(changed_fields) > 0 then
    insert into public.shipment_events (organization_id,customer_id,shipment_id,event_type,old_status,new_status,actor_id,actor_name,details)
    values (new.organization_id,new.customer_id,new.id,'shipment_updated',null,new.status,current_actor_id,current_actor_name,jsonb_build_object('changes',changed_fields));
  end if;
  return new;
end;
$$;
drop trigger if exists shipment_event_on_status_change on public.shipments;
create trigger shipment_event_on_status_change after update of status,route,cargo,incoterm,eta on public.shipments for each row execute function public.record_shipment_event();

create or replace function private.can_upload_document_path(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.shipments s
    where p_path ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/[^/]+$'
      and split_part(p_path,'/',1)=s.organization_id::text and split_part(p_path,'/',2)=s.id::text
      and private.has_org_role(s.organization_id,array['owner','admin','operations']::text[]));
$$;
create or replace function private.can_delete_document_path(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.shipment_documents d where d.storage_path=p_path
    and (private.has_org_role(d.organization_id,array['owner','admin']::text[])
      or (d.uploaded_by=(select auth.uid()) and private.has_org_role(d.organization_id,array['operations']::text[]))));
$$;
revoke all on function private.can_delete_document_path(text) from public,anon;
grant execute on function private.can_delete_document_path(text) to authenticated;
drop policy if exists shipment_document_files_delete on storage.objects;
create policy shipment_document_files_delete on storage.objects for delete to authenticated
  using (bucket_id='shipment-documents' and (select private.can_delete_document_path(name)));

create or replace function public.record_shipment_document_event()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  current_actor_id uuid := (select auth.uid());
  current_actor_name text;
  document_org uuid;
  document_shipment uuid;
  document_customer uuid;
  document_type_value text;
  event_name text;
begin
  select nullif(btrim(profile.full_name),'') into current_actor_name from public.profiles profile where profile.id=current_actor_id;
  if tg_op='INSERT' then
    document_org:=new.organization_id; document_shipment:=new.shipment_id; document_type_value:=new.document_type; event_name:='document_uploaded';
    update public.shipments s set documents=jsonb_set(coalesce(s.documents,'{}'::jsonb),array[document_type_value],'true'::jsonb,true),updated_at=now()
      where s.id=document_shipment and s.organization_id=document_org;
  else
    document_org:=old.organization_id; document_shipment:=old.shipment_id; document_type_value:=old.document_type; event_name:='document_deleted';
    update public.shipments s set documents=jsonb_set(coalesce(s.documents,'{}'::jsonb),array[document_type_value],
      to_jsonb(exists (select 1 from public.shipment_documents remaining where remaining.shipment_id=document_shipment
        and remaining.organization_id=document_org and remaining.document_type=document_type_value)),true),updated_at=now()
      where s.id=document_shipment and s.organization_id=document_org;
  end if;
  select s.customer_id into document_customer from public.shipments s where s.id=document_shipment and s.organization_id=document_org;
  if document_customer is not null then
    insert into public.shipment_events (organization_id,customer_id,shipment_id,event_type,old_status,new_status,actor_id,actor_name,details)
    values (document_org,document_customer,document_shipment,event_name,null,document_type_value,current_actor_id,current_actor_name,jsonb_build_object('document_type',document_type_value));
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.record_shipment_document_event() from public,anon,authenticated;
drop trigger if exists shipment_document_event_after_write on public.shipment_documents;
create trigger shipment_document_event_after_write after insert or delete on public.shipment_documents for each row execute function public.record_shipment_document_event();

create table public.support_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('bug','documents','account','other')),
  message text not null check (length(btrim(message)) between 10 and 2000),
  error_code text check (error_code is null or length(error_code)<=80),
  page text not null default '' check (length(page)<=40),
  created_at timestamptz not null default now()
);
create index support_requests_org_created_idx on public.support_requests(organization_id,created_at desc);
alter table public.support_requests enable row level security;
revoke all on public.support_requests from anon,authenticated;
grant select,insert on public.support_requests to authenticated;
create policy support_requests_insert_member on public.support_requests for insert to authenticated
  with check (user_id=(select auth.uid()) and (select private.has_org_role(organization_id,array['owner','admin','operations','finance','client']::text[])));
create policy support_requests_select_requester_or_admin on public.support_requests for select to authenticated
  using (user_id=(select auth.uid()) or (select private.has_org_role(organization_id,array['owner','admin']::text[])));
revoke all privileges on table public.notification_preferences from anon;
revoke all privileges on table public.email_delivery_alert_log from anon,authenticated;
revoke references,trigger,truncate on all tables in schema public from anon,authenticated;
