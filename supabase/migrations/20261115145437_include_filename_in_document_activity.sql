CREATE OR REPLACE FUNCTION public.record_shipment_document_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  current_actor_id uuid := (SELECT auth.uid());
  current_actor_name text;
  document_customer uuid;
  shipment_code text;
  target_org uuid;
  target_shipment uuid;
  document_type_value text;
  document_file_name text;
  event_name text;
BEGIN
  SELECT nullif(btrim(profile.full_name), '')
    INTO current_actor_name
    FROM public.profiles AS profile
   WHERE profile.id = current_actor_id;

  IF TG_OP = 'INSERT' THEN
    target_org := NEW.organization_id;
    target_shipment := NEW.shipment_id;
    document_type_value := NEW.document_type;
    document_file_name := NEW.file_name;
    event_name := 'document_uploaded';

    UPDATE public.shipments AS shipment
       SET documents = jsonb_set(coalesce(shipment.documents, '{}'::jsonb), ARRAY[document_type_value], 'true'::jsonb, true),
           updated_at = now()
     WHERE shipment.id = target_shipment AND shipment.organization_id = target_org;
  ELSE
    target_org := OLD.organization_id;
    target_shipment := OLD.shipment_id;
    document_type_value := OLD.document_type;
    document_file_name := OLD.file_name;
    event_name := 'document_deleted';

    UPDATE public.shipments AS shipment
       SET documents = jsonb_set(
             coalesce(shipment.documents, '{}'::jsonb),
             ARRAY[document_type_value],
             to_jsonb(EXISTS (
               SELECT 1 FROM public.shipment_documents AS remaining
                WHERE remaining.shipment_id = target_shipment
                  AND remaining.organization_id = target_org
                  AND remaining.document_type = document_type_value
             )),
             true
           ),
           updated_at = now()
     WHERE shipment.id = target_shipment AND shipment.organization_id = target_org;
  END IF;

  SELECT shipment.customer_id, shipment.code
    INTO document_customer, shipment_code
    FROM public.shipments AS shipment
   WHERE shipment.id = target_shipment AND shipment.organization_id = target_org;

  IF document_customer IS NOT NULL THEN
    INSERT INTO public.shipment_events
      (organization_id, customer_id, shipment_id, event_type, old_status, new_status, actor_id, actor_name, details)
    VALUES
      (target_org, document_customer, target_shipment, event_name, NULL, document_type_value,
       current_actor_id, current_actor_name, jsonb_build_object('document_type', document_type_value, 'file_name', document_file_name));

    IF TG_OP = 'INSERT' AND NEW.uploaded_by_client THEN
      INSERT INTO public.user_notifications
        (user_id, organization_id, shipment_id, entity_type, entity_id, title_key, description)
      SELECT member.user_id, target_org, target_shipment, 'shipment', target_shipment,
             'notifClientDocumentUploaded',
             concat(shipment_code, ' · ', document_type_value)
        FROM public.organization_members AS member
       WHERE member.organization_id = target_org
         AND member.role IN ('owner', 'admin', 'operations', 'finance')
         AND member.user_id <> current_actor_id;
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;