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
revoke update on public.shipment_private from authenticated;

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
  on conflict (shipment_id) do nothing;

  new.internal_data := coalesce(new.internal_data, '{}'::jsonb) - array['income','expense1','expense2'];
  return new;
end;
$function$;
revoke all on function private.capture_shipment_financials() from public, anon, authenticated;

drop trigger if exists shipment_private_capture_financials on public.shipment_private;
create trigger shipment_private_capture_financials
  before insert on public.shipment_private
  for each row execute function private.capture_shipment_financials();
