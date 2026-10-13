create table public.user_notifications (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    organization_id uuid not null references public.organizations(id) on delete cascade,
    shipment_id uuid references public.shipments(id) on delete cascade,
    title_key text not null,
    description text not null default '',
    is_read boolean not null default false,
    created_at timestamptz not null default now()
);

create index user_notifications_user_org_created_idx
    on public.user_notifications (user_id, organization_id, created_at desc);

alter table public.user_notifications enable row level security;
revoke all on public.user_notifications from anon, authenticated;
grant select on public.user_notifications to authenticated;
grant update (is_read) on public.user_notifications to authenticated;

create policy "Users can read their own notifications"
    on public.user_notifications
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

create policy "Users can mark their own notifications as read"
    on public.user_notifications
    for update
    to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

create or replace function public.create_shipment_status_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.status is not distinct from old.status then
        return new;
    end if;

    insert into public.user_notifications
        (user_id, organization_id, shipment_id, title_key, description)
    select
        member.user_id,
        new.organization_id,
        new.id,
        'notifShipmentUpdate',
        concat(new.code, ' · ', new.status)
    from public.organization_members as member
    where member.organization_id = new.organization_id
      and (
          member.role <> 'client'
          or member.customer_id = new.customer_id
      );

    return new;
end;
$$;

revoke all on function public.create_shipment_status_notifications() from public, anon, authenticated;

create trigger shipment_status_notification_trigger
    after update of status on public.shipments
    for each row
    execute function public.create_shipment_status_notifications();