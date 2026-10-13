create table if not exists public.notification_preferences (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email_delivery_alerts boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id),
  constraint notification_preferences_member_fk
    foreign key (organization_id, user_id)
    references public.organization_members(organization_id, user_id)
    on delete cascade
);
alter table public.notification_preferences enable row level security;
drop policy if exists "Users manage own notification preferences" on public.notification_preferences;
create policy "Users manage own notification preferences"
on public.notification_preferences
for all to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.organization_members m
    where m.organization_id = notification_preferences.organization_id
      and m.user_id = (select auth.uid())
  )
)
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.organization_members m
    where m.organization_id = notification_preferences.organization_id
      and m.user_id = (select auth.uid())
  )
);
create table if not exists public.email_delivery_alert_log (
  organization_id uuid not null,
  user_id uuid not null,
  shipment_id uuid not null,
  alert_type text not null check (alert_type in ('upcoming', 'overdue')),
  eta_date date not null,
  sent_at timestamptz not null default now(),
  primary key (user_id, shipment_id, alert_type, eta_date)
);
alter table public.email_delivery_alert_log enable row level security;
