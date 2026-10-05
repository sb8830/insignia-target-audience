# L4 Webinar — Round 2 Delta (Level/Language Rules + Strict Payment + Leads Format)

Only new/changed files from this round. Apply **on top of** the round-1
delta you already have (or your live project if you already merged it).

## 1. New file

```
supabase_schema_v6_webinar_level_language.sql   # run 6th, after v1-v5
```

Adds `level_name` / `language` (+ normalised versions) to the `webinars`
table. A webinar targets one level+language cohort — this determines which
status rule set applies to everyone who attended it.

## 2. Modified files (overwrite — full versions included)

| File | What changed |
|---|---|
| `utils/constants.py` | (1) `VALID_PAYMENT_STATUSES` narrowed to strictly `{"captured"}` — no other status counts, per your instruction. (2) New status codes `WEBINAR_STATUS_TOP_PRIORITY` / `WEBINAR_STATUS_FREE_CLASS_HIGH_PRIORITY` for the L1-L3 duration-tiered rules, and `WEBINAR_STATUS_UNQUALIFIED`'s label changed to "Webinar Not Attendee" to match your terminology. (3) New `WEBINAR_LEVEL_LANGUAGE_RULES` config — see below. |
| `services/webinar_service.py` | `create_webinar()` now accepts `level_name` / `language`, normalised the same way as the Leads dataset. |
| `services/webinar_matching_service.py` | `apply_status()` rewritten: checks the global "any captured payment -> Seat Booked" rule first (regardless of level/language/form), then looks up the webinar's level+language in `WEBINAR_LEVEL_LANGUAGE_RULES` to pick either the L4/L5 payment-form-based tiers or the L1-L3 duration-tiered rule. Returns `{"status": ..., "rule_configured": bool}` — records for an unconfigured level/language combo (see below) are automatically flagged for Manual Review instead of silently guessing. |
| `services/webinar_export_service.py` | New `build_leads_format_export()` / `build_leads_format_workbook()` — shapes the final dataset into your `Leads_8-8-2026.xlsx` format (`campaign_name`, `leadownername`, `leadsource`, `leadstatus`, `name`, `phone`, `stage_name`, `Form Fillup Details`), enriched by matching each person against the platform's shared `leads_master` table on **phone then email**. `leadstatus` is this webinar's freshly computed status; `stage_name` is carried over from the matched lead's own CRM stage (see note below). Also added to the combined "Final Dataset" workbook as its own sheet, plus Top Priority / Free Class High Priority sheets. |
| `pages/15_Webinar_Setup.py` | Added Level and Language dropdowns to webinar creation. Warns at creation time if the chosen level+language has no configured rule yet. |
| `pages/18_Webinar_Export.py` | Added a "Leads Format (enriched)" download button. |
| `tests/test_webinar.py` | Updated for the new `apply_status()` return shape; added tests proving Bengali L2 (2hr top) and Odia L2 (75min top) don't cross-contaminate, L4/L5 identical-across-languages, and unconfigured-pair fallback + flagging. |

## 3. The rules I implemented, exactly as you specified

```
GLOBAL (any level/language): captured payment -> Seat Booked, always,
form fill not required. This overrides everything else.

Bengali L2:  duration >= 120 min -> Top Priority
             30 <= duration < 120 -> Free Class High Priority
             duration < 30 -> Webinar Not Attendee

Odia L2:     duration >= 75 min (1h15m) -> Top Priority
             30 <= duration < 75 -> Free Class High Priority
             duration < 30 -> Webinar Not Attendee

Bengali L3:  duration >= 240 min (4hr) -> Top Priority
             30 <= duration < 240 -> Free Class High Priority
             duration < 30 -> Webinar Not Attendee

L4 & L5 (both languages, explicitly identical per your point 9):
             not paid, form filled -> Webinar High Priority
             not paid, no form, duration > 30 -> Webinar Medium Priority
             otherwise -> Webinar Not Attendee
```

## 4. Two gaps I did NOT guess at — need your confirmation

Your message didn't give thresholds for:
- **Odia L3** (point 8 was left blank)
- **L1, both languages** (never mentioned)

Rather than inventing numbers, `WEBINAR_LEVEL_LANGUAGE_RULES` has these
set to `None`. When a webinar is created with one of these combinations,
every attendee falls back to the generic payment/form-based tiers (same
as L4/L5) **and gets auto-flagged for Manual Review** with a note
explaining exactly why, so nothing silently ships with a guessed number.
Once you confirm the real thresholds, it's a one-line edit in
`WEBINAR_LEVEL_LANGUAGE_RULES` — no other code changes needed.

## 5. Ambiguity I resolved and want to flag

Your point 9 says: *"Webinar Medium Priority -> those who have not paid
and filled the form but joined more than 30 mins"* — this looks like a
copy-paste of the High Priority line (which already covers "not paid,
filled the form"). I implemented Medium Priority as **not paid, form NOT
filled, duration > 30 min**, since that's the only reading that doesn't
make Medium Priority unreachable (a record can't simultaneously be
"form-filled -> High Priority" and "form-filled -> Medium Priority").
Flag if this isn't what you meant.

## 6. Tested against your real files before shipping

- Ran the full pipeline with a synthetic Bengali L2 webinar covering all
  four outcomes at once: 125min unpaid -> Top Priority, 50min unpaid (with
  a `"success"`-status payment that's **correctly rejected** since only
  `"captured"` counts now) -> Free Class High Priority, 15min -> Not
  Attendee, and 5min **with** a captured payment -> Seat Booked regardless
  of the short duration.
- Verified Bengali L2 (120min top) and Odia L2 (75min top) don't leak into
  each other at the 69-90 minute boundary.
- Loaded your real `Leads_8-8-2026.xlsx` into `leads_master` and ran the
  Leads-format export shaping against it.
- 99/99 tests pass (26 for the webinar module specifically, including 13
  new/updated for this round), zero regressions elsewhere on the platform.

**One real limitation surfaced by your actual data**: the phone numbers in
`Leads_8-8-2026.xlsx` are masked (`867****626`), which won't phone-match
against a real unmasked number even for the same person (e.g. "Ratnadeep
saha" appears in both your Leads file and the dummy registration CSV with
the same name, but the masked phone can't link them). I did **not** add a
name-based fallback for this enrichment — the platform's established
pattern throughout (Insignia Audience, Leads, this module's own attendee
matching) deliberately avoids auto-linking on name alone, since a wrong
enrichment here would misattribute someone's real lead-source campaign. If
your production `leads_master` has full unmasked phone numbers (this
sample file was likely a masked export from the admin panel's display
view, not raw underlying data), phone matching will work correctly as-is.
