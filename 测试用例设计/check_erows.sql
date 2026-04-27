-- 估行断言存储过程：对任意 SELECT，EXPLAIN (FORMAT JSON) 抽顶层 Plan Rows，和预期比对
-- 推荐用法：CALL check_erows('<case_id>', '<sql>', <expected>, <tolerance>);
-- 兼容用法：CALL check_erows('<sql>', <expected>, <tolerance>);
-- 输出：一行 NOTICE，格式 [case_id] E_rows=A expected=B err=X% OK/FAIL
-- 注：本机 PG 未编译 libxml，使用 FORMAT JSON 替代 XML

CREATE OR REPLACE PROCEDURE check_erows(
    p_case_id   text,
    p_sql       text,
    p_expected  numeric,
    p_tol       numeric DEFAULT 0.05
) LANGUAGE plpgsql AS
    plan_json jsonb;
    E_rows_feature    numeric;
    E_rows_old    numeric;
    A_rows    numeric;
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

    IF (abs(E_rows_feature - p_expected) <= 2 AND p_expected <= 10) OR v_err <= p_tol THEN
        v_status := 'OK';
    ELSE
        v_status := 'FAIL';
    END IF;

    RAISE NOTICE '%', format('[%s] E_rows_old=%s A_rows=%s E_rows_feature=%s expected=%s err=%s%% %s',
        p_case_id, E_rows_old, A_rows, E_rows_feature, p_expected, round(v_err * 100, 2), v_status);
END;