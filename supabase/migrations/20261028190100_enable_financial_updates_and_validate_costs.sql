alter table public.shipment_financials
    add constraint shipment_financials_income_nonnegative check (income >= 0),
    add constraint shipment_financials_expense1_nonnegative check (expense1 >= 0),
    add constraint shipment_financials_expense2_nonnegative check (expense2 >= 0);

grant update (income, expense1, expense2)
on public.shipment_financials to authenticated;

create policy "shipment_financials_update_finance"
on public.shipment_financials
for update
to authenticated
using (
    (select private.has_org_role(
        organization_id,
        array['owner', 'admin', 'finance']::text[]
    ))
)
with check (
    (select private.has_org_role(
        organization_id,
        array['owner', 'admin', 'finance']::text[]
    ))
    and exists (
        select 1
        from public.shipments s
        where s.id = shipment_financials.shipment_id
          and s.organization_id = shipment_financials.organization_id
    )
);
