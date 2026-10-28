grant insert (user_id, organization_id, title_key, description, entity_type, entity_id)
on public.user_notifications to authenticated;

create policy "Users can create their own scoped notifications"
on public.user_notifications
for insert
to authenticated
with check (
    user_id = (select auth.uid())
    and (select private.has_org_role(
        organization_id,
        array['owner', 'admin', 'operations', 'finance', 'client']::text[]
    ))
    and (
        (entity_type is null and entity_id is null)
        or (
            entity_type = 'shipment'
            and exists (
                select 1
                from public.shipments s
                where s.id = user_notifications.entity_id
                  and s.organization_id = user_notifications.organization_id
                  and (select private.can_access_customer(s.organization_id, s.customer_id))
            )
        )
        or (
            entity_type = 'offer'
            and exists (
                select 1
                from public.offers o
                where o.id = user_notifications.entity_id
                  and o.organization_id = user_notifications.organization_id
                  and (select private.can_access_customer(o.organization_id, o.customer_id))
            )
        )
    )
);
