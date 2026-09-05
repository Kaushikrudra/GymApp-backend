-- Migration: 20260905000003_create_plans_table.sql
-- Description: Plans table with RLS for Xanvoraa Gym CRM (Phase 2)
-- Locked Decision: Multi-tenant architecture (mandatory gym_id)

-- 1. Helper function alias if referenced
CREATE OR REPLACE FUNCTION public.is_gym_staff_or_above(check_gym_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT public.is_gym_staff(check_gym_id);
$$;

COMMENT ON FUNCTION public.is_gym_staff_or_above(uuid) IS 'Alias for is_gym_staff: Checks if user has staff, manager, or owner role.';

-- 2. Create Plans Table
CREATE TABLE public.plans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gym_id uuid NOT NULL REFERENCES public.gyms(id) ON DELETE CASCADE,
    name text NOT NULL,
    duration_in_days integer NOT NULL CHECK (duration_in_days > 0),
    price numeric(10, 2) NOT NULL CHECK (price >= 0),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now())
);

COMMENT ON TABLE public.plans IS 'Membership plan templates (e.g. 1 Month, 3 Months, Annual) configured per gym.';
COMMENT ON COLUMN public.plans.gym_id IS 'Mandatory tenant identifier (gym_id) for multi-tenant isolation and RLS.';
COMMENT ON COLUMN public.plans.duration_in_days IS 'Duration of the plan in days. Used when calculating membership end_date.';
COMMENT ON COLUMN public.plans.price IS 'Price of the plan.';

-- 3. Indexes
CREATE INDEX idx_plans_gym_id ON public.plans(gym_id);
CREATE INDEX idx_plans_is_active ON public.plans(is_active);

-- 4. Updated At Trigger
CREATE TRIGGER set_plans_updated_at
    BEFORE UPDATE ON public.plans
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 5. Enable RLS
ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;

-- 6. RLS Policies
-- Members can view plans belonging to their gym
CREATE POLICY "plans_select_gym_member"
    ON public.plans
    FOR SELECT
    TO authenticated
    USING (public.is_gym_member(gym_id));

-- Only gym owner or manager can create plans
CREATE POLICY "plans_insert_manager_or_owner"
    ON public.plans
    FOR INSERT
    TO authenticated
    WITH CHECK (public.is_gym_manager_or_owner(gym_id));

-- Only gym owner or manager can update plans
CREATE POLICY "plans_update_manager_or_owner"
    ON public.plans
    FOR UPDATE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id))
    WITH CHECK (public.is_gym_manager_or_owner(gym_id));

-- Only gym owner or manager can delete plans
CREATE POLICY "plans_delete_manager_or_owner"
    ON public.plans
    FOR DELETE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id));
