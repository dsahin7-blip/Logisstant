drop policy if exists shipment_financials_insert_staff on public.shipment_financials;
drop policy if exists shipment_financials_insert_finance on public.shipment_financials;

create policy shipment_financials_insert_finance
  on public.shipment_financials for insert to authenticated
  with check (
    (select private.has_org_role(organization_id, array['owner','admin','finance']::text[]))
    and exists (
      select 1 from public.shipments s
      where s.id = shipment_id and s.organization_id = shipment_financials.organization_id
    )
  );