# 🏋️‍♂️ Xanvoraa Gym CRM — Backend Engine

> **Enterprise-grade Multi-Tenant Gym CRM Backend powered entirely by Supabase (PostgreSQL 17 + Supabase Auth + Row Level Security).**

---

## 📖 Executive Summary

**Xanvoraa Gym CRM** ka backend pure **Supabase BaaS (Backend-as-a-Service)** architecture par design kiya gaya hai. Isme koi traditional Node.js/Express ya Python server nahi hai. Application ki complete business logic, tenant isolation, authentication enforcement, aur role-based access control (RBAC) direct **PostgreSQL Database Engine** ke andar:
- **35 Row Level Security (RLS) Policies**
- **10 PostgreSQL Functions & Stored Procedures (`SECURITY DEFINER`)**
- **Automatic Database Triggers**
dwara enforce hoti hain.

---

## 📌 Locked Business Decisions

Neeche diye gaye core business rules architecture mein hard-locked hain aur database-level constraints dwara enforce kiye gaye hain:

| Code | Decision Title | Exact Rule & Implementation |
|---|---|---|
| **D-01** | **Auth Mode** | Sirf **Email + Password** login allowed hai. OTP/SMS signup system level par disabled hai. |
| **D-02** | **Contact Uniqueness** | Gym members ke **Phone aur Email unique nahi honge** (family members same number/email share kar sakte hain). Global login level (`auth.users`) par email unique rehta hai. |
| **D-03** | **Streak Tracking Engine** | Member streaks sirf un dino par count hoti hain jo gym ke branch shift ke `days_of_week` schedule mein operational hain. **Weekly closed/rest days (jaise Sat-Sun) streak ko break nahi karenge.** |
| **D-04** | **Exclusive Membership End Date** | Membership ki `end_date` **strictly EXCLUSIVE** hai. Us specified date ke `00:00:00 UTC` par membership expire ho jaati hai aur us din se membership **INVALID** maani jaati hai. Active validation: `start_date <= check_date AND check_date < end_date` (kabhi bhi `<= end_date` nahi). |
| **D-05** | **Owner-Only Freeze Authorization** | Sirf gym **owner** hi freeze authorize kar sakta hai (RPC `freeze_membership` mein check enforced). Freeze hone par `end_date` utne hi dino se extend hoti hai jitne din freeze rahi, aur immutable audit trail `membership_freeze_log` mein maintain hoti hai. |
| **D-06** | **Renewal without Record Duplication** | Membership renewal par **NAYA membership record NAHI banta** — existing membership ka hi `end_date` extend hota hai. Expired membership ke case mein extension `CURRENT_DATE` se start hoti hai. |
| **D-10** | **Strict Attendance Backdating** | Staff/owner manually attendance backdate kar sakte hain, lekin **MAX 7 din** tak hi allow hai. Backdate hone par **`backdate_reason` field mandatory** hai (database constraint + RPC check enforced). |
| **MULTI-TENANT** | **Mandatory Gym ID** | Har entity table mein `gym_id` column mandatory foreign key hai jo cross-tenant data leakage ko zero tolerance ke saath prevent karta hai. |

---

## 🏛️ System Architecture & Entity Relationships

```mermaid
erDiagram
    auth_users ||--|| profiles : "1:1 Identity"
    profiles ||--o{ gyms : "owns"
    gyms ||--o{ branches : "has multiple"
    gyms ||--o{ gym_users : "membership & roles"
    branches ||--o{ shifts : "schedules"
    gyms ||--o{ plans : "offers"
    gyms ||--o{ memberships : "manages"
    memberships ||--o{ membership_freeze_log : "freeze audits"
    gyms ||--o{ attendance_logs : "tracks check-ins"

    gyms {
        uuid id PK
        text name
        uuid owner_id FK
        timestamptz created_at
    }

    profiles {
        uuid id PK
        text email
        text full_name
        text phone
        app_role role
        text avatar_url
    }

    branches {
        uuid id PK
        uuid gym_id FK
        text name
        text address
    }

    shifts {
        uuid id PK
        uuid gym_id FK
        uuid branch_id FK
        text name
        integer_array days_of_week
        time open_time
        time close_time
    }

    gym_users {
        uuid id PK
        uuid gym_id FK
        uuid user_id FK
        app_role role
        uuid branch_id FK
    }

    plans {
        uuid id PK
        uuid gym_id FK
        text name
        integer duration_in_days
        numeric price
        boolean is_active
    }

    memberships {
        uuid id PK
        uuid gym_id FK
        uuid user_id FK
        uuid plan_id FK
        date start_date
        date end_date
        membership_status status
    }

    membership_freeze_log {
        uuid id PK
        uuid gym_id FK
        uuid membership_id FK
        uuid frozen_by FK
        integer frozen_days
        date freeze_start_date
        date freeze_end_date
        text reason
    }

    attendance_logs {
        uuid id PK
        uuid gym_id FK
        uuid branch_id FK
        uuid user_id FK
        uuid shift_id FK
        date check_in_date
        timestamptz check_in_time
        uuid marked_by FK
        boolean is_backdated
        text backdate_reason
    }
```

---

## 🗄️ Database Schema Breakdown (9 Core Tables)

### Phase 1: Foundation & Identity
1. **`public.profiles`**:
   - Linked 1:1 with Supabase `auth.users(id)` (`ON DELETE CASCADE`).
   - `id` (PK, UUID), `email` (TEXT), `full_name` (TEXT), `phone` (TEXT), `role` (`public.app_role`), `avatar_url` (TEXT), `created_at`, `updated_at`.
   - *Note*: Phone aur email par koi unique constraint nahi hai taaki family members shared contact info use kar sakein.
2. **`public.gyms`**:
   - Multi-tenant root entity.
   - `id` (PK, UUID), `name` (TEXT), `owner_id` (FK to `auth.users(id)`), `created_at`, `updated_at`.
3. **`public.branches`**:
   - Physical branch locations of a gym.
   - `id` (PK, UUID), `gym_id` (FK to `gyms(id)` `ON DELETE CASCADE`), `name` (TEXT), `address` (TEXT), `created_at`, `updated_at`.
4. **`public.gym_users`**:
   - Junction table associating users with gyms, roles, and branch assignments.
   - `id` (PK, UUID), `gym_id` (FK), `user_id` (FK), `role` (`'owner'`, `'manager'`, `'staff'`, `'member'`), `branch_id` (FK), `created_at`, `updated_at`.
   - *Constraint*: `UNIQUE (gym_id, user_id)`.

### Phase 2: CRM Core, Memberships & Shifts
5. **`public.plans`**:
   - Gym subscription templates.
   - `id` (PK, UUID), `gym_id` (FK), `name` (TEXT), `duration_in_days` (INT > 0), `price` (NUMERIC >= 0), `is_active` (BOOL), `created_at`, `updated_at`.
6. **`public.memberships`**:
   - Subscriptions assigned to members.
   - `id` (PK, UUID), `gym_id` (FK), `user_id` (FK), `plan_id` (FK), `start_date` (DATE), `end_date` (DATE), `status` (`'draft'`, `'scheduled'`, `'active'`, `'frozen'`, `'expired'`, `'cancelled'`), `created_at`, `updated_at`.
   - *Constraints*: `CHECK (end_date > start_date)`.
   - *Table Comment*: *"end_date is EXCLUSIVE - membership is INVALID on and after end_date"*.
7. **`public.membership_freeze_log`**:
   - Immutable audit trail for authorized freezes.
   - `id` (PK, UUID), `gym_id` (FK), `membership_id` (FK), `frozen_by` (FK), `frozen_days` (INT > 0), `freeze_start_date` (DATE), `freeze_end_date` (DATE), `reason` (TEXT), `created_at`.
   - *Constraint*: `CHECK (freeze_end_date >= freeze_start_date)`.
8. **`public.shifts`**:
   - Branch operating hours and scheduled workout days.
   - `id` (PK, UUID), `gym_id` (FK), `branch_id` (FK), `name` (TEXT), `days_of_week` (`INT[]`), `open_time` (TIME), `close_time` (TIME), `created_at`, `updated_at`.
   - *Constraints*: `CHECK (cardinality(days_of_week) > 0 AND days_of_week <@ ARRAY[1,2,3,4,5,6,7])`, `CHECK (open_time <> close_time)`.

### Phase 3: Attendance & Streak Engine
9. **`public.attendance_logs`**:
   - Daily member attendance logs.
   - `id` (PK, UUID), `gym_id` (FK), `branch_id` (FK), `user_id` (FK), `shift_id` (FK, nullable), `check_in_date` (DATE), `check_in_time` (TIMESTAMPTZ), `marked_by` (FK), `is_backdated` (BOOL), `backdate_reason` (TEXT), `created_at`.
   - *Constraints*:
     - `UNIQUE (gym_id, user_id, check_in_date)`: Prevents race conditions and double check-ins.
     - `CHECK (NOT is_backdated OR (backdate_reason IS NOT NULL AND length(trim(backdate_reason)) > 0))`: Mandates reason on backdating.

---

## ⚡ Stored Procedures & Helper Functions (`SECURITY DEFINER`)

All helper functions run as `SECURITY DEFINER` with fixed `search_path = public, pg_temp` to eliminate privilege escalation:

| Function Signature | Return Type | Description |
|---|---|---|
| `get_user_gym_ids()` | `SETOF uuid` | Authenticated user ke saare accessible `gym_id`s return karta hai. |
| `get_user_gym_id()` | `uuid` | Authenticated user ka primary/default `gym_id` return karta hai. |
| `get_user_role_in_gym(gym_id)` | `app_role` | Specified gym mein calling user ka role return karta hai. |
| `is_gym_owner(gym_id)` | `boolean` | Verify karta hai kya caller gym ka owner hai (`gyms.owner_id` ya `gym_users.role='owner'`). |
| `is_gym_manager_or_owner(gym_id)` | `boolean` | Verify karta hai kya caller manager ya owner hai. |
| `is_gym_staff(gym_id)` / `is_gym_staff_or_above(gym_id)` | `boolean` | Verify karta hai kya caller staff, manager ya owner hai. |
| `is_gym_member(gym_id)` | `boolean` | Verify karta hai kya caller gym ka affiliated member/user hai. |
| `is_membership_active(membership_id)` | `boolean` | Strictly evaluates D-04: `status='active' AND start_date <= CURRENT_DATE AND CURRENT_DATE < end_date`. |
| `freeze_membership(membership_id, frozen_days, reason)` | `memberships` | **D-05 RPC**: Validates owner authority, extends `end_date`, updates status to `'frozen'`, aur audit log insert karta hai. |
| `renew_membership(membership_id, additional_days)` | `memberships` | **D-06 RPC**: Existing membership record ko extend karta hai (no duplicates), expired membership ko `CURRENT_DATE` se reactivate karta hai. |
| `check_in_member(user_id, gym_id, branch_id, shift_id, check_in_date, reason)` | `attendance_logs` | **Check-in RPC**: Membership active check (D-04), duplicate prevention with clear error, D-10 backdate validation (max 7 days + reason). |
| `calculate_member_streak(user_id, gym_id, [as_of_date])` | `integer` | **D-03 Engine**: Branch shifts ke `days_of_week` ke against streak evaluate karta hai. Closed days streak break nahi karte. |

---

## 🔒 Row Level Security (RLS) Policy Matrix (35 Policies)

Every table has Row Level Security strictly enabled (`ALTER TABLE ... ENABLE ROW LEVEL SECURITY`):

| Table | Policy Name | Command | Access Criteria |
|---|---|---|---|
| `profiles` | `profiles_select_own` | SELECT | User views own profile (`auth.uid() = id`) |
| `profiles` | `profiles_select_gym_staff` | SELECT | Gym staff/manager/owner view members of their gym |
| `profiles` | `profiles_insert_own` | INSERT | Authenticated user creates own profile |
| `profiles` | `profiles_update_own` | UPDATE | User updates own profile |
| `profiles` | `profiles_update_by_gym_admin` | UPDATE | Gym owner/manager updates member profiles |
| `gyms` | `gyms_select_member` | SELECT | Users view gyms they belong to or own |
| `gyms` | `gyms_insert_authenticated` | INSERT | Authenticated user registers a gym (`auth.uid() = owner_id`) |
| `gyms` | `gyms_update_manager_or_owner` | UPDATE | Only gym owner or manager updates gym |
| `gyms` | `gyms_delete_owner` | DELETE | Only gym owner deletes gym |
| `branches` | `branches_select_member` | SELECT | Gym members view branches of their gym |
| `branches` | `branches_insert_manager_or_owner` | INSERT | Owner/Manager creates branches |
| `branches` | `branches_update_manager_or_owner` | UPDATE | Owner/Manager updates branches |
| `branches` | `branches_delete_manager_or_owner` | DELETE | Owner/Manager deletes branches |
| `gym_users` | `gym_users_select` | SELECT | Member views own membership; staff views all gym users |
| `gym_users` | `gym_users_insert_staff_or_owner` | INSERT | Staff/Manager/Owner enrolls users; Owner self-enrolled on create |
| `gym_users` | `gym_users_update_manager_or_owner` | UPDATE | Owner/Manager updates roles and branch assignments |
| `gym_users` | `gym_users_delete_manager_or_owner` | DELETE | Owner/Manager removes users from gym |
| `plans` | `plans_select_gym_member` | SELECT | Members view plans of their gym |
| `plans` | `plans_insert_manager_or_owner` | INSERT | Owner/Manager creates plans |
| `plans` | `plans_update_manager_or_owner` | UPDATE | Owner/Manager updates plans |
| `plans` | `plans_delete_manager_or_owner` | DELETE | Owner/Manager deletes plans |
| `memberships` | `memberships_select_member_or_staff` | SELECT | Member views own; staff views all gym memberships |
| `memberships` | `memberships_insert_staff` | INSERT | Staff/Manager/Owner creates memberships |
| `memberships` | `memberships_update_staff` | UPDATE | Staff/Manager/Owner updates memberships |
| `memberships` | `memberships_delete_manager_or_owner` | DELETE | Owner/Manager deletes memberships |
| `membership_freeze_log` | `freeze_log_select_staff` | SELECT | Staff/Manager/Owner views freeze audit logs |
| `membership_freeze_log` | `freeze_log_insert_owner` | INSERT | **D-05 Rule**: Only gym owner inserts freeze audit logs |
| `shifts` | `shifts_select_member` | SELECT | Members view branch shifts |
| `shifts` | `shifts_insert_manager_or_owner` | INSERT | Owner/Manager creates shifts |
| `shifts` | `shifts_update_manager_or_owner` | UPDATE | Owner/Manager updates shifts |
| `shifts` | `shifts_delete_manager_or_owner` | DELETE | Owner/Manager deletes shifts |
| `attendance_logs` | `attendance_logs_select_member_or_staff` | SELECT | Member views own attendance; staff views all gym attendance |
| `attendance_logs` | `attendance_logs_insert_staff` | INSERT | Direct insert for staff/owner; members must use `check_in_member()` RPC |
| `attendance_logs` | `attendance_logs_update_staff` | UPDATE | Staff/Manager/Owner updates attendance |
| `attendance_logs` | `attendance_logs_delete_manager_or_owner` | DELETE | Owner/Manager deletes attendance records |

---

## 🚀 Local Development Setup & Runbook

### Prerequisites
- [Docker Engine](https://docs.docker.com/engine/install/) running.
- Node.js (v18+) with `npx`.
- Python 3 (automated test suite ke liye).

### 1. Start Local Supabase
```bash
# Start all local containers (PostgreSQL, Auth, Storage, Studio, Mailpit)
npx supabase start
```

### 2. Available Endpoints
- **Supabase Studio (Dashboard UI)**: [http://127.0.0.1:54323](http://127.0.0.1:54323)
- **Postgres Database URL**: `postgresql://postgres:postgres@127.0.0.1:54322/postgres`
- **REST API (PostgREST)**: `http://127.0.0.1:54321/rest/v1`
- **Auth Service**: `http://127.0.0.1:54321/auth/v1`
- **Mailpit (Local Email Testing)**: [http://127.0.0.1:54324](http://127.0.0.1:54324)

### 3. Migration Commands
```bash
# Apply pending migrations
npx supabase migration up

# Check status of applied migrations
npx supabase migration list

# Full database reset (runs all migrations from scratch + seeds seed.sql)
npx supabase db reset

# Stop local containers
npx supabase stop
```

---

## 🧪 Automated Regression Test Suite

Project mein ek comprehensive automated regression test suite shamil hai jo sabhi 3 phases ke business rules, tenant isolation, concurrency, aur constraints ko end-to-end test karta hai:

```bash
# Run the test suite
python3 tests/regression_suite.py
```

### Regression Test Suite Results (17 / 17 Passed ✅)

| Test ID | Description | Result | Details & Validation |
|:---|:---|:---:|:---|
| **TEST 1.1** | Gym B owner queries Gym A data (`branches`, `gym_users`) | **PASS** | RLS blocked cross-tenant access (`branch_count=0`, `user_count=0`). |
| **TEST 1.2** | Gym A staff profile update boundary | **PASS** | Self profile updated; Gym B user update blocked (0 rows modified). |
| **TEST 1.3** | Auth user signup trigger | **PASS** | `profiles` entry auto-created with full name, email, and `'member'` role. |
| **TEST 1.4** | New gym creation trigger | **PASS** | Creator automatically enrolled in `gym_users` with `'owner'` role. |
| **TEST 2.1** | D-04 exclusive check on exact `end_date` | **PASS** | Day before `end_date` = Active (`t`), on exact `end_date` = Inactive (`f`). |
| **TEST 2.2** | D-05 unauthorized freeze attempt by staff | **PASS** | Rejected: *"Only the gym owner can authorize a membership freeze"*. |
| **TEST 2.3** | D-05 authorized freeze by owner for 7 days | **PASS** | `end_date` extended by 7 days, status `'frozen'`, audit entry logged. |
| **TEST 2.4** | D-06 renewal of expired membership | **PASS** | Existing row updated (no duplicate row), extended from `CURRENT_DATE + 30`, status `'active'`. |
| **TEST 2.5** | Constraint check: `end_date <= start_date` | **PASS** | Rejected by check constraint `memberships_end_date_after_start_date`. |
| **TEST 3.1** | Member1 regular self check-in for current date | **PASS** | Row created in `attendance_logs` with `is_backdated = false`. |
| **TEST 3.2** | Duplicate check-in prevention with explicit error | **PASS** | Rejected: *"Already checked in for this date"* (no silent fail). |
| **TEST 3.3** | Concurrent check-in race condition | **PASS** | 2 simultaneous calls: exactly 1 row created, 2nd call caught unique violation. |
| **TEST 3.4** | Member2 check-in after renewal | **PASS** | Active membership successfully validated, check-in passed. |
| **TEST 3.5** | D-10 valid backdating by staff (5 days back + reason) | **PASS** | Recorded with `is_backdated = true` and mandatory reason saved. |
| **TEST 3.6** | D-10 maximum backdating limit enforced | **PASS** | 10 days backdate attempt rejected: *"Backdating is limited to a maximum of 7 days (D-10)"*. |
| **TEST 3.7** | D-10 backdating reason validation | **PASS** | Backdate without reason rejected: *"Backdate reason is mandatory when marking past attendance (D-10)"*. |
| **TEST 3.8** | D-03 closed-day streak engine | **PASS** | Missed Thu–Fri reset streak on Next Mon to 1; Fri streak = 5; Sat/Sun closed weekend preserved streak. |

---

## 📁 Repository Directory Structure

```text
GymApp-backend/
├── .gitignore                                              # Root git ignore (runtime, caches, credentials)
├── README.md                                               # Detailed documentation, architecture, schema, runbook
├── supabase/
│   ├── config.toml                                         # Supabase CLI local configuration
│   ├── seed.sql                                            # Base seed data
│   └── migrations/                                         # Immutable sequential SQL migrations
│       ├── 20260905000001_create_base_schema.sql           # Profiles, Gyms, Branches, Gym Users, Triggers
│       ├── 20260905000002_create_rls_and_helpers.sql       # Helper functions & Phase 1 tenant isolation RLS
│       ├── 20260905000003_create_plans_table.sql           # Plans table & RBAC RLS
│       ├── 20260905000004_create_memberships_and_freeze.sql# Memberships, Freeze Log, D-05 Freeze & D-06 Renewal RPCs
│       ├── 20260905000005_create_shifts_table.sql          # Branch shifts & scheduled workout days
│       └── 20260905000006_create_attendance_and_streak.sql # Attendance Logs, Check-in RPC, D-03 Streak Engine
└── tests/
    └── regression_suite.py                                 # Automated end-to-end regression test suite (17 tests)
```

---

## 🔮 Upcoming Phases Roadmap

- **Phase 4 — Invoicing & Payments Ledger**:
  - `invoices` table (`id`, `gym_id`, `user_id`, `membership_id`, `amount`, `status`, `due_date`).
  - `payments` table (`id`, `gym_id`, `invoice_id`, `amount_paid`, `payment_method`, `transaction_ref`, `paid_at`).
  - Auto-invoice generation on membership creation and renewal.
- **Phase 5 — Analytics & Real-Time Reporting**:
  - Daily active attendance reporting per branch.
  - Expiring memberships alerts & revenue projection views.
