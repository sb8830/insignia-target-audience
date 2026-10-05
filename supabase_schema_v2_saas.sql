-- =============================================================================
-- Insignia Platform — SaaS Core Migration (v2)
-- Run AFTER supabase_schema.sql. Adds: product registry, RBAC
-- (roles/permissions/user-product-roles), and a full audit log so this
-- single Supabase database can host "Insignia Audience" as its first
-- product and additional products later without any schema rework.
-- =============================================================================

create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;

-- =============================================================================
-- 1. Product registry
-- Every product built on this platform registers one row here. All
-- product-owned tables carry a product_code column pointing at this table
-- so a single shared database can serve many products cleanly.
-- =============================================================================
create table if not exists products (
    id            uuid primary key default uuid_generate_v4(),
    code          text not null unique,
    name          text not null,
    description   text,
    icon          text default 'ti-apps',
    is_active     boolean not null default true,
    sort_order    integer default 0,
    created_at    timestamptz not null default now()
);

insert into products (code, name, description, icon, sort_order)
values ('insignia-audience', 'Insignia Audience Count', 'Identify fully paid Power TI students eligible for Insignia outreach.', 'ti-target-arrow', 1)
on conflict (code) do nothing;

-- =============================================================================
-- 2. Permissions (fixed action vocabulary, reused by every product)
-- =============================================================================
create table if not exists permissions (
    id            uuid primary key default uuid_generate_v4(),
    code          text not null unique,
    description   text
);

insert into permissions (code, description) values
    ('view',             'View records and reports'),
    ('create',           'Create new records'),
    ('edit',             'Edit existing records'),
    ('delete',           'Delete or deactivate records'),
    ('import',           'Upload / import data files'),
    ('export',           'Download / export data'),
    ('manage_database',  'Direct database record management (admin panel)'),
    ('manage_users',     'Create users and assign roles'),
    ('manage_products',  'Enable/disable products and platform settings')
on conflict (code) do nothing;

-- =============================================================================
-- 3. Roles (bundles of permissions)
-- =============================================================================
create table if not exists roles (
    id            uuid primary key default uuid_generate_v4(),
    code          text not null unique,
    name          text not null,
    description   text,
    is_system     boolean not null default false,
    created_at    timestamptz not null default now()
);

insert into roles (code, name, description, is_system) values
    ('super_admin', 'Super Admin', 'Full platform access across every product and the admin panel.', true),
    ('admin',       'Admin',       'Full access within assigned products, including database management.', true),
    ('operator',    'Operator',    'Create, edit, import, and export within assigned products.', true),
    ('viewer',      'Viewer',      'Read-only access within assigned products.', true)
on conflict (code) do nothing;

create table if not exists role_permissions (
    role_id        uuid not null references roles(id) on delete cascade,
    permission_id  uuid not null references permissions(id) on delete cascade,
    primary key (role_id, permission_id)
);

insert into role_permissions (role_id, permission_id)
select r.id, p.id from roles r cross join permissions p where r.code = 'super_admin'
on conflict do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id from roles r cross join permissions p
where r.code = 'admin' and p.code in ('view','create','edit','delete','import','export','manage_database','manage_users')
on conflict do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id from roles r cross join permissions p
where r.code = 'operator' and p.code in ('view','create','edit','import','export')
on conflict do nothing;

insert into role_permissions (role_id, permission_id)
select r.id, p.id from roles r cross join permissions p
where r.code = 'viewer' and p.code in ('view','export')
on conflict do nothing;

-- =============================================================================
-- 4. application_users — extend with platform-level flags
-- =============================================================================
alter table application_users add column if not exists is_super_admin boolean not null default false;
alter table application_users add column if not exists email text;
alter table application_users add column if not exists last_login_at timestamptz;
alter table application_users add column if not exists created_by text;

-- =============================================================================
-- 5. Per-product role assignment
-- A user may hold a different role in each product. Super admins (flag on
-- application_users) implicitly have every permission everywhere and do not
-- need rows here.
-- =============================================================================
create table if not exists user_product_roles (
    id            uuid primary key default uuid_generate_v4(),
    user_id       uuid not null references application_users(id) on delete cascade,
    product_id    uuid not null references products(id) on delete cascade,
    role_id       uuid not null references roles(id) on delete cascade,
    granted_by    text,
    granted_at    timestamptz not null default now(),
    unique (user_id, product_id)
);

create index if not exists idx_user_product_roles_user on user_product_roles (user_id);
create index if not exists idx_user_product_roles_product on user_product_roles (product_id);

-- =============================================================================
-- 6. Audit log — every create/update/delete/import/export made through the
-- admin panel or the API is recorded here, independent of which product or
-- table it touched.
-- =============================================================================
create table if not exists audit_log (
    id            uuid primary key default uuid_generate_v4(),
    product_code  text,
    table_name    text not null,
    record_id     text,
    action        text not null check (action in ('create','update','delete','import','export','login','permission_denied')),
    changed_by    text,
    changed_at    timestamptz not null default now(),
    before_data   jsonb,
    after_data    jsonb,
    ip_address    text,
    notes         text
);

create index if not exists idx_audit_log_table on audit_log (table_name);
create index if not exists idx_audit_log_changed_at on audit_log (changed_at);
create index if not exists idx_audit_log_changed_by on audit_log (changed_by);
create index if not exists idx_audit_log_product on audit_log (product_code);

-- =============================================================================
-- 7. Tag existing Insignia-Audience tables with product_code so future
-- products sharing this database are trivially distinguishable in any
-- cross-product report or audit query.
-- =============================================================================
alter table conversion_master add column if not exists product_code text not null default 'insignia-audience';
alter table conversion_master add column if not exists is_shortclosed boolean;
alter table conversion_master add column if not exists is_refunded boolean;
alter table insignia_registration_master add column if not exists product_code text not null default 'insignia-audience';
alter table insignia_prebooking_master add column if not exists product_code text not null default 'insignia-audience';
alter table upload_history add column if not exists product_code text not null default 'insignia-audience';
alter table saved_batch_groups add column if not exists product_code text not null default 'insignia-audience';
alter table target_audience_runs add column if not exists product_code text not null default 'insignia-audience';

-- =============================================================================
-- Row-level security for the new tables
-- =============================================================================
alter table products enable row level security;
alter table permissions enable row level security;
alter table roles enable row level security;
alter table role_permissions enable row level security;
alter table user_product_roles enable row level security;
alter table audit_log enable row level security;

-- No public policies: accessed only via the backend service-role key,
-- exactly like every other table in this schema.
