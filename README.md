# Insignia Platform

A centralised, multi-product SaaS platform on a single Supabase (PostgreSQL)
database. **Insignia Audience Count** — identifying fully paid Power TI
students eligible for Insignia outreach — is the first product. Every
future product reuses the same database, the same user directory, the same
role-based access control, and the same admin panel.

Two processes share one database:

| Process | What it's for | Run with |
|---|---|---|
| **Streamlit app** (`app.py`, `pages/`) | Product UI + admin panel (pro-level, browser-based) | `streamlit run app.py` |
| **FastAPI backend** (`api/`) | REST API for integrations, automation, or a future custom frontend | `uvicorn api.main:app` |

Both talk to the same `services/` business logic and the same Supabase
tables — there is exactly one source of truth for eligibility rules,
deduplication, and permission checks.

---

## 1. Architecture

```text
                         ┌─────────────────────────┐
                         │   Supabase PostgreSQL    │
                         │  (single shared database)│
                         │                          │
                         │  products · roles ·      │
                         │  permissions · users ·   │
                         │  audit_log ·             │
                         │  conversion_master ·     │
                         │  insignia_registration_* │
                         │  insignia_prebooking_*   │
                         └────────────┬─────────────┘
                                      │
                 ┌────────────────────┼────────────────────┐
                 │                    │                    │
        ┌────────▼────────┐  ┌────────▼────────┐  ┌────────▼────────┐
        │  services/       │  │  Streamlit app   │  │  FastAPI backend │
        │  (shared business│  │  (app.py, pages/)│  │  (api/)          │
        │  logic + RBAC)   │  │  Product Hub UI  │  │  REST API        │
        └──────────────────┘  │  + Admin Panel   │  │  /api/v1/*       │
                               └──────────────────┘  └──────────────────┘
```

## 2. Login → Product → Section Flow (Enforced, Not Cosmetic)

`app.py` is the *only* entrypoint. It uses Streamlit's `st.navigation()` API,
which means:

- **Before login**: no other page exists. There is no sidebar, no URL, no
  page name that reaches product content — `st.navigation()` is never
  called until `is_authenticated()` is true.
- **After login**: the sidebar is rebuilt from scratch by
  `app.py::build_navigation(user)`, which calls `has_permission(...)` for
  every candidate page and only includes the ones the user's role actually
  grants. A page you can't access isn't hidden by CSS — it was never added
  to your navigation tree, and Streamlit's old flat `pages/` auto-discovery
  is fully superseded once `st.navigation()` is in use.
- **Landing page**: "Product Hub" — every registered product appears as a
  card; opening one reveals that product's sections in the sidebar.
- **Defense in depth**: every page file *also* calls `require_permission(...)`
  itself. The navigation hiding a page is a UX convenience; the
  `require_permission()` call inside the page is the actual security
  boundary, exactly like the API's route-level checks.

## 3. Section-Level Permissions (Not Just Page-Level)

Beyond gating whole pages, individual actions within a page are now shown
or hidden based on the specific permission they need:

- **Database Management**: the Create / Edit / Delete tabs only appear if
  the user's role grants `create` / `edit` / `delete` respectively — a
  role with `manage_database` + `view` only gets a read-only browser.
- **Target Audience Creation**: the download buttons only appear with
  `export`; "Save Run" only appears with `create`.
- **Leads Explorer**: export buttons only appear with `export`.

## 4. Checkbox-Driven, Section-Wise Access Control

Access is granted per **section** (Insignia Audience Count, Leads,
Platform Administration — matching the sidebar exactly) as a direct set of
checked permission boxes, not a single named role picked blind:

- **Access Control → Users & Access → Customize Access** shows every
  section as its own checkbox grid (`view`, `create`, `edit`, `delete`,
  `import`, `export` for Insignia Audience Count and Leads; `view`,
  `manage_database`, `manage_users`, `manage_products` for Platform
  Administration). A user can have full Leads access and zero Insignia
  Audience access, or any other combination — the sections don't leak
  into each other.
- **Tier buttons** (Viewer / User / Admin) are one-click presets that
  populate a section's checkboxes; the grid label shows "Custom" the
  moment you hand-adjust anything, exactly reflecting what's actually
  checked.
- **Super Admin** is a single platform-wide toggle, gated so only an
  existing Super Admin can grant or revoke it.
- **Custom Roles** (Access Control → Custom Roles) remain available as
  reusable presets you can define once and apply to any user/section —
  applying one just checks the matching boxes, which is still the source
  of truth. `user_product_access` (added by
  `supabase_schema_v4_checkbox_access.sql`) is the single table every
  permission check reads from, in both the Streamlit pages and the API.

## 6. Leads — a Fourth Shared Dataset

`leads_master` is a fourth centrally-stored dataset (alongside Conversion,
Insignia Registration, and Insignia Prebooking), loaded via **Lead Upload**.
The source export has ~98 columns; the ~45 that are actually used for
filtering, contact, or matching are typed/indexed columns, and the long
tail of ad-tracking/CRM-internal fields is preserved losslessly in a
`extra_data jsonb` column rather than each getting its own column.

**Design note on "level":** the source `level` column is an internal
object-ID reference, not a human label — the actual filterable field is
`level_name` (e.g. `'Level 1'`). Both are stored; filtering uses
`level_name`.

**Level-wise, language-wise filtration, reused everywhere:**
`services/lead_service.py` is the single implementation of this filter —
called from:
- **Database Management** — a level/language quick-filter scoped to the
  `leads_master` table specifically.
- **Leads Explorer** (`pages/13_Leads_Explorer.py`) — the full filter
  (level, language, status, service code, search) plus export.
- **The API** — `GET /api/v1/leads?level=...&language=...`.
- **Insignia Audience Count itself** — the Target Audience Creation page
  has a "Related Leads" section that fetches leads for the same
  level/language/service code as the batch just processed, so outreach can
  work the lead pool alongside the paid target audience, entirely on
  demand (nothing is fetched until the operator sets criteria and clicks
  Fetch). Any future product calls the same `fetch_leads(...)` with its own
  default filters.

Run `supabase_schema_v3_leads.sql` after the first two migrations to add
this table.

## 7. Multi-Product & RBAC Model

- **`products`** — a registry table. Insignia Audience Count is row one.
  Adding a second product means inserting a row here and building its
  pages/routes against the same tables and services — no fork required.
- **`roles` / `permissions` / `role_permissions`** — a fixed permission
  vocabulary (`view`, `create`, `edit`, `delete`, `import`, `export`,
  `manage_database`, `manage_users`, `manage_products`) bundled into roles
  (`super_admin`, `admin`, `operator`, `viewer`).
- **`user_product_roles`** — a user can hold a *different* role on each
  product. A `super_admin` flag on `application_users` bypasses all of this
  with full access everywhere.
- **`audit_log`** — every create/update/delete/import/export/login, from
  either the Streamlit admin panel or the API, with before/after JSON.

Run, in order: `supabase_schema.sql`, `supabase_schema_v2_saas.sql`,
`supabase_schema_v3_leads.sql`, then `supabase_schema_v4_checkbox_access.sql`.
Each is an additive migration: the second layers the platform (products,
RBAC, audit log) on the original Insignia Audience Count tables, the third
adds the shared Leads dataset, and the fourth adds the checkbox-driven
access model (with a backfill so existing role assignments survive).

## 3. Admin Panel — Direct Database Access

`pages/9_Database_Management.py` gives permitted users (`manage_database`)
real Create / Edit / Delete forms against every table in
`services.supabase_service.ADMIN_MANAGED_TABLES` — not just search and
soft-deactivate. Every write is:

- Restricted to a **whitelist** of tables (no arbitrary table name from
  user input can ever be reached).
- **Audit-logged** with who changed what, and the before/after values.
- Reachable from **both** the Streamlit page and `PUT/POST/DELETE
  /api/v1/admin/{table}/records` in the API — one implementation, two
  surfaces.

`pages/10_Access_Control.py` manages users and per-product role grants.
`pages/11_Audit_Log.py` is the audit trail viewer.

## 4. The API (`api/`)

| Route | Purpose |
|---|---|
| `POST /api/v1/auth/login` | JWT login (shared user table with Streamlit) |
| `GET/POST/PUT/DELETE /api/v1/admin/{table}/records` | Generic, whitelisted, audited CRUD |
| `GET /api/v1/products` | List products + your role on each |
| `POST /api/v1/users`, `POST /api/v1/users/assign-role` | User + role management |
| `GET /api/v1/audit-log` | Audit trail |
| `GET /api/v1/insignia/{type}/records` | Browse conversion/registration/prebooking data |
| `GET /api/v1/leads`, `GET /api/v1/leads/filters` | Level/language/status/service-code filtered lead list + dropdown options |
| `POST /api/v1/leads/import` | Upload a Lead file (same pipeline as the UI) |
| `POST /api/v1/insignia/{type}/import` | Upload & process a file (same pipeline as the UI) |
| `POST /api/v1/insignia/target-audience/generate` | Run the matching engine, get JSON back |
| `POST /api/v1/insignia/target-audience/export` | Run the matching engine, get a formatted `.xlsx` back |

Interactive docs are auto-generated at `/docs` once the API is running.
Every route (except `/auth/login` and `/health`) requires a Bearer token
and enforces the same product-scoped permission the Streamlit UI checks.

## 5. Local Installation

```bash
git clone <your-repo-url>
cd insignia-platform
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt   # includes requirements.txt + test/lint tools
```

## 6. Supabase Setup

1. Create a project at https://supabase.com and note the Project URL, anon
   key, and service_role key (Project Settings → API).
2. In the SQL Editor, run, in order: **`supabase_schema.sql`**, then
   **`supabase_schema_v2_saas.sql`**, then **`supabase_schema_v3_leads.sql`**,
   then **`supabase_schema_v4_checkbox_access.sql`** (order matters — each
   depends on tables created by the previous file).

## 7. Configuration

The same codebase reads credentials from two places depending on how it's
run (see `utils/config.py`):

**Streamlit app** → `.streamlit/secrets.toml` (copy from
`.streamlit/secrets.example.toml`):

```toml
[supabase]
url = "https://your-project.supabase.co"
anon_key = "your-anon-key"
service_role_key = "your-service-role-key"

[app]
bootstrap_admin_username = "admin"
bootstrap_admin_password = "changeme123"
jwt_secret = "replace-with-a-long-random-string"
```

**FastAPI backend** → environment variables / `.env` (copy from
`.env.example`):

```bash
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
JWT_SECRET=replace-with-a-long-random-string
BOOTSTRAP_ADMIN_USERNAME=admin
BOOTSTRAP_ADMIN_PASSWORD=changeme123
```

`bootstrap_admin_*` lets you log in before any real user exists in
`application_users`. Create a real Super Admin from Access Control, then
retire the bootstrap password. Neither secrets file nor `.env` is ever
committed (see `.gitignore`).

## 8. Running Locally

```bash
# Streamlit product UI + admin panel
streamlit run app.py

# FastAPI backend (separate terminal)
uvicorn api.main:app --reload --port 8000
# → docs at http://localhost:8000/docs
```

Or run just the API in Docker:

```bash
cp .env.example .env   # fill in real values
docker compose up --build
```

## 9. Deployment

- **Streamlit app** → Streamlit Community Cloud. Set `app.py` as the main
  file, paste your real secrets into the app's "Secrets" panel, deploy.
- **FastAPI backend** → any container host (Fly.io, Render, Railway, ECS,
  etc.) using the included `Dockerfile`. Set the environment variables from
  `.env.example` on the host.

## 10. Testing & Linting

```bash
pytest tests/ -v --cov=services --cov=utils
ruff check .
black --check .
```

`tests/conftest.py` provides an in-memory fake Supabase client (`fake_db`
fixture) so the admin-CRUD and RBAC tests run without live credentials —
useful in CI (`.github/workflows/ci.yml` runs lint + tests + a Docker build
on every push).

## 11. Security Notes

- The service-role key is used only on the backend (Streamlit secrets /
  API environment) — never in client-side code.
- Every table not explicitly listed in `ADMIN_MANAGED_TABLES` is
  unreachable from the admin panel or the API, regardless of what a caller
  requests.
- Row-level security is enabled on every table with no public policies —
  the anon key alone cannot read or write anything.
- Phone numbers are masked in on-screen previews (`utils/security.py`) and
  shown in full only in authorised downloads.
- Passwords are hashed with PBKDF2-HMAC-SHA256 (`utils/security.py`),
  shared between the Streamlit login and the API's JWT issuance.

## 12. Adding a New Product

1. Insert a row into `products` (via Access Control → Products, or the API).
2. Design its tables; add them to `ADMIN_MANAGED_TABLES` in
   `services/supabase_service.py` if they should be admin-editable.
3. Build its Streamlit pages and/or API router, using
   `require_permission("view", product_code="your-product-code")` (or the
   API's `require_permission(..., product_code=...)` dependency) for every
   access check.
4. Grant users a role on the new product from Access Control — existing
   users, roles, and the audit log all just work.

## 13. Repository Structure

```text
insignia-platform/
├── app.py                     # Product Hub (login + landing page)
├── pages/                     # Streamlit multipage app
│   ├── 1_Dashboard.py … 8_Upload_History.py   # Insignia Audience Count product
│   ├── 9_Database_Management.py               # Generic admin CRUD
│   ├── 10_Access_Control.py                   # Users, roles, products
│   └── 11_Audit_Log.py
├── api/                        # FastAPI backend
│   ├── main.py, deps.py, schemas.py
│   ├── core/security.py        # JWT
│   └── routers/                # auth, admin, products, users, audit, insignia
├── services/                   # Shared business logic (used by both surfaces)
│   ├── supabase_service.py     # DB access, generic CRUD, audit log
│   ├── rbac_service.py         # Multi-product permission resolution
│   ├── authentication_service.py
│   ├── upload_service.py, matching_service.py, export_service.py, audit_service.py
├── utils/                       # Pure, testable helpers (+ config.py, logger.py)
├── models/                      # Dataclasses mirroring the schema
├── tests/                       # pytest suite (50 tests, incl. fake-DB RBAC/CRUD tests)
├── supabase_schema.sql          # Base Insignia Audience Count schema
├── supabase_schema_v2_saas.sql  # Platform layer: products, RBAC, audit log
├── supabase_schema_v3_leads.sql # Leads dataset (level/language filterable)
├── supabase_schema_v4_checkbox_access.sql # Checkbox-driven, section-wise access
├── Dockerfile, docker-compose.yml, .dockerignore
└── .github/workflows/ci.yml
```
