ALTER TABLE public.offers
  ADD COLUMN IF NOT EXISTS customer_response text
    CHECK (customer_response IS NULL OR customer_response IN ('accepted', 'rejected')),
  ADD COLUMN IF NOT EXISTS customer_responded_at timestamptz,
  ADD COLUMN IF NOT EXISTS customer_response_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.shipments
  ADD COLUMN IF NOT EXISTS delay_reason text NOT NULL DEFAULT ''
    CHECK (length(delay_reason) <= 1000);

ALTER TABLE public.shipment_documents
  ADD COLUMN IF NOT EXISTS uploaded_by_client boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.shipment_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  shipment_id uuid NOT NULL REFERENCES public.shipments(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  message text NOT NULL CHECK (length(btrim(message)) BETWEEN 1 AND 2000),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS shipment_messages_thread_idx
  ON public.shipment_messages (organization_id, shipment_id, created_at DESC);
ALTER TABLE public.shipment_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.shipment_messages FROM anon, authenticated;
GRANT SELECT, INSERT ON public.shipment_messages TO authenticated;

DROP POLICY IF EXISTS shipment_messages_select_accessible ON public.shipment_messages;
CREATE POLICY shipment_messages_select_accessible ON public.shipment_messages
  FOR SELECT TO authenticated
  USING (
    private.can_access_customer(organization_id, customer_id)
    AND EXISTS (
      SELECT 1 FROM public.shipments s
      WHERE s.id = shipment_messages.shipment_id
        AND s.organization_id = shipment_messages.organization_id
        AND s.customer_id = shipment_messages.customer_id
    )
  );

DROP POLICY IF EXISTS shipment_messages_insert_accessible ON public.shipment_messages;
CREATE POLICY shipment_messages_insert_accessible ON public.shipment_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    sender_id = (SELECT auth.uid())
    AND private.can_access_customer(organization_id, customer_id)
    AND EXISTS (
      SELECT 1 FROM public.shipments s
      WHERE s.id = shipment_messages.shipment_id
        AND s.organization_id = shipment_messages.organization_id
        AND s.customer_id = shipment_messages.customer_id
    )
  );

CREATE OR REPLACE FUNCTION private.respond_to_offer(p_offer_id uuid, p_response text)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_offer public.offers%rowtype;
  v_response_time timestamptz;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'Giriş yapmanız gerekiyor.' USING errcode = '28000';
  END IF;
  IF p_response IS NULL OR p_response NOT IN ('accepted', 'rejected') THEN
    RAISE EXCEPTION 'Geçersiz teklif yanıtı.' USING errcode = '22023';
  END IF;

  SELECT offer.* INTO v_offer
    FROM public.offers AS offer
   WHERE offer.id = p_offer_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Teklif bulunamadı veya erişiminiz yok.' USING errcode = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.organization_members AS member
     WHERE member.organization_id = v_offer.organization_id
       AND member.user_id = (SELECT auth.uid())
       AND member.role = 'client'
       AND member.customer_id = v_offer.customer_id
  ) THEN
    RAISE EXCEPTION 'Bu teklif için yetkiniz yok.' USING errcode = '42501';
  END IF;

  IF v_offer.status = 'Reddedildi' OR v_offer.converted_shipment_id IS NOT NULL THEN
    RAISE EXCEPTION 'Bu teklif artık yanıtlanamıyor.' USING errcode = '22023';
  END IF;
  IF v_offer.valid_until IS NOT NULL AND v_offer.valid_until < current_date THEN
    RAISE EXCEPTION 'Teklifin geçerlilik süresi dolmuş.' USING errcode = '22023';
  END IF;
  IF v_offer.customer_response IS NOT NULL THEN
    RAISE EXCEPTION 'Bu teklif için daha önce yanıt verilmiş.' USING errcode = '22023';
  END IF;

  UPDATE public.offers
     SET customer_response = p_response,
         customer_responded_at = now(),
         customer_response_by = (SELECT auth.uid())
   WHERE id = p_offer_id
   RETURNING customer_responded_at INTO v_response_time;

  INSERT INTO public.user_notifications
    (user_id, organization_id, entity_type, entity_id, title_key, description)
  SELECT member.user_id, v_offer.organization_id, 'offer', v_offer.id,
         'notifOfferResponse',
         concat(v_offer.route, ' · ', CASE WHEN p_response = 'accepted' THEN 'Müşteri teklifi kabul etti' ELSE 'Müşteri teklifi reddetti' END)
    FROM public.organization_members AS member
   WHERE member.organization_id = v_offer.organization_id
     AND member.role IN ('owner', 'admin', 'operations')
     AND member.user_id <> (SELECT auth.uid());

  RETURN v_response_time;
END;
$$;
REVOKE ALL ON FUNCTION private.respond_to_offer(uuid, text) FROM public, anon, authenticated;
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION private.respond_to_offer(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.respond_to_offer(p_offer_id uuid, p_response text)
RETURNS timestamptz
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.respond_to_offer(p_offer_id, p_response);
$$;
REVOKE ALL ON FUNCTION public.respond_to_offer(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.respond_to_offer(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION private.set_shipment_document_upload_source()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.uploaded_by_client := EXISTS (
    SELECT 1
      FROM public.organization_members AS member
     WHERE member.organization_id = NEW.organization_id
       AND member.user_id = NEW.uploaded_by
       AND member.role = 'client'
       AND EXISTS (
         SELECT 1 FROM public.shipments AS shipment
          WHERE shipment.id = NEW.shipment_id
            AND shipment.organization_id = NEW.organization_id
            AND shipment.customer_id = member.customer_id
       )
  );
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.set_shipment_document_upload_source() FROM public, anon, authenticated;
DROP TRIGGER IF EXISTS shipment_document_upload_source ON public.shipment_documents;
CREATE TRIGGER shipment_document_upload_source
  BEFORE INSERT ON public.shipment_documents
  FOR EACH ROW EXECUTE FUNCTION private.set_shipment_document_upload_source();

DROP POLICY IF EXISTS shipment_documents_insert_staff ON public.shipment_documents;
CREATE POLICY shipment_documents_insert_staff ON public.shipment_documents
  FOR INSERT TO authenticated
  WITH CHECK (
    uploaded_by = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.shipments AS shipment
       WHERE shipment.id = shipment_documents.shipment_id
         AND shipment.organization_id = shipment_documents.organization_id
         AND (
           private.has_org_role(shipment_documents.organization_id, ARRAY['owner', 'admin', 'operations']::text[])
           OR EXISTS (
             SELECT 1 FROM public.organization_members AS member
              WHERE member.organization_id = shipment_documents.organization_id
                AND member.user_id = (SELECT auth.uid())
                AND member.role = 'client'
                AND member.customer_id = shipment.customer_id
           )
         )
    )
  );

CREATE OR REPLACE FUNCTION private.can_upload_document_path(p_path text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.shipments AS shipment
     WHERE p_path ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/[^/]+$'
       AND split_part(p_path, '/', 1) = shipment.organization_id::text
       AND split_part(p_path, '/', 2) = shipment.id::text
       AND (
         private.has_org_role(shipment.organization_id, ARRAY['owner', 'admin', 'operations']::text[])
         OR EXISTS (
           SELECT 1 FROM public.organization_members AS member
            WHERE member.organization_id = shipment.organization_id
              AND member.user_id = (SELECT auth.uid())
              AND member.role = 'client'
              AND member.customer_id = shipment.customer_id
         )
       )
  );
$$;
REVOKE ALL ON FUNCTION private.can_upload_document_path(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION private.can_upload_document_path(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.record_shipment_document_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_actor_id uuid := (SELECT auth.uid());
  current_actor_name text;
  document_customer uuid;
  shipment_code text;
  target_org uuid;
  target_shipment uuid;
  document_type_value text;
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
    event_name := 'document_uploaded';

    UPDATE public.shipments AS shipment
       SET documents = jsonb_set(coalesce(shipment.documents, '{}'::jsonb), ARRAY[document_type_value], 'true'::jsonb, true),
           updated_at = now()
     WHERE shipment.id = target_shipment AND shipment.organization_id = target_org;
  ELSE
    target_org := OLD.organization_id;
    target_shipment := OLD.shipment_id;
    document_type_value := OLD.document_type;
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
       current_actor_id, current_actor_name, jsonb_build_object('document_type', document_type_value));

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
$$;
REVOKE ALL ON FUNCTION public.record_shipment_document_event() FROM public, anon, authenticated;
DROP TRIGGER IF EXISTS shipment_document_event_after_write ON public.shipment_documents;
CREATE TRIGGER shipment_document_event_after_write
  AFTER INSERT OR DELETE ON public.shipment_documents
  FOR EACH ROW EXECUTE FUNCTION public.record_shipment_document_event();

CREATE OR REPLACE FUNCTION public.record_shipment_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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

  IF jsonb_array_length(changed_fields) > 0 THEN
    INSERT INTO public.shipment_events
      (organization_id, customer_id, shipment_id, event_type, old_status, new_status, actor_id, actor_name, details)
    VALUES
      (NEW.organization_id, NEW.customer_id, NEW.id, 'shipment_updated', NULL, NEW.status, current_actor_id, current_actor_name,
       jsonb_build_object('changes', changed_fields));
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS shipment_event_on_status_change ON public.shipments;
CREATE TRIGGER shipment_event_on_status_change
  AFTER UPDATE OF status, route, cargo, incoterm, eta, delay_reason ON public.shipments
  FOR EACH ROW EXECUTE FUNCTION public.record_shipment_event();

CREATE OR REPLACE FUNCTION public.create_shipment_status_notifications()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status
     AND NEW.eta IS NOT DISTINCT FROM OLD.eta
     AND NEW.delay_reason IS NOT DISTINCT FROM OLD.delay_reason THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.user_notifications
    (user_id, organization_id, shipment_id, entity_type, entity_id, title_key, description)
  SELECT member.user_id, NEW.organization_id, NEW.id, 'shipment', NEW.id,
         'notifShipmentUpdate',
         concat(
           NEW.code, ' · ', NEW.status,
           CASE WHEN NEW.eta IS DISTINCT FROM OLD.eta AND NEW.eta IS NOT NULL
                THEN concat(' · Tahmini teslim: ', to_char(NEW.eta, 'DD.MM.YYYY')) ELSE '' END,
           CASE WHEN nullif(btrim(NEW.delay_reason), '') IS NOT NULL
                THEN concat(' · ', left(NEW.delay_reason, 160)) ELSE '' END
         )
    FROM public.organization_members AS member
   WHERE member.organization_id = NEW.organization_id
     AND (member.role <> 'client' OR member.customer_id = NEW.customer_id);

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.create_shipment_status_notifications() FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION private.notify_shipment_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sender_role text;
  v_shipment_code text;
BEGIN
  SELECT member.role INTO v_sender_role
    FROM public.organization_members AS member
   WHERE member.organization_id = NEW.organization_id
     AND member.user_id = NEW.sender_id;

  SELECT shipment.code INTO v_shipment_code
    FROM public.shipments AS shipment
   WHERE shipment.id = NEW.shipment_id AND shipment.organization_id = NEW.organization_id;

  INSERT INTO public.user_notifications
    (user_id, organization_id, shipment_id, entity_type, entity_id, title_key, description)
  SELECT member.user_id, NEW.organization_id, NEW.shipment_id, 'shipment', NEW.shipment_id,
         'notifShipmentMessage',
         concat(coalesce(v_shipment_code, ''), ' · ', left(NEW.message, 100))
    FROM public.organization_members AS member
   WHERE member.organization_id = NEW.organization_id
     AND member.user_id <> NEW.sender_id
     AND (
       (v_sender_role = 'client' AND member.role IN ('owner', 'admin', 'operations', 'finance'))
       OR (v_sender_role <> 'client' AND member.role = 'client' AND member.customer_id = NEW.customer_id)
     );

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.notify_shipment_message() FROM public, anon, authenticated;
DROP TRIGGER IF EXISTS shipment_message_notification ON public.shipment_messages;
CREATE TRIGGER shipment_message_notification
  AFTER INSERT ON public.shipment_messages
  FOR EACH ROW EXECUTE FUNCTION private.notify_shipment_message();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime'
       AND schemaname = 'public'
       AND tablename = 'shipment_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.shipment_messages;
  END IF;
END
$$;
