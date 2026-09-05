-- Migration: 20260905000004_create_memberships_and_freeze.sql
-- Description: Memberships table, freeze log table, and RPC functions (Phase 2)
-- Locked Decisions:
-- D-04: membership end_date is EXCLUSIVE (expires on that date at 00:00:00 UTC / exactly on that date; membership is INVALID on and after end_date)
-- D-05: only gym owner can authorize freeze; end_date extends by the frozen days count
-- D-06: renewal updates/extends existing membership end_date; NEVER creates a duplicate record

-- 1. Create Status Enum
CREATE TYPE public.membership_status AS ENUM ('draft', 'scheduled', 'active', 'frozen', 'expired', 'cancelled');

-- 2. Create Memberships Table
CREATE TABLE public.memberships (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gym_id uuid NOT NULL REFERENCES public.gyms(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plan_id uuid REFERENCES public.plans(id) ON DELETE SET NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    status public.membership_status NOT NULL DEFAULT 'draft',
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT memberships_end_date_after_start_date CHECK (end_date > start_date)
);

-- D-04 EXPLICIT TABLE & COLUMN COMMENTS
COMMENT ON TABLE public.memberships IS 'end_date is EXCLUSIVE - membership is INVALID on and after end_date. Active check: start_date <= current_date AND current_date < end_date.';
COMMENT ON COLUMN public.memberships.gym_id IS 'Mandatory tenant identifier (gym_id) for multi-tenant isolation and RLS.';
COMMENT ON COLUMN public.memberships.end_date IS 'EXCLUSIVE expiry date. The membership expires at 00:00:00 on this date and is INVALID on and after this date (D-04).';
COMMENT ON COLUMN public.memberships.status IS 'Status lifecycle: draft -> scheduled -> active -> frozen/expired/cancelled.';

-- 3. Indexes
CREATE INDEX idx_memberships_gym_id ON public.memberships(gym_id);
CREATE INDEX idx_memberships_user_id ON public.memberships(user_id);
CREATE INDEX idx_memberships_plan_id ON public.memberships(plan_id);
CREATE INDEX idx_memberships_status ON public.memberships(status);
CREATE INDEX idx_memberships_dates ON public.memberships(start_date, end_date);

-- 4. Updated At Trigger
CREATE TRIGGER set_memberships_updated_at
    BEFORE UPDATE ON public.memberships
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 5. Enable RLS on memberships
ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

-- 6. RLS Policies on memberships
-- Member can view own membership; staff/manager/owner can view all memberships in their gym
CREATE POLICY "memberships_select_member_or_staff"
    ON public.memberships
    FOR SELECT
    TO authenticated
    USING (user_id = auth.uid() OR public.is_gym_staff(gym_id));

-- Gym staff, manager, or owner can create memberships
CREATE POLICY "memberships_insert_staff"
    ON public.memberships
    FOR INSERT
    TO authenticated
    WITH CHECK (public.is_gym_staff(gym_id));

-- Gym staff, manager, or owner can update memberships
CREATE POLICY "memberships_update_staff"
    ON public.memberships
    FOR UPDATE
    TO authenticated
    USING (public.is_gym_staff(gym_id))
    WITH CHECK (public.is_gym_staff(gym_id));

-- Only gym owner or manager can delete memberships
CREATE POLICY "memberships_delete_manager_or_owner"
    ON public.memberships
    FOR DELETE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id));

--------------------------------------------------------------------------------
-- 7. Create Membership Freeze Log Table (Audit Trail)
--------------------------------------------------------------------------------
CREATE TABLE public.membership_freeze_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gym_id uuid NOT NULL REFERENCES public.gyms(id) ON DELETE CASCADE,
    membership_id uuid NOT NULL REFERENCES public.memberships(id) ON DELETE CASCADE,
    frozen_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    frozen_days integer NOT NULL CHECK (frozen_days > 0),
    freeze_start_date date NOT NULL,
    freeze_end_date date NOT NULL,
    reason text,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT freeze_log_date_order CHECK (freeze_end_date >= freeze_start_date)
);

COMMENT ON TABLE public.membership_freeze_log IS 'Immutable audit trail of authorized membership freezes (D-05: only authorized by gym owner).';
COMMENT ON COLUMN public.membership_freeze_log.gym_id IS 'Mandatory tenant identifier (gym_id) for multi-tenant isolation and RLS.';
COMMENT ON COLUMN public.membership_freeze_log.frozen_by IS 'Owner UUID who authorized the freeze.';

-- Indexes
CREATE INDEX idx_freeze_log_membership_id ON public.membership_freeze_log(membership_id);
CREATE INDEX idx_freeze_log_gym_id ON public.membership_freeze_log(gym_id);
CREATE INDEX idx_freeze_log_frozen_by ON public.membership_freeze_log(frozen_by);

-- Enable RLS
ALTER TABLE public.membership_freeze_log ENABLE ROW LEVEL SECURITY;

-- RLS: staff/manager/owner can view freeze audit trail
CREATE POLICY "freeze_log_select_staff"
    ON public.membership_freeze_log
    FOR SELECT
    TO authenticated
    USING (public.is_gym_staff(gym_id));

-- RLS: Only owner can insert freeze logs (D-05)
CREATE POLICY "freeze_log_insert_owner"
    ON public.membership_freeze_log
    FOR INSERT
    TO authenticated
    WITH CHECK (public.is_gym_owner(gym_id));

--------------------------------------------------------------------------------
-- 8. RPC Function: freeze_membership (D-05)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.freeze_membership(
    p_membership_id uuid,
    p_frozen_days integer,
    p_reason text DEFAULT NULL
)
RETURNS public.memberships
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_membership public.memberships%ROWTYPE;
    v_caller_id uuid := auth.uid();
    v_freeze_start date := CURRENT_DATE;
    v_freeze_end date := CURRENT_DATE + p_frozen_days;
BEGIN
    IF p_frozen_days IS NULL OR p_frozen_days <= 0 THEN
        RAISE EXCEPTION 'frozen_days must be greater than 0';
    END IF;

    SELECT * INTO v_membership
    FROM public.memberships
    WHERE id = p_membership_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Membership not found with ID %', p_membership_id;
    END IF;

    -- D-05: Strict authorization check - ONLY gym owner can authorize freeze
    IF NOT public.is_gym_owner(v_membership.gym_id) THEN
        RAISE EXCEPTION 'Unauthorized: Only the gym owner can authorize a membership freeze (D-05).';
    END IF;

    -- Cannot freeze already cancelled or expired memberships
    IF v_membership.status IN ('cancelled', 'expired') THEN
        RAISE EXCEPTION 'Cannot freeze membership with status "%"', v_membership.status;
    END IF;

    -- D-05: Extend end_date by frozen_days (date arithmetic: date + integer = date)
    v_membership.end_date := v_membership.end_date + p_frozen_days;

    -- Set status to frozen if freeze is active today
    IF v_membership.start_date <= CURRENT_DATE AND v_membership.end_date > CURRENT_DATE THEN
        v_membership.status := 'frozen';
    END IF;

    v_membership.updated_at := timezone('utc'::text, now());

    UPDATE public.memberships
    SET end_date = v_membership.end_date,
        status = v_membership.status,
        updated_at = v_membership.updated_at
    WHERE id = p_membership_id;

    -- Audit trail log entry
    INSERT INTO public.membership_freeze_log (
        gym_id,
        membership_id,
        frozen_by,
        frozen_days,
        freeze_start_date,
        freeze_end_date,
        reason
    ) VALUES (
        v_membership.gym_id,
        p_membership_id,
        v_caller_id,
        p_frozen_days,
        v_freeze_start,
        v_freeze_end,
        p_reason
    );

    RETURN v_membership;
END;
$$;

COMMENT ON FUNCTION public.freeze_membership(uuid, integer, text) IS 'Authorizes a membership freeze, logs audit record, and extends end_date (D-05: owner only).';
GRANT EXECUTE ON FUNCTION public.freeze_membership(uuid, integer, text) TO authenticated;

--------------------------------------------------------------------------------
-- 9. RPC Function: renew_membership (D-06)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.renew_membership(
    p_membership_id uuid,
    p_additional_days integer
)
RETURNS public.memberships
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_membership public.memberships%ROWTYPE;
    v_base_date date;
BEGIN
    IF p_additional_days IS NULL OR p_additional_days <= 0 THEN
        RAISE EXCEPTION 'additional_days must be greater than 0';
    END IF;

    SELECT * INTO v_membership
    FROM public.memberships
    WHERE id = p_membership_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Membership not found with ID %', p_membership_id;
    END IF;

    -- Authorization check: staff, manager, or owner can renew
    IF NOT public.is_gym_staff(v_membership.gym_id) THEN
        RAISE EXCEPTION 'Unauthorized: Only gym staff, managers, or owners can renew memberships.';
    END IF;

    IF v_membership.status = 'cancelled' THEN
        RAISE EXCEPTION 'Cannot renew a cancelled membership.';
    END IF;

    -- D-06: Do NOT create a new record. Extend end_date on the existing membership record.
    -- D-04: end_date is EXCLUSIVE. If currently expired (end_date <= CURRENT_DATE),
    -- base extension from CURRENT_DATE so the member gets full additional_days from today.
    v_base_date := GREATEST(v_membership.end_date, CURRENT_DATE);
    v_membership.end_date := v_base_date + p_additional_days;

    -- Reactivate membership if expired or scheduled/active
    IF v_membership.status = 'expired' OR (v_membership.start_date <= CURRENT_DATE AND v_membership.status NOT IN ('frozen', 'cancelled')) THEN
        v_membership.status := 'active';
    END IF;

    v_membership.updated_at := timezone('utc'::text, now());

    UPDATE public.memberships
    SET end_date = v_membership.end_date,
        status = v_membership.status,
        updated_at = v_membership.updated_at
    WHERE id = p_membership_id;

    RETURN v_membership;
END;
$$;

COMMENT ON FUNCTION public.renew_membership(uuid, integer) IS 'Renews existing membership by extending end_date without creating duplicate record (D-06).';
GRANT EXECUTE ON FUNCTION public.renew_membership(uuid, integer) TO authenticated;

--------------------------------------------------------------------------------
-- 10. Helper Function: is_membership_active (D-04 strictly exclusive check)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_membership_active(p_membership_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.memberships
        WHERE id = p_membership_id
          AND status = 'active'
          AND start_date <= CURRENT_DATE
          AND CURRENT_DATE < end_date -- D-04: STRICTLY EXCLUSIVE (< end_date, NEVER <=)
    );
$$;

COMMENT ON FUNCTION public.is_membership_active(uuid) IS 'Checks if membership is currently active following D-04 (current_date < end_date, strictly exclusive).';
GRANT EXECUTE ON FUNCTION public.is_membership_active(uuid) TO authenticated;
