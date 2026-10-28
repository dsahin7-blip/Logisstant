alter table public.shipment_documents
    add column deletion_pending boolean not null default false;

grant update (deletion_pending)
on public.shipment_documents to authenticated;

create policy "shipment_documents_update_delete_state"
on public.shipment_documents
for update
to authenticated
using (
    private.has_org_role(organization_id, array['owner', 'admin']::text[])
    or (
        uploaded_by = (select auth.uid())
        and private.has_org_role(organization_id, array['operations']::text[])
    )
)
with check (
    private.has_org_role(organization_id, array['owner', 'admin']::text[])
    or (
        uploaded_by = (select auth.uid())
        and private.has_org_role(organization_id, array['operations']::text[])
    )
);
