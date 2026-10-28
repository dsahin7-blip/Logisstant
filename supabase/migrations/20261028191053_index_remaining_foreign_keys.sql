CREATE INDEX IF NOT EXISTS shipment_financials_shipment_org_fk_idx
  ON public.shipment_financials (shipment_id, organization_id);
CREATE INDEX IF NOT EXISTS support_requests_user_id_fk_idx
  ON public.support_requests (user_id);
