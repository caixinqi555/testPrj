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
) LANGUAGE plpgsql AS $$
DECLARE
    plan_json jsonb;
    v_rows    numeric;
    v_err     numeric;
    v_status  text;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || p_sql INTO plan_json;

    v_rows := (plan_json -> 0 -> 'Plan' ->> 'Plan Rows')::numeric;

    IF p_expected = 0 THEN
        v_err := CASE WHEN v_rows = 0 THEN 0 ELSE 1 END;
    ELSE
        v_err := abs(v_rows - p_expected) / p_expected;
    END IF;

    IF (abs(v_rows - p_expected) <= 2 AND p_expected <= 10) OR v_err <= p_tol THEN
        v_status := 'OK';
    ELSE
        v_status := 'FAIL';
    END IF;

    RAISE NOTICE '%', format('[%s] E_rows=%s expected=%s err=%s%% %s',
        p_case_id, v_rows, p_expected, round(v_err * 100, 2), v_status);
END;
$$;

CREATE OR REPLACE PROCEDURE check_erows(
    p_sql       text,
    p_expected  numeric,
    p_tol       numeric DEFAULT 0.05
) LANGUAGE plpgsql AS $$
BEGIN
    CALL check_erows('-', p_sql, p_expected, p_tol);
END;
$$;
