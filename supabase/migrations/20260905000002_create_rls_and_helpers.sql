-- Migration: 20260905000002_create_rls_and_helpers.sql
-- Description: Enable RLS, define reusable helper functions, and create tenant isolation policies for Xanvoraa Gym CRM
-- Locked Business Decisions:
-- 1. Strict tenant isolation: Cross-gym data leakage is strictly forbidden.
-- 2. Role hierarchy: Owner > Manager > Staff > Member.
-- 3. All tables have Row Level Security enabled.

--------------------------------------------------------------------------------
-- 1. HELPER FUNCTIONS (SECURITY DEFINER with fixed search_path to prevent bypass)
--------------------------------------------------------------------------------

-- Returns list of all gym IDs associated with the calling user
CREATE OR REPLACE FUNCTION public.get_user_gym_ids()
RETURNS SETOF uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT gym_id FROM public.gym_users WHERE user_id = auth.uid()
    UNION
    SELECT id FROM public.gyms WHERE owner_id = auth.uid();
$$;

COMMENT ON FUNCTION public.get_user_gym_ids() IS 'Returns all gym_ids accessible to the currently authenticated user.';

-- Returns the primary/first gym ID for the calling user
CREATE OR REPLACE FUNCTION public.get_user_gym_id()
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT gym_id FROM public.gym_users 
    WHERE user_id = auth.uid() 
    ORDER BY created_at ASC 
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_user_gym_id() IS 'Returns the primary/default gym_id of the current user.';

-- Returns the user role within a specific gym
CREATE OR REPLACE FUNCTION public.get_user_role_in_gym(check_gym_id uuid)
RETURNS public.app_role
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT role FROM public.gym_users
    WHERE gym_id = check_gym_id AND user_id = auth.uid()
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_user_role_in_gym(uuid) IS 'Returns the app_role (owner/manager/staff/member) of the current user in the specified gym.';

-- Checks if current user is an owner of the specified gym
CREATE OR REPLACE FUNCTION public.is_gym_owner(check_gym_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.gyms
        WHERE id = check_gym_id AND owner_id = auth.uid()
    ) OR EXISTS (
        SELECT 1 FROM public.gym_users
        WHERE gym_id = check_gym_id AND user_id = auth.uid() AND role = 'owner'
    );
$$;

COMMENT ON FUNCTION public.is_gym_owner(uuid) IS 'Checks whether the current user is the owner of the given gym.';

-- Checks if current user is a manager or owner of the specified gym
CREATE OR REPLACE FUNCTION public.is_gym_manager_or_owner(check_gym_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.gyms
        WHERE id = check_gym_id AND owner_id = auth.uid()
    ) OR EXISTS (
        SELECT 1 FROM public.gym_users
        WHERE gym_id = check_gym_id AND user_id = auth.uid() AND role IN ('owner', 'manager')
    );
$$;

COMMENT ON FUNCTION public.is_gym_manager_or_owner(uuid) IS 'Checks whether the current user is a manager or owner in the given gym.';

-- Checks if current user is staff, manager, or owner of the specified gym
CREATE OR REPLACE FUNCTION public.is_gym_staff(check_gym_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.gyms
        WHERE id = check_gym_id AND owner_id = auth.uid()
    ) OR EXISTS (
        SELECT 1 FROM public.gym_users
        WHERE gym_id = check_gym_id AND user_id = auth.uid() AND role IN ('owner', 'manager', 'staff')
    );
$$;

COMMENT ON FUNCTION public.is_gym_staff(uuid) IS 'Checks whether current user has staff or administrative privileges in the given gym.';

-- Checks if current user is associated with the specified gym (any role)
CREATE OR REPLACE FUNCTION public.is_gym_member(check_gym_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.gyms
        WHERE id = check_gym_id AND owner_id = auth.uid()
    ) OR EXISTS (
        SELECT 1 FROM public.gym_users
        WHERE gym_id = check_gym_id AND user_id = auth.uid()
    );
$$;

COMMENT ON FUNCTION public.is_gym_member(uuid) IS 'Checks whether current user belongs to the specified gym in any capacity.';


--------------------------------------------------------------------------------
-- 2. ENABLE ROW LEVEL SECURITY (RLS) ON ALL TABLES
--------------------------------------------------------------------------------

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gyms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gym_users ENABLE ROW LEVEL SECURITY;


--------------------------------------------------------------------------------
-- 3. RLS POLICIES: PROFILES
--------------------------------------------------------------------------------

-- Users can view their own profile
CREATE POLICY "profiles_select_own"
    ON public.profiles
    FOR SELECT
    TO authenticated
    USING (auth.uid() = id);

-- Staff, managers, and owners can view profiles of members in the same gym
CREATE POLICY "profiles_select_gym_staff"
    ON public.profiles
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 
            FROM public.gym_users gu_viewer
            JOIN public.gym_users gu_target ON gu_viewer.gym_id = gu_target.gym_id
            WHERE gu_viewer.user_id = auth.uid()
              AND gu_viewer.role IN ('owner', 'manager', 'staff')
              AND gu_target.user_id = public.profiles.id
        )
    );

-- User can create/insert their own profile
CREATE POLICY "profiles_insert_own"
    ON public.profiles
    FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = id);

-- User can update their own profile
CREATE POLICY "profiles_update_own"
    ON public.profiles
    FOR UPDATE
    TO authenticated
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

-- Gym managers or owners can update profiles of members in their gym
CREATE POLICY "profiles_update_by_gym_admin"
    ON public.profiles
    FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 
            FROM public.gym_users gu_viewer
            JOIN public.gym_users gu_target ON gu_viewer.gym_id = gu_target.gym_id
            WHERE gu_viewer.user_id = auth.uid()
              AND gu_viewer.role IN ('owner', 'manager')
              AND gu_target.user_id = public.profiles.id
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 
            FROM public.gym_users gu_viewer
            JOIN public.gym_users gu_target ON gu_viewer.gym_id = gu_target.gym_id
            WHERE gu_viewer.user_id = auth.uid()
              AND gu_viewer.role IN ('owner', 'manager')
              AND gu_target.user_id = public.profiles.id
        )
    );


--------------------------------------------------------------------------------
-- 4. RLS POLICIES: GYMS
--------------------------------------------------------------------------------

-- Users can view gyms they belong to or own
CREATE POLICY "gyms_select_member"
    ON public.gyms
    FOR SELECT
    TO authenticated
    USING (public.is_gym_member(id));

-- Any authenticated user can create a new gym (they become owner)
CREATE POLICY "gyms_insert_authenticated"
    ON public.gyms
    FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = owner_id);

-- Only gym owner or manager can update gym details
CREATE POLICY "gyms_update_manager_or_owner"
    ON public.gyms
    FOR UPDATE
    TO authenticated
    USING (public.is_gym_manager_or_owner(id))
    WITH CHECK (public.is_gym_manager_or_owner(id));

-- Only the gym owner can delete the gym
CREATE POLICY "gyms_delete_owner"
    ON public.gyms
    FOR DELETE
    TO authenticated
    USING (public.is_gym_owner(id));


--------------------------------------------------------------------------------
-- 5. RLS POLICIES: BRANCHES
--------------------------------------------------------------------------------

-- Users belonging to the gym can view its branches
CREATE POLICY "branches_select_member"
    ON public.branches
    FOR SELECT
    TO authenticated
    USING (public.is_gym_member(gym_id));

-- Gym owner or manager can create branches
CREATE POLICY "branches_insert_manager_or_owner"
    ON public.branches
    FOR INSERT
    TO authenticated
    WITH CHECK (public.is_gym_manager_or_owner(gym_id));

-- Gym owner or manager can update branches
CREATE POLICY "branches_update_manager_or_owner"
    ON public.branches
    FOR UPDATE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id))
    WITH CHECK (public.is_gym_manager_or_owner(gym_id));

-- Gym owner or manager can delete branches
CREATE POLICY "branches_delete_manager_or_owner"
    ON public.branches
    FOR DELETE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id));


--------------------------------------------------------------------------------
-- 6. RLS POLICIES: GYM_USERS
--------------------------------------------------------------------------------

-- Users can view their own gym affiliation, and gym staff can view all gym users in their gym
CREATE POLICY "gym_users_select"
    ON public.gym_users
    FOR SELECT
    TO authenticated
    USING (user_id = auth.uid() OR public.is_gym_staff(gym_id));

-- Gym staff, manager, or owner can add members/users to their gym; owners can also enroll themselves
CREATE POLICY "gym_users_insert_staff_or_owner"
    ON public.gym_users
    FOR INSERT
    TO authenticated
    WITH CHECK (public.is_gym_staff(gym_id) OR public.is_gym_owner(gym_id));

-- Gym owner or manager can update user roles/branches
CREATE POLICY "gym_users_update_manager_or_owner"
    ON public.gym_users
    FOR UPDATE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id))
    WITH CHECK (public.is_gym_manager_or_owner(gym_id));

-- Gym owner or manager can remove users from the gym
CREATE POLICY "gym_users_delete_manager_or_owner"
    ON public.gym_users
    FOR DELETE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id));
