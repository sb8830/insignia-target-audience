-- =============================================================================
-- Insignia Platform — Checkbox-Driven Access Control Migration (v4)
-- Run AFTER supabase_schema.sql, supabase_schema_v2_saas.sql, and
-- supabase_schema_v3_leads.sql.
--
-- Replaces "assign a named role" as the only way to grant access with a
-- direct, per-section permission-checkbox model: Access Control's
-- "Customize Access" screen writes straight into user_product_access
-- (user_id, section_code, permission_code) rather than requiring every
-- grant to match a predefined role's exact bundle.
--
-- Named roles (roles / role_permissions, from v2) are NOT removed — they
-- remain available as one-click presets that populate the checkboxes
-- (services.rbac_service.assign_role now expands a role's permissions
-- into rows here rather than joining through user_product_roles at
-- check-time). This keeps a single source of truth for "what can this
-- user actually do", which is this table.
-- =============================================================================

create extension if not exists "uuid-ossp";

create table if not exists user_product_access (
    id                uuid primary key default uuid_generate_v4(),
    user_id           uuid not null references application_users(id) on delete cascade,
    product_code      text not null,   -- section code: 'insignia-audience' | 'leads' | 'platform-admin'
    permission_code   text not null,   -- 'view' | 'create' | 'edit' | 'delete' | 'import' | 'export' |
                                        -- 'manage_database' | 'manage_users' | 'manage_products'
    granted_by        text,
    granted_at        timestamptz not null default now(),
    unique (user_id, product_code, permission_code)
);

create index if not exists idx_upa_user_product on user_product_access (user_id, product_code);
create index if not exists idx_upa_product on user_product_access (product_code);

alter table user_product_access enable row level security;
-- No public policies: accessed only via the backend service-role key.

-- =============================================================================
-- One-time, best-effort backfill: expand every existing user_product_roles
-- assignment into the equivalent checked boxes here, so nobody's access
-- silently changes the moment this migration runs. Safe to re-run —
-- ON CONFLICT DO NOTHING makes it idempotent.
-- =============================================================================
insert into user_product_access (user_id, product_code, permission_code, granted_by)
select distinct upr.user_id, p.code, perm.code, 'migration_v4_backfill'
from user_product_roles upr
join products p on p.id = upr.product_id
join role_permissions rp on rp.role_id = upr.role_id
join permissions perm on perm.id = rp.permission_id
on conflict (user_id, product_code, permission_code) do nothing;

-- Any user who previously reached Platform Administration pages via
-- 'manage_database' / 'manage_users' granted on the insignia-audience
-- product (the old default scope) gets the equivalent grant on the new
-- dedicated 'platform-admin' section, so admins aren't locked out.
insert into user_product_access (user_id, product_code, permission_code, granted_by)
select distinct user_id, 'platform-admin', permission_code, 'migration_v4_backfill'
from user_product_access
where product_code = 'insignia-audience'
  and permission_code in ('manage_database', 'manage_users', 'manage_products')
on conflict (user_id, product_code, permission_code) do nothing;

insert into user_product_access (user_id, product_code, permission_code, granted_by)
select distinct user_id, 'platform-admin', 'view', 'migration_v4_backfill'
from user_product_access
where product_code = 'platform-admin'
on conflict (user_id, product_code, permission_code) do nothing;

-- Leads previously shared the insignia-audience scope; carry forward view/
-- import/export/create/edit/delete grants so existing Leads access survives.
insert into user_product_access (user_id, product_code, permission_code, granted_by)
select distinct user_id, 'leads', permission_code, 'migration_v4_backfill'
from user_product_access
where product_code = 'insignia-audience'
  and permission_code in ('view', 'create', 'edit', 'delete', 'import', 'export')
on conflict (user_id, product_code, permission_code) do nothing;
