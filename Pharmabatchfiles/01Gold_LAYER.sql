-- ═══════════════════════════════════════════════════════════════════════════════
-- PHARMA COPILOT — GOLD LAYER SQL
-- File: 02_gold_layer.sql
--
-- ARCHITECTURE:
--   LAYER 1 → ML prediction (failure probability from XGBoost UDF)
--   LAYER 2 → FDA rule engine override (auto-block, sterility, critical violations)
--   LAYER 3 → Financial impact calculation (revenue, cost, penalty, profit)
--   LAYER 4 → Gold views consumed by Streamlit
--
-- Run order:
--   1. gold_v2.BATCH_FACT           (core gold table)
--   2. gold_v2.VW_UI_BATCH_LIST     (list view for dashboard sidebar)
--   3. gold_v2.VW_UI_KPI            (KPI strip view)
--
-- Prerequisites:
--   FEATURE_TEST.FEAT_ML_INPUT          populated
--   FEATURE_TEST.FEAT_FINANCIAL_FEATURES populated
--   FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS populated
--   FEATURE_TEST.PREDICT_BATCH_FAILURE_PROB UDF registered (01_ml_training.py)
-- ═══════════════════════════════════════════════════════════════════════════════
-- create schema gold_v2;
create schema if not exists gold_v2;
-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 — ML PREDICTIONS TABLE
--   Run the XGBoost UDF over every batch in FEAT_ML_INPUT.
--   Stores raw ML probability + derived ML decision BEFORE rule overrides.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE gold_v2.ML_PREDICTIONS AS

WITH ml_base AS (
    SELECT
        mi.BATCH_ID,
        sb.BATCH_STATUS,
        ML_CODE.PREDICT_BATCH_FAILURE_PROB(
            mi.PRODUCT_TYPE,
            mi.PLANT_ID,
            sb.BATCH_STATUS,
            mi.BATCH_SIZE_BUCKET,
            mi.DURATION_BUCKET,
            mi.TOTAL_TESTS,
            mi.FAILED_TESTS,
            mi.OOS_COUNT,
            mi.BORDERLINE_COUNT,
            mi.PASS_RATE_PCT,
            mi.OOS_RATE_PCT,
            mi.FAIL_RATE_PCT,
            mi.STERILITY_FAIL_FLAG,
            mi.ENDOTOXIN_FAIL_FLAG,
            mi.STERILITY_X_ENDOTOXIN,
            mi.TEMP_VIOLATION_COUNT,
            mi.TEMP_MAX_EXCURSION_MINS,
            mi.AVG_TEMP_DEVIATION_C,
            mi.HUMIDITY_VIOLATION_COUNT,
            mi.PRESSURE_VIOLATION_COUNT,
            mi.TOTAL_IOT_VIOLATIONS,
            mi.IOT_VIOLATION_DENSITY,
            mi.TEMP_X_DURATION,
            mi.TOTAL_DEVIATIONS,
            mi.CRITICAL_DEVIATION_COUNT,
            mi.HIGH_DEVIATION_COUNT,
            mi.WEIGHTED_DEVIATION_SCORE,
            mi.PROCESS_DEVIATION_COUNT,
            mi.EQUIPMENT_DEVIATION_COUNT,
            mi.HUMAN_DEVIATION_COUNT,
            mi.DEVIATION_DENSITY,
            mi.CRITICAL_DEV_RATE,
            mi.TEMP_X_CRITICAL_DEV,
            mi.BATCH_SIZE,
            mi.BATCH_DURATION_HOURS,
            mi.PROCESS_VARIANCE,
            mi.BATCH_START_HOUR,
            mi.BATCH_START_DOW,
            mi.IS_WEEKEND_BATCH,
            mi.IS_NIGHT_SHIFT
        ) AS ML_FAILURE_PROB
    FROM FEATURE_TEST.FEAT_ML_INPUT mi
    JOIN SILVER_TEST.HUB_BATCH hb ON mi.BATCH_ID = hb.BATCH_ID
    JOIN SILVER_TEST.SAT_BATCH sb ON hb.HK_BATCH = sb.HK_BATCH
)

SELECT
    BATCH_ID,
    CURRENT_TIMESTAMP()                              AS PREDICTION_TS,
    ML_FAILURE_PROB,
    1.0 - ML_FAILURE_PROB                            AS ML_RELEASE_SCORE,
    CASE
        WHEN ML_FAILURE_PROB <= 0.20 THEN 'RELEASE'
        WHEN ML_FAILURE_PROB <= 0.40 THEN 'RETEST'
        WHEN ML_FAILURE_PROB <= 0.65 THEN 'HOLD'
        ELSE 'REJECT'
    END                                              AS ML_PREDICTED_ACTION

FROM ml_base;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 — FDA RULE ENGINE SUMMARY
--   Aggregates per-batch rule violations into override flags and penalty total.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE gold_v2.RULE_ENGINE_OVERRIDES AS

SELECT
    fv.BATCH_ID,

    -- ── Override flags ─────────────────────────────────────────────────────
    MAX(CASE WHEN fv.AUTO_BLOCK_RELEASE THEN 1 ELSE 0 END)       AS HAS_AUTO_BLOCK_RULE,
    MAX(CASE WHEN fv.MANDATORY_CAPA THEN 1 ELSE 0 END)           AS HAS_MANDATORY_CAPA,
    MAX(COALESCE(fv.REGULATORY_HOLD_DAYS, 0))                    AS MAX_HOLD_DAYS,
    COUNT(*)                                                      AS FDA_VIOLATION_COUNT,
    COUNT(CASE WHEN fv.VIOLATION_CATEGORY = 'CRITICAL' THEN 1 END) AS FDA_CRITICAL_VIOLATIONS,
    COUNT(CASE WHEN fv.VIOLATION_CATEGORY = 'MAJOR'    THEN 1 END) AS FDA_MAJOR_VIOLATIONS,

    -- ── Aggregated penalty from all triggered rules ────────────────────────
    SUM(COALESCE(fv.ESTIMATED_PENALTY_USD, 0))                   AS TOTAL_ESTIMATED_PENALTY_USD,

    -- ── Worst CFR reference ────────────────────────────────────────────────
    MAX(CASE WHEN fv.VIOLATION_CATEGORY = 'CRITICAL' THEN fv.CFR_REFERENCE END)
                                                                  AS CRITICAL_CFR_REFERENCE,
    -- ── Critical rate ─────────────────────────────────────────────────────
    ROUND(
        COUNT(CASE WHEN fv.VIOLATION_CATEGORY = 'CRITICAL' THEN 1 END)
        / NULLIF(COUNT(*), 0),
    4)                                                            AS FDA_CRITICAL_RATE

FROM FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS fv
GROUP BY fv.BATCH_ID;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 — BATCH_FACT  (Core Gold Table)
--   Combines: FEAT_ML_INPUT · ML_PREDICTIONS · RULE_ENGINE_OVERRIDES
--             · FEAT_FINANCIAL_FEATURES · raw batch metadata
--
-- FINAL DECISION LOGIC:
--   Rule engine always wins over ML when a hard trigger is met.
--   Override priority (highest first):
--     1. STERILITY FAIL + ENDOTOXIN → hard REJECT
--     2. AUTO_BLOCK_RELEASE rule → REJECT
--     3. CRITICAL FDA violations ≥ 3 → REJECT
--     4. HOLD days > 0 && ML says RELEASE → downgrade to HOLD
--     5. Otherwise → trust ML predicted action
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE gold_v2.BATCH_FACT AS

WITH

-- pull latest batch metadata from source
batch_meta AS (
    SELECT
        rbm.BATCH_ID,
        rbm.PRODUCT_ID,
        rbm.BATCH_SIZE,
        rbm.PLANNED_RELEASE_DATE                                      AS BATCH_DATE,
        rbm.BATCH_STATUS,

        -- product name via HUB/SAT join
        COALESCE(sp.PRODUCT_NAME, rbm.PRODUCT_ID)                  AS PRODUCT_NAME,
        sp.PRODUCT_TYPE,
        CASE
            WHEN sp.PRODUCT_TYPE ILIKE '%Oral%'      THEN 'Tablet'
            WHEN sp.PRODUCT_TYPE ILIKE '%Injection%'  THEN 'Injectable'
            WHEN sp.PRODUCT_TYPE ILIKE '%Vaccine%'    THEN 'Vaccine'
            WHEN sp.PRODUCT_TYPE ILIKE '%Topical%'    THEN 'Topical'
            WHEN sp.PRODUCT_TYPE ILIKE '%Biologic%'   THEN 'Biologic'
            ELSE 'Other'
        END                                                         AS DOSAGE_FORM,
        NULL                                                        AS THERAPEUTIC_AREA,
        rbm.PLANT_ID

    FROM RAW.RAW_BATCH_MASTER rbm
    LEFT JOIN SILVER_TEST.HUB_PRODUCT hp  ON rbm.PRODUCT_ID = hp.PRODUCT_ID
    LEFT JOIN SILVER_TEST.SAT_PRODUCT sp  ON hp.HK_PRODUCT  = sp.HK_PRODUCT
    QUALIFY ROW_NUMBER() OVER (PARTITION BY rbm.BATCH_ID ORDER BY rbm._RAW_LOAD_TS DESC) = 1
),

-- deviation top-3 names from deviation satellite
top_deviations AS (
    SELECT
        hb.BATCH_ID,
        sd.DEVIATION_TYPE AS DEVIATION_DESCRIPTION,
        ROW_NUMBER() OVER (
            PARTITION BY hb.BATCH_ID
            ORDER BY
                CASE sd.DEVIATION_TYPE
                    WHEN 'CRITICAL'   THEN 1
                    WHEN 'HIGH'       THEN 2
                    WHEN 'MAJOR'      THEN 3
                    ELSE 4
                END,
                sd.LOAD_DATE DESC
        ) AS DEV_RANK
    FROM SILVER_TEST.HUB_BATCH hb
    JOIN SILVER_TEST.LNK_BATCH_DEVIATION lbd ON hb.HK_BATCH = lbd.HK_BATCH
    JOIN SILVER_TEST.SAT_DEVIATION sd ON lbd.HK_DEVIATION = sd.HK_DEVIATION
    QUALIFY DEV_RANK <= 3
),

dev_pivot AS (
    SELECT
        BATCH_ID,
        MAX(CASE WHEN DEV_RANK = 1 THEN DEVIATION_DESCRIPTION END) AS DEVIATION_1_NAME,
        MAX(CASE WHEN DEV_RANK = 2 THEN DEVIATION_DESCRIPTION END) AS DEVIATION_2_NAME,
        MAX(CASE WHEN DEV_RANK = 3 THEN DEVIATION_DESCRIPTION END) AS DEVIATION_3_NAME
    FROM top_deviations
    GROUP BY BATCH_ID
),

-- top 3 risk factors from quality features
risk_tags AS (
    SELECT
        q.BATCH_ID,
        CASE WHEN q.STERILITY_FAIL_FLAG = 1
             THEN '🧫 Sterility Failure (21 CFR 211.113)'
             WHEN q.TEMP_VIOLATION_COUNT >= 5
             THEN '🌡️ Temperature Excursions (21 CFR 211.68)'
             WHEN q.CRITICAL_DEVIATION_COUNT >= 2
             THEN '⚠️ Critical Deviations (ICH Q9)'
             WHEN q.OOS_COUNT >= 3
             THEN '🔬 OOS Results (21 CFR 211.192)'
             WHEN q.PASS_RATE_PCT <= 80
             THEN '📉 High Failure Rate (21 CFR 211.165)'
             ELSE '📋 Process Non-Conformance'
        END                 AS TOP_RISK_FACTOR_1,
        CASE WHEN q.HUMIDITY_VIOLATION_COUNT >= 3
             THEN '💧 Humidity Violations (21 CFR 211.68)'
             WHEN q.HIGH_DEVIATION_COUNT >= 3
             THEN '📌 High Deviations (ICH Q10)'
             WHEN q.PROCESS_VARIANCE >= 0.3
             THEN '🔧 High Process Variance'
             WHEN q.ENDOTOXIN_FAIL_FLAG = 1
             THEN '🧪 Endotoxin Failure (USP <85>)'
             ELSE '📊 Borderline Quality Readings'
        END                 AS TOP_RISK_FACTOR_2,
        CASE WHEN q.PRESSURE_VIOLATION_COUNT >= 2
             THEN '🌀 Pressure Violations (21 CFR 211.68)'
             WHEN q.EQUIPMENT_DEVIATION_COUNT >= 2
             THEN '⚙️ Equipment Deviations (21 CFR 211.68)'
             WHEN q.HUMAN_DEVIATION_COUNT >= 2
             THEN '👤 Human Error Deviations (21 CFR 211.68)'
             WHEN q.BORDERLINE_COUNT >= 5
             THEN '📋 Multiple Borderline Results'
             ELSE '🔍 Process Monitoring Required'
        END                 AS TOP_RISK_FACTOR_3
    FROM FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES q
),

-- AI decision reason (rule-based text, no LLM needed at table load time)
ai_reason AS (
    SELECT
        ml.BATCH_ID,
        CASE
            WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1
                THEN 'MANDATORY REJECT: Sterility and endotoxin failures detected. ' ||
                     '21 CFR 211.113 requires immediate batch rejection. CAPA and ' ||
                     'full investigation mandatory before any future release.'
            WHEN ro.HAS_AUTO_BLOCK_RULE = 1
                THEN 'RULE OVERRIDE: FDA auto-block rule triggered (' ||
                     COALESCE(ro.CRITICAL_CFR_REFERENCE, 'see violation log') ||
                     '). ML predicted ' || ml.ML_PREDICTED_ACTION ||
                     ' but regulatory rule mandates REJECT.'
            WHEN ro.FDA_CRITICAL_VIOLATIONS >= 3
                THEN 'HIGH REGULATORY RISK: ' || ro.FDA_CRITICAL_VIOLATIONS::VARCHAR ||
                     ' critical FDA violations detected. Batch escalated from ML ' ||
                     'prediction of ' || ml.ML_PREDICTED_ACTION || ' to REJECT. ' ||
                     'Root cause analysis required under ICH Q9.'
            WHEN ml.ML_FAILURE_PROB <= 0.20
                THEN 'RELEASE RECOMMENDED: XGBoost model assigns ' ||
                     ROUND(ml.ML_FAILURE_PROB * 100, 1)::VARCHAR ||
                     '% failure probability. All quality parameters within acceptable ' ||
                     'ranges. No FDA violations that override release.'
            WHEN ml.ML_FAILURE_PROB <= 0.40
                THEN 'RETEST RECOMMENDED: Failure probability of ' ||
                     ROUND(ml.ML_FAILURE_PROB * 100, 1)::VARCHAR ||
                     '% is borderline. Additional testing recommended before final ' ||
                     'release decision. Review critical parameters identified by ML.'
            WHEN ml.ML_FAILURE_PROB <= 0.65
                THEN 'HOLD RECOMMENDED: ' || ROUND(ml.ML_FAILURE_PROB * 100, 1)::VARCHAR ||
                     '% failure probability indicates significant quality concerns. ' ||
                     'Batch held pending full QA investigation per ICH Q10.'
            ELSE
                'REJECT RECOMMENDED: XGBoost model assigns ' ||
                ROUND(ml.ML_FAILURE_PROB * 100, 1)::VARCHAR ||
                '% failure probability — exceeds 65% rejection threshold. ' ||
                'Multiple quality signals indicate batch does not meet release criteria. ' ||
                'File deviation report and initiate CAPA per ICH Q9.'
        END AS AI_DECISION_REASON
    FROM gold_v2.ML_PREDICTIONS ml
    JOIN FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES qi ON ml.BATCH_ID = qi.BATCH_ID
    LEFT JOIN gold_v2.RULE_ENGINE_OVERRIDES ro     ON ml.BATCH_ID = ro.BATCH_ID
),

-- financial impact by decision scenario
financial_impact AS (
    SELECT
        ff.BATCH_ID,
        ff.TOTAL_COMMITTED_REVENUE,
        ff.TOTAL_MATERIAL_COST,
        ff.GROSS_MARGIN,
        ff.GROSS_MARGIN_PCT,
        ff.TOTAL_PENALTY_EXPOSURE,
        me.ON_TIME_RATE_PCT,
        me.DELAYED_DELIVERIES,
        me.FAILED_DELIVERIES,

        -- Financial risk score (0-1): higher = worse
        ROUND(
            CASE
                WHEN ff.TOTAL_COMMITTED_REVENUE > 0
                THEN LEAST(
                    (ff.TOTAL_PENALTY_EXPOSURE / ff.TOTAL_COMMITTED_REVENUE) * 0.6
                    + (1 - COALESCE(me.ON_TIME_RATE_PCT, 100) / 100.0) * 0.4,
                    1.0
                )
                ELSE 0.5
            END,
        4) AS FINANCIAL_RISK_SCORE,

        -- Cost per unit
        CASE WHEN ff.TOTAL_COMMITTED_REVENUE > 0
            THEN ROUND(ff.TOTAL_MATERIAL_COST / ff.TOTAL_COMMITTED_REVENUE, 4)
            ELSE 0
        END AS COST_PER_BATCH_UNIT,

        -- Penalty to revenue ratio
        CASE WHEN ff.TOTAL_COMMITTED_REVENUE > 0
            THEN ROUND(ff.TOTAL_PENALTY_EXPOSURE / ff.TOTAL_COMMITTED_REVENUE, 4)
            ELSE 0
        END AS PENALTY_TO_REVENUE_RATIO,

        -- Overall risk score blending ML + financial
        NULL AS OVERALL_RISK_SCORE -- populated in final select below

    FROM FEATURE_TEST.FEAT_FINANCIAL_FEATURES ff
    LEFT JOIN FEATURE_TEST.FEAT_ML_ENHANCED me ON ff.BATCH_ID = me.BATCH_ID
)

-- ── FINAL BATCH_FACT SELECT ──────────────────────────────────────────────────
SELECT
    bm.BATCH_ID,
    bm.PRODUCT_NAME,
    bm.PRODUCT_TYPE,
    bm.DOSAGE_FORM,
    bm.THERAPEUTIC_AREA,
    bm.PLANT_ID,
    bm.BATCH_SIZE,
    bm.BATCH_DATE,
    bm.BATCH_STATUS,

    -- ── ML outputs ────────────────────────────────────────────────────────
    ml.ML_FAILURE_PROB                              AS FAILURE_PROBABILITY,
    ml.ML_RELEASE_SCORE                             AS RELEASE_SCORE,
    ml.ML_PREDICTED_ACTION,

    -- ── FDA rule engine ───────────────────────────────────────────────────
    COALESCE(ro.HAS_AUTO_BLOCK_RULE,        0)      AS HAS_AUTO_BLOCK_RULE,
    COALESCE(ro.FDA_VIOLATION_COUNT,        0)      AS FDA_VIOLATION_COUNT,
    COALESCE(ro.FDA_CRITICAL_VIOLATIONS,    0)      AS FDA_CRITICAL_VIOLATIONS,
    COALESCE(ro.FDA_MAJOR_VIOLATIONS,       0)      AS FDA_MAJOR_VIOLATIONS,
    COALESCE(ro.TOTAL_ESTIMATED_PENALTY_USD,0)      AS TOTAL_ESTIMATED_PENALTY_USD,
    COALESCE(ro.MAX_HOLD_DAYS,              0)      AS REGULATORY_HOLD_DAYS,
    COALESCE(ro.FDA_CRITICAL_RATE,          0)      AS FDA_CRITICAL_RATE,
    ro.CRITICAL_CFR_REFERENCE,

    -- ── FINAL DECISION (ML + rule engine override) ────────────────────────
    CASE
        -- Hard biological safety rules (non-negotiable)
        WHEN qi.STERILITY_FAIL_FLAG = 1
         AND qi.ENDOTOXIN_FAIL_FLAG = 1
            THEN 'REJECT'

        -- FDA auto-block override
        WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1
            THEN 'REJECT'

        -- Too many critical FDA violations → reject regardless of ML
        WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3
            THEN 'REJECT'

        -- Regulatory hold days > 0 but ML says release → downgrade to HOLD
        WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0
         AND ml.ML_PREDICTED_ACTION = 'RELEASE'
            THEN 'HOLD'

        -- Trust ML
        ELSE ml.ML_PREDICTED_ACTION
    END                                             AS FINAL_DECISION,

    -- ── Was there a rule engine override? ─────────────────────────────────
    CASE
        WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'STERILITY_HARD_RULE'
        WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1                   THEN 'FDA_AUTO_BLOCK'
        WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3              THEN 'CRITICAL_VIOLATIONS'
        WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0
         AND ml.ML_PREDICTED_ACTION = 'RELEASE'                         THEN 'HOLD_DAYS_APPLIED'
        ELSE NULL
    END                                             AS RULE_OVERRIDE_REASON,

    -- ── Quality features (for detail panel) ───────────────────────────────
    qi.TOTAL_TESTS,
    qi.FAILED_TESTS                                 AS FAILED_TEST_COUNT,
    qi.OOS_COUNT,
    qi.BORDERLINE_COUNT,
    qi.PASS_RATE_PCT                                AS FE_PASS_RATE_PCT,
    qi.STERILITY_FAIL_FLAG,
    qi.ENDOTOXIN_FAIL_FLAG,
    qi.TEMP_VIOLATION_COUNT,
    qi.HUMIDITY_VIOLATION_COUNT,
    qi.PRESSURE_VIOLATION_COUNT,
    qi.CRITICAL_DEVIATION_COUNT,
    qi.HIGH_DEVIATION_COUNT,
    qi.TOTAL_DEVIATIONS,
    qi.PROCESS_VARIANCE,
    qi.WEIGHTED_DEVIATION_SCORE,
    qi.PROCESS_DEVIATION_COUNT,
    qi.EQUIPMENT_DEVIATION_COUNT,
    qi.HUMAN_DEVIATION_COUNT,
    qi.AVG_TEMP_DEVIATION_C,
    qi.BATCH_DURATION_HOURS,
    me.BATCH_START_HOUR,
    me.BATCH_START_DOW,
    me.IS_WEEKEND_BATCH,
    me.IS_NIGHT_SHIFT,

    -- ── Financial outputs ─────────────────────────────────────────────────
    COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0)         AS TOTAL_COMMITTED_REVENUE,
    COALESCE(fi.TOTAL_MATERIAL_COST,     0)         AS TOTAL_MATERIAL_COST,
    COALESCE(fi.GROSS_MARGIN,            0)         AS GROSS_MARGIN,
    COALESCE(fi.GROSS_MARGIN_PCT,        0)         AS GROSS_MARGIN_PCT,
    COALESCE(fi.TOTAL_PENALTY_EXPOSURE,  0)         AS TOTAL_PENALTY_EXPOSURE,
    COALESCE(fi.ON_TIME_RATE_PCT,        100)       AS ON_TIME_RATE_PCT,
    COALESCE(fi.DELAYED_DELIVERIES,      0)         AS DELAYED_DELIVERIES,
    COALESCE(fi.FAILED_DELIVERIES,       0)         AS FAILED_DELIVERIES,
    COALESCE(fi.FINANCIAL_RISK_SCORE,    0)         AS FINANCIAL_RISK_SCORE,
    COALESCE(fi.COST_PER_BATCH_UNIT,     0)         AS COST_PER_BATCH_UNIT,
    COALESCE(fi.PENALTY_TO_REVENUE_RATIO,0)         AS PENALTY_TO_REVENUE_RATIO,

    -- ── Final P&L by decision ─────────────────────────────────────────────
    --   RELEASE → full revenue realised; penalty applied if delayed
    --   RETEST  → 10% revenue at risk during retest window
    --   HOLD    → 0 revenue (batch frozen); holding cost = material cost
    --   REJECT  → 0 revenue; penalty exposure fully materialises
    CASE
        WHEN (CASE
                WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT'
                WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT'
                WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT'
                WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD'
                ELSE ml.ML_PREDICTED_ACTION
              END) = 'RELEASE'
            THEN ROUND(COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0)
                       - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.1, 2)

        WHEN (CASE
                WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT'
                WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT'
                WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT'
                WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD'
                ELSE ml.ML_PREDICTED_ACTION
              END) = 'RETEST'
            THEN ROUND(COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0) * 0.90
                       - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.3, 2)

        WHEN (CASE
                WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT'
                WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT'
                WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT'
                WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD'
                ELSE ml.ML_PREDICTED_ACTION
              END) = 'HOLD'
            THEN ROUND(0 - COALESCE(fi.TOTAL_MATERIAL_COST, 0) * 0.05, 2)

        ELSE   -- REJECT
            ROUND(0 - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0)
                    - COALESCE(fi.TOTAL_MATERIAL_COST, 0), 2)
    END                                             AS FINAL_REVENUE,

    -- ── Final profit = final_revenue − material_cost (where applicable) ───
    CASE
        WHEN (CASE
                WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT'
                WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT'
                WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT'
                WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD'
                ELSE ml.ML_PREDICTED_ACTION
              END) IN ('RELEASE', 'RETEST')
            THEN ROUND(
                (CASE
                    WHEN (CASE
                            WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT'
                            WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT'
                            WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT'
                            WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD'
                            ELSE ml.ML_PREDICTED_ACTION
                          END) = 'RELEASE'
                        THEN COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0)
                             - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.1
                    ELSE COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0) * 0.90
                         - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.3
                END)
                - COALESCE(fi.TOTAL_MATERIAL_COST, 0),
            2)
        ELSE
            ROUND(0 - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0)
                    - COALESCE(fi.TOTAL_MATERIAL_COST, 0), 2)
    END                                             AS FINAL_PROFIT,

    -- ── Penalty actually applied (0 unless reject/hold) ───────────────────
    CASE
        WHEN (CASE
                WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT'
                WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT'
                WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT'
                WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD'
                ELSE ml.ML_PREDICTED_ACTION
              END) = 'REJECT'
            THEN COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0)
                 + COALESCE(ro.TOTAL_ESTIMATED_PENALTY_USD, 0)
        WHEN (CASE
                WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT'
                WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT'
                WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT'
                WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD'
                ELSE ml.ML_PREDICTED_ACTION
              END) IN ('HOLD', 'RETEST')
            THEN COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.3
        ELSE 0
    END                                             AS PENALTY_APPLIED,

    -- ── Overall risk score (0-1, blends ML + financial) ───────────────────
    ROUND(
        ml.ML_FAILURE_PROB * 0.6
        + COALESCE(fi.FINANCIAL_RISK_SCORE, 0) * 0.4,
    4)                                              AS OVERALL_RISK_SCORE,

    -- ── Deviation names for UI detail panel ───────────────────────────────
    dv.DEVIATION_1_NAME,
    dv.DEVIATION_2_NAME,
    dv.DEVIATION_3_NAME,

    -- ── Risk factor tags ──────────────────────────────────────────────────
    rt.TOP_RISK_FACTOR_1,
    rt.TOP_RISK_FACTOR_2,
    rt.TOP_RISK_FACTOR_3,

    -- ── AI decision reason ────────────────────────────────────────────────
    ar.AI_DECISION_REASON,

    -- ── Audit timestamp ───────────────────────────────────────────────────
    CURRENT_TIMESTAMP()                             AS GOLD_CALC_TS

FROM gold_v2.ML_PREDICTIONS ml

-- batch metadata
JOIN batch_meta bm                                  ON ml.BATCH_ID = bm.BATCH_ID

-- quality features (all flagged columns)
JOIN FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES qi    ON ml.BATCH_ID = qi.BATCH_ID

-- rule engine (left — some batches may have 0 FDA violations)
LEFT JOIN gold_v2.RULE_ENGINE_OVERRIDES ro        ON ml.BATCH_ID = ro.BATCH_ID

-- financial (left — some batches may have 0 agreements)
LEFT JOIN financial_impact fi                        ON ml.BATCH_ID = fi.BATCH_ID

-- ML enhanced features (temporal columns)
LEFT JOIN FEATURE_TEST.FEAT_ML_ENHANCED me           ON ml.BATCH_ID = me.BATCH_ID

-- top 3 deviations
LEFT JOIN dev_pivot dv                              ON ml.BATCH_ID = dv.BATCH_ID

-- risk tags
LEFT JOIN risk_tags rt                              ON ml.BATCH_ID = rt.BATCH_ID

-- AI reason
LEFT JOIN ai_reason ar                              ON ml.BATCH_ID = ar.BATCH_ID;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 — VW_UI_BATCH_LIST  (for dashboard left-panel batch queue)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW gold_v2.VW_UI_BATCH_LIST AS
SELECT
    BATCH_ID,
    PRODUCT_NAME,
    PRODUCT_TYPE,
    PLANT_ID,
    DOSAGE_FORM,
    DATE(BATCH_DATE)        AS BATCH_DATE,
    FINAL_DECISION,
    ML_PREDICTED_ACTION,
    RULE_OVERRIDE_REASON,
    ROUND(FAILURE_PROBABILITY, 4)   AS FAILURE_PROBABILITY,
    ROUND(RELEASE_SCORE, 4)         AS RELEASE_SCORE,
    OVERALL_RISK_SCORE,
    TOP_RISK_FACTOR_1,
    TOTAL_COMMITTED_REVENUE,
    TOTAL_PENALTY_EXPOSURE,
    FINAL_REVENUE,
    FINAL_PROFIT,
    PENALTY_APPLIED
FROM gold_v2.BATCH_FACT
ORDER BY BATCH_DATE DESC, FAILURE_PROBABILITY DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5 — VW_UI_KPI  (for dashboard KPI strip)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW gold_v2.VW_UI_KPI AS
SELECT
    COUNT(*)                                                    AS TOTAL_BATCHES,
    COUNT(CASE WHEN FINAL_DECISION = 'RELEASE' THEN 1 END)     AS RELEASE_READY,
    COUNT(CASE WHEN FINAL_DECISION = 'REJECT'  THEN 1 END)     AS REJECTED,
    COUNT(CASE WHEN FINAL_DECISION = 'HOLD'    THEN 1 END)     AS ON_HOLD,
    COUNT(CASE WHEN FINAL_DECISION = 'RETEST'  THEN 1 END)     AS RETEST_REQUIRED,

    -- ML accuracy proxy: batches where rule engine overrode ML
    COUNT(CASE WHEN RULE_OVERRIDE_REASON IS NOT NULL THEN 1 END) AS ML_OVERRIDES,

    -- Financial KPIs
    ROUND(SUM(TOTAL_COMMITTED_REVENUE), 2)                     AS TOTAL_REVENUE,
    ROUND(SUM(TOTAL_MATERIAL_COST), 2)                         AS TOTAL_MATERIAL_COST,
    ROUND(SUM(FINAL_REVENUE), 2)                               AS NET_REALISED_REVENUE,
    ROUND(SUM(FINAL_PROFIT), 2)                                AS NET_PROFIT,
    ROUND(SUM(PENALTY_APPLIED), 2)                             AS TOTAL_PENALTY,
    ROUND(SUM(TOTAL_PENALTY_EXPOSURE), 2)                      AS TOTAL_PENALTY_EXPOSURE,

    -- Quality KPIs
    ROUND(
        COUNT(CASE WHEN FINAL_DECISION = 'RELEASE' THEN 1 END)
        / NULLIF(COUNT(*), 0) * 100, 1
    )                                                          AS BATCH_PASS_RATE_PCT,
    ROUND(AVG(FAILURE_PROBABILITY) * 100, 1)                   AS AVG_FAILURE_PROBABILITY_PCT,
    ROUND(AVG(RELEASE_SCORE) * 100, 1)                         AS AVG_RELEASE_SCORE_PCT

FROM gold_v2.BATCH_FACT;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6 — VW_UI_SIMULATION_BASE  (for simulation lab — read original features)
--   The simulation page reads this view to get all mutable + fixed parameters
--   for a batch. Streamlit modifies mutable ones, keeps fixed ones untouched.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW gold_v2.VW_UI_SIMULATION_BASE AS
SELECT
    bf.BATCH_ID,
    bf.PRODUCT_NAME,
    bf.PRODUCT_TYPE,
    bf.DOSAGE_FORM,
    bf.PLANT_ID,
    bf.BATCH_SIZE,
    bf.BATCH_DURATION_HOURS,
    bf.BATCH_DATE,

    -- ── ML baseline (original) ────────────────────────────────────────────
    bf.FAILURE_PROBABILITY          AS ORIG_FAILURE_PROB,
    bf.RELEASE_SCORE                AS ORIG_RELEASE_SCORE,
    bf.ML_PREDICTED_ACTION          AS ORIG_ML_DECISION,
    bf.FINAL_DECISION               AS ORIG_FINAL_DECISION,
    bf.RULE_OVERRIDE_REASON,

    -- ── Mutable quality parameters (these change in simulation) ───────────
    bf.TEMP_VIOLATION_COUNT,
    bf.HUMIDITY_VIOLATION_COUNT,
    bf.PRESSURE_VIOLATION_COUNT,
    bf.FAILED_TEST_COUNT,
    bf.OOS_COUNT,
    bf.BORDERLINE_COUNT,
    bf.FE_PASS_RATE_PCT,
    bf.CRITICAL_DEVIATION_COUNT,
    bf.HIGH_DEVIATION_COUNT,
    bf.PROCESS_VARIANCE,

    -- ── Fixed features (held constant during simulation) ──────────────────
    bf.TOTAL_TESTS,
    bf.STERILITY_FAIL_FLAG,
    bf.ENDOTOXIN_FAIL_FLAG,
    bf.PROCESS_DEVIATION_COUNT,
    bf.EQUIPMENT_DEVIATION_COUNT,
    bf.HUMAN_DEVIATION_COUNT,
    bf.BATCH_START_HOUR,
    bf.BATCH_START_DOW,
    bf.IS_WEEKEND_BATCH,
    bf.IS_NIGHT_SHIFT,
    bf.AVG_TEMP_DEVIATION_C,

    -- ── Fixed financial (post-simulation financial recalc uses these) ─────
    bf.TOTAL_COMMITTED_REVENUE,
    bf.TOTAL_MATERIAL_COST,
    bf.GROSS_MARGIN_PCT,
    bf.TOTAL_PENALTY_EXPOSURE,
    bf.PENALTY_TO_REVENUE_RATIO,
    bf.COST_PER_BATCH_UNIT,
    bf.ON_TIME_RATE_PCT,
    bf.DELAYED_DELIVERIES,
    bf.FAILED_DELIVERIES,
    bf.FINANCIAL_RISK_SCORE,

    -- ── Fixed FDA (held constant; simulation can't change regulatory history)
    bf.FDA_VIOLATION_COUNT,
    bf.FDA_CRITICAL_VIOLATIONS,
    bf.FDA_MAJOR_VIOLATIONS,
    bf.TOTAL_ESTIMATED_PENALTY_USD,
    bf.HAS_AUTO_BLOCK_RULE,
    bf.FDA_CRITICAL_RATE,

    -- ── Derived fixed features (UDF needs these; precomputed here) ────────
    mi.BATCH_SIZE_BUCKET,
    mi.DURATION_BUCKET,
    mi.TEMP_MAX_EXCURSION_MINS,
    mi.TOTAL_IOT_VIOLATIONS,
    mi.IOT_VIOLATION_DENSITY,
    mi.TEMP_X_DURATION,
    mi.TOTAL_DEVIATIONS,
    mi.WEIGHTED_DEVIATION_SCORE,
    mi.DEVIATION_DENSITY,
    mi.CRITICAL_DEV_RATE,
    mi.TEMP_X_CRITICAL_DEV,
    mi.STERILITY_X_ENDOTOXIN,
    mi.OOS_RATE_PCT,
    mi.FAIL_RATE_PCT,

    -- ── Financial P&L baseline ────────────────────────────────────────────
    bf.FINAL_REVENUE                AS ORIG_FINAL_REVENUE,
    bf.FINAL_PROFIT                 AS ORIG_FINAL_PROFIT,
    bf.PENALTY_APPLIED              AS ORIG_PENALTY_APPLIED,
    bf.OVERALL_RISK_SCORE,
    -- ── Revenue data quality flag ─────────────────────────────────────────
    CASE
        WHEN COALESCE(bf.TOTAL_COMMITTED_REVENUE, 0) > 0 THEN 'ACTUAL'
        ELSE 'ESTIMATED'
    END                                                AS REVENUE_DATA_QUALITY

FROM gold_v2.BATCH_FACT bf
JOIN FEATURE_TEST.FEAT_ML_INPUT mi ON bf.BATCH_ID = mi.BATCH_ID;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 7 — BATCH_SIMULATION_LOG  (optional: persist simulation runs)
--   Streamlit can INSERT here after each simulation click for audit trail.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS gold_v2.BATCH_SIMULATION_LOG (
    SIM_ID                  VARCHAR(64)     DEFAULT SHA2(UUID_STRING(), 256),
    BATCH_ID                VARCHAR(50),
    SIM_TS                  TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    SIMULATED_BY            VARCHAR(200)    DEFAULT CURRENT_USER(),

    -- Parameter snapshot (mutable inputs used in this run)
    SIM_TEMP_VIOL           INT,
    SIM_HUM_VIOL            INT,
    SIM_PRES_VIOL           INT,
    SIM_FAILED_TEST         INT,
    SIM_OOS                 INT,
    SIM_BORDERLINE          INT,
    SIM_PASS_RATE           FLOAT,
    SIM_CRIT_DEV            INT,
    SIM_HIGH_DEV            INT,
    SIM_PROC_VAR            FLOAT,

    -- ML output
    SIM_FAILURE_PROB        FLOAT,
    SIM_RELEASE_SCORE       FLOAT,
    SIM_ML_DECISION         VARCHAR(20),

    -- Financial recalc
    SIM_FINAL_REVENUE       FLOAT,
    SIM_FINAL_PROFIT        FLOAT,
    SIM_PENALTY_APPLIED     FLOAT,

    -- Delta vs original
    DELTA_FAILURE_PROB_PP   FLOAT,
    DECISION_CHANGED        BOOLEAN,
    ORIG_DECISION           VARCHAR(20),

    NOTES                   VARCHAR(1000)
);


-- ─────────────────────────────────────────────────────────────────────────────
