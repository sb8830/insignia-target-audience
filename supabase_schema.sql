-- =============================================================================
-- Insignia Target Audience Creation Platform
-- Supabase PostgreSQL schema
-- Run this entire file once in the Supabase SQL editor before first use.
-- =============================================================================

create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;

-- =============================================================================
-- Generic updated_at trigger function
-- =============================================================================
create or replace function set_updated_at()
returns trigger as $$
begin
  new.last_updated_at = now();
  return new;
end;
$$ language plpgsql;

-- =============================================================================
-- 1. conversion_master
-- =============================================================================
create table if not exists conversion_master (
    id                          uuid primary key default uuid_generate_v4(),
    student_id                  text,
    student_invid               text,
    student_name                text,
    normalised_name             text,
    phone                       text,
    normalised_phone            text,
    whatsapp                    text,
    normalised_whatsapp         text,
    email                       text,
    normalised_email            text,
    service_code                text,
    normalised_service_code     text,
    total_amount                numeric(14,2),
    total_due                   numeric(14,2),
    status                      text,
    order_id                    text,
    order_date                  text,
    is_shortclosed              boolean,
    is_refunded                 boolean,
    source_file_name            text,
    source_row_number           integer,
    first_uploaded_at           timestamptz not null default now(),
    last_updated_at             timestamptz not null default now(),
    upload_batch_id             uuid,
    record_hash                 text unique,
    is_active                   boolean not null default true
);

create index if not exists idx_conversion_normalised_phone on conversion_master (normalised_phone);
create index if not exists idx_conversion_normalised_whatsapp on conversion_master (normalised_whatsapp);
create index if not exists idx_conversion_normalised_email on conversion_master (normalised_email);
create index if not exists idx_conversion_student_id on conversion_master (student_id);
create index if not exists idx_conversion_student_invid on conversion_master (student_invid);
create index if not exists idx_conversion_service_code on conversion_master (normalised_service_code);
create index if not exists idx_conversion_order_id on conversion_master (order_id);

drop trigger if exists trg_conversion_updated_at on conversion_master;
create trigger trg_conversion_updated_at
before update on conversion_master
for each row execute function set_updated_at();

-- =============================================================================
-- 2. insignia_registration_master
-- =============================================================================
create table if not exists insignia_registration_master (
    id                          uuid primary key default uuid_generate_v4(),
    source_registration_id      text,
    student_id                  text,
    student_invid               text,
    student_name                text,
    normalised_name             text,
    phone                       text,
    normalised_phone            text,
    whatsapp_number             text,
    normalised_whatsapp         text,
    telegram_number             text,
    normalised_telegram         text,
    email                       text,
    normalised_email            text,
    insignia_code                text,
    normalised_insignia_code    text,
    insignia_name                text,
    coupon_code                  text,
    registration_date            text,
    source_file_name            text,
    source_row_number           integer,
    first_uploaded_at           timestamptz not null default now(),
    last_updated_at             timestamptz not null default now(),
    upload_batch_id             uuid,
    record_hash                 text unique,
    is_active                   boolean not null default true
);

create index if not exists idx_registration_normalised_phone on insignia_registration_master (normalised_phone);
create index if not exists idx_registration_normalised_whatsapp on insignia_registration_master (normalised_whatsapp);
create index if not exists idx_registration_normalised_telegram on insignia_registration_master (normalised_telegram);
create index if not exists idx_registration_normalised_email on insignia_registration_master (normalised_email);
create index if not exists idx_registration_student_id on insignia_registration_master (student_id);
create index if not exists idx_registration_student_invid on insignia_registration_master (student_invid);
create index if not exists idx_registration_insignia_code on insignia_registration_master (normalised_insignia_code);

drop trigger if exists trg_registration_updated_at on insignia_registration_master;
create trigger trg_registration_updated_at
before update on insignia_registration_master
for each row execute function set_updated_at();

-- =============================================================================
-- 3. insignia_prebooking_master
-- =============================================================================
create table if not exists insignia_prebooking_master (
    id                          uuid primary key default uuid_generate_v4(),
    booking_id                  text,
    order_id                    text,
    student_invid               text,
    student_name                text,
    normalised_name             text,
    telephone                   text,
    normalised_telephone        text,
    batch_preference            text,
    insignia_name                text,
    normalised_insignia_name    text,
    booking_date                 text,
    is_payment_done              boolean,
    is_booking_confirmed         boolean,
    is_order_completed           boolean,
    source_file_name            text,
    source_row_number           integer,
    first_uploaded_at           timestamptz not null default now(),
    last_updated_at             timestamptz not null default now(),
    upload_batch_id             uuid,
    record_hash                 text unique,
    is_active                   boolean not null default true
);

create index if not exists idx_prebooking_booking_id on insignia_prebooking_master (booking_id);
create index if not exists idx_prebooking_order_id on insignia_prebooking_master (order_id);
create index if not exists idx_prebooking_student_invid on insignia_prebooking_master (student_invid);
create index if not exists idx_prebooking_normalised_telephone on insignia_prebooking_master (normalised_telephone);

drop trigger if exists trg_prebooking_updated_at on insignia_prebooking_master;
create trigger trg_prebooking_updated_at
before update on insignia_prebooking_master
for each row execute function set_updated_at();

-- =============================================================================
-- 4. upload_history
-- =============================================================================
create table if not exists upload_history (
    id                  uuid primary key default uuid_generate_v4(),
    upload_type         text not null check (upload_type in ('conversion','registration','prebooking')),
    source_file_name    text,
    file_size           bigint default 0,
    uploaded_by          text,
    uploaded_at          timestamptz not null default now(),
    total_rows           integer default 0,
    valid_rows            integer default 0,
    new_rows               integer default 0,
    updated_rows           integer default 0,
    duplicate_rows          integer default 0,
    rejected_rows            integer default 0,
    status                     text default 'success',
    error_message              text,
    processing_seconds          numeric(10,2)
);

create index if not exists idx_upload_history_type on upload_history (upload_type);
create index if not exists idx_upload_history_date on upload_history (uploaded_at);

-- =============================================================================
-- 5. saved_batch_groups
-- =============================================================================
create table if not exists saved_batch_groups (
    id             uuid primary key default uuid_generate_v4(),
    group_name     text not null unique,
    batch_codes    jsonb not null default '[]'::jsonb,
    created_by     text,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

drop trigger if exists trg_batch_groups_updated_at on saved_batch_groups;
create trigger trg_batch_groups_updated_at
before update on saved_batch_groups
for each row execute function set_updated_at();

-- =============================================================================
-- 6. target_audience_runs
-- =============================================================================
create table if not exists target_audience_runs (
    id                              uuid primary key default uuid_generate_v4(),
    run_name                        text,
    selected_batch_codes            jsonb not null default '[]'::jsonb,
    eligible_conversion_count       integer default 0,
    registered_exclusion_count      integer default 0,
    prebooking_exclusion_count      integer default 0,
    review_count                    integer default 0,
    final_audience_count            integer default 0,
    created_by                      text,
    created_at                      timestamptz not null default now()
);

create index if not exists idx_runs_created_at on target_audience_runs (created_at);

-- =============================================================================
-- 7. target_audience_run_details (optional stored results)
-- =============================================================================
create table if not exists target_audience_run_details (
    id                  uuid primary key default uuid_generate_v4(),
    run_id              uuid references target_audience_runs(id) on delete cascade,
    student_name        text,
    phone               text,
    whatsapp            text,
    email               text,
    batch_code          text
);

create index if not exists idx_run_details_run_id on target_audience_run_details (run_id);

-- =============================================================================
-- 8. application_users
-- =============================================================================
create table if not exists application_users (
    id                uuid primary key default uuid_generate_v4(),
    username          text not null unique,
    password_hash     text not null,
    role              text not null check (role in ('Admin','Operator','Viewer')),
    display_name      text,
    is_active         boolean not null default true,
    created_at        timestamptz not null default now()
);

-- =============================================================================
-- Row-level security
-- All tables are backend-accessed only via the service-role key from the
-- Streamlit application, so RLS is enabled with no public policies, which
-- blocks all access via the anon/public API key.
-- =============================================================================
alter table conversion_master enable row level security;
alter table insignia_registration_master enable row level security;
alter table insignia_prebooking_master enable row level security;
alter table upload_history enable row level security;
alter table saved_batch_groups enable row level security;
alter table target_audience_runs enable row level security;
alter table target_audience_run_details enable row level security;
alter table application_users enable row level security;

-- No policies are created intentionally: the service-role key used by the
-- backend bypasses RLS entirely, while the anon key (if ever exposed) will
-- be denied all access by default.
