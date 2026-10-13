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
grant select, insert, update on public.shipment_financials to authenticated;

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
create policy shipment_financials_update_finance
  on public.shipment_financials for update to authenticated
  using ((select private.has_org_role(organization_id, array['owner','admin','finance']::text[])))
  with check ((select private.has_org_role(organization_id, array['owner','admin','finance']::text[])));

insert into public.shipment_financials (shipment_id, organization_id, income, expense1, expense2)
select shipment_id, organization_id,
       coalesce(nullif(internal_data->>'income','')::numeric, 0),
       coalesce(nullif(internal_data->>'expense1','')::numeric, 0),
       coalesce(nullif(internal_data->>'expense2','')::numeric, 0)
from public.shipment_private
on conflict (shipment_id) do nothing;

update public.shipment_private
set internal_data = coalesce(internal_data, '{}'::jsonb) - array['income','expense1','expense2']
where coalesce(internal_data, '{}'::jsonb) ?| array['income','expense1','expense2'];

drop policy if exists shipment_private_select_staff on public.shipment_private;
create policy shipment_private_select_operations
  on public.shipment_private for select to authenticated
  using ((select private.has_org_role(organization_id, array['owner','admin','operations']::text[])));
drop policy if exists shipment_private_insert_staff on public.shipment_private;
create policy shipment_private_insert_operations
  on public.shipment_private for insert to authenticated
  with check (
    (select private.has_org_role(organization_id, array['owner','admin','operations']::text[]))
    and exists (
      select 1 from public.shipments s
      where s.id = shipment_id and s.organization_id = shipment_private.organization_id
    )
  );
drop policy if exists shipment_private_update_staff on public.shipment_private;
create policy shipment_private_update_operations
  on public.shipment_private for update to authenticated
  using ((select private.has_org_role(organization_id, array['owner','admin','operations']::text[])))
  with check ((select private.has_org_role(organization_id, array['owner','admin','operations']::text[])));

create or replace function private.capture_shipment_financials()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  insert into public.shipment_financials (shipment_id, organization_id, income, expense1, expense2)
  values (
    new.shipment_id,
    new.organization_id,
    coalesce(nullif(new.internal_data->>'income','')::numeric, 0),
    coalesce(nullif(new.internal_data->>'expense1','')::numeric, 0),
    coalesce(nullif(new.internal_data->>'expense2','')::numeric, 0)
  )
  on conflict (shipment_id) do update
    set organization_id = excluded.organization_id,
        income = excluded.income,
        expense1 = excluded.expense1,
        expense2 = excluded.expense2,
        updated_at = now();

  update public.shipment_private
     set internal_data = coalesce(internal_data, '{}'::jsonb) - array['income','expense1','expense2']
   where shipment_id = new.shipment_id;

  return new;
end;
$function$;
revoke all on function private.capture_shipment_financials() from public, anon, authenticated;

drop trigger if exists shipment_private_capture_financials on public.shipment_private;
create trigger shipment_private_capture_financials
  after insert on public.shipment_private
  for each row execute function private.capture_shipment_financials();
