"""
Standalone Supabase connection diagnostic.

Run this directly (not through Streamlit) to check every layer independently:
credentials loaded -> client created -> each expected table reachable.
Tells you exactly which layer is broken instead of one generic error.

Usage:
    python check_connection.py
"""

import sys


def check(label, fn):
    try:
        result = fn()
        print(f"  [OK] {label}: {result}")
        return True
    except Exception as e:
        print(f"  [FAIL] {label}: {type(e).__name__}: {e}")
        return False


def main():
    print("=" * 70)
    print("Insignia Platform — Supabase Connection Diagnostic")
    print("=" * 70)

    print("\n0. Checking the raw secrets file directly (bypassing Streamlit)...")
    import os
    secrets_path = os.path.join(os.getcwd(), ".streamlit", "secrets.toml")
    print(f"  Looking for: {secrets_path}")
    if not os.path.isfile(secrets_path):
        print("  [FAIL] That file does not exist at this exact path.")
        print(f"\n  Current working directory is: {os.getcwd()}")
        print("  Make sure you're running this command from inside the")
        print("  'insignia-target-audience' folder (the one containing app.py),")
        print("  and that the file is named exactly 'secrets.toml' — not")
        print("  'secrets.toml.txt' or 'secrets.example.toml'.")
        try:
            streamlit_dir = os.path.join(os.getcwd(), ".streamlit")
            if os.path.isdir(streamlit_dir):
                print(f"\n  Files actually found in {streamlit_dir}:")
                for f in os.listdir(streamlit_dir):
                    print(f"    - {f}")
            else:
                print(f"\n  There is no '.streamlit' folder at all in {os.getcwd()}")
        except Exception:
            pass
        sys.exit(1)
    else:
        size = os.path.getsize(secrets_path)
        print(f"  [OK] File exists, {size} bytes.")
        if size == 0:
            print("  [FAIL] ...but it's empty (0 bytes). Open it and add the [supabase] content.")
            sys.exit(1)
        try:
            with open(secrets_path, "r", encoding="utf-8") as f:
                raw = f.read()
            has_section = "[supabase]" in raw
            print(f"  Contains '[supabase]' header: {'YES' if has_section else 'NO — this is the problem'}")
            if not has_section:
                print("\n  First 200 characters of the file, for comparison:")
                print("  " + raw[:200].replace("\n", "\n  "))
                sys.exit(1)
        except Exception as e:
            print(f"  [FAIL] Could not read the file: {type(e).__name__}: {e}")
            sys.exit(1)

    print("\n1. Loading configuration...")
    try:
        from utils.config import get_settings
        settings = get_settings()
        sb = settings["supabase"]
        url = sb.get("url") or ""
        key = sb.get("service_role_key") or sb.get("anon_key") or ""
        print(f"  URL:  {url or '(EMPTY — this is the problem)'}")
        print(f"  Key:  {'set, ' + str(len(key)) + ' chars' if key else '(EMPTY — this is the problem)'}")
        if not url or not key:
            print("\n  -> secrets.toml is not being read, or [supabase] section is empty.")
            print("     Check .streamlit/secrets.toml exists, has a [supabase] header,")
            print("     and quoted url/anon_key/service_role_key values.")
            sys.exit(1)
    except Exception as e:
        print(f"  [FAIL] Could not even load configuration: {type(e).__name__}: {e}")
        sys.exit(1)

    print("\n2. Creating Supabase client...")
    from services import supabase_service as db
    if not check("Client created", lambda: db.get_client()):
        print("\n  -> Credentials loaded but the client itself failed to initialise.")
        sys.exit(1)

    print("\n3. Querying each expected table (confirms migrations ran AND the key is valid)...")
    tables = [
        ("conversion_master", "supabase_schema.sql"),
        ("insignia_registration_master", "supabase_schema.sql"),
        ("insignia_prebooking_master", "supabase_schema.sql"),
        ("products", "supabase_schema_v2_saas.sql"),
        ("roles", "supabase_schema_v2_saas.sql"),
        ("permissions", "supabase_schema_v2_saas.sql"),
        ("application_users", "supabase_schema_v2_saas.sql"),
        ("audit_log", "supabase_schema_v2_saas.sql"),
        ("leads_master", "supabase_schema_v3_leads.sql"),
        ("user_product_access", "supabase_schema_v4_checkbox_access.sql"),
    ]

    all_ok = True
    for table, source_file in tables:
        client = db.get_client()
        ok = check(
            f"{table:30s} (from {source_file})",
            lambda t=table: f"{len(client.table(t).select('id', count='exact').limit(1).execute().data)} row(s) sampled",
        )
        all_ok = all_ok and ok

    print("\n4. Checking the products table has the seed row...")
    check("insignia-audience product exists", lambda: db.get_client().table("products").select("*").eq("code", "insignia-audience").execute().data)

    print("\n" + "=" * 70)
    if all_ok:
        print("ALL CHECKS PASSED — Supabase is connected and all migrations have run.")
        print("If the Streamlit app still shows an error, restart it fully (Ctrl+C, then rerun).")
    else:
        print("SOME CHECKS FAILED — see [FAIL] lines above.")
        print("A 'relation does not exist' error means that table's SQL file wasn't run.")
        print("A 'JWT' / '401' / 'Invalid API key' error means the key in secrets.toml")
        print("doesn't match this Supabase project — re-copy it from Project Settings -> API.")
    print("=" * 70)


if __name__ == "__main__":
    main()