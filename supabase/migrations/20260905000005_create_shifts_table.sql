-- Migration: 20260905000005_create_shifts_table.sql
-- Description: Shifts table for branch workout schedules & D-03 streak foundation (Phase 2)
-- Locked Decisions:
-- Multi-tenant: gym_id is mandatory for tenant isolation
-- D-03: Scheduled gym days streak calculation will be evaluated against branch shifts and active days_of_week

-- 1. Create Shifts Table
CREATE TABLE public.shifts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gym_id uuid NOT NULL REFERENCES public.gyms(id) ON DELETE CASCADE,
    branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
    name text NOT NULL,
    days_of_week integer[] NOT NULL,
    open_time time NOT NULL,
    close_time time NOT NULL,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT shifts_days_of_week_valid CHECK (
        cardinality(days_of_week) > 0 AND days_of_week <@ ARRAY[1,2,3,4,5,6,7]
    ),
    CONSTRAINT shifts_time_valid CHECK (open_time <> close_time)
);

COMMENT ON TABLE public.shifts IS 'Branch shifts and scheduled workout days. Serves as the foundation for D-03 streak calculation.';
COMMENT ON COLUMN public.shifts.gym_id IS 'Mandatory tenant identifier (gym_id) for multi-tenant isolation and RLS.';
COMMENT ON COLUMN public.shifts.branch_id IS 'Branch location where this shift is active.';
COMMENT ON COLUMN public.shifts.days_of_week IS 'Array of active ISO weekday numbers (1=Monday, 2=Tuesday, ..., 7=Sunday).';
COMMENT ON COLUMN public.shifts.open_time IS 'Shift start time.';
COMMENT ON COLUMN public.shifts.close_time IS 'Shift end time.';

-- 2. Indexes
CREATE INDEX idx_shifts_gym_id ON public.shifts(gym_id);
CREATE INDEX idx_shifts_branch_id ON public.shifts(branch_id);

-- 3. Updated At Trigger
CREATE TRIGGER set_shifts_updated_at
    BEFORE UPDATE ON public.shifts
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 4. Enable RLS
ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;

-- 5. RLS Policies
-- Gym members can view shifts of their gym
CREATE POLICY "shifts_select_member"
    ON public.shifts
    FOR SELECT
    TO authenticated
    USING (public.is_gym_member(gym_id));

-- Gym owner or manager can create shifts
CREATE POLICY "shifts_insert_manager_or_owner"
    ON public.shifts
    FOR INSERT
    TO authenticated
    WITH CHECK (public.is_gym_manager_or_owner(gym_id));

-- Gym owner or manager can update shifts
CREATE POLICY "shifts_update_manager_or_owner"
    ON public.shifts
    FOR UPDATE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id))
    WITH CHECK (public.is_gym_manager_or_owner(gym_id));

-- Gym owner or manager can delete shifts
CREATE POLICY "shifts_delete_manager_or_owner"
    ON public.shifts
    FOR DELETE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id));
