alter table public.user_notifications
    add column entity_type text,
    add column entity_id uuid,
    add constraint user_notifications_entity_reference_check
        check (
            (entity_type is null and entity_id is null)
            or (entity_type in ('offer', 'shipment') and entity_id is not null)
        );