create index user_notifications_organization_id_idx
    on public.user_notifications (organization_id);

create index user_notifications_shipment_id_idx
    on public.user_notifications (shipment_id);