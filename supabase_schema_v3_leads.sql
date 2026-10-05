-- =============================================================================
-- Insignia Platform — Leads Dataset Migration (v3)
-- Run AFTER supabase_schema.sql and supabase_schema_v2_saas.sql.
--
-- Adds `leads_master`: a fourth centrally-stored dataset (alongside
-- Conversion, Insignia Registration, and Insignia Prebooking) sourced from
-- the raw Lead export (98 columns). Design decision, stated plainly:
--
--   The ~45 columns that are actually used for filtering, matching, contact,
--   or reporting are promoted to real typed/indexed columns below. The
--   remaining long tail of ad-tracking / CRM-internal fields (adsID,
--   adName, insightsPlanId, custom_question, tat_details, etc.) is preserved
--   losslessly in a single `extra_data jsonb` column rather than each
--   getting its own rarely-queried column. Nothing from the source file is
--   dropped; it's just not all individually indexed.
--
-- NOTE ON "level": the source `level` column is an internal object-ID
-- reference (e.g. '63c3a4b775c48847124fceb5'), not a human label. The
-- human-readable value used for "level-wise" filtering is `level_name`
-- (e.g. 'Level 1'). Both are stored; filtering/UI uses level_name.
-- =============================================================================

create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;

create table if not exists leads_master (
    id                          uuid primary key default uuid_generate_v4(),

    -- Source identifiers
    source_lead_id              text,           -- _id
    l_id                        text,
    customer_id                 text,
    student_id                  text,

    -- Identity & contact
    name                        text,
    normalised_name             text,
    phone                       text,
    normalised_phone            text,
    alternate_num               text,
    normalised_alternate        text,
    whatsapp_num                text,
    normalised_whatsapp         text,
    telegram                    text,
    email                       text,
    normalised_email            text,
    gender                      text,
    dob                         text,
    address                     text,
    city                        text,
    state                       text,
    pincode                     text,

    -- The two primary filter dimensions this migration exists for
    level_id                    text,           -- raw `level` (object-ID reference)
    level_name                  text,           -- human-readable level, e.g. 'Level 1'
    normalised_level            text,           -- uppercased/trimmed, used for filtering
    language                    text,
    normalised_language         text,           -- uppercased/trimmed, used for filtering

    -- Service / programme context
    service_code                text,
    normalised_service_code     text,
    service_name                text,
    service_type                text,
    prev_service_code           text,
    prev_service_name           text,
    prev_level_name             text,

    -- Pipeline / status
    leadstatus                  text,
    normalised_lead_status      text,
    lead_stage                  text,
    stage_name                  text,
    leadsource                  text,
    leadowner                   text,
    leadownername               text,
    leadassigndate              text,
    leaddate                    text,
    campaign_name                text,
    converted_from                text,

    -- Profile
    occupation                  text,
    educational_qualification   text,
    experience                  text,
    monthlyincome                text,

    -- Insignia / promotion signals (relevant to the Insignia Audience product)
    is_insignia_prospect        boolean,
    is_lead_promoted            boolean,
    lead_promoted_to            text,
    lead_promoted_date          text,
    demo_given                  text,
    demo_date                   text,

    -- Free text
    remarks                     text,
    comment                     text,
    referrer_name                text,
    referrer_phone                text,

    -- Source timestamps (kept as text like the other master tables, since
    -- the source export format varies row to row)
    source_updated_at            text,           -- updatedate
    source_uploaded_at            text,           -- uploaddate

    -- Everything else from the 98-column source file, losslessly preserved
    extra_data                  jsonb default '{}'::jsonb,

    -- Standard platform bookkeeping (matches every other master table)
    source_file_name            text,
    source_row_number           integer,
    first_uploaded_at           timestamptz not null default now(),
    last_updated_at             timestamptz not null default now(),
    upload_batch_id             uuid,
    record_hash                 text unique,
    is_active                   boolean not null default true,
    product_code                text  -- nullable: leads are shared centrally; a product
                                       -- may optionally tag leads it originated/claimed
);

create index if not exists idx_leads_normalised_phone on leads_master (normalised_phone);
create index if not exists idx_leads_normalised_whatsapp on leads_master (normalised_whatsapp);
create index if not exists idx_leads_normalised_email on leads_master (normalised_email);
create index if not exists idx_leads_normalised_level on leads_master (normalised_level);
create index if not exists idx_leads_normalised_language on leads_master (normalised_language);
create index if not exists idx_leads_service_code on leads_master (normalised_service_code);
create index if not exists idx_leads_lead_status on leads_master (normalised_lead_status);
create index if not exists idx_leads_source_lead_id on leads_master (source_lead_id);
create index if not exists idx_leads_student_id on leads_master (student_id);
create index if not exists idx_leads_product_code on leads_master (product_code);
-- Composite index for the platform's core use case: "leads at level X in language Y"
create index if not exists idx_leads_level_language on leads_master (normalised_level, normalised_language);

drop trigger if exists trg_leads_updated_at on leads_master;
create trigger trg_leads_updated_at
before update on leads_master
for each row execute function set_updated_at();

alter table leads_master enable row level security;
-- No public policies: accessed only via the backend service-role key.

-- Register in the admin-managed table whitelist happens in application
-- code (services/supabase_service.py ADMIN_MANAGED_TABLES), not SQL.
