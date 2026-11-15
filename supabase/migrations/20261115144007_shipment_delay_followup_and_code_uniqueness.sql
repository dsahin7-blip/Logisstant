ALTER TABLE public.shipments
  ADD COLUMN delay_owner text NOT NULL DEFAULT '' CHECK (length(delay_owner) <= 120),
  ADD COLUMN delay_follow_up_on date;

CREATE UNIQUE INDEX shipments_organization_code_normalized_uidx
  ON public.shipments (organization_id, upper(btrim(code)));

CREATE OR REPLACE FUNCTION public.record_shipment_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  current_actor_id uuid := (SELECT auth.uid());
  current_actor_name text;
  changed_fields jsonb := '[]'::jsonb;
BEGIN
  SELECT nullif(btrim(profile.full_name), '')
    INTO current_actor_name
    FROM public.profiles AS profile
   WHERE profile.id = current_actor_id;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.shipment_events
      (organization_id, customer_id, shipment_id, event_type, old_status, new_status, actor_id, actor_name, details)
    VALUES (NEW.organization_id, NEW.customer_id, NEW.id, 'shipment_created', NULL, NEW.status, current_actor_id, current_actor_name, '{}'::jsonb);
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.shipment_events
      (organization_id, customer_id, shipment_id, event_type, old_status, new_status, actor_id, actor_name, details)
    VALUES (NEW.organization_id, NEW.customer_id, NEW.id, 'status_changed', OLD.status, NEW.status, current_actor_id, current_actor_name, '{}'::jsonb);
  END IF;
  IF NEW.route IS DISTINCT FROM OLD.route THEN
    changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field', 'route', 'old', OLD.route, 'new', NEW.route));
  END IF;
  IF NEW.cargo IS DISTINCT FROM OLD.cargo THEN
    changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field', 'cargo', 'old', OLD.cargo, 'new', NEW.cargo));
  END IF;
  IF NEW.incoterm IS DISTINCT FROM OLD.incoterm THEN
    changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field', 'incoterm', 'old', OLD.incoterm, 'new', NEW.incoterm));
  END IF;
  IF NEW.eta IS DISTINCT FROM OLD.eta THEN
    changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field', 'eta', 'old', OLD.eta, 'new', NEW.eta));
  END IF;
  IF NEW.delay_reason IS DISTINCT FROM OLD.delay_reason THEN
    changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field', 'delay_reason', 'old', OLD.delay_reason, 'new', NEW.delay_reason));
  END IF;
  IF NEW.delay_owner IS DISTINCT FROM OLD.delay_owner THEN
    changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field', 'delay_owner', 'old', OLD.delay_owner, 'new', NEW.delay_owner));
  END IF;
  IF NEW.delay_follow_up_on IS DISTINCT FROM OLD.delay_follow_up_on THEN
    changed_fields := changed_fields || jsonb_build_array(jsonb_build_object('field', 'delay_follow_up_on', 'old', OLD.delay_follow_up_on, 'new', NEW.delay_follow_up_on));
  END IF;

  IF jsonb_array_length(changed_fields) > 0 THEN
    INSERT INTO public.shipment_events
      (organization_id, customer_id, shipment_id, event_type, old_status, new_status, actor_id, actor_name, details)
    VALUES
      (NEW.organization_id, NEW.customer_id, NEW.id, 'shipment_updated', NULL, NEW.status, current_actor_id, current_actor_name,
       jsonb_build_object('changes', changed_fields));
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER shipment_event_on_status_change ON public.shipments;
CREATE TRIGGER shipment_event_on_status_change
  AFTER UPDATE OF status, route, cargo, incoterm, eta, delay_reason, delay_owner, delay_follow_up_on
  ON public.shipments
  FOR EACH ROW
  EXECUTE FUNCTION public.record_shipment_event();