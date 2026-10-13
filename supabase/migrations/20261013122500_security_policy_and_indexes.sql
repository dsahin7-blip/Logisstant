-- Merge equivalent shipment document delete rules and index notification preference membership lookups.

create index if not exists notification_preferences_user_id_idx
  on public.notification_preferences (user_id);

drop policy if exists shipment_documents_delete_admin
  on public.shipment_documents;

drop policy if exists shipment_documents_delete_uploader
  on public.shipment_documents;

create policy shipment_documents_delete_authorized
  on public.shipment_documents
  for delete
  to authenticated
  using (
    private.has_org_role(organization_id, array['owner', 'admin'])
    or (
      uploaded_by = (select auth.uid())
      and private.has_org_role(organization_id, array['operations'])
    )
  );
