"""
Insignia Platform — single entrypoint.

Flow enforced by this file (not just by convention):
  1. Not logged in  -> only the Login screen exists. No other page is
     reachable, because st.navigation() is never called until authenticated.
  2. Logged in       -> st.navigation() builds the sidebar FROM SCRATCH based
     on the user's permissions. A page the user can't access doesn't exist
     in their sidebar at all — it isn't just hidden by CSS, and isn't
     reachable via Streamlit's old flat pages/ auto-discovery either, since
     calling st.navigation() here fully replaces that behaviour.
  3. Product Hub      -> the default landing page after login; every product
     the platform hosts appears as a card there, and its pages appear in the
     sidebar as a named section only if the user holds a role on it.

Every page file still calls require_permission(...) itself too — the nav
hiding a page is a UX convenience, the require_permission() call inside the
page is the actual security boundary.
"""

import streamlit as st

from services.authentication_service import login, is_authenticated, current_user, logout, has_permission
from services import supabase_service as db
from services import rbac_service
from utils.constants import PLATFORM_NAME

st.set_page_config(page_title=PLATFORM_NAME, page_icon="🧭", layout="wide")

# ---------------------------------------------------------------------------
# Pro-level theme (applies to every page, since this file always runs first)
# ---------------------------------------------------------------------------
st.markdown(
    """
    <style>
    .stApp { background-color: #F7F9FC; }
    section[data-testid="stSidebar"] { background-color: #0F1B33; }
    section[data-testid="stSidebar"] * { color: #E6ECF7 !important; }
    div[data-testid="stMetric"] {
        background-color: #FFFFFF;
        border: 1px solid #E3E9F2;
        border-radius: 12px;
        padding: 14px;
        box-shadow: 0 1px 2px rgba(15, 27, 51, 0.04);
    }
    .platform-banner {
        background: linear-gradient(135deg, #0F1B33 0%, #1F3A63 100%);
        border-radius: 16px;
        padding: 32px 36px;
        color: #FFFFFF;
        margin-bottom: 24px;
    }
    .platform-banner h1 { color: #FFFFFF; margin: 0 0 6px 0; }
    .platform-banner p { color: #C9D6EA; margin: 0; }
    .product-card {
        background: #FFFFFF;
        border: 1px solid #E3E9F2;
        border-radius: 14px;
        padding: 22px;
        height: 100%;
        box-shadow: 0 1px 3px rgba(15, 27, 51, 0.05);
    }
    .product-card h3 { margin: 4px 0 6px 0; color: #12395B; }
    .product-card p { color: #5B6B85; font-size: 0.92rem; }
    .badge-live { background:#E3F6EC; color:#0F6E56; padding:2px 10px; border-radius:999px; font-size:0.75rem; font-weight:600; }
    .badge-soon { background:#F0F1F4; color:#6B7A90; padding:2px 10px; border-radius:999px; font-size:0.75rem; font-weight:600; }
    .app-footer { text-align: center; color: #8A97AC; padding: 24px 0 8px 0; font-size: 0.85rem; }
    h1, h2, h3 { color: #12395B; }
    </style>
    """,
    unsafe_allow_html=True,
)


# ---------------------------------------------------------------------------
# Stage 1: Login (no navigation exists yet)
# ---------------------------------------------------------------------------
def render_login():
    st.markdown(
        f"""
        <div class="platform-banner">
            <h1>🧭 {PLATFORM_NAME}</h1>
            <p>One secure, centralised database — every product your team runs, in one place.</p>
        </div>
        """,
        unsafe_allow_html=True,
    )

    col1, col2 = st.columns([1, 1])
    with col1:
        st.subheader("Sign in")
        with st.form("login_form"):
            username = st.text_input("Username")
            password = st.text_input("Password", type="password")
            submitted = st.form_submit_button("Sign In", use_container_width=True, type="primary")

        if submitted:
            user = login(username, password)
            if user:
                st.session_state["auth_user"] = user
                st.success(f"Welcome, {user['display_name']}.")
                st.rerun()
            else:
                st.error("Invalid username or password.")

    with col2:
        st.subheader("What is this platform?")
        st.info(
            "Sign in, then land on the Product Hub, where every product you have "
            "access to appears as a card. Opening a product reveals only the "
            "sections your role grants you — nothing else is in your sidebar."
        )
        st.caption("Every product added later reuses this same login, the same roles, and the same admin panel.")


# ---------------------------------------------------------------------------
# Stage 2, landing page: Product Hub
# ---------------------------------------------------------------------------
def render_product_hub():
    user = current_user()
    top = st.columns([5, 1])
    with top[0]:
        st.markdown(
            f"""
            <div class="platform-banner">
                <h1>🧭 {PLATFORM_NAME}</h1>
                <p>Signed in as <b>{user['display_name']}</b> — {user['role'].replace('_', ' ').title()}</p>
            </div>
            """,
            unsafe_allow_html=True,
        )
    with top[1]:
        if st.button("Log out", use_container_width=True):
            logout()
            st.rerun()

    with st.spinner("Loading products..."):
        try:
            products = rbac_service.list_products()
        except Exception:
            products = []
            st.error(
                "Could not connect to the database. Verify the Supabase credentials and that "
                "supabase_schema.sql, supabase_schema_v2_saas.sql, supabase_schema_v3_leads.sql, "
                "and supabase_schema_v4_checkbox_access.sql have all been executed, in that order."
            )

    st.subheader("Your Products")
    if not products:
        st.info("No products registered yet. An administrator can register one from Access Control.")
    else:
        cols = st.columns(3)
        for i, product in enumerate(products):
            role = rbac_service.get_user_role_for_product(user, product["code"])
            accessible = role is not None or user.get("is_super_admin")
            with cols[i % 3]:
                st.markdown(
                    f"""
                    <div class="product-card">
                        <span class="{'badge-live' if accessible else 'badge-soon'}">{('Your access: ' + role.replace('_',' ').title()) if role else ('Your access: Super Admin' if user.get('is_super_admin') else 'No access')}</span>
                        <h3>{product['name']}</h3>
                        <p>{product.get('description') or ''}</p>
                    </div>
                    """,
                    unsafe_allow_html=True,
                )
                if not accessible:
                    st.caption("Ask an administrator to grant you a role for this product.")
        st.caption("Open a product from the sidebar on the left — only products and sections you have access to are listed there.")

    st.divider()
    try:
        health = db.health_check()
        st.caption("🟢 Database connection healthy." if health["ok"] else f"🔴 {health['detail']}")
    except Exception:
        pass

    st.markdown(f'<div class="app-footer">{PLATFORM_NAME}</div>', unsafe_allow_html=True)


# ---------------------------------------------------------------------------
# Stage 2: build the permission-filtered navigation tree
# ---------------------------------------------------------------------------
def build_navigation(user) -> dict:
    from utils.constants import PRODUCT_CODE_LEADS, PRODUCT_CODE_PLATFORM_ADMIN, PRODUCT_CODE_L4_WEBINAR
    p = rbac_service.DEFAULT_PRODUCT_CODE  # "insignia-audience"
    nav = {"Platform": [st.Page(render_product_hub, title="Product Hub", icon="🧭", default=True)]}

    insignia_pages = []
    if has_permission("view", p):
        insignia_pages.append(st.Page("pages/1_Dashboard.py", title="Dashboard", icon="📊"))
        insignia_pages.append(st.Page("pages/2_Batch_Input.py", title="Power TI Batch Input", icon="🧾"))
    if has_permission("import", p):
        insignia_pages.append(st.Page("pages/3_Conversion_Upload.py", title="Conversion Upload", icon="📥"))
        insignia_pages.append(st.Page("pages/4_Registration_Upload.py", title="Registration Upload", icon="📥"))
        insignia_pages.append(st.Page("pages/5_Prebooking_Upload.py", title="Prebooking Upload", icon="📥"))
    if has_permission("create", p):
        insignia_pages.append(st.Page("pages/6_Target_Audience.py", title="Target Audience Creation", icon="🎯"))
    if has_permission("view", p):
        insignia_pages.append(st.Page("pages/7_Excluded_Report.py", title="Excluded Students Report", icon="🚫"))
        insignia_pages.append(st.Page("pages/8_Upload_History.py", title="Upload History", icon="🗂️"))
    if insignia_pages:
        nav["Insignia Audience Count"] = insignia_pages

    # Leads is its own section with its own checkboxes — a user can have
    # Insignia Audience access without Leads access, or vice versa.
    leads_pages = []
    if has_permission("view", PRODUCT_CODE_LEADS):
        leads_pages.append(st.Page("pages/13_Leads_Explorer.py", title="Leads Explorer", icon="🔎"))
    if has_permission("import", PRODUCT_CODE_LEADS):
        leads_pages.append(st.Page("pages/12_Lead_Upload.py", title="Lead Upload", icon="📥"))
    if leads_pages:
        nav["Leads (Shared Dataset)"] = leads_pages

    webinar_pages = []
    if has_permission("view", PRODUCT_CODE_L4_WEBINAR):
        webinar_pages.append(st.Page("pages/14_Webinar_Dashboard.py", title="Dashboard", icon="📊"))
        webinar_pages.append(st.Page("pages/15_Webinar_Setup.py", title="Create / Select Webinar", icon="🎥"))
        webinar_pages.append(st.Page("pages/17_Webinar_Process_Match.py", title="Process & Match", icon="🧮"))
    if has_permission("import", PRODUCT_CODE_L4_WEBINAR):
        webinar_pages.append(st.Page("pages/16_Webinar_Upload.py", title="Upload Files", icon="📥"))
    if has_permission("export", PRODUCT_CODE_L4_WEBINAR):
        webinar_pages.append(st.Page("pages/18_Webinar_Export.py", title="Export", icon="📤"))
    if webinar_pages:
        nav["L4 Webinar"] = webinar_pages

    admin_pages = []
    if user.get("is_super_admin") or has_permission("manage_database", PRODUCT_CODE_PLATFORM_ADMIN):
        admin_pages.append(st.Page("pages/9_Database_Management.py", title="Database Management", icon="🗄️"))
        admin_pages.append(st.Page("pages/11_Audit_Log.py", title="Audit Log", icon="🧾"))
    if user.get("is_super_admin") or has_permission("manage_users", PRODUCT_CODE_PLATFORM_ADMIN):
        admin_pages.append(st.Page("pages/10_Access_Control.py", title="Access Control", icon="🔐"))
    if admin_pages:
        nav["Platform Administration"] = admin_pages

    return nav


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
if not is_authenticated():
    render_login()
else:
    try:
        navigation = build_navigation(current_user())
        page = st.navigation(navigation)
        page.run()
    except db.ConfigurationError as e:
        st.error(f"⚠️ Setup issue: {e}")
        st.stop()
