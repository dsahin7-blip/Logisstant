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
        (user_id, organization_id, shipment_id, entity_type, entity_id, title_key, description)
    select
        member.user_id,
        new.organization_id,
        new.id,
        'shipment',
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
