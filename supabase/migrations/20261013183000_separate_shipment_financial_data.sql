create table public.shipment_financials (
  shipment_id uuid not null,
  organization_id uuid not null,
  income numeric not null default 0 check (income >= 0),
  expense1 numeric not null default 0 check (expense1 >= 0),
  expense2 numeric not null default 0 check (expense2 >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (shipment_id),
  constraint shipment_financials_shipment_org_fkey
    foreign key (shipment_id, organization_id)
    references public.shipments(id, organization_id) on delete cascade
);
create index shipment_financials_organization_id_idx
  on public.shipment_financials(organization_id, shipment_id);

alter table public.shipment_financials enable row level security;
revoke all on public.shipment_financials from anon, authenticated;
grant select, insert on public.shipment_financials to authenticated;

create policy shipment_financials_select_finance
  on public.shipment_financials for select to authenticated
  using ((select private.has_org_role(organization_id, array['owner','admin','finance']::text[])));
create policy shipment_financials_insert_staff
  on public.shipment_financials for insert to authenticated
  with check (
    (select private.has_org_role(organization_id, array['owner','admin','operations','finance']::text[]))
    and exists (
      select 1 from public.shipments s
      where s.id = shipment_id and s.organization_id = shipment_financials.organization_id
    )
  );

insert into public.shipment_financials (shipment_id, organization_id, income, expense1, expense2)
select shipment_id, organization_id,
       coalesce(nullif(internal_data->>'income','')::numeric, 0),
       coalesce(nullif(internal_data->>'expense1','')::numeric, 0),
       coalesce(nullif(internal_data->>'expense2','')::numeric, 0)
from public.shipment_private
on conflict (shipment_id) do nothing;
