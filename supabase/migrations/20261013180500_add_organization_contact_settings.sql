alter table public.organizations
  add column if not exists contact_email text not null default '' check (length(contact_email) <= 254),
  add column if not exists phone text not null default '' check (length(phone) <= 40),
  add column if not exists website text not null default '' check (length(website) <= 255),
  add column if not exists address text not null default '' check (length(address) <= 500);

drop policy if exists organizations_update_owner_admin on public.organizations;
create policy organizations_update_owner_admin
  on public.organizations
  for update
  to authenticated
  using ((select private.has_org_role(id, array['owner','admin']::text[])))
  with check ((select private.has_org_role(id, array['owner','admin']::text[])));
