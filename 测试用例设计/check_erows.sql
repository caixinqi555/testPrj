DROP FUNCTION IF EXISTS check_erows;
CREATE OR REPLACE FUNCTION check_erows(
    p_case_id   text,
    p_sql       text,
    p_expected  numeric,
    p_tol       numeric DEFAULT 0.05
) RETURNS TABLE (
    case_id        text,
    E_rows_old     numeric,
    A_rows         numeric,
    E_rows_feature numeric,
    expected       numeric,
    err_percent    numeric,
    status         text
)
LANGUAGE plpgsql AS $$
DECLARE
    plan_json jsonb;
    v_err     numeric;
    v_status  text;
BEGIN
    EXECUTE 'set refine_growth_sel = off';
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || p_sql INTO plan_json;
    E_rows_old := (plan_json -> 0 -> 'Plan' ->> 'Plan Rows')::numeric;

    EXECUTE 'set refine_growth_sel = on';
    EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || p_sql INTO plan_json;
    E_rows_feature := (plan_json -> 0 -> 'Plan' ->> 'Plan Rows')::numeric;
    A_rows := (plan_json -> 0 -> 'Plan' ->> 'Actual Rows')::numeric;

    IF p_expected = 0 THEN
        v_err := CASE WHEN E_rows_feature = 0 THEN 0 ELSE 1 END;
    ELSE
        v_err := abs(E_rows_feature - p_expected) / p_expected;
    END IF;

    IF (abs(E_rows_feature - p_expected) <= 2 AND p_expected <= 10)
       OR v_err <= p_tol THEN
        v_status := 'OK';
    ELSE
        v_status := 'FAIL';
    END IF;

    case_id := p_case_id;
    expected := p_expected;
    err_percent := round(v_err * 100, 2);
    status := v_status;

    RETURN NEXT;
END;
$$;
