ALTER TABLE public.organizations ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE public.organizations DROP CONSTRAINT IF EXISTS organizations_created_by_fkey;
ALTER TABLE public.organizations ADD CONSTRAINT organizations_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.offers ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE public.offers DROP CONSTRAINT IF EXISTS offers_created_by_fkey;
ALTER TABLE public.offers ADD CONSTRAINT offers_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.shipments ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE public.shipments DROP CONSTRAINT IF EXISTS shipments_created_by_fkey;
ALTER TABLE public.shipments ADD CONSTRAINT shipments_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.shipment_documents ALTER COLUMN uploaded_by DROP NOT NULL;
ALTER TABLE public.shipment_documents DROP CONSTRAINT IF EXISTS shipment_documents_uploaded_by_fkey;
ALTER TABLE public.shipment_documents ADD CONSTRAINT shipment_documents_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES auth.users(id) ON DELETE SET NULL;