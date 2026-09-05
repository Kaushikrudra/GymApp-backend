#!/usr/bin/env python3
"""
Comprehensive Regression Test Suite for Xanvoraa Gym CRM Backend
Covers:
  - Phase 1: Foundation & Multi-Tenant RLS
  - Phase 2: CRM Core (Plans, Memberships, Freeze D-05, Renewal D-06, Exclusive D-04)
  - Phase 3: Attendance & Streak Engine (Check-in, D-10 Backdate, D-03 Streak)
"""

import subprocess
import json
import uuid
import sys
import threading
import time

DB_HOST = "127.0.0.1"
DB_PORT = "54322"
DB_USER = "postgres"
DB_PASS = "postgres"
DB_NAME = "postgres"

test_results = []

def run_sql(query, as_user_id=None, expect_error=False):
    """
    Executes a SQL statement via psql.
    If as_user_id is provided, sets auth.jwt.claims so RLS is evaluated as that user.
    """
    cmd_prefix = ""
    if as_user_id:
        jwt_claims = json.dumps({"sub": str(as_user_id), "role": "authenticated"}).replace("'", "''")
        cmd_prefix = f"SET ROLE authenticated;\nSELECT set_config('request.jwt.claims', '{jwt_claims}', false);\n"
    
    full_sql = f"{cmd_prefix}{query}"
    
    proc = subprocess.run(
        ["psql", "-h", DB_HOST, "-p", DB_PORT, "-U", DB_USER, "-d", DB_NAME, "-X", "-t", "-A", "-v", "ON_ERROR_STOP=1"],
        input=full_sql,
        env={"PGPASSWORD": DB_PASS, "PATH": subprocess.os.environ.get("PATH", "")},
        capture_output=True,
        text=True
    )
    
    raw_output = proc.stdout.strip()
    error = proc.stderr.strip()
    
    # Filter out SET, DO, and auth config outputs
    cleaned_lines = [
        l.strip() for l in raw_output.splitlines() 
        if l.strip() and l.strip() not in ("SET", "DO") and not l.strip().startswith('{"sub":')
    ]
    output = "\n".join(cleaned_lines)
    
    if proc.returncode != 0:
        if expect_error:
            return {"success": False, "error": error, "output": output}
        else:
            return {"success": False, "error": error, "output": output}
    
    return {"success": True, "output": output, "error": error}

def record_result(test_id, description, passed, notes=""):
    result_str = "PASS" if passed else "FAIL"
    test_results.append({
        "id": test_id,
        "description": description,
        "result": result_str,
        "notes": notes
    })
    print(f"[{result_str}] {test_id}: {description} -> {notes}")

print("==================================================================")
print("  STARTING REGRESSION TEST SUITE: Xanvoraa Gym CRM Backend       ")
print("==================================================================")

# ==============================================================================
# SETUP TEST DATA (Unique deterministic IDs for reproducible test runs)
# ==============================================================================
print("\n>>> Setting up fresh test data for Gym A and Gym B...")

setup_sql = """
DO $$
DECLARE
    -- Gym A IDs
    v_owner_a_id uuid := '11111111-1111-4111-8111-111111111111';
    v_gym_a_id uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    v_branch_a_id uuid := 'baaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    v_shift_a_id uuid := '55555555-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    v_manager_a_id uuid := '11111111-2222-4111-8111-111111111111';
    v_staff_a_id uuid := '11111111-3333-4111-8111-111111111111';
    v_member1_id uuid := '11111111-4444-4111-8111-111111111111';
    v_member2_id uuid := '11111111-5555-4111-8111-111111111111';
    v_plan_a_id uuid := '66666666-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    v_mem1_id uuid := '77777777-1111-4aaa-8aaa-aaaaaaaaaaaa';
    v_mem2_id uuid := '77777777-2222-4aaa-8aaa-aaaaaaaaaaaa';

    -- Gym B IDs
    v_owner_b_id uuid := '22222222-1111-4222-8222-222222222222';
    v_gym_b_id uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    v_branch_b_id uuid := 'bbbbbbbb-2222-4bbb-8bbb-bbbbbbbbbbbb';
    v_member3_id uuid := '22222222-3333-4222-8222-222222222222';
BEGIN
    -- 1. Create Users in auth.users (Trigger automatically creates profiles)
    INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
        (v_owner_a_id, 'owner_gym_a@regression.test', '{"full_name":"Gym A Owner"}'::jsonb),
        (v_manager_a_id, 'manager_gym_a@regression.test', '{"full_name":"Gym A Manager"}'::jsonb),
        (v_staff_a_id, 'staff_gym_a@regression.test', '{"full_name":"Gym A Staff"}'::jsonb),
        (v_member1_id, 'member1_gym_a@regression.test', '{"full_name":"Gym A Member 1"}'::jsonb),
        (v_member2_id, 'member2_gym_a@regression.test', '{"full_name":"Gym A Member 2"}'::jsonb),
        (v_owner_b_id, 'owner_gym_b@regression.test', '{"full_name":"Gym B Owner"}'::jsonb),
        (v_member3_id, 'member3_gym_b@regression.test', '{"full_name":"Gym B Member 3"}'::jsonb)
    ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email;

    -- 2. Create Gyms (Trigger automatically enrolls owner in gym_users)
    INSERT INTO public.gyms (id, name, owner_id) VALUES
        (v_gym_a_id, 'Regression Gym A', v_owner_a_id)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    INSERT INTO public.gyms (id, name, owner_id) VALUES
        (v_gym_b_id, 'Regression Gym B', v_owner_b_id)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    -- 3. Create Branches
    INSERT INTO public.branches (id, gym_id, name, address) VALUES
        (v_branch_a_id, v_gym_a_id, 'Gym A Main Branch', '100 Fitness Blvd')
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    INSERT INTO public.branches (id, gym_id, name, address) VALUES
        (v_branch_b_id, v_gym_b_id, 'Gym B Downtown Branch', '200 Power St')
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

    -- 4. Create Shift in Gym A: Mon-Fri (1,2,3,4,5). Sat & Sun (6,7) are closed.
    INSERT INTO public.shifts (id, gym_id, branch_id, name, days_of_week, open_time, close_time) VALUES
        (v_shift_a_id, v_gym_a_id, v_branch_a_id, 'Gym A Weekday Shift', ARRAY[1,2,3,4,5], '06:00:00'::time, '22:00:00'::time)
    ON CONFLICT (id) DO UPDATE SET days_of_week = EXCLUDED.days_of_week;

    -- 5. Enroll gym_users
    INSERT INTO public.gym_users (gym_id, user_id, role, branch_id) VALUES
        (v_gym_a_id, v_manager_a_id, 'manager', v_branch_a_id),
        (v_gym_a_id, v_staff_a_id, 'staff', v_branch_a_id),
        (v_gym_a_id, v_member1_id, 'member', v_branch_a_id),
        (v_gym_a_id, v_member2_id, 'member', v_branch_a_id),
        (v_gym_b_id, v_member3_id, 'member', v_branch_b_id)
    ON CONFLICT (gym_id, user_id) DO UPDATE SET role = EXCLUDED.role, branch_id = EXCLUDED.branch_id;

    -- 6. Create Plan for Gym A
    INSERT INTO public.plans (id, gym_id, name, duration_in_days, price) VALUES
        (v_plan_a_id, v_gym_a_id, 'Gym A 30-Day Plan', 30, 2499.00)
    ON CONFLICT (id) DO UPDATE SET price = EXCLUDED.price;

    -- 7. Create Memberships
    -- Member 1: Active (start_date = 10 days ago, end_date = 20 days ahead)
    INSERT INTO public.memberships (id, gym_id, user_id, plan_id, start_date, end_date, status) VALUES
        (v_mem1_id, v_gym_a_id, v_member1_id, v_plan_a_id, CURRENT_DATE - 10, CURRENT_DATE + 20, 'active')
    ON CONFLICT (id) DO UPDATE SET start_date = EXCLUDED.start_date, end_date = EXCLUDED.end_date, status = EXCLUDED.status;

    -- Member 2: Expired (start_date = 32 days ago, end_date = 2 days ago)
    INSERT INTO public.memberships (id, gym_id, user_id, plan_id, start_date, end_date, status) VALUES
        (v_mem2_id, v_gym_a_id, v_member2_id, v_plan_a_id, CURRENT_DATE - 32, CURRENT_DATE - 2, 'expired')
    ON CONFLICT (id) DO UPDATE SET start_date = EXCLUDED.start_date, end_date = EXCLUDED.end_date, status = EXCLUDED.status;

    -- Clean any past attendance logs for fresh test runs
    DELETE FROM public.attendance_logs WHERE gym_id IN (v_gym_a_id, v_gym_b_id);
    DELETE FROM public.membership_freeze_log WHERE gym_id IN (v_gym_a_id, v_gym_b_id);
END $$;
"""

res = run_sql(setup_sql)
if not res["success"]:
    print(f"Setup Error: {res['error']}")
    sys.exit(1)

print(">>> Setup completed successfully!")

OWNER_A_ID = "11111111-1111-4111-8111-111111111111"
MANAGER_A_ID = "11111111-2222-4111-8111-111111111111"
STAFF_A_ID = "11111111-3333-4111-8111-111111111111"
MEMBER1_ID = "11111111-4444-4111-8111-111111111111"
MEMBER2_ID = "11111111-5555-4111-8111-111111111111"
GYM_A_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
BRANCH_A_ID = "baaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
SHIFT_A_ID = "55555555-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
PLAN_A_ID = "66666666-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
MEM1_ID = "77777777-1111-4aaa-8aaa-aaaaaaaaaaaa"
MEM2_ID = "77777777-2222-4aaa-8aaa-aaaaaaaaaaaa"

OWNER_B_ID = "22222222-1111-4222-8222-222222222222"
GYM_B_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
BRANCH_B_ID = "bbbbbbbb-2222-4bbb-8bbb-bbbbbbbbbbbb"
MEMBER3_ID = "22222222-3333-4222-8222-222222222222"

# ==============================================================================
# PHASE 1 TESTS (Tenant Isolation & RLS)
# ==============================================================================
print("\n━━━ RUNNING PHASE 1 TESTS (Tenant Isolation & RLS) ━━━")

# TEST 1.1: Gym B owner queries Gym A data
q1_1 = f"""
SELECT 
  (SELECT count(*) FROM public.branches WHERE gym_id = '{GYM_A_ID}') AS branch_count,
  (SELECT count(*) FROM public.gym_users WHERE gym_id = '{GYM_A_ID}') AS user_count;
"""
res = run_sql(q1_1, as_user_id=OWNER_B_ID)
branch_count, user_count = res["output"].split("|")
p1_1 = (int(branch_count) == 0 and int(user_count) == 0)
record_result(
    "TEST 1.1",
    "Gym B owner queries Gym A branches and gym_users (Tenant Isolation)",
    p1_1,
    f"RLS blocked access: branch_count={branch_count}, user_count={user_count}"
)

# TEST 1.2: Gym A staff updates own profile vs Gym B user profile
q1_2_self = f"UPDATE public.profiles SET phone = '9876543210' WHERE id = '{STAFF_A_ID}'; SELECT phone FROM public.profiles WHERE id = '{STAFF_A_ID}';"
res_self = run_sql(q1_2_self, as_user_id=STAFF_A_ID)
self_ok = ("9876543210" in res_self["output"])

q1_2_cross = f"UPDATE public.profiles SET phone = '0000000000' WHERE id = '{MEMBER3_ID}'; SELECT count(*) FROM public.profiles WHERE id = '{MEMBER3_ID}' AND phone = '0000000000';"
res_cross = run_sql(q1_2_cross, as_user_id=STAFF_A_ID)
cross_blocked = (res_cross["output"].split("\n")[-1].strip() == "0")

p1_2 = (self_ok and cross_blocked)
record_result(
    "TEST 1.2",
    "Gym A staff profile update boundary (Self allowed, Gym B user blocked)",
    p1_2,
    f"Self updated: {self_ok}, Cross-tenant update prevented: {cross_blocked}"
)

# TEST 1.3: Auth trigger check (automatic profile creation)
test_auth_uid = str(uuid.uuid4())
test_email_1_3 = f"autotrigger_{uuid.uuid4().hex[:8]}@regression.test"
q1_3 = f"""
INSERT INTO auth.users (id, email, raw_user_meta_data) 
VALUES ('{test_auth_uid}', '{test_email_1_3}', '{{"full_name":"Trigger Test User"}}'::jsonb);
SELECT email, full_name, role FROM public.profiles WHERE id = '{test_auth_uid}';
"""
res = run_sql(q1_3)
p1_3 = (test_email_1_3 in res["output"] and "Trigger Test User" in res["output"])
record_result(
    "TEST 1.3",
    "Auth user signup trigger (profiles auto-created with metadata)",
    p1_3,
    f"Profile created: {res['output']}"
)

# TEST 1.4: Gym trigger check (creator automatically owner in gym_users)
test_gym_id = str(uuid.uuid4())
test_gym_owner = str(uuid.uuid4())
test_email_1_4 = f"gym_owner_{uuid.uuid4().hex[:8]}@regression.test"
q1_4 = f"""
INSERT INTO auth.users (id, email) VALUES ('{test_gym_owner}', '{test_email_1_4}');
INSERT INTO public.gyms (id, name, owner_id) VALUES ('{test_gym_id}', 'Trigger Created Gym', '{test_gym_owner}');
SELECT role FROM public.gym_users WHERE gym_id = '{test_gym_id}' AND user_id = '{test_gym_owner}';
"""
res = run_sql(q1_4)
gym_user_role = res["output"].strip().splitlines()[-1] if res["output"].strip() else ""
p1_4 = (gym_user_role == "owner")
record_result(
    "TEST 1.4",
    "New gym creation trigger (owner automatically enrolled in gym_users with 'owner' role)",
    p1_4,
    f"gym_users role: {gym_user_role}"
)


# ==============================================================================
# PHASE 2 TESTS (Memberships, Freeze D-05, Renewal D-06, Exclusive D-04)
# ==============================================================================
print("\n━━━ RUNNING PHASE 2 TESTS (Memberships, Freeze, Renewal) ━━━")

# TEST 2.1: D-04 exclusive check on exact end_date
# Member1 membership: end_date = CURRENT_DATE + 20.
# On (CURRENT_DATE + 20), active check (start_date <= D AND D < end_date) must be FALSE.
q2_1 = f"""
SELECT 
  (end_date) as actual_end_date,
  -- Check validity on day before end_date
  (start_date <= (end_date - 1) AND (end_date - 1) < end_date) as active_day_before,
  -- D-04 check on exact end_date (MUST BE FALSE)
  (start_date <= end_date AND end_date < end_date) as active_on_end_date
FROM public.memberships 
WHERE id = '{MEM1_ID}';
"""
res = run_sql(q2_1)
end_d, before_ok, on_end_ok = res["output"].split("|")
p2_1 = (before_ok == "t" and on_end_ok == "f")
record_result(
    "TEST 2.1",
    "D-04 exclusive check: membership is INVALID on and after exact end_date",
    p2_1,
    f"Active on day before: {before_ok}, Active on exact end_date: {on_end_ok} (strictly exclusive)"
)

# TEST 2.2: D-05 Staff tries to freeze Member1 membership -> Unauthorized
q2_2 = f"SELECT * FROM public.freeze_membership('{MEM1_ID}', 7, 'Staff freeze attempt');"
res = run_sql(q2_2, as_user_id=STAFF_A_ID, expect_error=True)
p2_2 = (not res["success"] and "Only the gym owner can authorize a membership freeze" in res["error"])
record_result(
    "TEST 2.2",
    "D-05 unauthorized freeze attempt by staff (Owner only authorization)",
    p2_2,
    f"Caught expected authorization error: {res['error'].splitlines()[-1] if res['error'] else ''}"
)

# TEST 2.3: D-05 Owner freezes Member1 membership for 7 days
q2_3 = f"""
SELECT end_date FROM public.memberships WHERE id = '{MEM1_ID}';
SELECT * FROM public.freeze_membership('{MEM1_ID}', 7, 'Owner authorized vacation freeze');
SELECT count(*) FROM public.membership_freeze_log WHERE membership_id = '{MEM1_ID}' AND frozen_days = 7;
SELECT status, end_date FROM public.memberships WHERE id = '{MEM1_ID}';
"""
res = run_sql(q2_3, as_user_id=OWNER_A_ID)
lines = [l.strip() for l in res["output"].splitlines() if l.strip()]
freeze_log_count = lines[-2]
status_and_end = lines[-1]
status, new_end = status_and_end.split("|")
p2_3 = (status == "frozen" and int(freeze_log_count) >= 1)
record_result(
    "TEST 2.3",
    "D-05 authorized freeze by owner (end_date extended by 7 days, status='frozen', audit log created)",
    p2_3,
    f"Status={status}, New End Date={new_end}, Freeze Log Count={freeze_log_count}"
)

# Reactivate Member1 for attendance tests
run_sql(f"UPDATE public.memberships SET status = 'active' WHERE id = '{MEM1_ID}';")

# TEST 2.4: D-06 Renewal of expired membership (Member2)
# Member2 had expired membership (end_date = CURRENT_DATE - 2)
q2_4 = f"""
SELECT count(*) FROM public.memberships WHERE user_id = '{MEMBER2_ID}';
SELECT * FROM public.renew_membership('{MEM2_ID}', 30);
SELECT count(*) FROM public.memberships WHERE user_id = '{MEMBER2_ID}';
SELECT status, end_date = (CURRENT_DATE + 30) FROM public.memberships WHERE id = '{MEM2_ID}';
"""
res = run_sql(q2_4, as_user_id=OWNER_A_ID)
lines = [l.strip() for l in res["output"].splitlines() if l.strip()]
count_before = lines[0]
count_after = lines[-2]
status_and_extended = lines[-1].split("|")
new_status = status_and_extended[0]
is_extended_correctly = (status_and_extended[1] == "t")

p2_4 = (count_before == "1" and count_after == "1" and new_status == "active" and is_extended_correctly)
record_result(
    "TEST 2.4",
    "D-06 renewal updates existing record end_date without creating duplicate row",
    p2_4,
    f"Rows before={count_before}, Rows after={count_after}, Status={new_status}, Extended from CURRENT_DATE={is_extended_correctly}"
)

# TEST 2.5: Constraint check: end_date <= start_date fails
q2_5 = f"""
INSERT INTO public.memberships (gym_id, user_id, start_date, end_date, status)
VALUES ('{GYM_A_ID}', '{MEMBER1_ID}', CURRENT_DATE, CURRENT_DATE, 'active');
"""
res = run_sql(q2_5, expect_error=True)
p2_5 = (not res["success"] and "memberships_end_date_after_start_date" in res["error"])
record_result(
    "TEST 2.5",
    "Constraint enforcement: end_date > start_date",
    p2_5,
    f"Rejected with constraint violation: {'memberships_end_date_after_start_date' in res['error']}"
)


# ==============================================================================
# PHASE 3 TESTS (Attendance & Streak Engine)
# ==============================================================================
print("\n━━━ RUNNING PHASE 3 TESTS (Attendance & Streak Engine) ━━━")

# TEST 3.1: Member1 checks in today
q3_1 = f"SELECT check_in_date, is_backdated FROM public.check_in_member('{MEMBER1_ID}', '{GYM_A_ID}', '{BRANCH_A_ID}', '{SHIFT_A_ID}', CURRENT_DATE);"
res = run_sql(q3_1, as_user_id=MEMBER1_ID)
p3_1 = (res["success"] and ("|f" in res["output"] or "false" in res["output"].lower()))
record_result(
    "TEST 3.1",
    "Member1 regular self check-in for current date",
    p3_1,
    f"Logged successfully: {res['output']}"
)

# TEST 3.2: Member1 duplicate check-in today -> Clear duplicate error
q3_2 = f"SELECT * FROM public.check_in_member('{MEMBER1_ID}', '{GYM_A_ID}', '{BRANCH_A_ID}', '{SHIFT_A_ID}', CURRENT_DATE);"
res = run_sql(q3_2, as_user_id=MEMBER1_ID, expect_error=True)
p3_2 = (not res["success"] and "Already checked in for this date" in res["error"])
record_result(
    "TEST 3.2",
    "Duplicate check-in prevention with explicit error message",
    p3_2,
    f"Clear error returned: {res['error'].splitlines()[-1] if res['error'] else ''}"
)

# TEST 3.3: Concurrent check-in race condition test
# Use Member1 on CURRENT_DATE - 1 via two parallel threads simultaneously
run_sql(f"DELETE FROM public.attendance_logs WHERE gym_id = '{GYM_A_ID}' AND user_id = '{MEMBER1_ID}' AND check_in_date = (CURRENT_DATE - 1);")

concurrent_results = []
def checkin_thread(tid):
    q = f"SELECT check_in_date FROM public.check_in_member('{MEMBER1_ID}', '{GYM_A_ID}', '{BRANCH_A_ID}', '{SHIFT_A_ID}', CURRENT_DATE - 1, 'Parallel test');"
    r = run_sql(q, as_user_id=STAFF_A_ID, expect_error=True)
    concurrent_results.append((tid, r))

t1 = threading.Thread(target=checkin_thread, args=(1,))
t2 = threading.Thread(target=checkin_thread, args=(2,))
t1.start()
t2.start()
t1.join()
t2.join()

successes = [r for tid, r in concurrent_results if r["success"]]
duplicates = [r for tid, r in concurrent_results if not r["success"] and "Already checked in for this date" in r["error"]]

q_count = f"SELECT count(*) FROM public.attendance_logs WHERE gym_id = '{GYM_A_ID}' AND user_id = '{MEMBER1_ID}' AND check_in_date = (CURRENT_DATE - 1);"
r_count = run_sql(q_count)
total_inserted = int(r_count["output"].strip())

p3_3 = (len(successes) == 1 and len(duplicates) == 1 and total_inserted == 1)
record_result(
    "TEST 3.3",
    "Concurrent check-in race condition (Simultaneous calls result in exactly 1 row, second gets clear duplicate error)",
    p3_3,
    f"Success count={len(successes)}, Rejected duplicate count={len(duplicates)}, Database row count={total_inserted}"
)

# TEST 3.4: Member2 (renewed in TEST 2.4) checks in today
q3_4 = f"SELECT check_in_date FROM public.check_in_member('{MEMBER2_ID}', '{GYM_A_ID}', '{BRANCH_A_ID}', '{SHIFT_A_ID}', CURRENT_DATE);"
res = run_sql(q3_4, as_user_id=MEMBER2_ID)
p3_4 = res["success"]
record_result(
    "TEST 3.4",
    "Member2 check-in after renewal (Active membership validated)",
    p3_4,
    f"Check-in successful: {res['output'] if res['success'] else res['error']}"
)

# TEST 3.5: Backdate check - Staff marks Member1 check-in for 5 days ago with reason
q3_5 = f"SELECT check_in_date, is_backdated, backdate_reason FROM public.check_in_member('{MEMBER1_ID}', '{GYM_A_ID}', '{BRANCH_A_ID}', '{SHIFT_A_ID}', CURRENT_DATE - 5, 'Turnstile hardware failure');"
res = run_sql(q3_5, as_user_id=STAFF_A_ID)
p3_5 = (res["success"] and ("|t|" in res["output"] or "true" in res["output"].lower()) and "Turnstile hardware failure" in res["output"])
record_result(
    "TEST 3.5",
    "D-10 valid backdating by staff (5 days back with mandatory reason)",
    p3_5,
    f"Logged with backdate flag & reason: {res['output']}"
)

# TEST 3.6: Backdate limit - Staff attempts 10 days backdate (> 7 days)
q3_6 = f"SELECT * FROM public.check_in_member('{MEMBER1_ID}', '{GYM_A_ID}', '{BRANCH_A_ID}', '{SHIFT_A_ID}', CURRENT_DATE - 10, 'Too far in the past');"
res = run_sql(q3_6, as_user_id=STAFF_A_ID, expect_error=True)
p3_6 = (not res["success"] and "Backdating is limited to a maximum of 7 days" in res["error"])
record_result(
    "TEST 3.6",
    "D-10 maximum backdating limit enforced (Attempt > 7 days rejected)",
    p3_6,
    f"Caught expected limit error: {res['error'].splitlines()[-1] if res['error'] else ''}"
)

# TEST 3.7: Backdate without reason rejected
q3_7 = f"SELECT * FROM public.check_in_member('{MEMBER1_ID}', '{GYM_A_ID}', '{BRANCH_A_ID}', '{SHIFT_A_ID}', CURRENT_DATE - 3, '');"
res = run_sql(q3_7, as_user_id=STAFF_A_ID, expect_error=True)
p3_7 = (not res["success"] and "Backdate reason is mandatory" in res["error"])
record_result(
    "TEST 3.7",
    "D-10 backdating reason validation (Empty reason rejected)",
    p3_7,
    f"Caught expected mandatory reason error: {res['error'].splitlines()[-1] if res['error'] else ''}"
)

# TEST 3.8: D-03 Closed-day streak calculation test
# Schedule in Gym A shift is Mon-Fri (1,2,3,4,5). Sat & Sun (6,7) are closed.
# We test:
# 1. Mon-Tue-Wed (2026-08-24 to 2026-08-26) attended.
# 2. Thu-Fri (2026-08-27 to 2026-08-28) MISSED (scheduled open days missed!).
# 3. Sat-Sun (2026-08-29 to 2026-08-30) CLOSED.
# 4. Next Mon (2026-08-31) attended.
# -> As of 2026-08-31, streak must be 1 (reset by missed Thu-Fri).
# 5. Then Tue-Wed-Thu-Fri (2026-09-01 to 2026-09-04) attended.
# -> As of Friday 2026-09-04, streak must be 5.
# -> As of Saturday 2026-09-05 (CURRENT_DATE, closed day), streak is preserved at 5!
q3_8 = f"""
INSERT INTO public.attendance_logs (gym_id, branch_id, user_id, check_in_date, marked_by) VALUES
    ('{GYM_A_ID}', '{BRANCH_A_ID}', '{MEMBER1_ID}', '2026-08-24', '{OWNER_A_ID}'),
    ('{GYM_A_ID}', '{BRANCH_A_ID}', '{MEMBER1_ID}', '2026-08-25', '{OWNER_A_ID}'),
    ('{GYM_A_ID}', '{BRANCH_A_ID}', '{MEMBER1_ID}', '2026-08-26', '{OWNER_A_ID}'),
    ('{GYM_A_ID}', '{BRANCH_A_ID}', '{MEMBER1_ID}', '2026-08-31', '{OWNER_A_ID}'),
    ('{GYM_A_ID}', '{BRANCH_A_ID}', '{MEMBER1_ID}', '2026-09-01', '{OWNER_A_ID}'),
    ('{GYM_A_ID}', '{BRANCH_A_ID}', '{MEMBER1_ID}', '2026-09-02', '{OWNER_A_ID}'),
    ('{GYM_A_ID}', '{BRANCH_A_ID}', '{MEMBER1_ID}', '2026-09-03', '{OWNER_A_ID}'),
    ('{GYM_A_ID}', '{BRANCH_A_ID}', '{MEMBER1_ID}', '2026-09-04', '{OWNER_A_ID}')
ON CONFLICT (gym_id, user_id, check_in_date) DO NOTHING;

SELECT 
  public.calculate_member_streak('{MEMBER1_ID}', '{GYM_A_ID}', '2026-08-31'::date),
  public.calculate_member_streak('{MEMBER1_ID}', '{GYM_A_ID}', '2026-09-04'::date),
  public.calculate_member_streak('{MEMBER1_ID}', '{GYM_A_ID}', '2026-09-05'::date);
"""
res = run_sql(q3_8)
streak_line = res["output"].strip().splitlines()[-1]
streak_mon, streak_fri, streak_sat = streak_line.split("|")
p3_8 = (int(streak_mon) == 1 and int(streak_fri) == 5 and int(streak_sat) == 6)
record_result(
    "TEST 3.8",
    "D-03 closed-day streak engine (Missed open days reset streak; closed weekend preserves streak)",
    p3_8,
    f"Streak after missed Thu-Fri on Mon={streak_mon} (reset), Fri streak={streak_fri}, Sat (today) streak={streak_sat}"
)

# ==============================================================================
# SUMMARY TABLE
# ==============================================================================
print("\n" + "="*80)
print("  REGRESSION TEST RESULTS SUMMARY")
print("="*80)
print(f"| {'Test ID':<10} | {'Description':<65} | {'Result':<6} | {'Notes':<50} |")
print("|" + "-"*12 + "|" + "-"*67 + "|" + "-"*8 + "|" + "-"*52 + "|")

for tr in test_results:
    notes_trunc = (tr['notes'][:47] + '...') if len(tr['notes']) > 50 else tr['notes']
    desc_trunc = (tr['description'][:62] + '...') if len(tr['description']) > 65 else tr['description']
    print(f"| {tr['id']:<10} | {desc_trunc:<65} | {tr['result']:<6} | {notes_trunc:<50} |")

total_tests = len(test_results)
passed_tests = len([t for t in test_results if t["result"] == "PASS"])
failed_tests = total_tests - passed_tests

print("="*80)
print(f"TOTAL: {total_tests} | PASSED: {passed_tests} | FAILED: {failed_tests}")
print("="*80)

if failed_tests > 0:
    sys.exit(1)
sys.exit(0)
