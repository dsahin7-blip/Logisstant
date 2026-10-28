CREATE INDEX IF NOT EXISTS offers_customer_response_by_idx ON public.offers (customer_response_by);
CREATE INDEX IF NOT EXISTS shipment_messages_customer_id_idx ON public.shipment_messages (customer_id);
CREATE INDEX IF NOT EXISTS shipment_messages_shipment_id_idx ON public.shipment_messages (shipment_id);
CREATE INDEX IF NOT EXISTS shipment_messages_sender_id_idx ON public.shipment_messages (sender_id);

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

  IF v_offer.status <> 'Onaylandı' THEN
    RAISE EXCEPTION 'Firma henüz bu teklifi onaylamadı.' USING errcode = '22023';
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

