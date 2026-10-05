-- =============================================================================
-- Insignia Platform — L4 Webinar Level/Language Migration (v6)
-- Run AFTER supabase_schema_v5_l4_webinar.sql.
--
-- A webinar targets one level+language cohort (e.g. "Bengali L2 webinar on
-- 8-Aug"), which determines which status rule set applies to everyone who
-- attended it — see WEBINAR_LEVEL_LANGUAGE_RULES in utils/constants.py.
-- =============================================================================

alter table webinars add column if not exists level_name text;
alter table webinars add column if not exists language text;
alter table webinars add column if not exists normalised_level text;
alter table webinars add column if not exists normalised_language text;

create index if not exists idx_webinars_level_language on webinars (normalised_level, normalised_language);
