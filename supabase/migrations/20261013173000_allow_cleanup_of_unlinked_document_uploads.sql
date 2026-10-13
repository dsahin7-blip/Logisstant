create or replace function private.can_delete_document_path(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.shipments s
     where p_path ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/[^/]+$'
       and split_part(p_path,'/',1)=s.organization_id::text
       and split_part(p_path,'/',2)=s.id::text
       and (
         (not exists (select 1 from public.shipment_documents d where d.storage_path=p_path)
          and private.has_org_role(s.organization_id,array['owner','admin','operations']::text[]))
         or exists (select 1 from public.shipment_documents d
          where d.storage_path=p_path and d.shipment_id=s.id and d.organization_id=s.organization_id
            and (private.has_org_role(d.organization_id,array['owner','admin']::text[])
              or (d.uploaded_by=(select auth.uid()) and private.has_org_role(d.organization_id,array['operations']::text[]))))
       )
  );
$$;
revoke all on function private.can_delete_document_path(text) from public,anon;
grant execute on function private.can_delete_document_path(text) to authenticated;