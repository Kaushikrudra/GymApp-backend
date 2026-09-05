-- Migration: 20260905000006_create_attendance_and_streak.sql
-- Description: Attendance logs table, check-in RPC, and D-03 streak calculation function (Phase 3)
-- Locked Decisions:
-- D-03: Streaks are measured against scheduled shift days_of_week; weekly closed/off days do not break the streak.
-- D-10: Max 7 days backdate allowed for staff/owners; reason field is mandatory on backdated attendance.
-- Multi-tenant: gym_id mandatory across tables and queries.
-- D-04: Active membership strictly exclusive (start_date <= check_in_date AND check_in_date < end_date).

--------------------------------------------------------------------------------
-- 1. Create Attendance Logs Table
--------------------------------------------------------------------------------
CREATE TABLE public.attendance_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gym_id uuid NOT NULL REFERENCES public.gyms(id) ON DELETE CASCADE,
    branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    shift_id uuid REFERENCES public.shifts(id) ON DELETE SET NULL,
    check_in_date date NOT NULL,
    check_in_time timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    marked_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    is_backdated boolean NOT NULL DEFAULT false,
    backdate_reason text,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT attendance_logs_gym_user_date_key UNIQUE (gym_id, user_id, check_in_date),
    CONSTRAINT attendance_logs_backdate_reason_required CHECK (
        NOT is_backdated OR (backdate_reason IS NOT NULL AND length(trim(backdate_reason)) > 0)
    )
);

COMMENT ON TABLE public.attendance_logs IS 'Daily attendance check-in logs. Locked Decisions: D-03 streak tracking & D-10 max 7 days backdate with mandatory reason.';
COMMENT ON COLUMN public.attendance_logs.gym_id IS 'Mandatory tenant identifier (gym_id) for multi-tenant isolation and RLS.';
COMMENT ON COLUMN public.attendance_logs.check_in_date IS 'Business date of check-in. Unique per member per gym per day.';
COMMENT ON COLUMN public.attendance_logs.marked_by IS 'User UUID who recorded the attendance (self member or gym staff/owner).';
COMMENT ON COLUMN public.attendance_logs.is_backdated IS 'Flag indicating if check-in was recorded for a past date.';
COMMENT ON COLUMN public.attendance_logs.backdate_reason IS 'Mandatory explanation for backdating attendance (D-10).';

-- Performance Indexes
CREATE INDEX idx_attendance_logs_gym_user ON public.attendance_logs(gym_id, user_id);
CREATE INDEX idx_attendance_logs_date ON public.attendance_logs(check_in_date);
CREATE INDEX idx_attendance_logs_branch ON public.attendance_logs(branch_id);
CREATE INDEX idx_attendance_logs_shift ON public.attendance_logs(shift_id);
CREATE INDEX idx_attendance_logs_marked_by ON public.attendance_logs(marked_by);

--------------------------------------------------------------------------------
-- 2. Enable Row Level Security (RLS) on attendance_logs
--------------------------------------------------------------------------------
ALTER TABLE public.attendance_logs ENABLE ROW LEVEL SECURITY;

-- Member can view own attendance; staff/manager/owner can view all attendance in gym
CREATE POLICY "attendance_logs_select_member_or_staff"
    ON public.attendance_logs
    FOR SELECT
    TO authenticated
    USING (user_id = auth.uid() OR public.is_gym_staff(gym_id));

-- Direct insert restricted to staff/manager/owner (Members MUST use check_in_member RPC)
CREATE POLICY "attendance_logs_insert_staff"
    ON public.attendance_logs
    FOR INSERT
    TO authenticated
    WITH CHECK (public.is_gym_staff(gym_id));

-- Staff/manager/owner can update attendance records if needed
CREATE POLICY "attendance_logs_update_staff"
    ON public.attendance_logs
    FOR UPDATE
    TO authenticated
    USING (public.is_gym_staff(gym_id))
    WITH CHECK (public.is_gym_staff(gym_id));

-- Only gym owner or manager can delete attendance records
CREATE POLICY "attendance_logs_delete_manager_or_owner"
    ON public.attendance_logs
    FOR DELETE
    TO authenticated
    USING (public.is_gym_manager_or_owner(gym_id));

--------------------------------------------------------------------------------
-- 3. RPC Function: check_in_member
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_in_member(
    p_user_id uuid,
    p_gym_id uuid,
    p_branch_id uuid,
    p_shift_id uuid DEFAULT NULL,
    p_check_in_date date DEFAULT CURRENT_DATE,
    p_backdate_reason text DEFAULT NULL
)
RETURNS public.attendance_logs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id uuid := auth.uid();
    v_is_staff boolean := false;
    v_is_backdated boolean := false;
    v_days_diff integer;
    v_active_membership_exists boolean := false;
    v_result public.attendance_logs%ROWTYPE;
BEGIN
    -- 1. Caller validation: Self check-in or staff/manager/owner
    v_is_staff := public.is_gym_staff(p_gym_id);
    
    IF v_caller_id <> p_user_id AND NOT v_is_staff THEN
        RAISE EXCEPTION 'Unauthorized: Members can only check in for themselves.';
    END IF;

    -- Validate target user belongs to the gym
    IF NOT EXISTS (
        SELECT 1 FROM public.gym_users WHERE gym_id = p_gym_id AND user_id = p_user_id
    ) AND NOT EXISTS (
        SELECT 1 FROM public.gyms WHERE id = p_gym_id AND owner_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User does not belong to this gym.';
    END IF;

    -- Validate branch belongs to the gym
    IF NOT EXISTS (
        SELECT 1 FROM public.branches WHERE id = p_branch_id AND gym_id = p_gym_id
    ) THEN
        RAISE EXCEPTION 'Branch does not belong to the specified gym.';
    END IF;

    -- If shift_id provided, validate it belongs to the branch/gym
    IF p_shift_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.shifts WHERE id = p_shift_id AND gym_id = p_gym_id AND branch_id = p_branch_id
    ) THEN
        RAISE EXCEPTION 'Shift does not belong to the specified gym and branch.';
    END IF;

    -- 2. Future date check
    IF p_check_in_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot check in for a future date (% > %).', p_check_in_date, CURRENT_DATE;
    END IF;

    -- 3. Backdate validation (D-10)
    IF p_check_in_date < CURRENT_DATE THEN
        -- D-10: Only staff/manager/owner can mark backdated attendance
        IF NOT v_is_staff THEN
            RAISE EXCEPTION 'Unauthorized: Only staff, managers, or owners can backdate attendance (D-10).';
        END IF;

        v_days_diff := CURRENT_DATE - p_check_in_date;

        -- D-10: MAX 7 days backdate allowed
        IF v_days_diff > 7 THEN
            RAISE EXCEPTION 'Backdating is limited to a maximum of 7 days (D-10). Attempted: % days.', v_days_diff;
        END IF;

        -- D-10: Reason is MANDATORY
        IF p_backdate_reason IS NULL OR length(trim(p_backdate_reason)) = 0 THEN
            RAISE EXCEPTION 'Backdate reason is mandatory when marking past attendance (D-10).';
        END IF;

        v_is_backdated := true;
    ELSE
        v_is_backdated := false;
    END IF;

    -- 4. Membership check: Must be active on p_check_in_date
    -- D-04: start_date <= p_check_in_date AND p_check_in_date < end_date (EXCLUSIVE)
    -- Status must be 'active' (not frozen, cancelled, or expired)
    SELECT EXISTS (
        SELECT 1 FROM public.memberships
        WHERE gym_id = p_gym_id
          AND user_id = p_user_id
          AND status = 'active'
          AND start_date <= p_check_in_date
          AND p_check_in_date < end_date -- D-04: EXCLUSIVE (< end_date, NEVER <=)
    ) INTO v_active_membership_exists;

    IF NOT v_active_membership_exists THEN
        RAISE EXCEPTION 'Member does not have an active membership for this gym on % (frozen, expired, or invalid).', p_check_in_date;
    END IF;

    -- 5. Duplicate handling: Check if already checked in on p_check_in_date
    IF EXISTS (
        SELECT 1 FROM public.attendance_logs
        WHERE gym_id = p_gym_id
          AND user_id = p_user_id
          AND check_in_date = p_check_in_date
    ) THEN
        RAISE EXCEPTION 'Already checked in for this date';
    END IF;

    -- 6. Insert attendance record
    BEGIN
        INSERT INTO public.attendance_logs (
            gym_id,
            branch_id,
            user_id,
            shift_id,
            check_in_date,
            check_in_time,
            marked_by,
            is_backdated,
            backdate_reason
        ) VALUES (
            p_gym_id,
            p_branch_id,
            p_user_id,
            p_shift_id,
            p_check_in_date,
            timezone('utc'::text, now()),
            v_caller_id,
            v_is_backdated,
            CASE WHEN v_is_backdated THEN trim(p_backdate_reason) ELSE NULL END
        )
        RETURNING * INTO v_result;
    EXCEPTION
        WHEN unique_violation THEN
            -- In case of concurrent race conditions, raise clear duplicate error
            RAISE EXCEPTION 'Already checked in for this date';
    END;

    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.check_in_member(uuid, uuid, uuid, uuid, date, text) IS 'Marks member attendance with membership validation, D-10 backdate rule (max 7 days + reason), and duplicate prevention.';
GRANT EXECUTE ON FUNCTION public.check_in_member(uuid, uuid, uuid, uuid, date, text) TO authenticated;

--------------------------------------------------------------------------------
-- 4. Streak Calculation Function: calculate_member_streak (D-03)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculate_member_streak(
    p_user_id uuid,
    p_gym_id uuid,
    p_as_of_date date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_branch_id uuid;
    v_scheduled_days integer[];
    v_streak integer := 0;
    v_check_date date;
    v_dow integer;
    v_attended boolean;
    v_attended_as_of boolean;
BEGIN
    -- 1. Identify user's branch affiliation (if any)
    SELECT branch_id INTO v_user_branch_id
    FROM public.gym_users
    WHERE gym_id = p_gym_id AND user_id = p_user_id
    LIMIT 1;

    -- 2. Find scheduled workout days (D-03) for the branch or gym
    IF v_user_branch_id IS NOT NULL THEN
        SELECT array_agg(DISTINCT day_num) INTO v_scheduled_days
        FROM (
            SELECT unnest(days_of_week) AS day_num
            FROM public.shifts
            WHERE gym_id = p_gym_id AND branch_id = v_user_branch_id
        ) s;
    END IF;

    -- If branch has no shifts defined, fallback to all gym shifts
    IF v_scheduled_days IS NULL OR cardinality(v_scheduled_days) = 0 THEN
        SELECT array_agg(DISTINCT day_num) INTO v_scheduled_days
        FROM (
            SELECT unnest(days_of_week) AS day_num
            FROM public.shifts
            WHERE gym_id = p_gym_id
        ) s;
    END IF;

    -- If gym has no shifts at all, default to Monday-Sunday (all 7 days)
    IF v_scheduled_days IS NULL OR cardinality(v_scheduled_days) = 0 THEN
        v_scheduled_days := ARRAY[1, 2, 3, 4, 5, 6, 7];
    END IF;

    -- 3. Check attendance on p_as_of_date
    SELECT EXISTS (
        SELECT 1 FROM public.attendance_logs
        WHERE gym_id = p_gym_id
          AND user_id = p_user_id
          AND check_in_date = p_as_of_date
    ) INTO v_attended_as_of;

    IF v_attended_as_of THEN
        v_streak := 1;
    END IF;

    -- 4. Walk backwards through past calendar dates
    v_check_date := p_as_of_date - 1;

    LOOP
        -- Safety bound: limit streak search to past 365 calendar days
        EXIT WHEN v_check_date < (p_as_of_date - 365);

        -- ISO weekday: 1 = Monday, ..., 7 = Sunday
        v_dow := EXTRACT(ISODOW FROM v_check_date)::integer;

        -- D-03: If day was NOT in scheduled shifts (gym closed/rest day),
        -- skip it! Closed days do NOT break streak and do NOT count towards streak days.
        IF NOT (v_dow = ANY(v_scheduled_days)) THEN
            v_check_date := v_check_date - 1;
            CONTINUE;
        END IF;

        -- On a scheduled gym day, check if member attended
        SELECT EXISTS (
            SELECT 1 FROM public.attendance_logs
            WHERE gym_id = p_gym_id
              AND user_id = p_user_id
              AND check_in_date = v_check_date
        ) INTO v_attended;

        IF v_attended THEN
            v_streak := v_streak + 1;
            v_check_date := v_check_date - 1;
        ELSE
            -- Scheduled gym day missed -> Streak ends here
            EXIT;
        END IF;
    END LOOP;

    RETURN v_streak;
END;
$$;

-- Default 2-argument signature forwarding to CURRENT_DATE
CREATE OR REPLACE FUNCTION public.calculate_member_streak(
    p_user_id uuid,
    p_gym_id uuid
)
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
    SELECT public.calculate_member_streak(p_user_id, p_gym_id, CURRENT_DATE);
$$;

COMMENT ON FUNCTION public.calculate_member_streak(uuid, uuid, date) IS 'Calculates member continuous streak counting only shift-scheduled days as of a specific date (D-03: closed days do not break streak).';
COMMENT ON FUNCTION public.calculate_member_streak(uuid, uuid) IS 'Calculates member continuous streak counting only shift-scheduled days as of CURRENT_DATE (D-03: closed days do not break streak).';
GRANT EXECUTE ON FUNCTION public.calculate_member_streak(uuid, uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_member_streak(uuid, uuid) TO authenticated;
