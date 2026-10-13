create table public.shipment_events (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid not null references public.organizations(id) on delete cascade,
    customer_id uuid not null,
    shipment_id uuid not null,
    event_type text not null check (event_type in ('shipment_created', 'status_changed')),
    old_status text,
    new_status text not null,
    actor_id uuid,
    actor_name text,
    created_at timestamptz not null default now(),
    constraint shipment_events_customer_org_fk
        foreign key (customer_id, organization_id)
        references public.customers(id, organization_id) on delete cascade,
    constraint shipment_events_shipment_org_fk
        foreign key (shipment_id, organization_id)
        references public.shipments(id, organization_id) on delete cascade
);

create index shipment_events_shipment_org_created_idx
    on public.shipment_events (shipment_id, organization_id, created_at desc);
create index shipment_events_customer_org_idx
    on public.shipment_events (customer_id, organization_id);
create index shipment_events_organization_id_idx
    on public.shipment_events (organization_id);

alter table public.shipment_events enable row level security;
revoke all on public.shipment_events from anon, authenticated;
grant select on public.shipment_events to authenticated;

create policy "Members can read shipment events they can access"
    on public.shipment_events
    for select
    to authenticated
    using ((select private.can_access_customer(organization_id, customer_id)));

create or replace function public.record_shipment_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_actor_id uuid := (select auth.uid());
    current_actor_name text;
begin
    select nullif(btrim(profile.full_name), '')
      into current_actor_name
      from public.profiles as profile
     where profile.id = current_actor_id;

    if tg_op = 'INSERT' then
        insert into public.shipment_events
            (organization_id, customer_id, shipment_id, event_type, old_status, new_status, actor_id, actor_name)
        values
            (new.organization_id, new.customer_id, new.id, 'shipment_created', null, new.status, current_actor_id, current_actor_name);
        return new;
    end if;

    if new.status is distinct from old.status then
        insert into public.shipment_events
            (organization_id, customer_id, shipment_id, event_type, old_status, new_status, actor_id, actor_name)
        values
            (new.organization_id, new.customer_id, new.id, 'status_changed', old.status, new.status, current_actor_id, current_actor_name);
    end if;

    return new;
end;
$$;

revoke all on function public.record_shipment_event() from public, anon, authenticated;

create trigger shipment_event_on_create
    after insert on public.shipments
    for each row
    execute function public.record_shipment_event();

create trigger shipment_event_on_status_change
    after update of status on public.shipments
    for each row
    execute function public.record_shipment_event();