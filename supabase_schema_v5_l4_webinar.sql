-- =============================================================================
-- Insignia Platform — L4 Webinar Product Migration (v5)
-- Run AFTER supabase_schema.sql, supabase_schema_v2_saas.sql,
-- supabase_schema_v3_leads.sql, and supabase_schema_v4_checkbox_access.sql.
--
-- Adds a new, isolated product: "L4 Webinar". Follows the exact same
-- patterns already established by the platform:
--   - staging tables carry typed columns for the fields that matter for
--     matching/filtering + a raw_data jsonb catch-all (see leads_master
--     in v3) so nothing from an upload is ever lost.
--   - every row has record_hash (idempotent re-upload), source_file_name,
--     first_uploaded_at/last_updated_at, upload_batch_id, is_active
--     (soft delete) — identical bookkeeping to every other master table.
--   - product_code = 'l4-webinar' throughout, checked via the same
--     services.rbac_service section model as every other product.
-- =============================================================================

create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;

-- =============================================================================
-- 1. Register the product
-- =============================================================================
insert into products (code, name, description, icon, sort_order)
values ('l4-webinar', 'L4 Webinar', 'Upload, clean, match, and prioritise webinar leads from Zoom/WebinarJam attendance, form fills, and payments.', 'ti-video', 2)
on conflict (code) do nothing;

-- =============================================================================
-- 2. Webinars — one row per webinar event, with a configurable payment cutoff
-- =============================================================================
create table if not exists webinars (
    id                    uuid primary key default uuid_generate_v4(),
    name                  text not null,
    webinar_date          date not null,
    start_time            text,                       -- stored as text like other tables; display-only
    platform              text not null check (platform in ('zoom', 'webinarjam')),
    payment_pitch_at      timestamptz,                 -- when the payment pitch was made during/after the webinar
    payment_cutoff_at     timestamptz not null,        -- configurable per webinar; NEVER hardcoded in application code
    plan_product          text,                        -- plan/product being sold on this webinar
    notes                 text,
    created_by            text,
    created_at            timestamptz not null default now(),
    updated_at            timestamptz not null default now(),
    is_active             boolean not null default true
);

create index if not exists idx_webinars_date on webinars (webinar_date);
create index if not exists idx_webinars_platform on webinars (platform);

drop trigger if exists trg_webinars_updated_at on webinars;
create trigger trg_webinars_updated_at
before update on webinars
for each row execute function set_updated_at();

-- =============================================================================
-- 3. Uploads — one row per file uploaded against a webinar (any of the 5 types)
-- =============================================================================
create table if not exists webinar_uploads (
    id                   uuid primary key default uuid_generate_v4(),
    webinar_id           uuid not null references webinars(id) on delete cascade,
    upload_type          text not null check (upload_type in
                          ('attendee', 'dummy_template', 'form_fill', 'payment_details', 'payment_qr')),
    source_file_name     text,
    file_size            bigint default 0,
    uploaded_by          text,
    uploaded_at          timestamptz not null default now(),
    detected_columns     jsonb default '[]'::jsonb,     -- raw source column order, esp. for dummy_template
    column_mapping       jsonb default '{}'::jsonb,     -- confirmed canonical-field -> source-column mapping
    total_rows           integer default 0,
    valid_rows           integer default 0,
    new_rows             integer default 0,
    duplicate_rows       integer default 0,
    rejected_rows        integer default 0,
    status               text default 'success',
    error_message        text,
    processing_seconds   numeric(10,2)
);

create index if not exists idx_webinar_uploads_webinar on webinar_uploads (webinar_id);
create index if not exists idx_webinar_uploads_type on webinar_uploads (upload_type);

-- =============================================================================
-- 4. Attendee staging — normalised, per-session attendance rows (Zoom's
-- "Attendee Details" section or WebinarJam's flat export). One row per
-- join/leave session; aggregation into total duration happens at match time
-- so raw session data is never lost or pre-collapsed.
-- =============================================================================
create table if not exists webinar_attendee_records (
    id                    uuid primary key default uuid_generate_v4(),
    webinar_id            uuid not null references webinars(id) on delete cascade,
    upload_id             uuid references webinar_uploads(id) on delete set null,
    name                  text,
    normalised_name       text,
    phone                 text,
    normalised_phone      text,
    email                 text,
    normalised_email      text,
    registration_time     text,
    approval_status       text,
    join_time             timestamptz,
    leave_time             timestamptz,
    duration_minutes       numeric(10,2),
    is_guest               boolean,
    country                 text,
    raw_data                jsonb default '{}'::jsonb,
    source_file_name       text,
    source_row_number      integer,
    first_uploaded_at      timestamptz not null default now(),
    last_updated_at        timestamptz not null default now(),
    upload_batch_id        uuid,
    record_hash             text unique,
    is_active                boolean not null default true
);

create index if not exists idx_webinar_attendee_webinar on webinar_attendee_records (webinar_id);
create index if not exists idx_webinar_attendee_phone on webinar_attendee_records (normalised_phone);
create index if not exists idx_webinar_attendee_email on webinar_attendee_records (normalised_email);

drop trigger if exists trg_webinar_attendee_updated_at on webinar_attendee_records;
create trigger trg_webinar_attendee_updated_at
before update on webinar_attendee_records
for each row execute function set_updated_at();

-- =============================================================================
-- 5. Form-fill staging — subscription/registration form responses
-- =============================================================================
create table if not exists webinar_form_records (
    id                    uuid primary key default uuid_generate_v4(),
    webinar_id            uuid not null references webinars(id) on delete cascade,
    upload_id             uuid references webinar_uploads(id) on delete set null,
    name                  text,
    normalised_name       text,
    phone                 text,
    normalised_phone      text,
    email                 text,
    normalised_email      text,
    plan_opted            text,
    submitted_at           text,
    raw_data                jsonb default '{}'::jsonb,
    source_file_name       text,
    source_row_number      integer,
    first_uploaded_at      timestamptz not null default now(),
    last_updated_at        timestamptz not null default now(),
    upload_batch_id        uuid,
    record_hash             text unique,
    is_active                boolean not null default true
);

create index if not exists idx_webinar_form_webinar on webinar_form_records (webinar_id);
create index if not exists idx_webinar_form_phone on webinar_form_records (normalised_phone);
create index if not exists idx_webinar_form_email on webinar_form_records (normalised_email);

drop trigger if exists trg_webinar_form_updated_at on webinar_form_records;
create trigger trg_webinar_form_updated_at
before update on webinar_form_records
for each row execute function set_updated_at();

-- =============================================================================
-- 6. Payment staging — from payment-details exports AND QR reports, unified
-- =============================================================================
create table if not exists webinar_payment_records (
    id                    uuid primary key default uuid_generate_v4(),
    webinar_id            uuid not null references webinars(id) on delete cascade,
    upload_id             uuid references webinar_uploads(id) on delete set null,
    name                  text,
    normalised_name       text,
    phone                 text,
    normalised_phone      text,
    email                 text,
    normalised_email      text,
    amount                numeric(14,2),
    payment_status        text,
    payment_datetime       timestamptz,
    transaction_id          text,
    order_id                text,
    payment_source           text check (payment_source in ('payment_details', 'payment_qr')),
    raw_data                jsonb default '{}'::jsonb,
    source_file_name       text,
    source_row_number      integer,
    first_uploaded_at      timestamptz not null default now(),
    last_updated_at        timestamptz not null default now(),
    upload_batch_id        uuid,
    record_hash             text unique,
    is_active                boolean not null default true
);

create index if not exists idx_webinar_payment_webinar on webinar_payment_records (webinar_id);
create index if not exists idx_webinar_payment_phone on webinar_payment_records (normalised_phone);
create index if not exists idx_webinar_payment_email on webinar_payment_records (normalised_email);
create index if not exists idx_webinar_payment_txn on webinar_payment_records (transaction_id);
create index if not exists idx_webinar_payment_order on webinar_payment_records (order_id);

drop trigger if exists trg_webinar_payment_updated_at on webinar_payment_records;
create trigger trg_webinar_payment_updated_at
before update on webinar_payment_records
for each row execute function set_updated_at();

-- =============================================================================
-- 7. Final matched dataset — one row per person, per webinar, with status
-- =============================================================================
create table if not exists webinar_leads_master (
    id                       uuid primary key default uuid_generate_v4(),
    webinar_id               uuid not null references webinars(id) on delete cascade,
    name                     text,
    normalised_name          text,
    phone                    text,
    normalised_phone         text,
    email                    text,
    normalised_email         text,

    matched_attendee_id      uuid references webinar_attendee_records(id) on delete set null,
    matched_form_id          uuid references webinar_form_records(id) on delete set null,
    matched_payment_id       uuid references webinar_payment_records(id) on delete set null,
    match_method             text,     -- 'phone' | 'email' | 'transaction_id' | 'normalised_name' | 'fuzzy_name'
    match_confidence         text,     -- 'high' | 'medium' | 'low'

    total_duration_minutes   numeric(10,2) default 0,
    plan_opted               text,
    payment_amount           numeric(14,2),
    payment_status           text,
    payment_datetime          timestamptz,
    transaction_id             text,

    status                   text not null check (status in
                              ('seat_booked', 'high_priority', 'medium_priority', 'unqualified')),
    requires_manual_review   boolean not null default false,
    manual_review_notes      text,
    manually_edited_by       text,
    manually_edited_at       timestamptz,

    source_file_name         text,
    first_uploaded_at        timestamptz not null default now(),
    last_updated_at          timestamptz not null default now(),
    upload_batch_id          uuid,
    record_hash               text unique,
    is_active                  boolean not null default true
);

create index if not exists idx_webinar_leads_webinar on webinar_leads_master (webinar_id);
create index if not exists idx_webinar_leads_status on webinar_leads_master (status);
create index if not exists idx_webinar_leads_review on webinar_leads_master (requires_manual_review);
create index if not exists idx_webinar_leads_phone on webinar_leads_master (normalised_phone);
create index if not exists idx_webinar_leads_email on webinar_leads_master (normalised_email);

drop trigger if exists trg_webinar_leads_updated_at on webinar_leads_master;
create trigger trg_webinar_leads_updated_at
before update on webinar_leads_master
for each row execute function set_updated_at();

-- =============================================================================
-- Row-level security — identical pattern to every other table
-- =============================================================================
alter table webinars enable row level security;
alter table webinar_uploads enable row level security;
alter table webinar_attendee_records enable row level security;
alter table webinar_form_records enable row level security;
alter table webinar_payment_records enable row level security;
alter table webinar_leads_master enable row level security;
-- No public policies: accessed only via the backend service-role key.
