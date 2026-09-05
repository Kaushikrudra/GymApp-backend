-- Migration: 20260905000001_create_base_schema.sql
-- Description: Phase 1 Foundation Schema for Xanvoraa Gym CRM
-- Locked Business Decisions:
-- 1. Multi-tenant architecture: Every tenant table must include a mandatory gym_id column.
-- 2. Membership end_date is EXCLUSIVE (expires on that date at 00:00:00 UTC / exactly on that date).
-- 3. Member phone/email are NOT unique (family shared numbers/emails allowed); only auth.users email is unique.
-- 4. Auth is strictly Email + Password (no OTP/phone login in Phase 1).

-- Schema-level documentation comment for locked architectural decisions
COMMENT ON SCHEMA public IS 'Xanvoraa Gym CRM Backend (Phase 1 Foundation).
Locked Architectural Decisions:
1. Multi-Tenant Architecture: Every tenant data table must include a mandatory gym_id column.
2. Membership Validity: Membership end_date is strictly EXCLUSIVE (expires on that exact date at 00:00:00 UTC / exactly on that date).
3. Contact Uniqueness: Member phone and email are NOT unique across gym members (family members may share phone/email). auth.users email remains unique.
4. Authentication: Strictly email + password (no OTP/phone login in Phase 1).';

-- 1. Create Role Enum
CREATE TYPE public.app_role AS ENUM ('owner', 'manager', 'staff', 'member');

-- 2. Profiles Table (Linked to auth.users)
CREATE TABLE public.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email text,
    full_name text NOT NULL DEFAULT '',
    phone text,
    role public.app_role NOT NULL DEFAULT 'member',
    avatar_url text,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now())
);

COMMENT ON TABLE public.profiles IS 'User profile data linked to auth.users. Member phone and email are NOT unique to permit family sharing.';
COMMENT ON COLUMN public.profiles.phone IS 'Contact phone number. Non-unique to allow family members to share phone numbers.';
COMMENT ON COLUMN public.profiles.email IS 'Email address. Non-unique across member records (family sharing allowed); uniqueness enforced at auth.users level.';

-- 3. Gyms Table (Tenant Root)
CREATE TABLE public.gyms (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now())
);

COMMENT ON TABLE public.gyms IS 'Gym entity representing a tenant in the multi-tenant system.';
COMMENT ON COLUMN public.gyms.owner_id IS 'UUID of the gym owner from auth.users.';

-- 4. Branches Table
CREATE TABLE public.branches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gym_id uuid NOT NULL REFERENCES public.gyms(id) ON DELETE CASCADE,
    name text NOT NULL,
    address text,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now())
);

COMMENT ON TABLE public.branches IS 'Physical locations or branches belonging to a gym.';
COMMENT ON COLUMN public.branches.gym_id IS 'Mandatory tenant identifier (gym_id) for isolation and RLS.';

-- 5. Gym Users Junction Table
CREATE TABLE public.gym_users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gym_id uuid NOT NULL REFERENCES public.gyms(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role public.app_role NOT NULL DEFAULT 'member',
    branch_id uuid REFERENCES public.branches(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT gym_users_gym_id_user_id_key UNIQUE (gym_id, user_id)
);

COMMENT ON TABLE public.gym_users IS 'Junction table associating users with gyms and assigning roles and branches.';
COMMENT ON COLUMN public.gym_users.gym_id IS 'Mandatory tenant identifier (gym_id) for isolation and RLS.';
COMMENT ON COLUMN public.gym_users.role IS 'Role of the user within this specific gym (owner, manager, staff, member).';

-- 6. Performance Indexes
CREATE INDEX idx_profiles_role ON public.profiles(role);
CREATE INDEX idx_gyms_owner_id ON public.gyms(owner_id);
CREATE INDEX idx_branches_gym_id ON public.branches(gym_id);
CREATE INDEX idx_gym_users_gym_id ON public.gym_users(gym_id);
CREATE INDEX idx_gym_users_user_id ON public.gym_users(user_id);
CREATE INDEX idx_gym_users_branch_id ON public.gym_users(branch_id);

-- 7. Updated At Trigger Function
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER set_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER set_gyms_updated_at
    BEFORE UPDATE ON public.gyms
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER set_branches_updated_at
    BEFORE UPDATE ON public.branches
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER set_gym_users_updated_at
    BEFORE UPDATE ON public.gym_users
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 8. Auto-create profile trigger on auth.users sign up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name, role)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(
            NULLIF(NEW.raw_user_meta_data->>'full_name', ''),
            NULLIF(NEW.raw_user_meta_data->>'name', ''),
            split_part(COALESCE(NEW.email, ''), '@', 1),
            'User'
        ),
        'member'
    )
    ON CONFLICT (id) DO UPDATE
    SET email = EXCLUDED.email;
    RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 9. Auto-enroll gym owner in gym_users upon gym creation
CREATE OR REPLACE FUNCTION public.handle_new_gym()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.gym_users (gym_id, user_id, role)
    VALUES (NEW.id, NEW.owner_id, 'owner')
    ON CONFLICT (gym_id, user_id) DO UPDATE SET role = 'owner';
    RETURN NEW;
END;
$$;

CREATE TRIGGER on_gym_created
    AFTER INSERT ON public.gyms
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_gym();
