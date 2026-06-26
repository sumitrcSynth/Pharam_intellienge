-- =============================================================================
-- FILE: 05_feature_engineering_layer.sql
-- PURPOSE: Feature Engineering Layer — builds all ML-ready feature tables
--          consumed by the Gold Layer (gold_v2)
-- SCHEMA:   FEATURE_TEST  (used by gold_v2 references)
-- SOURCE:   SILVER_TEST (Data Vault tables)  +  RAW (supplemental)
--
-- TABLES PRODUCED (all required by gold_v2):
--   1. FEAT_BATCH_QUALITY_FEATURES   ← qi  alias in gold BATCH_FACT
--   2. FEAT_ML_INPUT                 ← mi  alias in gold BATCH_FACT / VW_UI_SIMULATION_BASE
--   3. FEAT_FINANCIAL_FEATURES       ← ff  alias in gold BATCH_FACT
--   4. FEAT_FDA_RULE_VIOLATIONS      ← fv  alias in gold RULE_ENGINE_OVERRIDES
--   5. FEAT_ML_ENHANCED              ← me  alias in gold BATCH_FACT
--
-- RUN ORDER: Execute sequentially top to bottom.
-- RUN AS:    PHARMA_ADMIN  |  WH: PHARMA_TRANSFORM_WH  (or COMPUTE_WH)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS FEATURE_TEST;
-- =============================================================================
-- TABLE 1: FEAT_BATCH_QUALITY_FEATURES
-- Alias in Gold: qi (FEAT_BATCH_QUALITY_FEATURES qi)
-- Columns required by gold_v2.BATCH_FACT:
--   BATCH_ID, TOTAL_TESTS, FAILED_TESTS, OOS_COUNT, BORDERLINE_COUNT,
--   PASS_RATE_PCT, OOS_RATE_PCT, FAIL_RATE_PCT,
--   STERILITY_FAIL_FLAG, ENDOTOXIN_FAIL_FLAG, STERILITY_X_ENDOTOXIN,
--   TEMP_VIOLATION_COUNT, HUMIDITY_VIOLATION_COUNT, PRESSURE_VIOLATION_COUNT,
--   CRITICAL_DEVIATION_COUNT, HIGH_DEVIATION_COUNT, TOTAL_DEVIATIONS,
--   PROCESS_VARIANCE, WEIGHTED_DEVIATION_SCORE,
--   PROCESS_DEVIATION_COUNT, EQUIPMENT_DEVIATION_COUNT, HUMAN_DEVIATION_COUNT,
--   AVG_TEMP_DEVIATION_C, BATCH_DURATION_HOURS
-- Also used in risk_tags CTE and ai_reason CTE inside gold BATCH_FACT.
-- =============================================================================

CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES AS

WITH

-- ── Lab test aggregates ────────────────────────────────────────────────────
lab_agg AS (
    SELECT
        hb.BATCH_ID,
        COUNT(*)                                                        AS TOTAL_TESTS,
        SUM(CASE WHEN slt.TEST_STATUS = 'FAIL'       THEN 1 ELSE 0 END) AS FAILED_TESTS,
        SUM(CASE WHEN slt.TEST_STATUS = 'OOS'        THEN 1 ELSE 0 END) AS OOS_COUNT,
        SUM(CASE WHEN slt.TEST_STATUS = 'BORDERLINE' THEN 1 ELSE 0 END) AS BORDERLINE_COUNT,
        SUM(CASE WHEN slt.TEST_STATUS = 'PASS'       THEN 1 ELSE 0 END) AS PASSED_TESTS,

        -- Sterility: test name match
        MAX(CASE
            WHEN UPPER(slt.TEST_NAME) LIKE '%STERILITY%'
             AND slt.TEST_STATUS IN ('FAIL','OOS') THEN 1 ELSE 0
        END) AS STERILITY_FAIL_FLAG,

        -- Endotoxin: test name match
        MAX(CASE
            WHEN UPPER(slt.TEST_NAME) LIKE '%ENDOTOXIN%'
             AND slt.TEST_STATUS IN ('FAIL','OOS') THEN 1 ELSE 0
        END) AS ENDOTOXIN_FAIL_FLAG,

        -- Potency fail flag (used in compliance)
        MAX(CASE
            WHEN UPPER(slt.TEST_NAME) LIKE '%POTENCY%'
             AND slt.TEST_STATUS IN ('FAIL','OOS') THEN 1 ELSE 0
        END) AS POTENCY_FAIL_FLAG,

        -- Average spec distance (how far results are from spec boundaries)
        AVG(
            CASE
                WHEN (slt.SPEC_MAX - slt.SPEC_MIN) > 0
                THEN ABS(slt.TEST_RESULT - ((slt.SPEC_MAX + slt.SPEC_MIN) / 2.0))
                     / ((slt.SPEC_MAX - slt.SPEC_MIN) / 2.0)
                ELSE 0
            END
        ) AS AVG_SPEC_DISTANCE_NORMALIZED,

        -- Repeat test count from RAW (flag in raw lab tests)
        0 AS REPEAT_TEST_COUNT   -- populated below via join to raw

    FROM SILVER_TEST.HUB_BATCH hb
    JOIN SILVER_TEST.LNK_BATCH_LAB_TEST lblt ON hb.HK_BATCH = lblt.HK_BATCH
    JOIN SILVER_TEST.SAT_LAB_TEST slt        ON lblt.HK_TEST = slt.HK_TEST
    GROUP BY hb.BATCH_ID
),

-- ── Repeat test count from RAW (REPEAT_TEST_FLAG column) ─────────────────
repeat_tests AS (
    SELECT
        BATCH_ID,
        SUM(CASE WHEN UPPER(TRIM(REPEAT_TEST_FLAG)) = 'TRUE' THEN 1 ELSE 0 END) AS REPEAT_TEST_COUNT
    FROM RAW.RAW_LAB_TESTS
    GROUP BY BATCH_ID
),

-- ── Sensor aggregates ──────────────────────────────────────────────────────
sensor_agg AS (
    SELECT
        hb.BATCH_ID,

        -- Temperature
        AVG(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP'        THEN rsr.SENSOR_VALUE END)   AS TEMP_AVG,
        STDDEV(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP'     THEN rsr.SENSOR_VALUE END)   AS TEMP_STDDEV,
        SUM(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP'
                  AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE'   THEN 1 ELSE 0 END)           AS TEMP_VIOLATION_COUNT,
        -- Average temperature deviation from midpoint of thresholds
        AVG(CASE
            WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP'
             AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE'
             AND (rsr.THRESHOLD_MAX - rsr.THRESHOLD_MIN) > 0
            THEN ABS(rsr.SENSOR_VALUE - ((rsr.THRESHOLD_MAX + rsr.THRESHOLD_MIN) / 2.0))
            ELSE 0
        END)                                                                              AS AVG_TEMP_DEVIATION_C,
        -- Max excursion minutes proxy (each out-of-range reading assumed 5 min window)
        SUM(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP'
                  AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE'   THEN 5 ELSE 0 END)           AS TEMP_MAX_EXCURSION_MINS,

        -- Humidity
        SUM(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'HUMIDITY'
                  AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE'   THEN 1 ELSE 0 END)           AS HUMIDITY_VIOLATION_COUNT,

        -- Pressure
        SUM(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'PRESSURE'
                  AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE'   THEN 1 ELSE 0 END)           AS PRESSURE_VIOLATION_COUNT,

        -- Total IoT violations across all sensor types
        SUM(CASE WHEN UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE'   THEN 1 ELSE 0 END)           AS TOTAL_IOT_VIOLATIONS,

        -- Total readings (used for density calc)
        COUNT(*)                                                                          AS TOTAL_SENSOR_READINGS

    FROM SILVER_TEST.HUB_BATCH hb
    JOIN SILVER_TEST.LNK_BATCH_SENSOR lbs  ON hb.HK_BATCH  = lbs.HK_BATCH
    JOIN SILVER_TEST.HUB_SENSOR hs         ON lbs.HK_SENSOR = hs.HK_SENSOR
    JOIN SILVER_TEST.SAT_SENSOR sr         ON hs.HK_SENSOR  = sr.HK_SENSOR
    -- Join raw sensor readings to get IS_OUT_OF_RANGE and SENSOR_VALUE
    JOIN RAW.RAW_SENSOR_READINGS rsr       ON rsr.SENSOR_ID = hs.SENSOR_ID
                                          AND rsr.BATCH_ID  = hb.BATCH_ID
    GROUP BY hb.BATCH_ID
),

-- ── Deviation aggregates ───────────────────────────────────────────────────
deviation_agg AS (
    SELECT
        hb.BATCH_ID,
        COUNT(*)                                                                AS TOTAL_DEVIATIONS,
        SUM(CASE WHEN UPPER(sd.SEVERITY) = 'CRITICAL' THEN 1 ELSE 0 END)       AS CRITICAL_DEVIATION_COUNT,
        SUM(CASE WHEN UPPER(sd.SEVERITY) = 'HIGH'     THEN 1 ELSE 0 END)       AS HIGH_DEVIATION_COUNT,
        SUM(CASE WHEN UPPER(sd.SEVERITY) IN ('MEDIUM','LOW') THEN 1 ELSE 0 END) AS LOW_MED_DEVIATION_COUNT,

        -- Weighted deviation score (critical=3, high=2, medium/low=1)
        SUM(
            CASE UPPER(sd.SEVERITY)
                WHEN 'CRITICAL' THEN 3
                WHEN 'HIGH'     THEN 2
                ELSE 1
            END
        )                                                                       AS WEIGHTED_DEVIATION_SCORE,

        -- Deviation type breakdown
        SUM(CASE WHEN UPPER(sd.DEVIATION_TYPE) LIKE '%PROCESS%'     THEN 1 ELSE 0 END) AS PROCESS_DEVIATION_COUNT,
        SUM(CASE WHEN UPPER(sd.DEVIATION_TYPE) LIKE '%EQUIPMENT%'   THEN 1 ELSE 0 END) AS EQUIPMENT_DEVIATION_COUNT,
        SUM(CASE WHEN UPPER(sd.DEVIATION_TYPE) LIKE '%HUMAN%'
                   OR UPPER(sd.DEVIATION_TYPE) LIKE '%OPERATOR%'    THEN 1 ELSE 0 END) AS HUMAN_DEVIATION_COUNT,
        SUM(CASE WHEN UPPER(sd.DEVIATION_TYPE) LIKE '%ENVIRONMENT%' THEN 1 ELSE 0 END) AS ENV_DEVIATION_COUNT

    FROM SILVER_TEST.HUB_BATCH hb
    JOIN SILVER_TEST.LNK_BATCH_DEVIATION lbd ON hb.HK_BATCH    = lbd.HK_BATCH
    JOIN SILVER_TEST.SAT_DEVIATION sd         ON lbd.HK_DEVIATION = sd.HK_DEVIATION
    GROUP BY hb.BATCH_ID
),

-- ── Batch duration from SAT_BATCH ──────────────────────────────────────────
batch_duration AS (
    SELECT
        hb.BATCH_ID,
        COALESCE(
            DATEDIFF(HOUR, sb.START_TIME, sb.END_TIME),
            8
        )                              AS BATCH_DURATION_HOURS,
        sb.BATCH_SIZE,
        sb.BATCH_SIZE_UNIT,
        sb.PROCESS_STAGE,
        sb.PLANT_ID,
        sb.LINE_ID
    FROM SILVER_TEST.HUB_BATCH hb
    JOIN SILVER_TEST.SAT_BATCH sb ON hb.HK_BATCH = sb.HK_BATCH
    QUALIFY ROW_NUMBER() OVER (PARTITION BY hb.BATCH_ID ORDER BY sb.LOAD_DATE DESC) = 1
),

-- ── Product info ───────────────────────────────────────────────────────────
product_info AS (
    SELECT
        hb.BATCH_ID,
        sp.PRODUCT_TYPE,
        sp.PRODUCT_NAME
    FROM SILVER_TEST.HUB_BATCH hb
    JOIN SILVER_TEST.LNK_BATCH_PRODUCT lbp ON hb.HK_BATCH  = lbp.HK_BATCH
    JOIN SILVER_TEST.SAT_PRODUCT sp         ON lbp.HK_PRODUCT = sp.HK_PRODUCT
    QUALIFY ROW_NUMBER() OVER (PARTITION BY hb.BATCH_ID ORDER BY sp.LOAD_DATE DESC) = 1
)

-- ── FINAL SELECT ───────────────────────────────────────────────────────────
SELECT
    bd.BATCH_ID,
    bd.PLANT_ID,
    bd.PROCESS_STAGE,
    pi.PRODUCT_TYPE,
    pi.PRODUCT_NAME,
    bd.BATCH_DURATION_HOURS,
    bd.BATCH_SIZE,

    -- Lab quality
    COALESCE(la.TOTAL_TESTS,        0)      AS TOTAL_TESTS,
    COALESCE(la.FAILED_TESTS,       0)      AS FAILED_TESTS,
    COALESCE(la.OOS_COUNT,          0)      AS OOS_COUNT,
    COALESCE(la.BORDERLINE_COUNT,   0)      AS BORDERLINE_COUNT,
    COALESCE(la.PASSED_TESTS,       0)      AS PASSED_TESTS,

    -- Rates
    ROUND(
        COALESCE(la.PASSED_TESTS, 0) /
        NULLIF(COALESCE(la.TOTAL_TESTS, 0), 0) * 100.0,
    2)                                      AS PASS_RATE_PCT,

    ROUND(
        COALESCE(la.OOS_COUNT, 0) /
        NULLIF(COALESCE(la.TOTAL_TESTS, 0), 0),
    4)                                      AS OOS_RATE_PCT,

    ROUND(
        COALESCE(la.FAILED_TESTS, 0) /
        NULLIF(COALESCE(la.TOTAL_TESTS, 0), 0),
    4)                                      AS FAIL_RATE_PCT,

    -- Critical test flags
    COALESCE(la.STERILITY_FAIL_FLAG,  0)    AS STERILITY_FAIL_FLAG,
    COALESCE(la.ENDOTOXIN_FAIL_FLAG,  0)    AS ENDOTOXIN_FAIL_FLAG,
    COALESCE(la.POTENCY_FAIL_FLAG,    0)    AS POTENCY_FAIL_FLAG,

    -- Interaction term (used in FEAT_ML_INPUT)
    COALESCE(la.STERILITY_FAIL_FLAG, 0)
      * COALESCE(la.ENDOTOXIN_FAIL_FLAG, 0) AS STERILITY_X_ENDOTOXIN,

    -- Spec distance
    COALESCE(la.AVG_SPEC_DISTANCE_NORMALIZED, 0) AS AVG_SPEC_DISTANCE_NORMALIZED,

    -- Repeat tests
    COALESCE(rt.REPEAT_TEST_COUNT, 0)       AS REPEAT_TEST_COUNT,

    -- IoT / Sensor
    COALESCE(sa.TEMP_VIOLATION_COUNT,    0) AS TEMP_VIOLATION_COUNT,
    COALESCE(sa.HUMIDITY_VIOLATION_COUNT,0) AS HUMIDITY_VIOLATION_COUNT,
    COALESCE(sa.PRESSURE_VIOLATION_COUNT,0) AS PRESSURE_VIOLATION_COUNT,
    COALESCE(sa.TOTAL_IOT_VIOLATIONS,    0) AS TOTAL_IOT_VIOLATIONS,
    COALESCE(sa.AVG_TEMP_DEVIATION_C,  0.0) AS AVG_TEMP_DEVIATION_C,
    COALESCE(sa.TEMP_MAX_EXCURSION_MINS, 0) AS TEMP_MAX_EXCURSION_MINS,
    COALESCE(sa.TOTAL_SENSOR_READINGS,   1) AS TOTAL_SENSOR_READINGS,

    -- IoT density = violations per reading
    ROUND(
        COALESCE(sa.TOTAL_IOT_VIOLATIONS, 0) /
        NULLIF(COALESCE(sa.TOTAL_SENSOR_READINGS, 1), 0),
    4)                                      AS IOT_VIOLATION_DENSITY,

    -- Temperature × duration interaction
    ROUND(
        COALESCE(sa.TEMP_VIOLATION_COUNT, 0) *
        COALESCE(bd.BATCH_DURATION_HOURS, 8.0),
    2)                                      AS TEMP_X_DURATION,

    -- Deviations
    COALESCE(da.TOTAL_DEVIATIONS,           0) AS TOTAL_DEVIATIONS,
    COALESCE(da.CRITICAL_DEVIATION_COUNT,   0) AS CRITICAL_DEVIATION_COUNT,
    COALESCE(da.HIGH_DEVIATION_COUNT,       0) AS HIGH_DEVIATION_COUNT,
    COALESCE(da.LOW_MED_DEVIATION_COUNT,    0) AS LOW_MED_DEVIATION_COUNT,
    COALESCE(da.WEIGHTED_DEVIATION_SCORE,   0) AS WEIGHTED_DEVIATION_SCORE,
    COALESCE(da.PROCESS_DEVIATION_COUNT,    0) AS PROCESS_DEVIATION_COUNT,
    COALESCE(da.EQUIPMENT_DEVIATION_COUNT,  0) AS EQUIPMENT_DEVIATION_COUNT,
    COALESCE(da.HUMAN_DEVIATION_COUNT,      0) AS HUMAN_DEVIATION_COUNT,
    COALESCE(da.ENV_DEVIATION_COUNT,        0) AS ENV_DEVIATION_COUNT,

    -- Deviation density = deviations per hour
    ROUND(
        COALESCE(da.TOTAL_DEVIATIONS, 0) /
        NULLIF(COALESCE(bd.BATCH_DURATION_HOURS, 8.0), 0),
    4)                                      AS DEVIATION_DENSITY,

    -- Critical deviation rate
    ROUND(
        COALESCE(da.CRITICAL_DEVIATION_COUNT, 0) /
        NULLIF(COALESCE(da.TOTAL_DEVIATIONS, 0), 0),
    4)                                      AS CRITICAL_DEV_RATE,

    -- Interaction: temp violations × critical deviations
    COALESCE(sa.TEMP_VIOLATION_COUNT, 0)
      * COALESCE(da.CRITICAL_DEVIATION_COUNT, 0) AS TEMP_X_CRITICAL_DEV,

    -- Process variance proxy: stddev of temp / mean temp (CV)
    ROUND(
        COALESCE(sa.TEMP_STDDEV, 0) /
        NULLIF(ABS(COALESCE(sa.TEMP_AVG, 1)), 0),
    4)                                      AS PROCESS_VARIANCE,

    CURRENT_TIMESTAMP()                     AS FEATURE_COMPUTED_AT

FROM batch_duration bd
LEFT JOIN product_info         pi ON bd.BATCH_ID = pi.BATCH_ID
LEFT JOIN lab_agg              la ON bd.BATCH_ID = la.BATCH_ID
LEFT JOIN repeat_tests         rt ON bd.BATCH_ID = rt.BATCH_ID
LEFT JOIN sensor_agg           sa ON bd.BATCH_ID = sa.BATCH_ID
LEFT JOIN deviation_agg        da ON bd.BATCH_ID = da.BATCH_ID;


-- =============================================================================
-- TABLE 2: FEAT_ML_INPUT
-- Alias in Gold: mi (FEAT_ML_INPUT mi)
-- This is the EXACT input to the XGBoost UDF call in gold_v2.ML_PREDICTIONS.
-- Columns required (positional in UDF call):
--   PRODUCT_TYPE, PLANT_ID, BATCH_SIZE_BUCKET, DURATION_BUCKET,
--   TOTAL_TESTS, FAILED_TESTS, OOS_COUNT, BORDERLINE_COUNT,
--   PASS_RATE_PCT, OOS_RATE_PCT, FAIL_RATE_PCT,
--   STERILITY_FAIL_FLAG, ENDOTOXIN_FAIL_FLAG, STERILITY_X_ENDOTOXIN,
--   TEMP_VIOLATION_COUNT, TEMP_MAX_EXCURSION_MINS, AVG_TEMP_DEVIATION_C,
--   HUMIDITY_VIOLATION_COUNT, PRESSURE_VIOLATION_COUNT,
--   TOTAL_IOT_VIOLATIONS, IOT_VIOLATION_DENSITY, TEMP_X_DURATION,
--   TOTAL_DEVIATIONS, CRITICAL_DEVIATION_COUNT, HIGH_DEVIATION_COUNT,
--   WEIGHTED_DEVIATION_SCORE, PROCESS_DEVIATION_COUNT,
--   EQUIPMENT_DEVIATION_COUNT, HUMAN_DEVIATION_COUNT,
--   DEVIATION_DENSITY, CRITICAL_DEV_RATE, TEMP_X_CRITICAL_DEV,
--   BATCH_SIZE, BATCH_DURATION_HOURS, PROCESS_VARIANCE,
--   BATCH_START_HOUR, BATCH_START_DOW, IS_WEEKEND_BATCH, IS_NIGHT_SHIFT
-- Also used in VW_UI_SIMULATION_BASE:
--   BATCH_SIZE_BUCKET, DURATION_BUCKET, TEMP_MAX_EXCURSION_MINS,
--   TOTAL_IOT_VIOLATIONS, IOT_VIOLATION_DENSITY, TEMP_X_DURATION,
--   TOTAL_DEVIATIONS, WEIGHTED_DEVIATION_SCORE, DEVIATION_DENSITY,
--   CRITICAL_DEV_RATE, TEMP_X_CRITICAL_DEV, STERILITY_X_ENDOTOXIN,
--   OOS_RATE_PCT, FAIL_RATE_PCT
-- =============================================================================

CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_ML_INPUT AS

WITH

-- Batch temporal features from RAW (start time for DOW/hour features)
batch_time AS (
    SELECT
        BATCH_ID,
        START_TIME,
        PRODUCT_ID,
        PLANT_ID,
        BATCH_SIZE,
        HOUR(START_TIME)                                AS BATCH_START_HOUR,
        DAYOFWEEK(START_TIME)                           AS BATCH_START_DOW,   -- 0=Sun,6=Sat (Snowflake: 0=Mon)
        CASE WHEN DAYOFWEEK(START_TIME) IN (6, 7)
             THEN 1 ELSE 0 END                          AS IS_WEEKEND_BATCH,
        CASE WHEN HOUR(START_TIME) >= 22
               OR HOUR(START_TIME) < 6
             THEN 1 ELSE 0 END                          AS IS_NIGHT_SHIFT
    FROM RAW.RAW_BATCH_MASTER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY BATCH_ID ORDER BY _RAW_LOAD_TS DESC) = 1
)

SELECT
    qf.BATCH_ID,
    qf.PRODUCT_TYPE,
    qf.PLANT_ID,

    -- ── Bucketed features (categorical for tree model) ────────────────────
    CASE
        WHEN qf.BATCH_SIZE < 100   THEN 'SMALL'
        WHEN qf.BATCH_SIZE < 500   THEN 'MEDIUM'
        WHEN qf.BATCH_SIZE < 1000  THEN 'LARGE'
        ELSE 'XLARGE'
    END                                     AS BATCH_SIZE_BUCKET,

    CASE
        WHEN qf.BATCH_DURATION_HOURS < 4    THEN 'SHORT'
        WHEN qf.BATCH_DURATION_HOURS < 10   THEN 'NORMAL'
        WHEN qf.BATCH_DURATION_HOURS < 16   THEN 'LONG'
        ELSE 'EXTENDED'
    END                                     AS DURATION_BUCKET,

    -- ── Lab features (passed through from quality features) ───────────────
    qf.TOTAL_TESTS,
    qf.FAILED_TESTS,
    qf.OOS_COUNT,
    qf.BORDERLINE_COUNT,
    qf.PASS_RATE_PCT,
    qf.OOS_RATE_PCT,
    qf.FAIL_RATE_PCT,
    qf.STERILITY_FAIL_FLAG,
    qf.ENDOTOXIN_FAIL_FLAG,
    qf.STERILITY_X_ENDOTOXIN,

    -- ── Sensor features ───────────────────────────────────────────────────
    qf.TEMP_VIOLATION_COUNT,
    qf.TEMP_MAX_EXCURSION_MINS,
    qf.AVG_TEMP_DEVIATION_C,
    qf.HUMIDITY_VIOLATION_COUNT,
    qf.PRESSURE_VIOLATION_COUNT,
    qf.TOTAL_IOT_VIOLATIONS,
    qf.IOT_VIOLATION_DENSITY,
    qf.TEMP_X_DURATION,

    -- ── Deviation features ────────────────────────────────────────────────
    qf.TOTAL_DEVIATIONS,
    qf.CRITICAL_DEVIATION_COUNT,
    qf.HIGH_DEVIATION_COUNT,
    qf.WEIGHTED_DEVIATION_SCORE,
    qf.PROCESS_DEVIATION_COUNT,
    qf.EQUIPMENT_DEVIATION_COUNT,
    qf.HUMAN_DEVIATION_COUNT,
    qf.DEVIATION_DENSITY,
    qf.CRITICAL_DEV_RATE,
    qf.TEMP_X_CRITICAL_DEV,

    -- ── Process / size features ───────────────────────────────────────────
    qf.BATCH_SIZE,
    qf.BATCH_DURATION_HOURS,
    qf.PROCESS_VARIANCE,

    -- ── Temporal features ─────────────────────────────────────────────────
    bt.BATCH_START_HOUR,
    bt.BATCH_START_DOW,
    bt.IS_WEEKEND_BATCH,
    bt.IS_NIGHT_SHIFT,

    CURRENT_TIMESTAMP()                     AS FEATURE_COMPUTED_AT

FROM FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES qf
LEFT JOIN batch_time bt ON qf.BATCH_ID = bt.BATCH_ID;


-- =============================================================================
-- TABLE 5: FEAT_FDA_RULE_VIOLATIONS
-- Alias in Gold: fv (FEAT_FDA_RULE_VIOLATIONS fv) in RULE_ENGINE_OVERRIDES CTE
-- Columns required:
--   BATCH_ID, AUTO_BLOCK_RELEASE, MANDATORY_CAPA, REGULATORY_HOLD_DAYS,
--   VIOLATION_CATEGORY, CFR_REFERENCE, ESTIMATED_PENALTY_USD
-- Logic: match each batch to FDA penalty rules it triggers based on
--        quality signals from FEAT_BATCH_QUALITY_FEATURES.
-- =============================================================================

CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS AS

WITH

-- Latest active FDA rules from silver
fda_rules AS (
    SELECT
        hfr.PENALTY_RULE_ID,
        sfr.CFR_REFERENCE,
        sfr.VIOLATION_TYPE,
        sfr.VIOLATION_CATEGORY,
        sfr.APPLICABLE_PRODUCT_TYPE,
        sfr.PENALTY_TYPE,
        sfr.MIN_PENALTY_USD,
        sfr.MAX_PENALTY_USD,
        CASE WHEN UPPER(sfr.AUTO_BLOCK_RELEASE) = 'TRUE' THEN TRUE ELSE FALSE END  AS AUTO_BLOCK_RELEASE,
        CASE WHEN UPPER(sfr.MANDATORY_CAPA)     = 'TRUE' THEN TRUE ELSE FALSE END  AS MANDATORY_CAPA,
        sfr.REGULATORY_HOLD_DAYS,
        sfr.RECALL_CLASS,
        sfr.BUSINESS_IMPACT,
        sfr.IS_ACTIVE
    FROM SILVER_TEST.HUB_FDA_RULE hfr
    JOIN SILVER_TEST.SAT_FDA_RULE sfr ON hfr.HK_FDA_RULE = sfr.HK_FDA_RULE
    WHERE UPPER(sfr.IS_ACTIVE) = 'TRUE'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY hfr.PENALTY_RULE_ID ORDER BY sfr.LOAD_DATE DESC
    ) = 1
),

-- Quality features for rule matching
batch_quality AS (
    SELECT
        qf.BATCH_ID,
        qf.PRODUCT_TYPE,
        qf.FAILED_TESTS,
        qf.OOS_COUNT,
        qf.STERILITY_FAIL_FLAG,
        qf.ENDOTOXIN_FAIL_FLAG,
        qf.TEMP_VIOLATION_COUNT,
        qf.PRESSURE_VIOLATION_COUNT,
        qf.CRITICAL_DEVIATION_COUNT,
        qf.TOTAL_DEVIATIONS,
        qf.IOT_VIOLATION_DENSITY,
        qf.BATCH_DURATION_HOURS,
        qf.TOTAL_IOT_VIOLATIONS
    FROM FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES qf
),

-- Map each batch to triggered penalty rules
-- Rules align with LNK_BATCH_FDA_RULE logic in silver:
--   FDA-PEN-001: lab failures >= 2
--   FDA-PEN-002: sensor violation density >= 2/hr
--   FDA-PEN-003: critical deviations >= 1
--   FDA-PEN-005: total deviations >= 5
--   FDA-PEN-009: endotoxin failure >= 1
triggered_rules AS (

    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID
    FROM batch_quality bq
    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-001'
    WHERE (bq.FAILED_TESTS + bq.OOS_COUNT) >= 2
      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL
           OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE)

    UNION

    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID
    FROM batch_quality bq
    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-002'
    WHERE (bq.TOTAL_IOT_VIOLATIONS / NULLIF(bq.BATCH_DURATION_HOURS, 1)) >= 2
      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL
           OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE)

    UNION

    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID
    FROM batch_quality bq
    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-003'
    WHERE bq.CRITICAL_DEVIATION_COUNT >= 1
      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL
           OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE)

    UNION

    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID
    FROM batch_quality bq
    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-005'
    WHERE bq.TOTAL_DEVIATIONS >= 5
      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL
           OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE)

    UNION

    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID
    FROM batch_quality bq
    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-009'
    WHERE bq.ENDOTOXIN_FAIL_FLAG = 1
      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL
           OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE)

    UNION

    -- Sterility failure: map to relevant CFR rule (auto-block)
    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID
    FROM batch_quality bq
    JOIN fda_rules fr ON fr.PENALTY_RULE_ID NOT IN (
            'FDA-PEN-001','FDA-PEN-002','FDA-PEN-003','FDA-PEN-005','FDA-PEN-009'
        )
     AND fr.AUTO_BLOCK_RELEASE = TRUE
    WHERE bq.STERILITY_FAIL_FLAG = 1
      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL
           OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE)
)

SELECT
    tr.BATCH_ID,
    fr.PENALTY_RULE_ID,
    fr.CFR_REFERENCE,
    fr.VIOLATION_TYPE,
    fr.VIOLATION_CATEGORY,
    fr.PENALTY_TYPE,
    fr.AUTO_BLOCK_RELEASE,
    fr.MANDATORY_CAPA,
    fr.REGULATORY_HOLD_DAYS,
    fr.RECALL_CLASS,
    fr.BUSINESS_IMPACT,
    -- Midpoint penalty estimate
    ROUND(
        (COALESCE(fr.MIN_PENALTY_USD, 0) + COALESCE(fr.MAX_PENALTY_USD, 0)) / 2.0,
    2)                                  AS ESTIMATED_PENALTY_USD,
    CURRENT_TIMESTAMP()                 AS FEATURE_COMPUTED_AT

FROM triggered_rules tr
JOIN fda_rules fr ON tr.PENALTY_RULE_ID = fr.PENALTY_RULE_ID;


-- =============================================================================
-- FILE: 05b_fix_feat_financial_features.sql
-- PURPOSE: Fix FEAT_FINANCIAL_FEATURES — handles missing / empty
--          RAW_BATCH_FULFILLMENT by falling back to RAW_MATERIAL_ACQUISITION
--          and RAW_CUSTOMER_AGREEMENTS directly.
-- RUN AS: PHARMA_ADMIN  |  WH: COMPUTE_WH
-- =============================================================================
-- =============================================================================
-- FEAT_FINANCIAL_FEATURES  (fixed version)
-- Strategy:
--   Revenue  → RAW_CUSTOMER_AGREEMENTS (agreed_qty × unit_price per product)
--              joined to RAW_BATCH_MASTER via PRODUCT_ID to assign to batches.
--              If RAW_BATCH_FULFILLMENT has rows, use fulfilled_qty instead.
--   Material → SAT_MATERIAL_COST (already loaded from RAW_MATERIAL_ACQUISITION)
--   Penalty  → SAT_AGREEMENT penalty_pct fields × total_value
-- =============================================================================

CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_FINANCIAL_FEATURES AS

WITH

-- ── All batches (anchor) ───────────────────────────────────────────────────
all_batches AS (
    SELECT DISTINCT
        hb.BATCH_ID,
        hb.HK_BATCH
    FROM SILVER_TEST.HUB_BATCH hb
),

-- ── Check if RAW_BATCH_FULFILLMENT has any usable rows ────────────────────
-- We join it optionally; if empty the COALESCE falls through to agreement-based revenue.

fulfillment_revenue AS (
    SELECT
        rbf.BATCH_ID,
        SUM(
            COALESCE(rbf.FULFILLED_QTY, 0) *
            COALESCE(rca.UNIT_PRICE, 0)
        )                                       AS FULFILLED_REVENUE,
        SUM(
            COALESCE(rbf.DELAY_DAYS, 0) *
            COALESCE(rca.PENALTY_PCT_PER_DAY, 0) / 100.0 *
            COALESCE(rca.TOTAL_VALUE, 0)
        )                                       AS FULFILLMENT_PENALTY
    FROM RAW.RAW_BATCH_FULFILLMENT rbf
    LEFT JOIN RAW.RAW_CUSTOMER_AGREEMENTS rca
        ON rbf.AGREEMENT_ID = rca.AGREEMENT_ID
    WHERE rbf.BATCH_ID IS NOT NULL
      AND rbf.BATCH_ID <> 'NO_BATCH_AVAILABLE'
    GROUP BY rbf.BATCH_ID
),

-- ── Agreement-based revenue (fallback when no fulfillment rows exist) ─────
-- Map agreements to batches via shared PRODUCT_ID.
-- One batch can serve multiple agreements for the same product;
-- we distribute the agreement value proportionally across batches
-- that manufacture that product (simplest defensible approximation).

product_batch_counts AS (
    SELECT
        rbm.PRODUCT_ID,
        COUNT(DISTINCT rbm.BATCH_ID) AS BATCH_COUNT
    FROM RAW.RAW_BATCH_MASTER rbm
    WHERE rbm.PRODUCT_ID IS NOT NULL
    GROUP BY rbm.PRODUCT_ID
),

agreement_revenue AS (
    SELECT
        rbm.BATCH_ID,
        SUM(
            -- Distribute agreement value across all batches for this product
            COALESCE(rca.TOTAL_VALUE, 0) /
            NULLIF(pbc.BATCH_COUNT, 0)
        )                                       AS AGR_COMMITTED_REVENUE,
        SUM(
            -- Max penalty per agreement, distributed across batches
            COALESCE(rca.TOTAL_VALUE, 0) *
            COALESCE(rca.MAX_PENALTY_PCT, 0) / 100.0 /
            NULLIF(pbc.BATCH_COUNT, 0)
        )                                       AS AGR_PENALTY_EXPOSURE
    FROM RAW.RAW_BATCH_MASTER rbm
    JOIN RAW.RAW_CUSTOMER_AGREEMENTS rca
        ON rbm.PRODUCT_ID = rca.PRODUCT_ID
       AND UPPER(rca.STATUS) NOT IN ('CANCELLED', 'EXPIRED')
    JOIN product_batch_counts pbc
        ON rbm.PRODUCT_ID = pbc.PRODUCT_ID
    GROUP BY rbm.BATCH_ID
),

-- ── Material cost from Silver SAT_MATERIAL_COST ───────────────────────────
material_cost AS (
    SELECT
        hb.BATCH_ID,
        hb.HK_BATCH,
        SUM(COALESCE(smc.TOTAL_MATERIAL_COST, 0)) AS TOTAL_MATERIAL_COST
    FROM SILVER_TEST.HUB_BATCH hb
    JOIN SILVER_TEST.SAT_MATERIAL_COST smc
        ON hb.HK_BATCH = smc.HK_BATCH
    GROUP BY hb.BATCH_ID, hb.HK_BATCH
),

-- ── Combine revenue sources: prefer fulfillment if available ──────────────
combined AS (
    SELECT
        ab.BATCH_ID,
        ab.HK_BATCH,

        -- Use fulfilled revenue if fulfillment data exists, else agreement-based
        COALESCE(
            NULLIF(fr.FULFILLED_REVENUE, 0),
            ar.AGR_COMMITTED_REVENUE,
            0
        )                                       AS TOTAL_COMMITTED_REVENUE,

        -- Material cost
        COALESCE(mc.TOTAL_MATERIAL_COST, 0)     AS TOTAL_MATERIAL_COST,

        -- Penalty: use fulfillment penalty if available, else agreement max exposure
        COALESCE(
            NULLIF(fr.FULFILLMENT_PENALTY, 0),
            ar.AGR_PENALTY_EXPOSURE,
            0
        )                                       AS TOTAL_PENALTY_EXPOSURE

    FROM all_batches ab
    LEFT JOIN fulfillment_revenue fr  ON ab.BATCH_ID = fr.BATCH_ID
    LEFT JOIN agreement_revenue   ar  ON ab.BATCH_ID = ar.BATCH_ID
    LEFT JOIN material_cost       mc  ON ab.BATCH_ID = mc.BATCH_ID
)

-- ── Final select with derived financial metrics ───────────────────────────
SELECT
    c.BATCH_ID,

    ROUND(c.TOTAL_COMMITTED_REVENUE, 2)         AS TOTAL_COMMITTED_REVENUE,
    ROUND(c.TOTAL_MATERIAL_COST,     2)         AS TOTAL_MATERIAL_COST,

    -- Gross margin = revenue - material cost
    ROUND(
        c.TOTAL_COMMITTED_REVENUE - c.TOTAL_MATERIAL_COST,
    2)                                          AS GROSS_MARGIN,

    -- Gross margin %
    ROUND(
        CASE
            WHEN c.TOTAL_COMMITTED_REVENUE > 0
            THEN (c.TOTAL_COMMITTED_REVENUE - c.TOTAL_MATERIAL_COST)
                 / c.TOTAL_COMMITTED_REVENUE * 100.0
            ELSE 0
        END,
    2)                                          AS GROSS_MARGIN_PCT,

    ROUND(c.TOTAL_PENALTY_EXPOSURE,  2)         AS TOTAL_PENALTY_EXPOSURE,

    -- Cost per unit (material cost / revenue)
    ROUND(
        CASE
            WHEN c.TOTAL_COMMITTED_REVENUE > 0
            THEN c.TOTAL_MATERIAL_COST / c.TOTAL_COMMITTED_REVENUE
            ELSE 0
        END,
    4)                                          AS COST_PER_BATCH_UNIT,

    -- Penalty to revenue ratio
    ROUND(
        CASE
            WHEN c.TOTAL_COMMITTED_REVENUE > 0
            THEN c.TOTAL_PENALTY_EXPOSURE / c.TOTAL_COMMITTED_REVENUE
            ELSE 0
        END,
    4)                                          AS PENALTY_TO_REVENUE_RATIO,

    CURRENT_TIMESTAMP()                         AS FEATURE_COMPUTED_AT

FROM combined c;


-- =============================================================================
-- ALSO FIX: FEAT_ML_ENHANCED — ON_TIME_RATE_PCT will be 0 if no fulfillment.
-- This recreates it safely so the gold layer LEFT JOIN never breaks.
-- =============================================================================

CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_ML_ENHANCED AS

WITH

batch_time AS (
    SELECT
        BATCH_ID,
        START_TIME,
        HOUR(START_TIME)                            AS BATCH_START_HOUR,
        DAYOFWEEK(START_TIME)                       AS BATCH_START_DOW,
        CASE WHEN DAYOFWEEK(START_TIME) IN (6, 7)
             THEN 1 ELSE 0 END                      AS IS_WEEKEND_BATCH,
        CASE WHEN HOUR(START_TIME) >= 22
               OR HOUR(START_TIME) < 6
             THEN 1 ELSE 0 END                      AS IS_NIGHT_SHIFT
    FROM RAW.RAW_BATCH_MASTER
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY BATCH_ID ORDER BY _RAW_LOAD_TS DESC
    ) = 1
),

-- Delivery metrics: try fulfillment table, default to 0 if empty
fulfillment_metrics AS (
    SELECT
        rbf.BATCH_ID,
        COUNT(*)                                                            AS TOTAL_DELIVERIES,
        SUM(CASE WHEN UPPER(COALESCE(rbf.DELIVERY_STATUS,'')) IN
                      ('ON_TIME','DELIVERED','ON TIME') THEN 1 ELSE 0 END) AS ON_TIME_COUNT,
        SUM(CASE WHEN UPPER(COALESCE(rbf.DELIVERY_STATUS,'')) LIKE '%DELAY%'
                 THEN 1 ELSE 0 END)                                         AS DELAYED_DELIVERIES,
        SUM(CASE WHEN UPPER(COALESCE(rbf.DELIVERY_STATUS,'')) IN
                      ('FAILED','REJECTED','NOT_DELIVERED') THEN 1 ELSE 0 END) AS FAILED_DELIVERIES
    FROM RAW.RAW_BATCH_FULFILLMENT rbf
    WHERE rbf.BATCH_ID IS NOT NULL
      AND rbf.BATCH_ID <> 'NO_BATCH_AVAILABLE'
    GROUP BY rbf.BATCH_ID
)

SELECT
    mi.BATCH_ID,
    bt.BATCH_START_HOUR,
    bt.BATCH_START_DOW,
    bt.IS_WEEKEND_BATCH,
    bt.IS_NIGHT_SHIFT,

    -- Delivery metrics (0 if no fulfillment data — gold LEFT JOINs this)
    COALESCE(fm.TOTAL_DELIVERIES,   0)          AS TOTAL_DELIVERIES,
    COALESCE(fm.DELAYED_DELIVERIES, 0)          AS DELAYED_DELIVERIES,
    COALESCE(fm.FAILED_DELIVERIES,  0)          AS FAILED_DELIVERIES,

    ROUND(
        COALESCE(fm.ON_TIME_COUNT, 0) /
        NULLIF(COALESCE(fm.TOTAL_DELIVERIES, 0), 0) * 100.0,
    2)                                          AS ON_TIME_RATE_PCT,

    CURRENT_TIMESTAMP()                         AS FEATURE_COMPUTED_AT

FROM FEATURE_TEST.FEAT_ML_INPUT mi
LEFT JOIN batch_time          bt ON mi.BATCH_ID = bt.BATCH_ID
LEFT JOIN fulfillment_metrics fm ON mi.BATCH_ID = fm.BATCH_ID;