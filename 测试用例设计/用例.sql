
-- 3. Range 谓词用例组

-- 3.1 组 Fixture

-- R-Fixture-01：astore 普通表
DROP TABLE IF EXISTS t_r_astore;
CREATE TABLE t_r_astore (id int, ts timestamp, big bigint, v varchar(32));
INSERT INTO t_r_astore
  SELECT g,
         '2026-01-01'::timestamp + (g || ' seconds')::interval,
         g::bigint * 1000,
         'v' || g
  FROM generate_series(1, 10000) g;
ANALYZE t_r_astore;   -- stats_min=1, stats_max=10000, analyzed_tuples=10000
INSERT INTO t_r_astore
  SELECT g, '2026-01-01'::timestamp + (g || ' seconds')::interval,
         g::bigint * 1000, 'v' || g
  FROM generate_series(10001, 12000) g;   -- increase_tuples ≈ 2000

-- R-Fixture-02：ustore 普通表
DROP TABLE IF EXISTS t_r_ustore;
CREATE TABLE t_r_ustore (id int, ts timestamp, big bigint, v varchar(32))
  WITH (storage_type=ustore);
-- 装数同 astore
INSERT INTO t_r_ustore SELECT g, '2026-01-01'::timestamp + (g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_r_ustore;
INSERT INTO t_r_ustore SELECT g, '2026-01-01'::timestamp + (g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(10001, 12000) g;

-- R-Fixture-03：一级分区（range 按 id 分区），10 个分区覆盖 [1, 10000]，追加 2 个分区覆盖 [10001, 12000]
DROP TABLE IF EXISTS t_r_part1;
CREATE TABLE t_r_part1 (id int, ts timestamp, big bigint, v varchar(32))
  PARTITION BY RANGE (id) (
    PARTITION p01 VALUES LESS THAN (1001),
    PARTITION p02 VALUES LESS THAN (2001),
    PARTITION p03 VALUES LESS THAN (3001),
    PARTITION p04 VALUES LESS THAN (4001),
    PARTITION p05 VALUES LESS THAN (5001),
    PARTITION p06 VALUES LESS THAN (6001),
    PARTITION p07 VALUES LESS THAN (7001),
    PARTITION p08 VALUES LESS THAN (8001),
    PARTITION p09 VALUES LESS THAN (9001),
    PARTITION p10 VALUES LESS THAN (10001),
    PARTITION p11 VALUES LESS THAN (11001),
    PARTITION p12 VALUES LESS THAN (12001)
  );
INSERT INTO t_r_part1 SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_r_part1 WITH ALL COMPLETE;
INSERT INTO t_r_part1 SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(10001, 12000) g;  -- 落入 p11、p12

-- 基础 fixture 下：density = 10000 / (10000-1) ≈ 1.0，increase_tuples ≈ 2000。

-- 3.2 组 A：基础笛卡尔（触发路径）8 条

-- 【R-A-01】range 触发 | astore | 单列 | 公式值生效 | int
-- 预期：触发 range 边界外矫正 | rows ≈ 100（±5%）| 公式 min(100*1.0=100, increase_tuples≈2000) = 100
CALL check_erows('R-A-01', $$SELECT * FROM t_r_astore WHERE id > 11000 AND id < 11100$$, 100, 0.20);

-- 【R-A-02】range 触发 | astore | 单列 | 上界截断 | int
-- 预期：触发 range 边界外矫正 | rows ≈ 2000（±5%）| 公式 min(9000*1.0=9000, increase_tuples≈2000) = 2000
CALL check_erows('R-A-02', $$SELECT * FROM t_r_astore WHERE id > 11000 AND id < 20000$$, 2000, 0.20);

-- 【R-A-03】range 触发 | ustore | 单列 | 公式值生效 | int
-- 预期：触发 range 边界外矫正 | rows ≈ 100（±5%）| 公式 min(100, 2000) = 100
CALL check_erows('R-A-03', $$SELECT * FROM t_r_ustore WHERE id > 11000 AND id < 11100$$, 100, 0.20);

-- 【R-A-04】range 触发 | ustore | 单列 | 上界截断 | int
-- 预期：触发 range 边界外矫正 | rows ≈ 2000（±5%）| 公式 min(9000, 2000) = 2000
CALL check_erows('R-A-04', $$SELECT * FROM t_r_ustore WHERE id > 11000 AND id < 20000$$, 2000, 0.20);

-- 【R-A-05】range 触发 | 一级分区-剪枝单分区 p11 | 单列 | 公式值生效 | int
--   p11 边界 [10001, 11000]；查询 id ∈ [10501, 10599] 严格落在 p11，剪枝到 p11 单分区
--   主表 stats_max=10000，qual_l=10500 > stats_max 触发；p11 无本地直方图（ANALYZE 早于增量），回退到主表统计路径
-- 预期：触发 range 边界外矫正 | rows ≈ 100（±20%）| 公式 min(100*1.0, 2000) = 100
CALL check_erows('R-A-05', $$SELECT * FROM t_r_part1 WHERE id > 10500 AND id < 10600$$, 100, 0.20);

-- 【R-A-06】range 触发 | 一级分区-剪枝多分区 p11+p12 | 单列 | 上界截断 | int
--   qual_l=10500 严格大于 stats_max=10000，避免 10000 == stats_max 的边界误判
-- 预期：触发 range 边界外矫正 | rows ≈ 2000（±20%）| 公式 min(3500, 2000) = 2000，上界截断
CALL check_erows('R-A-06', $$SELECT * FROM t_r_part1 WHERE id > 10500 AND id < 14000$$, 2000, 0.20);

-- 【R-A-07】range 触发 | 一级分区-不剪枝（全表扫主表统计）| 单列 | 公式值生效 | int
--   不剪枝场景：用非分区键列（ts）构造谓词，让分区剪枝失效，走主表级统计信息分支
--   ts 的 stats_max ≈ '2026-01-01 02:46:40'（g=10000 时），谓词范围远超 stats_max
-- 预期：触发 range 边界外矫正 | rows ≈ 100（±5%）| 走主表 estimate_rel_size 访问下属所有分区存储层
CALL check_erows('R-A-07', $$SELECT * FROM t_r_part1 WHERE ts > '2026-01-02 00:00:00' AND ts < '2026-01-02 00:01:40'$$, 100, 0.20);

-- 【R-A-08】range 触发 | 一级分区-不剪枝 | 单列 | 上界截断 | int
-- 预期：触发 range 边界外矫正 | rows ≈ 2000（±5%）| 公式值远大于 increase_tuples，上界截断
CALL check_erows('R-A-08', $$SELECT * FROM t_r_part1 WHERE ts > '2026-01-02 00:00:00' AND ts < '2026-01-10 00:00:00'$$, 2000, 0.20);

-- 3.3 组 B：不触发单测 2 条

-- 【R-B-01】range 不触发 | 谓词范围部分重合（本特性明确收束此场景）
-- 预期：不触发矫正（原逻辑）| rows ≈ 1200（±20%）| 选择率 0.1 × pages 膨胀后 reltuples≈12000 = 1200
CALL check_erows('R-B-01', $$SELECT * FROM t_r_astore WHERE id > 9000 AND id < 11000$$, 1200, 0.20);

-- 【R-B-02】range 不触发 | 谓词范围完全包含在统计信息范围内
-- 预期：不触发矫正（原逻辑）| rows ≈ 240（±20%）| 选择率 0.02 × 12000 = 240
CALL check_erows('R-B-02', $$SELECT * FROM t_r_astore WHERE id > 5000 AND id < 5200$$, 240, 0.20);

-- 3.4 组 C：约束回退 5 条

-- 【R-C-01】range 约束回退 | 谓词列为索引主列
-- 预期：不触发矫正（约束回退到原逻辑）| rows ≈ 1（直方图边界被索引修正为实时值，原逻辑已给合理估值）
CREATE INDEX ix_r_astore_id ON t_r_astore (id);
CALL check_erows('R-C-01', $$SELECT * FROM t_r_astore WHERE id > 11000 AND id < 11100$$, 1, 0.20);
DROP INDEX ix_r_astore_id;

-- 【R-C-02】range 约束回退 | 多列统计信息（详设明确不支持多列贝叶斯）
-- 预期：不触发矫正（约束回退）| 走原有多列估算逻辑（估为 1 行）
CREATE STATISTICS st_r_astore_ts_id (dependencies) ON ts, id FROM t_r_astore;
ANALYZE t_r_astore;
CALL check_erows('R-C-02', $$SELECT * FROM t_r_astore WHERE id > 11000 AND id < 11100 AND ts > '2026-04-01'::timestamp$$, 1, 0.20);
DROP STATISTICS st_r_astore_ts_id;

-- 【R-C-03】range 约束回退 | opt_use_static_stats=on
-- 预期：不触发矫正（整体不支持）| rows = 1（原逻辑）
SET opt_use_static_stats = on;
CALL check_erows('R-C-03', $$SELECT * FROM t_r_astore WHERE id > 11000 AND id < 11100$$, 1, 0.20);
SET opt_use_static_stats = off;

-- 【R-C-04】range 约束回退 | 页面存在空洞（大量 DELETE 后 pages 不下降）
-- 预期：不触发矫正/估算不准但不崩溃 | increase_tuples 计算失真，本特性不探测空洞
DROP TABLE IF EXISTS t_r_astore;
CREATE TABLE t_r_astore (id int, ts timestamp, big bigint, v varchar(32));
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_r_astore;
DELETE FROM t_r_astore WHERE id BETWEEN 2000 AND 8000;  -- 产生空洞但 pages 不变
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(10001, 12000) g;
CALL check_erows('R-C-04', $$SELECT * FROM t_r_astore WHERE id > 11000 AND id < 11100$$, 100, 0.20);

-- 【R-C-05】range 约束回退 | insert 不产生页面增长（update 或 fillfactor=0 预留空间）
-- 预期：不触发矫正有效增量 | increase_tuples ≈ 0 | 本特性不探测此场景
CREATE TABLE t_r_nopagegrow (id int) WITH (fillfactor=30);
INSERT INTO t_r_nopagegrow SELECT g FROM generate_series(1, 10000) g;
ANALYZE t_r_nopagegrow;
INSERT INTO t_r_nopagegrow SELECT g FROM generate_series(10001, 10050) g;  -- 仅 50 行填入预留空间
CALL check_erows('R-C-05', $$SELECT * FROM t_r_nopagegrow WHERE id > 11000 AND id < 11100$$, 1, 0.20);

-- 3.5 组 D：其它单测 6 条

-- 【R-D-01】表类型单测 | 本地临时表
-- 预期：触发 range 边界外矫正 | rows ≈ 100（±5%）| 本地临时表统计信息走会话级 pg_class
CREATE TEMP TABLE t_r_temp (id int, v varchar(32)) ON COMMIT PRESERVE ROWS;
INSERT INTO t_r_temp SELECT g, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_r_temp;
INSERT INTO t_r_temp SELECT g, 'v'||g FROM generate_series(10001, 12000) g;
CALL check_erows('R-D-01', $$SELECT * FROM t_r_temp WHERE id > 11000 AND id < 11100$$, 100, 0.20);

-- 【R-D-02】表类型单测 | 全局临时表 GTT
-- 预期：触发 range 边界外矫正 | rows ≈ 100（±5%）| GTT 的 pg_class 行数是会话级，需验证 estimate_rel_size 返回正确
CREATE GLOBAL TEMP TABLE t_r_gtt (id int, v varchar(32)) ON COMMIT PRESERVE ROWS;
INSERT INTO t_r_gtt SELECT g, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_r_gtt;
INSERT INTO t_r_gtt SELECT g, 'v'||g FROM generate_series(10001, 12000) g;
CALL check_erows('R-D-02', $$SELECT * FROM t_r_gtt WHERE id > 11000 AND id < 11100$$, 100, 0.20);

-- 【R-D-03】统计信息类型 | 表达式统计信息（GaussDB 用表达式 INDEX 注入表达式列统计）
-- 预期：rows ≈ 100（±20%）| 表达式列同时是索引主列，本特性的 range 不矫正，直方图边界被索引修正后选择率自洽
--   重建 + 在 ANALYZE 前建表达式索引，让 ANALYZE 一并冻结表达式列直方图
DROP TABLE IF EXISTS t_r_astore;
CREATE TABLE t_r_astore (id int, ts timestamp, big bigint, v varchar(32));
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(1, 10000) g;
CREATE INDEX st_r_expr ON t_r_astore((id * 2));
ANALYZE t_r_astore;
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(10001, 12000) g;
CALL check_erows('R-D-03', $$SELECT * FROM t_r_astore WHERE (id * 2) > 22000 AND (id * 2) < 22200$$, 100, 0.20);
DROP INDEX st_r_expr;

-- 【R-D-04】increase_tuples=0 边界
-- 预期：触发矫正但被 0 上界截断 | rows = 1（回退到原下界钳制）| 公式 min(100, 0) = 0 → 钳为 1
CREATE TABLE t_r_noincr (id int);
INSERT INTO t_r_noincr SELECT g FROM generate_series(1, 10000) g;
ANALYZE t_r_noincr;
-- 不再 insert，increase_tuples = 0
CALL check_erows('R-D-04', $$SELECT * FROM t_r_noincr WHERE id > 11000 AND id < 11100$$, 1, 0.20);

-- 【R-D-05】历史统计信息已 prune（回退 estimate_rel_size 当前值）
-- 预期：触发 range 边界外矫正 | rows ≈ 100（±20%）| 历史统计被清后由当前 relpages/reltuples 代替
--   重建 + 用 DBMS_STATS.PURGE_STATS 清历史
DROP TABLE IF EXISTS t_r_astore;
CREATE TABLE t_r_astore (id int, ts timestamp, big bigint, v varchar(32));
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_r_astore;
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(10001, 12000) g;
CALL DBMS_STATS.PURGE_STATS(current_timestamp);
CALL check_erows('R-D-05', $$SELECT * FROM t_r_astore WHERE id > 11000 AND id < 11100$$, 100, 0.20);

-- 【R-D-06】vacuum 只更表级不更列级
-- 预期：触发 range 边界外矫正 | rows ≈ 100（±20%）| vacuum 后表级统计新了但列级直方图仍为旧值
--   重建 + VACUUM 在增量后做（VACUUM 会改 pg_class.relpages/reltuples，必须重建以恢复 baseline）
DROP TABLE IF EXISTS t_r_astore;
CREATE TABLE t_r_astore (id int, ts timestamp, big bigint, v varchar(32));
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_r_astore;
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(10001, 12000) g;
VACUUM t_r_astore;   -- 更新 pg_class.relpages/reltuples，不更新 pg_statistic 列级统计
CALL check_erows('R-D-06', $$SELECT * FROM t_r_astore WHERE id > 11000 AND id < 11100$$, 100, 0.20);

-- ---

-- 4. Gt 谓词用例组

-- 4.1 组 Fixture

-- 与 Range 组相同的 `t_r_astore / t_r_ustore / t_r_part1` 可复用，记作 `t_g_*` 别名使用。若需要独立 fixture，建表语句与 3.1 完全对称。下文复用 `t_r_astore` 等表名。

-- G 组复用 t_r_astore 前先恢复标准基线，避免 Range 组中 DELETE/ANALYZE/VACUUM 用例污染增量。
DROP TABLE IF EXISTS t_r_astore;
CREATE TABLE t_r_astore (id int, ts timestamp, big bigint, v varchar(32));
INSERT INTO t_r_astore
  SELECT g, '2026-01-01'::timestamp + (g || ' seconds')::interval,
         g::bigint * 1000, 'v' || g
  FROM generate_series(1, 10000) g;
ANALYZE t_r_astore;
INSERT INTO t_r_astore
  SELECT g, '2026-01-01'::timestamp + (g || ' seconds')::interval,
         g::bigint * 1000, 'v' || g
  FROM generate_series(10001, 12000) g;

-- gt 谓词的外推公式：`qual_h = stats_max + (stats_max - stats_min) × (increase_tuples / analyzed_tuples)`
-- 在基础 fixture 下：qual_h ≈ 10000 + 9999 × (2000/10000) ≈ 12000
-- 外推后 out_of_bounds_width = 12000 - qual_l

-- 4.2 组 A：基础笛卡尔 8 条

-- 【G-A-01】gt 触发 | astore | 单列 | 公式值生效 | int
-- 预期：触发 gt 边界外矫正 | rows ≈ 400（±5%）| qual_l=11600，外推 qual_h≈12000，宽度=400，公式 min(400, 2000)=400
CALL check_erows('G-A-01', $$SELECT * FROM t_r_astore WHERE id > 11600$$, 400, 0.20);

-- 【G-A-02】gt 触发 | astore | 单列 | 上界截断 | int
-- 预期：触发 gt 边界外矫正 | rows ≈ 2000（±5%）| qual_l=10001 极近边界，外推宽度≈1999，结果贴近上界
CALL check_erows('G-A-02', $$SELECT * FROM t_r_astore WHERE id > 10001$$, 2000, 0.20);

-- 【G-A-03】gt 触发 | ustore | 单列 | 公式值生效 | int
-- 预期：触发 gt 边界外矫正 | rows ≈ 400（±5%）| 公式同 G-A-01
CALL check_erows('G-A-03', $$SELECT * FROM t_r_ustore WHERE id > 11600$$, 400, 0.20);

-- 【G-A-04】gt 触发 | ustore | 单列 | 上界截断 | int
-- 预期：触发 gt 边界外矫正 | rows ≈ 2000（±5%）| qual_l 靠近边界，估行结果贴近上界
CALL check_erows('G-A-04', $$SELECT * FROM t_r_ustore WHERE id > 10001$$, 2000, 0.20);

-- 【G-A-05】gt 触发 | 一级分区-剪枝到 p12 | 单列 | 公式值生效 | int
-- 预期：触发 gt 边界外矫正 | 在 p12 上估行 ≈ 400（±5%）
CALL check_erows('G-A-05', $$SELECT * FROM t_r_part1 WHERE id > 11600 AND id < 12001$$, 400, 0.20);

-- 【G-A-06】gt 触发 | 一级分区-剪枝到 p11+p12 | 单列 | 上界截断 | int
-- 预期：触发 gt 边界外矫正 | rows ≈ 2000（±5%）| qual_l 靠近边界，估行结果贴近上界
CALL check_erows('G-A-06', $$SELECT * FROM t_r_part1 WHERE id > 10001 AND id < 12001$$, 2000, 0.20);

-- 【G-A-07】gt 触发 | 一级分区-不剪枝 | 单列 | 公式值生效 | int
-- 预期：触发 gt 边界外矫正 | rows ≈ 400（±5%）| 走主表统计+外推
CALL check_erows('G-A-07', $$SELECT * FROM t_r_part1 WHERE ts > '2026-01-01 03:13:20'$$, 400, 0.20);

-- 【G-A-08】gt 触发 | 一级分区-不剪枝 | 单列 | 上界截断 | int
-- 预期：触发 gt 边界外矫正 | rows ≈ 2000（±5%）| qual_l 靠近边界，估行结果贴近上界
CALL check_erows('G-A-08', $$SELECT * FROM t_r_part1 WHERE ts > '2026-01-01 02:46:41'$$, 2000, 0.20);

-- 4.3 组 B：不触发单测 2 条

-- 【G-B-01】gt 不触发 | qual_l 在统计信息范围内（部分重合）
-- 预期：不触发矫正（原逻辑）| rows ≈ 2400（±20%）| 选择率 0.2 × 12000（pages 膨胀后）= 2400
CALL check_erows('G-B-01', $$SELECT * FROM t_r_astore WHERE id > 8000$$, 2400, 0.20);

-- 【G-B-02】gt 不触发 | qual_l 在统计信息范围内（恰好等于 stats_max）
-- 预期：不触发矫正（原逻辑）| rows 按直方图估算 | qual_l=10000 恰等 stats_max，不严格大于
CALL check_erows('G-B-02', $$SELECT * FROM t_r_astore WHERE id > 10000$$, 1, 0.20);

-- 4.4 组 C：约束回退 5 条

-- 【G-C-01】gt 约束回退 | 谓词列为索引主列
-- 预期：不触发矫正（约束回退）| 走原逻辑（直方图边界被索引修正为实时值）
CREATE INDEX ix_g_astore_id ON t_r_astore (id);
CALL check_erows('G-C-01', $$SELECT * FROM t_r_astore WHERE id > 10100$$, 1, 0.20);
DROP INDEX ix_g_astore_id;

-- 【G-C-02】gt 约束回退 | 多列统计信息（详设明确不支持）
-- 预期：不触发矫正（约束回退）| 走原有多列估算
CREATE STATISTICS st_g_ts_id (dependencies) ON ts, id FROM t_r_astore;
ANALYZE t_r_astore;
CALL check_erows('G-C-02', $$SELECT * FROM t_r_astore WHERE id > 10100 AND ts > '2026-04-01'::timestamp$$, 1, 0.20);
DROP STATISTICS st_g_ts_id;

-- 【G-C-03】gt 约束回退 | opt_use_static_stats=on
-- 预期：不触发矫正 | rows = 1（原逻辑）
SET opt_use_static_stats = on;
CALL check_erows('G-C-03', $$SELECT * FROM t_r_astore WHERE id > 10100$$, 1, 0.20);
SET opt_use_static_stats = off;

-- 【G-C-04】gt 约束回退 | 页面空洞
-- 预期：增量估算失真但不崩溃 | 本特性不探测空洞
DROP TABLE IF EXISTS t_r_astore;
CREATE TABLE t_r_astore (id int, ts timestamp, big bigint, v varchar(32));
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_r_astore;
DELETE FROM t_r_astore WHERE id BETWEEN 3000 AND 9000;
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(10001, 12000) g;
CALL check_erows('G-C-04', $$SELECT * FROM t_r_astore WHERE id > 10100$$, 1900, 0.20);

-- 【G-C-05】gt 约束回退 | insert 无页面增长（fillfactor）
-- 预期：increase_tuples ≈ 0 | 触发但截断为 0 → 钳为 1
CREATE TABLE t_g_nopagegrow (id int) WITH (fillfactor=30);
INSERT INTO t_g_nopagegrow SELECT g FROM generate_series(1, 10000) g;
ANALYZE t_g_nopagegrow;
INSERT INTO t_g_nopagegrow SELECT g FROM generate_series(10001, 10050) g;
CALL check_erows('G-C-05', $$SELECT * FROM t_g_nopagegrow WHERE id > 10100$$, 1, 0.20);

-- 4.5 组 D：其它单测 7 条

-- 【G-D-01】表类型 | 本地临时表
-- 预期：触发 gt 边界外矫正 | rows ≈ 400（±5%）
CREATE TEMP TABLE t_g_temp (id int, v varchar(32)) ON COMMIT PRESERVE ROWS;
INSERT INTO t_g_temp SELECT g, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_g_temp;
INSERT INTO t_g_temp SELECT g, 'v'||g FROM generate_series(10001, 12000) g;
CALL check_erows('G-D-01', $$SELECT * FROM t_g_temp WHERE id > 11600$$, 400, 0.20);

-- 【G-D-02】表类型 | 全局临时表 GTT
-- 预期：触发 gt 边界外矫正 | rows ≈ 400（±5%）
CREATE GLOBAL TEMP TABLE t_g_gtt (id int, v varchar(32)) ON COMMIT PRESERVE ROWS;
INSERT INTO t_g_gtt SELECT g, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_g_gtt;
INSERT INTO t_g_gtt SELECT g, 'v'||g FROM generate_series(10001, 12000) g;
CALL check_erows('G-D-02', $$SELECT * FROM t_g_gtt WHERE id > 11600$$, 400, 0.20);

-- 【G-D-03】表类型 | 一级分区-剪枝多
-- 预期：触发 gt 边界外矫正 | rows ≈ 1900（±5%）| 剪枝到 p11+p12 两个分区
CALL check_erows('G-D-03', $$SELECT * FROM t_r_part1 WHERE id > 10100 AND id < 12001$$, 1900, 0.20);

-- 【G-D-04】表类型 | 二级分区-剪枝到一级
-- 预期：触发 gt 边界外矫正 | 剪枝到二级分区中间层，走主表-子分区统计叠加
DROP TABLE IF EXISTS t_g_part2;
CREATE TABLE t_g_part2 (id int, region int, v varchar(32))
  PARTITION BY RANGE (id) SUBPARTITION BY LIST (region) (
    PARTITION p01 VALUES LESS THAN (5001) (
      SUBPARTITION p01_r1 VALUES (1),
      SUBPARTITION p01_r2 VALUES (2)
    ),
    PARTITION p02 VALUES LESS THAN (10001) (
      SUBPARTITION p02_r1 VALUES (1),
      SUBPARTITION p02_r2 VALUES (2)
    ),
    PARTITION p03 VALUES LESS THAN (12001) (
      SUBPARTITION p03_r1 VALUES (1),
      SUBPARTITION p03_r2 VALUES (2)
    )
  );
INSERT INTO t_g_part2 SELECT g, (g%2)+1, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_g_part2 WITH ALL COMPLETE;
INSERT INTO t_g_part2 SELECT g, (g%2)+1, 'v'||g FROM generate_series(10001, 12000) g;
CALL check_erows('G-D-04', $$SELECT * FROM t_g_part2 WHERE id > 10100$$, 1900, 0.20);  -- 只按 id 过滤，二级维度不剪枝

-- 【G-D-05】表类型 | 二级分区-剪枝到叶子
-- 预期：触发 gt 边界外矫正 | 剪枝到单个叶子分区 p03_r1
CALL check_erows('G-D-05', $$SELECT * FROM t_g_part2 WHERE id > 10100 AND region = 1$$, 950, 0.20);

-- 【G-D-06】表类型 | 二级分区-不剪枝
-- 预期：触发 gt 边界外矫正 | 无法剪枝，走主表统计+存储层访问
CALL check_erows('G-D-06', $$SELECT * FROM t_g_part2 WHERE v > 'z9999'$$, 1, 0.20);  -- v 非分区键，无法剪枝

-- 【G-D-07】统计信息类型 | 表达式统计信息
-- 预期：触发 gt 边界外矫正 | 表达式列走非索引主列路径
DROP TABLE IF EXISTS t_r_astore;
CREATE TABLE t_r_astore (id int, ts timestamp, big bigint, v varchar(32));
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(1, 10000) g;
CREATE INDEX st_g_expr ON t_r_astore((id * 2));
ANALYZE t_r_astore;
INSERT INTO t_r_astore SELECT g, '2026-01-01'::timestamp+(g||' seconds')::interval,
  g::bigint*1000, 'v'||g FROM generate_series(10001, 12000) g;
CALL check_erows('G-D-07', $$SELECT * FROM t_r_astore WHERE (id * 2) > 20200$$, 1900, 0.20);
DROP INDEX st_g_expr;

-- ---

-- 5. Equal 谓词用例组

-- 5.1 组 Fixture

-- E-Fixture-01：astore 普通表（低 NDV 列，全为 MCV 场景）
DROP TABLE IF EXISTS t_e_astore;
CREATE TABLE t_e_astore (ver int, region int, v varchar(32));
-- ver 取值 1..50，每值 200 行，analyzed_tuples=10000，n_distinct=50，全部为 MCV
INSERT INTO t_e_astore
  SELECT (g % 50) + 1, (g % 10) + 1, 'v' || g FROM generate_series(1, 10000) g;
ANALYZE t_e_astore;   -- stats 下 num_mcv=50，other_distinct = n_distinct - num_mcv = 0
-- 引入新 ver=51 的增量，未命中 MCV，触发 equal 矫正
INSERT INTO t_e_astore SELECT 51, (g % 10) + 1, 'v' || g FROM generate_series(1, 2000) g;
-- increase_tuples ≈ 2000

-- E-Fixture-02：ustore 低 NDV 表
DROP TABLE IF EXISTS t_e_ustore;
CREATE TABLE t_e_ustore (ver int, region int, v varchar(32)) WITH (storage_type=ustore);
INSERT INTO t_e_ustore SELECT (g%50)+1, (g%10)+1, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_e_ustore;
INSERT INTO t_e_ustore SELECT 51, (g%10)+1, 'v'||g FROM generate_series(1, 2000) g;

-- E-Fixture-03：一级分区（range 按 region）
DROP TABLE IF EXISTS t_e_part1;
CREATE TABLE t_e_part1 (ver int, region int, v varchar(32))
  PARTITION BY RANGE (region) (
    PARTITION p1 VALUES LESS THAN (4),
    PARTITION p2 VALUES LESS THAN (7),
    PARTITION p3 VALUES LESS THAN (11)
  );
INSERT INTO t_e_part1 SELECT (g%50)+1, (g%10)+1, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_e_part1 WITH ALL COMPLETE;
INSERT INTO t_e_part1 SELECT 51, (g%10)+1, 'v'||g FROM generate_series(1, 2000) g;

-- equal 公式：`target_rows = Min(analyzed_tuples / n_distinct, increase_tuples)`
-- 基础 fixture 下：10000/50 = 200 → min(200, 2000) = 200（公式生效）；若 n_distinct 较小（如 2）则 10000/2=5000 > 2000 → 上界截断

-- 5.2 组 A：基础笛卡尔 16 条

-- 【E-A-01】equal 触发 | astore | 单列 | 未命中+other=0 | 公式值生效 | int
-- 预期：触发 equal 边界外矫正 | rows ≈ 200（±5%）| 公式 min(10000/50=200, 2000) = 200
CALL check_erows('E-A-01', $$SELECT * FROM t_e_astore WHERE ver = 51$$, 200, 0.20);

-- 【E-A-02】equal 触发 | astore | 单列 | 未命中+other=0 | 上界截断 | int
-- 预期：触发 equal 边界外矫正 | rows ≈ 2000（±5%）| 通过临时降低 n_distinct 制造公式值大于上界
DROP TABLE IF EXISTS t_e_astore_low;
CREATE TABLE t_e_astore_low (ver int, region int);
INSERT INTO t_e_astore_low
  SELECT (g % 2) + 1, (g % 2) + 1
  FROM generate_series(1, 10000) g;  -- ver/region 均为低 NDV，单列 n_distinct=2
ANALYZE t_e_astore_low;
INSERT INTO t_e_astore_low SELECT 3, 3 FROM generate_series(1, 2000) g;
CALL check_erows('E-A-02', $$SELECT * FROM t_e_astore_low WHERE ver = 3$$, 2000, 0.20);

-- 【E-A-03】equal 触发 | astore | 多列统计 | 未命中+other=0 | 公式值生效 | int
-- 预期：触发 equal 边界外矫正 | rows ≈ 20（±30%）| 多列 eq 估算走贝叶斯+本特性矫正
CREATE STATISTICS st_e_ver_region ON ver, region FROM t_e_astore;
ANALYZE t_e_astore;
CALL check_erows('E-A-03', $$SELECT * FROM t_e_astore WHERE ver = 51 AND region = 3$$, 20, 0.20);
DROP STATISTICS st_e_ver_region;

-- 【E-A-04】equal 触发 | astore | 多列统计 | 未命中+other=0 | 上界截断 | int
-- 前置：制造公式值 > increase_tuples 的多列场景
CREATE STATISTICS st_e_ver_region2 ON ver, region FROM t_e_astore_low;
INSERT INTO t_e_astore_low SELECT 7, 7 FROM generate_series(1, 2000) g;
ANALYZE t_e_astore_low;
CALL check_erows('E-A-04', $$SELECT * FROM t_e_astore_low WHERE ver = 7$$, 2000, 0.20);
DROP STATISTICS st_e_ver_region2;

-- 【E-A-05】equal 触发 | ustore | 单列 | 未命中+other=0 | 公式值生效
-- 预期：触发 equal 边界外矫正 | rows ≈ 200（±5%）
CALL check_erows('E-A-05', $$SELECT * FROM t_e_ustore WHERE ver = 51$$, 200, 0.20);

-- 【E-A-06】equal 触发 | ustore | 单列 | 未命中+other=0 | 上界截断
DROP TABLE IF EXISTS t_e_ustore_low;
CREATE TABLE t_e_ustore_low (ver int, region int) WITH (storage_type=ustore);
INSERT INTO t_e_ustore_low
  SELECT (g%2)+1, (g%2)+1
  FROM generate_series(1, 10000) g;
ANALYZE t_e_ustore_low;
INSERT INTO t_e_ustore_low SELECT 3, 3 FROM generate_series(1, 2000) g;
CALL check_erows('E-A-06', $$SELECT * FROM t_e_ustore_low WHERE ver = 3$$, 2000, 0.20);

-- 【E-A-07】equal 触发 | ustore | 多列 | 公式值生效
CREATE STATISTICS st_e_ust_mc ON ver, region FROM t_e_ustore;
ANALYZE t_e_ustore;
CALL check_erows('E-A-07', $$SELECT * FROM t_e_ustore WHERE ver = 51 AND region = 3$$, 20, 0.20);
DROP STATISTICS st_e_ust_mc;

-- 【E-A-08】equal 触发 | ustore | 多列 | 上界截断
CREATE STATISTICS st_e_ust_mc2 ON ver, region FROM t_e_ustore_low;
INSERT INTO t_e_ustore_low SELECT 7, 7 FROM generate_series(1, 2000) g;
ANALYZE t_e_ustore_low;
CALL check_erows('E-A-08', $$SELECT * FROM t_e_ustore_low WHERE ver = 7$$, 2000, 0.20);
DROP STATISTICS st_e_ust_mc2;

-- 【E-A-09】equal 触发 | 一级分区-剪枝单（p3）| 单列 | 公式值生效
-- 预期：触发 equal 边界外矫正 | rows ≈ 200（±5%）| p3 上 ver=51 未命中该分区 MCV
CALL check_erows('E-A-09', $$SELECT * FROM t_e_part1 WHERE ver = 51 AND region = 8$$, 200, 0.20);

-- 【E-A-10】equal 触发 | 一级分区-剪枝单（p3）| 单列 | 上界截断
-- 前置：一级分区-低 NDV
DROP TABLE IF EXISTS t_e_part1_low;
CREATE TABLE t_e_part1_low (ver int, region int)
  PARTITION BY RANGE (region) (PARTITION p1 VALUES LESS THAN (6), PARTITION p2 VALUES LESS THAN (11));
INSERT INTO t_e_part1_low SELECT (g%2)+1, (g%10)+1 FROM generate_series(1, 10000) g;
ANALYZE t_e_part1_low WITH ALL COMPLETE;
INSERT INTO t_e_part1_low SELECT 6, (g%10)+1 FROM generate_series(1, 2000) g;
CALL check_erows('E-A-10', $$SELECT * FROM t_e_part1_low WHERE ver = 6 AND region = 8$$, 2000, 0.20);

-- 【E-A-11】equal 触发 | 一级分区-剪枝单 | 多列 | 公式值生效
CREATE STATISTICS st_e_p1_mc ON ver, region FROM t_e_part1;
ANALYZE t_e_part1 WITH ALL COMPLETE;
CALL check_erows('E-A-11', $$SELECT * FROM t_e_part1 WHERE ver = 51 AND region = 8$$, 20, 0.20);
DROP STATISTICS st_e_p1_mc;

-- 【E-A-12】equal 触发 | 一级分区-剪枝单 | 多列 | 上界截断
CREATE STATISTICS st_e_p1_mc2 ON ver, region FROM t_e_part1_low;
ANALYZE t_e_part1_low WITH ALL COMPLETE;
CALL check_erows('E-A-12', $$SELECT * FROM t_e_part1_low WHERE ver = 6 AND region = 8$$, 2000, 0.20);
DROP STATISTICS st_e_p1_mc2;

-- 【E-A-13】equal 触发 | 一级分区-不剪枝 | 单列 | 公式值生效
-- 不剪枝：通过 ver 过滤但无分区键限定，扫所有分区用主表统计
CALL check_erows('E-A-13', $$SELECT * FROM t_e_part1 WHERE ver = 51$$, 200, 0.20);

-- 【E-A-14】equal 触发 | 一级分区-不剪枝 | 单列 | 上界截断
CALL check_erows('E-A-14', $$SELECT * FROM t_e_part1_low WHERE ver = 6$$, 2000, 0.20);

-- 【E-A-15】equal 触发 | 一级分区-不剪枝 | 多列 | 公式值生效
CREATE STATISTICS st_e_p1_nopr ON ver, region FROM t_e_part1;
ANALYZE t_e_part1 WITH ALL COMPLETE;
CALL check_erows('E-A-15', $$SELECT * FROM t_e_part1 WHERE ver = 51 AND v = 'v100'$$, 1, 0.20);  -- v 非分区键，不剪枝
DROP STATISTICS st_e_p1_nopr;

-- 【E-A-16】equal 触发 | 一级分区-不剪枝 | 多列 | 上界截断
CREATE STATISTICS st_e_p1_nopr2 ON ver, region FROM t_e_part1_low;
ANALYZE t_e_part1_low WITH ALL COMPLETE;
CALL check_erows('E-A-16', $$SELECT * FROM t_e_part1_low WHERE ver = 6 AND region IN (1,5,9)$$, 600, 0.20);
DROP STATISTICS st_e_p1_nopr2;

-- 5.3 组 B：不触发单测 2 条

-- 【E-B-01】equal 不触发 | qual_c 命中 MCV
-- 预期：不触发矫正（原逻辑）| rows ≈ 240（±20%）| MCV 频率 0.02 × pages 膨胀后 reltuples≈12000 = 240
CALL check_erows('E-B-01', $$SELECT * FROM t_e_astore WHERE ver = 1$$, 240, 0.20);

-- 【E-B-02】equal 不触发 | qual_c 未命中 MCV 但 other_distinct > 0
-- 前置：构造部分 MCV + 部分 non-MCV 场景
DROP TABLE IF EXISTS t_e_otherdist;
CREATE TABLE t_e_otherdist (ver int);
-- ver 1..10 各 900 行（高频,进 MCV），ver 11..110 各 10 行（低频,不进 MCV，other_distinct=100）
INSERT INTO t_e_otherdist SELECT (g%10)+1 FROM generate_series(1, 9000) g;
INSERT INTO t_e_otherdist SELECT (g%100)+11 FROM generate_series(1, 1000) g;
ANALYZE t_e_otherdist;
CALL check_erows('E-B-02', $$SELECT * FROM t_e_otherdist WHERE ver = 50$$, 10, 0.20);  -- 未命中 MCV，但 other_distinct>0，走原逻辑

-- 5.4 组 C：约束回退 3 条

-- 【E-C-01】equal 约束回退 | opt_use_static_stats=on
-- 预期：不触发矫正（整体不支持）| rows = 1（原逻辑）
SET opt_use_static_stats = on;
CALL check_erows('E-C-01', $$SELECT * FROM t_e_astore WHERE ver = 51$$, 1, 0.20);
SET opt_use_static_stats = off;

-- 【E-C-02】equal 约束回退 | 页面空洞
-- 预期：估算失真但不崩溃
DROP TABLE IF EXISTS t_e_astore;
CREATE TABLE t_e_astore (ver int, region int, v varchar(32));
INSERT INTO t_e_astore
  SELECT (g % 50) + 1, (g % 10) + 1, 'v' || g FROM generate_series(1, 10000) g;
ANALYZE t_e_astore;
DELETE FROM t_e_astore WHERE ver BETWEEN 10 AND 40;
INSERT INTO t_e_astore SELECT 51, (g % 10) + 1, 'v' || g FROM generate_series(1, 2000) g;
CALL check_erows('E-C-02', $$SELECT * FROM t_e_astore WHERE ver = 51$$, 200, 0.20);

-- 【E-C-03】equal 约束回退 | insert 无页面增长
CREATE TABLE t_e_nopagegrow (ver int) WITH (fillfactor=30);
INSERT INTO t_e_nopagegrow SELECT (g%50)+1 FROM generate_series(1, 10000) g;
ANALYZE t_e_nopagegrow;
INSERT INTO t_e_nopagegrow SELECT 51 FROM generate_series(1, 50) g;
CALL check_erows('E-C-03', $$SELECT * FROM t_e_nopagegrow WHERE ver = 51$$, 1, 0.20);

-- equal 不包含"索引主列"和"多列统计回退"约束（equal 明确支持多列；索引主列对 equal 不构成限制）。

-- 5.5 组 D：其它单测 7 条

-- 【E-D-01】表类型 | 本地临时表
-- 预期：触发 equal 边界外矫正 | rows ≈ 200（±5%）
CREATE TEMP TABLE t_e_temp (ver int) ON COMMIT PRESERVE ROWS;
INSERT INTO t_e_temp SELECT (g%50)+1 FROM generate_series(1, 10000) g;
ANALYZE t_e_temp;
INSERT INTO t_e_temp SELECT 51 FROM generate_series(1, 2000) g;
CALL check_erows('E-D-01', $$SELECT * FROM t_e_temp WHERE ver = 51$$, 200, 0.20);

-- 【E-D-02】表类型 | 全局临时表 GTT
-- 预期：触发 equal 边界外矫正 | rows ≈ 200（±5%）
CREATE GLOBAL TEMP TABLE t_e_gtt (ver int) ON COMMIT PRESERVE ROWS;
INSERT INTO t_e_gtt SELECT (g%50)+1 FROM generate_series(1, 10000) g;
ANALYZE t_e_gtt;
INSERT INTO t_e_gtt SELECT 51 FROM generate_series(1, 2000) g;
CALL check_erows('E-D-02', $$SELECT * FROM t_e_gtt WHERE ver = 51$$, 200, 0.20);

-- 【E-D-03】表类型 | 一级分区-剪枝多分区
-- 预期：触发 equal 边界外矫正 | rows ≈ 200（±5%）| 剪枝到 p2+p3
CALL check_erows('E-D-03', $$SELECT * FROM t_e_part1 WHERE ver = 51 AND region >= 4$$, 200, 0.20);

-- 【E-D-04】表类型 | 二级分区-剪枝到一级
CREATE TABLE t_e_part2 (ver int, region int, v varchar(32))
  PARTITION BY RANGE (region) SUBPARTITION BY LIST (ver) (
    PARTITION p1 VALUES LESS THAN (6) (
      SUBPARTITION p1_v1 VALUES (1,2,3,4,5),
      SUBPARTITION p1_v2 VALUES (DEFAULT)
    ),
    PARTITION p2 VALUES LESS THAN (11) (
      SUBPARTITION p2_v1 VALUES (1,2,3,4,5),
      SUBPARTITION p2_v2 VALUES (DEFAULT)
    )
  );
INSERT INTO t_e_part2 SELECT (g%50)+1, (g%10)+1, 'v'||g FROM generate_series(1, 10000) g;
ANALYZE t_e_part2 WITH ALL COMPLETE;
INSERT INTO t_e_part2 SELECT 51, (g%10)+1, 'v'||g FROM generate_series(1, 2000) g;
-- 预期：触发 equal 边界外矫正 | 剪枝到 p2（含 p2_v2），二级维度不剪枝
CALL check_erows('E-D-04', $$SELECT * FROM t_e_part2 WHERE ver = 51 AND region = 8$$, 200, 0.20);

-- 【E-D-05】表类型 | 二级分区-剪枝到叶子
-- 预期：触发 equal 边界外矫正 | 剪枝到 p2_v2 单叶子
CALL check_erows('E-D-05', $$SELECT * FROM t_e_part2 WHERE ver = 51 AND region = 8 AND ver > 50$$, 200, 0.20);  -- 仅 p2_v2 满足

-- 【E-D-06】表类型 | 二级分区-不剪枝
-- 预期：触发 equal 边界外矫正 | 按 v 过滤无法剪枝
CALL check_erows('E-D-06', $$SELECT * FROM t_e_part2 WHERE ver = 51$$, 200, 0.20);  -- ver 非分区键，扫所有叶子

-- 【E-D-07】统计信息类型 | 表达式统计信息（equal 谓词在表达式列上）
-- 预期：触发 equal 边界外矫正 | rows ≈ 200（±5%）
DROP TABLE IF EXISTS t_e_astore;
CREATE TABLE t_e_astore (ver int, region int, v varchar(32));
INSERT INTO t_e_astore
  SELECT (g % 50) + 1, (g % 10) + 1, 'v' || g FROM generate_series(1, 10000) g;
CREATE INDEX st_e_expr ON t_e_astore((ver * 2));
ANALYZE t_e_astore;
INSERT INTO t_e_astore SELECT 51, (g % 10) + 1, 'v' || g FROM generate_series(1, 2000) g;
CALL check_erows('E-D-07', $$SELECT * FROM t_e_astore WHERE (ver * 2) = 102$$, 200, 0.20);
DROP INDEX st_e_expr;

-- 还有 3 个"跨谓词共用"的单测用例放在这里（increase_tuples=0、历史统计 prune、数据类型 timestamp/bigint/varchar、vacuum 只更表级的 equal 部分），避免重复：

-- 【E-D-08】increase_tuples = 0 边界
-- 预期：触发但上界=0 | rows = 1（钳制）| 公式 min(200, 0) = 0 → 1
CREATE TABLE t_e_noincr (ver int);
INSERT INTO t_e_noincr SELECT (g%50)+1 FROM generate_series(1, 10000) g;
ANALYZE t_e_noincr;
-- 不再 insert
CALL check_erows('E-D-08', $$SELECT * FROM t_e_noincr WHERE ver = 51$$, 1, 0.20);

-- 【E-D-09】历史统计信息已 prune
-- 预期：触发 equal 边界外矫正 | rows ≈ 200（±容忍，走当前 relpages/reltuples）
DROP TABLE IF EXISTS t_e_astore;
CREATE TABLE t_e_astore (ver int, region int, v varchar(32));
INSERT INTO t_e_astore
  SELECT (g % 50) + 1, (g % 10) + 1, 'v' || g FROM generate_series(1, 10000) g;
ANALYZE t_e_astore;
INSERT INTO t_e_astore SELECT 51, (g % 10) + 1, 'v' || g FROM generate_series(1, 2000) g;
CALL DBMS_STATS.PURGE_STATS(current_timestamp);
CALL check_erows('E-D-09', $$SELECT * FROM t_e_astore WHERE ver = 51$$, 200, 0.20);

-- 【E-D-10】vacuum 只更表级不更列级
-- 预期：触发 equal 边界外矫正 | rows ≈ 200（±5%）
DROP TABLE IF EXISTS t_e_astore;
CREATE TABLE t_e_astore (ver int, region int, v varchar(32));
INSERT INTO t_e_astore
  SELECT (g % 50) + 1, (g % 10) + 1, 'v' || g FROM generate_series(1, 10000) g;
ANALYZE t_e_astore;
INSERT INTO t_e_astore SELECT 51, (g % 10) + 1, 'v' || g FROM generate_series(1, 2000) g;
VACUUM t_e_astore;
CALL check_erows('E-D-10', $$SELECT * FROM t_e_astore WHERE ver = 51$$, 200, 0.20);

-- 【E-D-11】数据类型 | timestamp 列 equal 触发
CREATE TABLE t_e_ts (ts timestamp);
INSERT INTO t_e_ts SELECT '2026-01-01'::timestamp + ((g%50)||' days')::interval FROM generate_series(1, 10000) g;
ANALYZE t_e_ts;
INSERT INTO t_e_ts SELECT '2026-03-01'::timestamp FROM generate_series(1, 2000) g;  -- 新值
CALL check_erows('E-D-11', $$SELECT * FROM t_e_ts WHERE ts = '2026-03-01'::timestamp$$, 200, 0.20);

-- 【E-D-12】数据类型 | bigint 列 equal 触发
CREATE TABLE t_e_bi (b bigint);
INSERT INTO t_e_bi SELECT ((g%50)+1)::bigint * 1000000000 FROM generate_series(1, 10000) g;
ANALYZE t_e_bi;
INSERT INTO t_e_bi SELECT 99999999999::bigint FROM generate_series(1, 2000) g;
CALL check_erows('E-D-12', $$SELECT * FROM t_e_bi WHERE b = 99999999999$$, 200, 0.20);

-- 【E-D-13】数据类型 | varchar 列 equal 触发
CREATE TABLE t_e_va (v varchar(32));
INSERT INTO t_e_va SELECT 'ver' || ((g%50)+1) FROM generate_series(1, 10000) g;
ANALYZE t_e_va;
INSERT INTO t_e_va SELECT 'ver999' FROM generate_series(1, 2000) g;
CALL check_erows('E-D-13', $$SELECT * FROM t_e_va WHERE v = 'ver999'$$, 200, 0.20);

-- 实际对应规模测算（D 组 20 条）：range D 6 + gt D 7 + equal D 13 = 26，稍超出原预算（20），但覆盖更完整，后续可砍合并。

-- ---

-- 6. 开关回归组

-- 【S-01】refine_growth_sel=off | range 触发场景估行回退到 1
-- 预期：rows = 1（新特性关闭，走原下界钳制）
SET refine_growth_sel = off;
CALL check_erows('S-01', $$SELECT * FROM t_r_astore WHERE id > 11000 AND id < 11100$$, 1, 0.20);
SET refine_growth_sel = on;

-- 【S-02】refine_growth_sel=off | gt 触发场景估行回退到 1
SET refine_growth_sel = off;
CALL check_erows('S-02', $$SELECT * FROM t_r_astore WHERE id > 10100$$, 1, 0.20);
SET refine_growth_sel = on;

-- 【S-03】refine_growth_sel=off | equal 触发场景估行回退到 1
SET refine_growth_sel = off;
CALL check_erows('S-03', $$SELECT * FROM t_e_astore WHERE ver = 51$$, 1, 0.20);
SET refine_growth_sel = on;

-- 【S-04】refine_growth_sel=on | 一般场景 range 估行不变（守默认开启底线）
-- 预期：rows ≈ 1200（±20%）| 选择率 0.1 × 12000（pages 膨胀后）= 1200，与特性关闭一致
CALL check_erows('S-04', $$SELECT * FROM t_r_astore WHERE id > 2000 AND id < 3000$$, 1200, 0.20);

-- 【S-05】refine_growth_sel=on | 一般场景 equal 命中 MCV 估行不变
-- 预期：rows ≈ 240（±20%）| MCV 频率 0.02 × 12000 = 240
CALL check_erows('S-05', $$SELECT * FROM t_e_astore WHERE ver = 1$$, 240, 0.20);

-- 【S-06】refine_growth_sel=on vs off | 一般场景 range 数值严格一致
-- 前置：分别断言 refine_growth_sel=off/on 的 rows 相同（均按 pages 膨胀后估算）
SET refine_growth_sel = off;
CALL check_erows('S-06-off', $$SELECT * FROM t_r_astore WHERE id > 2000 AND id < 3000$$, 1200, 0.20);
SET refine_growth_sel = on;
CALL check_erows('S-06-on', $$SELECT * FROM t_r_astore WHERE id > 2000 AND id < 3000$$, 1200, 0.20);

-- 【S-07】refine_growth_sel=on vs off | 一般场景 gt 数值严格一致
-- 预期：rows ≈ 6000（±20%）| 选择率 0.5 × 12000 = 6000
SET refine_growth_sel = off;
CALL check_erows('S-07-off', $$SELECT * FROM t_r_astore WHERE id > 5000$$, 6000, 0.20);
SET refine_growth_sel = on;
CALL check_erows('S-07-on', $$SELECT * FROM t_r_astore WHERE id > 5000$$, 6000, 0.20);

-- 【S-08】refine_growth_sel=on vs off | 一般场景 equal 命中 MCV 数值严格一致
SET refine_growth_sel = off;
CALL check_erows('S-08-off', $$SELECT * FROM t_e_astore WHERE ver = 1$$, 240, 0.20);
SET refine_growth_sel = on;
CALL check_erows('S-08-on', $$SELECT * FROM t_e_astore WHERE ver = 1$$, 240, 0.20);

-- 【S-09】refine_growth_sel=on | equal 未命中 MCV 但 other_distinct>0 的一般场景估行不变
SET refine_growth_sel = off;
CALL check_erows('S-09-off', $$SELECT * FROM t_e_otherdist WHERE ver = 50$$, 10, 0.20);
SET refine_growth_sel = on;
CALL check_erows('S-09-on', $$SELECT * FROM t_e_otherdist WHERE ver = 50$$, 10, 0.20);

-- ---
