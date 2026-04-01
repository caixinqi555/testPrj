--
-- Tests for testing query planner selectivity and width estimates
--
-- Most selectivity and width estimations rely too heavily on statistics
-- gathered by ANALYZE, or could vary depending on hardware.  However, there
-- are a few cases where we can have more certainty about the expected number
-- of rows, or width of rows.  This is a good home for such tests.
--

-- Function to assist with verifying EXPLAIN which includes costs.  A series
-- of bool flags allows control over which portions are masked out
CREATE FUNCTION explain_mask_costs(query text, do_analyze bool,
    hide_costs bool, hide_row_est bool, hide_width bool) RETURNS setof text
LANGUAGE plpgsql AS
$$
DECLARE
    ln text;
    analyze_str text;
BEGIN
    IF do_analyze = true THEN
        analyze_str := 'on';
    ELSE
        analyze_str := 'off';
    END IF;

    -- avoid jit related output by disabling it
    SET LOCAL jit = 0;

    FOR ln IN
        EXECUTE format('explain (analyze %s, costs on, summary off, timing off, buffers off) %s',
            analyze_str, query)
    LOOP
        IF hide_costs = true THEN
            ln := regexp_replace(ln, 'cost=\d+\.\d\d\.\.\d+\.\d\d', 'cost=N..N');
        END IF;

        IF hide_row_est = true THEN
            -- don't use 'g' so that we leave the actual rows intact
            ln := regexp_replace(ln, 'rows=\d+', 'rows=N');
        END IF;

        IF hide_width = true THEN
            ln := regexp_replace(ln, 'width=\d+', 'width=N');
        END IF;

        RETURN NEXT ln;
    END LOOP;
END;
$$;

--
-- Test the SupportRequestRows support function for generate_series_timestamp()
--

-- Ensure the row estimate matches the actual rows
SELECT explain_mask_costs($$
SELECT * FROM generate_series(TIMESTAMPTZ '2024-02-01', TIMESTAMPTZ '2024-03-01', INTERVAL '1 day') g(s);$$,
true, true, false, true);

-- As above but with generate_series_timestamp
SELECT explain_mask_costs($$
SELECT * FROM generate_series(TIMESTAMP '2024-02-01', TIMESTAMP '2024-03-01', INTERVAL '1 day') g(s);$$,
true, true, false, true);

-- As above but with generate_series_timestamptz_at_zone()
SELECT explain_mask_costs($$
SELECT * FROM generate_series(TIMESTAMPTZ '2024-02-01', TIMESTAMPTZ '2024-03-01', INTERVAL '1 day', 'UTC') g(s);$$,
true, true, false, true);

-- Ensure the estimated and actual row counts match when the range isn't
-- evenly divisible by the step
SELECT explain_mask_costs($$
SELECT * FROM generate_series(TIMESTAMPTZ '2024-02-01', TIMESTAMPTZ '2024-03-01', INTERVAL '7 day') g(s);$$,
true, true, false, true);

-- Ensure the estimates match when step is decreasing
SELECT explain_mask_costs($$
SELECT * FROM generate_series(TIMESTAMPTZ '2024-03-01', TIMESTAMPTZ '2024-02-01', INTERVAL '-1 day') g(s);$$,
true, true, false, true);

-- Ensure an empty range estimates 1 row
SELECT explain_mask_costs($$
SELECT * FROM generate_series(TIMESTAMPTZ '2024-03-01', TIMESTAMPTZ '2024-02-01', INTERVAL '1 day') g(s);$$,
true, true, false, true);

-- Ensure we get the default row estimate for infinity values
SELECT explain_mask_costs($$
SELECT * FROM generate_series(TIMESTAMPTZ '-infinity', TIMESTAMPTZ 'infinity', INTERVAL '1 day') g(s);$$,
false, true, false, true);

-- Ensure the row estimate behaves correctly when step size is zero.
-- We expect generate_series_timestamp() to throw the error rather than in
-- the support function.
SELECT * FROM generate_series(TIMESTAMPTZ '2024-02-01', TIMESTAMPTZ '2024-03-01', INTERVAL '0 day') g(s);

--
-- Test the SupportRequestRows support function for generate_series_numeric()
--

-- Ensure the row estimate matches the actual rows
SELECT explain_mask_costs($$
SELECT * FROM generate_series(1.0, 25.0) g(s);$$,
true, true, false, true);

-- As above but with non-default step
SELECT explain_mask_costs($$
SELECT * FROM generate_series(1.0, 25.0, 2.0) g(s);$$,
true, true, false, true);

-- Ensure the estimates match when step is decreasing
SELECT explain_mask_costs($$
SELECT * FROM generate_series(25.0, 1.0, -1.0) g(s);$$,
true, true, false, true);

-- Ensure an empty range estimates 1 row
SELECT explain_mask_costs($$
SELECT * FROM generate_series(25.0, 1.0, 1.0) g(s);$$,
true, true, false, true);

-- Ensure we get the default row estimate for error cases (infinity/NaN values
-- and zero step size)
SELECT explain_mask_costs($$
SELECT * FROM generate_series('-infinity'::NUMERIC, 'infinity'::NUMERIC, 1.0) g(s);$$,
false, true, false, true);

SELECT explain_mask_costs($$
SELECT * FROM generate_series(1.0, 25.0, 'NaN'::NUMERIC) g(s);$$,
false, true, false, true);

SELECT explain_mask_costs($$
SELECT * FROM generate_series(25.0, 2.0, 0.0) g(s);$$,
false, true, false, true);

--
-- Test ScalarArrayOpExpr row estimates for <> ALL for arrays with NULLs.  We
-- expect the planner to estimate 1 row will match in both of the following
-- tests.
--

-- Try a const array containing a NULL
SELECT explain_mask_costs($$
SELECT * FROM tenk1 WHERE unique1 <> ALL (ARRAY[1, 2, 99, NULL]);$$,
false, true, false, true);

-- Try a non-const array containing a NULL
SELECT explain_mask_costs($$
SELECT * FROM tenk1 WHERE unique1 <> ALL (ARRAY[1, 2, 98, (SELECT 99), NULL]);$$,
false, true, false, true);

--
-- Scalar range predicates should consider rows inserted after the last
-- ANALYZE under a right-tail growth model, while still capping selectivity
-- at 1.
--
CREATE TABLE scalar_range_est_test AS
SELECT g AS x, repeat('x', 200) AS pad
FROM generate_series(1, 1000) g;
ALTER TABLE scalar_range_est_test ALTER COLUMN x SET STATISTICS 1000;
ANALYZE scalar_range_est_test;
INSERT INTO scalar_range_est_test
SELECT g, repeat('x', 200)
FROM generate_series(1001, 2000) g;
\a\t
SELECT * FROM explain_mask_costs($$
SELECT * FROM scalar_range_est_test WHERE x >= 1501;$$,
true, true, false, true);
SELECT * FROM explain_mask_costs($$
SELECT * FROM scalar_range_est_test WHERE x BETWEEN 501 AND 2000;$$,
true, true, false, true);
SELECT * FROM explain_mask_costs($$
SELECT * FROM scalar_range_est_test WHERE x BETWEEN 1000 AND 1000;$$,
true, true, false, true);
\a\t
DROP TABLE scalar_range_est_test;

--
-- Range and multirange histogram estimates should avoid exact zero when the
-- finite query bound lies past the histogram maximum.
--
CREATE TABLE range_est_test AS
SELECT numrange(i, i + 1) AS r
FROM generate_series(1, 20000) g(i);
ANALYZE range_est_test;
\a\t
SELECT * FROM explain_mask_costs($$
SELECT * FROM range_est_test WHERE r && numrange(40000, 40001);$$,
true, true, false, true);

CREATE TABLE multirange_est_test AS
SELECT nummultirange(numrange(i, i + 1)) AS mr
FROM generate_series(1, 20000) g(i);
ANALYZE multirange_est_test;
SELECT * FROM explain_mask_costs($$
SELECT * FROM multirange_est_test WHERE mr && numrange(40000, 40001);$$,
true, true, false, true);
\a\t

DROP TABLE range_est_test;
DROP TABLE multirange_est_test;

DROP FUNCTION explain_mask_costs(text, bool, bool, bool, bool);
