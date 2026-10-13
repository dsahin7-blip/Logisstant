revoke update on public.organizations from authenticated;
grant update (name, contact_email, phone, website, address)
  on public.organizations to authenticated;
