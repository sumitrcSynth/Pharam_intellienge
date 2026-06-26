CREATE SCHEMA IF NOT EXISTS SILVER_TEST;
-- =====================================================
-- HUBS
-- =====================================================

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_BATCH (
    HK_BATCH VARCHAR,
    BATCH_ID VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_PRODUCT (
    HK_PRODUCT VARCHAR,
    PRODUCT_ID VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_CUSTOMER (
    HK_CUSTOMER VARCHAR,
    CUSTOMER_ID VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_AGREEMENT (
    HK_AGREEMENT VARCHAR,
    AGREEMENT_ID VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_SENSOR (
    HK_SENSOR VARCHAR,
    SENSOR_ID VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_LAB_TEST (
    HK_TEST VARCHAR,
    TEST_ID VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_DEVIATION (
    HK_DEVIATION VARCHAR,
    DEVIATION_ID VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_FDA_RULE (
    HK_FDA_RULE VARCHAR,
    PENALTY_RULE_ID VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

-- =====================================================
-- LINKS
-- =====================================================

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_PRODUCT (
    HK_LNK_BATCH_PRODUCT VARCHAR,
    HK_BATCH VARCHAR,
    HK_PRODUCT VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_CUSTOMER_AGREEMENT (
    HK_LNK_CUST_AGR VARCHAR,
    HK_CUSTOMER VARCHAR,
    HK_AGREEMENT VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_AGREEMENT_PRODUCT (
    HK_LNK_AGR_PROD VARCHAR,
    HK_AGREEMENT VARCHAR,
    HK_PRODUCT VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_AGREEMENT (
    HK_LNK_BATCH_AGR VARCHAR,
    HK_BATCH VARCHAR,
    HK_AGREEMENT VARCHAR,
    HK_PRODUCT VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_SENSOR (
    HK_LNK_BATCH_SENSOR VARCHAR,
    HK_BATCH VARCHAR,
    HK_SENSOR VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_LAB_TEST (
    HK_LNK_BATCH_TEST VARCHAR,
    HK_BATCH VARCHAR,
    HK_TEST VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_DEVIATION (
    HK_LNK_BATCH_DEV VARCHAR,
    HK_BATCH VARCHAR,
    HK_DEVIATION VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_FDA_RULE (
    HK_LNK_BATCH_RULE VARCHAR,
    HK_BATCH VARCHAR,
    HK_FDA_RULE VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR
);

-- =====================================================
-- SATELLITES
-- =====================================================

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_BATCH (
    HK_BATCH VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    PLANT_ID VARCHAR,
    LINE_ID VARCHAR,
    BATCH_SIZE NUMBER(12,3),
    BATCH_SIZE_UNIT VARCHAR,
    START_TIME TIMESTAMP_NTZ,
    END_TIME TIMESTAMP_NTZ,
    PROCESS_STAGE VARCHAR,
    EQUIPMENT_ID VARCHAR,
    BATCH_STATUS VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_PRODUCT (
    HK_PRODUCT VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    PRODUCT_NAME VARCHAR,
    PRODUCT_TYPE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_CUSTOMER (
    HK_CUSTOMER VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    CUSTOMER_NAME VARCHAR,
    CUSTOMER_TYPE VARCHAR,
    REGULATORY_MARKET VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_AGREEMENT (
    HK_AGREEMENT VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    AGREED_QTY NUMBER(18,2),
    UNIT_PRICE FLOAT,
    TOTAL_VALUE FLOAT,
    DELIVERY_DEADLINE DATE,
    PENALTY_PCT_PER_DAY FLOAT,
    MAX_PENALTY_PCT FLOAT,
    STATUS VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_BATCH_FULFILLMENT (
    HK_LNK_BATCH_AGR VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    FULFILLED_QTY FLOAT,
    DELIVERY_STATUS VARCHAR(30),
    DELAY_DAYS NUMBER,
    FULFILLMENT_DATE DATE
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_MATERIAL_COST (
    HK_BATCH VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    MATERIAL_CATEGORY VARCHAR,
    TOTAL_MATERIAL_COST FLOAT,
    COST_PER_UNIT FLOAT
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_FDA_RULE (
    HK_FDA_RULE VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    CFR_REFERENCE VARCHAR,
    VIOLATION_TYPE VARCHAR,
    VIOLATION_CATEGORY VARCHAR,
    APPLICABLE_PRODUCT_TYPE VARCHAR,
    PENALTY_TYPE VARCHAR,
    MIN_PENALTY_USD FLOAT,
    MAX_PENALTY_USD FLOAT,
    RECALL_CLASS VARCHAR,
    BUSINESS_IMPACT VARCHAR,
    AUTO_BLOCK_RELEASE VARCHAR,
    MANDATORY_CAPA VARCHAR,
    REGULATORY_HOLD_DAYS NUMBER,
    EFFECTIVE_DATE DATE,
    IS_ACTIVE VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_SENSOR (
    HK_SENSOR VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    SENSOR_TYPE VARCHAR,
    LOCATION VARCHAR
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_LAB_TEST (
    HK_TEST VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    TEST_NAME VARCHAR,
    TEST_RESULT FLOAT,
    TEST_STATUS VARCHAR,
    SPEC_MIN FLOAT,
    SPEC_MAX FLOAT
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_DEVIATION (
    HK_DEVIATION VARCHAR,
    LOAD_DATE TIMESTAMP_NTZ,
    RECORD_SOURCE VARCHAR,
    DEVIATION_TYPE VARCHAR,
    SEVERITY VARCHAR,
    ROOT_CAUSE VARCHAR,
    STATUS VARCHAR
);

-- =============================================================================
-- SECTION 1 — HUB INSERTS
-- Rule: DISTINCT business keys only, no duplicates
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- HUB_BATCH  ← RAW_BATCH_MASTER
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.HUB_BATCH
(
    HK_BATCH,
    BATCH_ID,
    LOAD_DATE,
    RECORD_SOURCE
)
SELECT
    SHA2(COALESCE(src.BATCH_ID, ''), 256)        AS HK_BATCH,
    src.BATCH_ID,
    src._RAW_LOAD_TS                            AS LOAD_DATE,
    'MES::RAW_BATCH_MASTER'                     AS RECORD_SOURCE
FROM RAW.RAW_BATCH_MASTER src
WHERE src._RAW_LOAD_TS > (
    SELECT COALESCE(MAX(LOAD_DATE), '1900-01-01')
    FROM SILVER_TEST.HUB_BATCH
)
AND NOT EXISTS (
    SELECT 1
    FROM SILVER_TEST.HUB_BATCH tgt
    WHERE tgt.HK_BATCH = SHA2(COALESCE(src.BATCH_ID, ''), 256)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- HUB_PRODUCT  ← RAW_BATCH_MASTER
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.HUB_PRODUCT(HK_PRODUCT, PRODUCT_ID, LOAD_DATE, RECORD_SOURCE)
SELECT DISTINCT
    SHA2(PRODUCT_ID, 256)       AS HK_PRODUCT,
    PRODUCT_ID,
    MIN(_RAW_LOAD_TS)           AS LOAD_DATE,
    'MES::RAW_BATCH_MASTER'     AS RECORD_SOURCE
FROM RAW.RAW_BATCH_MASTER
GROUP BY PRODUCT_ID
HAVING SHA2(PRODUCT_ID, 256) NOT IN (SELECT HK_PRODUCT FROM SILVER_TEST.HUB_PRODUCT);

-- ─────────────────────────────────────────────────────────────────────────────
-- HUB_CUSTOMER  ← RAW_CUSTOMER_AGREEMENTS
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.HUB_CUSTOMER(HK_CUSTOMER, CUSTOMER_ID, LOAD_DATE, RECORD_SOURCE)
SELECT DISTINCT
    SHA2(CUSTOMER_ID, 256)          AS HK_CUSTOMER,
    CUSTOMER_ID,
    MIN(_RAW_LOAD_TS)               AS LOAD_DATE,
    'CRM::RAW_CUSTOMER_AGREEMENTS'  AS RECORD_SOURCE
FROM RAW.RAW_CUSTOMER_AGREEMENTS
GROUP BY CUSTOMER_ID
HAVING SHA2(CUSTOMER_ID, 256) NOT IN (SELECT HK_CUSTOMER FROM SILVER_TEST.HUB_CUSTOMER);

-- ─────────────────────────────────────────────────────────────────────────────
-- HUB_AGREEMENT  ← RAW_CUSTOMER_AGREEMENTS
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.HUB_AGREEMENT
    (HK_AGREEMENT, AGREEMENT_ID, LOAD_DATE, RECORD_SOURCE)
SELECT DISTINCT
    SHA2(AGREEMENT_ID, 256)         AS HK_AGREEMENT,
    AGREEMENT_ID,
    _RAW_LOAD_TS                    AS LOAD_DATE,
    'CRM::RAW_CUSTOMER_AGREEMENTS'  AS RECORD_SOURCE
FROM RAW.RAW_CUSTOMER_AGREEMENTS
WHERE SHA2(AGREEMENT_ID, 256)
      NOT IN (SELECT HK_AGREEMENT FROM SILVER_TEST.HUB_AGREEMENT);

-- ─────────────────────────────────────────────────────────────────────────────
-- HUB_SENSOR  ← RAW_SENSOR_READINGS
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.HUB_SENSOR
    (HK_SENSOR, SENSOR_ID, LOAD_DATE, RECORD_SOURCE)
SELECT DISTINCT
    SHA2(SENSOR_ID, 256)        AS HK_SENSOR,
    SENSOR_ID,
    MIN(_RAW_LOAD_TS)           AS LOAD_DATE,
    'IOT::RAW_SENSOR_READINGS'  AS RECORD_SOURCE
FROM RAW.RAW_SENSOR_READINGS
GROUP BY SENSOR_ID
HAVING SHA2(SENSOR_ID, 256)
       NOT IN (SELECT HK_SENSOR FROM SILVER_TEST.HUB_SENSOR);

-- ─────────────────────────────────────────────────────────────────────────────
-- HUB_LAB_TEST  ← RAW_LAB_TESTS
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.HUB_LAB_TEST
    (HK_TEST, TEST_ID, LOAD_DATE, RECORD_SOURCE)
SELECT DISTINCT
    SHA2(TEST_ID, 256)          AS HK_TEST,
    TEST_ID,
    _RAW_LOAD_TS                AS LOAD_DATE,
    'LIMS::RAW_LAB_TESTS'       AS RECORD_SOURCE
FROM RAW.RAW_LAB_TESTS
WHERE SHA2(TEST_ID, 256)
      NOT IN (SELECT HK_TEST FROM SILVER_TEST.HUB_LAB_TEST);

-- ─────────────────────────────────────────────────────────────────────────────
-- HUB_DEVIATION  ← RAW_DEVIATIONS
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.HUB_DEVIATION
    (HK_DEVIATION, DEVIATION_ID, LOAD_DATE, RECORD_SOURCE)
SELECT DISTINCT
    SHA2(DEVIATION_ID, 256)     AS HK_DEVIATION,
    DEVIATION_ID,
    _RAW_LOAD_TS                AS LOAD_DATE,
    'QA::RAW_DEVIATIONS'        AS RECORD_SOURCE
FROM RAW.RAW_DEVIATIONS
WHERE SHA2(DEVIATION_ID, 256)
      NOT IN (SELECT HK_DEVIATION FROM SILVER_TEST.HUB_DEVIATION);

-- ─────────────────────────────────────────────────────────────────────────────
-- HUB_FDA_RULE  ← RAW_FDA_PENALTIES
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.HUB_FDA_RULE
    (HK_FDA_RULE, PENALTY_RULE_ID, LOAD_DATE, RECORD_SOURCE)
SELECT DISTINCT
    SHA2(PENALTY_RULE_ID, 256)  AS HK_FDA_RULE,
    PENALTY_RULE_ID,
    _RAW_LOAD_TS                AS LOAD_DATE,
    'FDA::RAW_FDA_PENALTIES'    AS RECORD_SOURCE
FROM RAW.RAW_FDA_PENALTIES
WHERE SHA2(PENALTY_RULE_ID, 256)
      NOT IN (SELECT HK_FDA_RULE FROM SILVER_TEST.HUB_FDA_RULE);

-- =============================================================================
-- SECTION 2 — LINK INSERTS
-- Rule: Hash of combined business keys, no duplicates
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- LNK_BATCH_PRODUCT  ← RAW_BATCH_MASTER
-- Each batch manufactures one product
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.LNK_BATCH_PRODUCT
SELECT
    SHA2(src.BATCH_ID || '|' || src.PRODUCT_ID, 256),
    SHA2(src.BATCH_ID, 256),
    SHA2(src.PRODUCT_ID, 256),
    src._RAW_LOAD_TS,
    'MES::RAW_BATCH_MASTER'
FROM RAW.RAW_BATCH_MASTER src
WHERE NOT EXISTS (
    SELECT 1
    FROM SILVER_TEST.LNK_BATCH_PRODUCT tgt
    WHERE tgt.HK_LNK_BATCH_PRODUCT =
          SHA2(src.BATCH_ID || '|' || src.PRODUCT_ID, 256)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- LNK_CUSTOMER_AGREEMENT  ← RAW_CUSTOMER_AGREEMENTS
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.LNK_CUSTOMER_AGREEMENT
SELECT
    SHA2(src.CUSTOMER_ID || '|' || src.AGREEMENT_ID, 256),
    SHA2(src.CUSTOMER_ID, 256),
    SHA2(src.AGREEMENT_ID, 256),
    src._RAW_LOAD_TS,
    'CRM::RAW_CUSTOMER_AGREEMENTS'
FROM RAW.RAW_CUSTOMER_AGREEMENTS src
WHERE NOT EXISTS (
    SELECT 1
    FROM SILVER_TEST.LNK_CUSTOMER_AGREEMENT tgt
    WHERE tgt.HK_LNK_CUST_AGR =
          SHA2(src.CUSTOMER_ID || '|' || src.AGREEMENT_ID, 256)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- LNK_AGREEMENT_PRODUCT  ← RAW_CUSTOMER_AGREEMENTS
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.LNK_AGREEMENT_PRODUCT
SELECT
    SHA2(src.AGREEMENT_ID || '|' || src.PRODUCT_ID, 256),
    SHA2(src.AGREEMENT_ID, 256),
    SHA2(src.PRODUCT_ID, 256),
    src._RAW_LOAD_TS,
    'CRM::RAW_CUSTOMER_AGREEMENTS'
FROM RAW.RAW_CUSTOMER_AGREEMENTS src
WHERE NOT EXISTS (
    SELECT 1
    FROM SILVER_TEST.LNK_AGREEMENT_PRODUCT tgt
    WHERE tgt.HK_LNK_AGR_PROD =
          SHA2(src.AGREEMENT_ID || '|' || src.PRODUCT_ID, 256)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- LNK_BATCH_AGREEMENT  ← RAW_BATCH_FULFILLMENT
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.LNK_BATCH_AGREEMENT
SELECT
    SHA2(src.BATCH_ID || '|' || src.AGREEMENT_ID || '|' || src.PRODUCT_ID, 256),
    SHA2(src.BATCH_ID, 256),
    SHA2(src.AGREEMENT_ID, 256),
    SHA2(src.PRODUCT_ID, 256),
    src._RAW_LOAD_TS,
    'ERP::RAW_BATCH_FULFILLMENT'
FROM RAW.RAW_BATCH_FULFILLMENT src
WHERE src.BATCH_ID <> 'NO_BATCH_AVAILABLE'
AND NOT EXISTS (
    SELECT 1
    FROM SILVER_TEST.LNK_BATCH_AGREEMENT tgt
    WHERE tgt.HK_LNK_BATCH_AGR =
          SHA2(src.BATCH_ID || '|' || src.AGREEMENT_ID || '|' || src.PRODUCT_ID, 256)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- LNK_BATCH_SENSOR  ← RAW_SENSOR_READINGS (AGG REQUIRED)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.LNK_BATCH_SENSOR
SELECT
    SHA2(src.BATCH_ID || '|' || src.SENSOR_ID, 256),
    SHA2(src.BATCH_ID, 256),
    SHA2(src.SENSOR_ID, 256),
    MIN(src._RAW_LOAD_TS),
    'IOT::RAW_SENSOR_READINGS'
FROM RAW.RAW_SENSOR_READINGS src
GROUP BY src.BATCH_ID, src.SENSOR_ID
HAVING NOT EXISTS (
    SELECT 1
    FROM SILVER_TEST.LNK_BATCH_SENSOR tgt
    WHERE tgt.HK_LNK_BATCH_SENSOR =
          SHA2(src.BATCH_ID || '|' || src.SENSOR_ID, 256)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- LNK_BATCH_LAB_TEST  ← RAW_LAB_TESTS
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.LNK_BATCH_LAB_TEST
SELECT
    SHA2(src.BATCH_ID || '|' || src.TEST_ID, 256),
    SHA2(src.BATCH_ID, 256),
    SHA2(src.TEST_ID, 256),
    src._RAW_LOAD_TS,
    'LIMS::RAW_LAB_TESTS'
FROM RAW.RAW_LAB_TESTS src
WHERE NOT EXISTS (
    SELECT 1
    FROM SILVER_TEST.LNK_BATCH_LAB_TEST tgt
    WHERE tgt.HK_LNK_BATCH_TEST =
          SHA2(src.BATCH_ID || '|' || src.TEST_ID, 256)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- LNK_BATCH_DEVIATION  ← RAW_DEVIATIONS
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.LNK_BATCH_DEVIATION
SELECT
    SHA2(src.BATCH_ID || '|' || src.DEVIATION_ID, 256),
    SHA2(src.BATCH_ID, 256),
    SHA2(src.DEVIATION_ID, 256),
    src._RAW_LOAD_TS,
    'QA::RAW_DEVIATIONS'
FROM RAW.RAW_DEVIATIONS src
WHERE NOT EXISTS (
    SELECT 1
    FROM SILVER_TEST.LNK_BATCH_DEVIATION tgt
    WHERE tgt.HK_LNK_BATCH_DEV =
          SHA2(src.BATCH_ID || '|' || src.DEVIATION_ID, 256)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- LNK_BATCH_FDA_RULE  ← RULE ENGINE (lab failures, sensor violations,
-- deviations, endotoxin failures) with active-rule and product-type filtering
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.LNK_BATCH_FDA_RULE

WITH batch_context AS (
    SELECT
        hb.BATCH_ID,
        sp.PRODUCT_TYPE,
        sb.START_TIME,
        sb.END_TIME,
        COALESCE(
            DATEDIFF(HOUR, sb.START_TIME, sb.END_TIME),
            1
        ) AS BATCH_DURATION_HOURS
    FROM SILVER_TEST.HUB_BATCH hb
    JOIN SILVER_TEST.SAT_BATCH sb
        ON hb.HK_BATCH = sb.HK_BATCH
    LEFT JOIN SILVER_TEST.LNK_BATCH_PRODUCT lbp
        ON hb.HK_BATCH = lbp.HK_BATCH
    LEFT JOIN SILVER_TEST.SAT_PRODUCT sp
        ON lbp.HK_PRODUCT = sp.HK_PRODUCT
),

lab_failures AS (
    SELECT
        hb.BATCH_ID,
        COUNT(*) AS FAIL_COUNT
    FROM SILVER_TEST.LNK_BATCH_LAB_TEST l
    JOIN SILVER_TEST.HUB_BATCH hb
        ON l.HK_BATCH = hb.HK_BATCH
    JOIN SILVER_TEST.SAT_LAB_TEST s
        ON l.HK_TEST = s.HK_TEST
    WHERE s.TEST_STATUS IN ('FAIL','OOS')
    GROUP BY hb.BATCH_ID
),

sensor_violations AS (
    SELECT
        hb.BATCH_ID,
        COUNT(*) AS TOTAL_VIOLATIONS,
        COUNT_IF(s.SENSOR_TYPE = 'TEMP')     AS TEMP_VIOLATIONS,
        COUNT_IF(s.SENSOR_TYPE = 'HUMIDITY') AS HUMIDITY_VIOLATIONS,
        COUNT_IF(s.SENSOR_TYPE = 'PRESSURE') AS PRESSURE_VIOLATIONS
    FROM SILVER_TEST.LNK_BATCH_SENSOR l
    JOIN SILVER_TEST.HUB_BATCH hb
        ON l.HK_BATCH = hb.HK_BATCH
    JOIN SILVER_TEST.SAT_SENSOR s
        ON l.HK_SENSOR = s.HK_SENSOR
    WHERE s.SENSOR_TYPE IS NOT NULL
    GROUP BY hb.BATCH_ID
),

deviations AS (
    SELECT
        hb.BATCH_ID,
        COUNT(*) AS TOTAL_DEVIATIONS,
        COUNT_IF(s.SEVERITY = 'Critical') AS CRITICAL_DEVIATIONS,
        SUM(
            CASE
                WHEN s.SEVERITY = 'Critical' THEN 3
                WHEN s.SEVERITY = 'High'     THEN 2
                ELSE 1
            END
        ) AS WEIGHTED_DEVIATION_SCORE
    FROM SILVER_TEST.LNK_BATCH_DEVIATION l
    JOIN SILVER_TEST.HUB_BATCH hb
        ON l.HK_BATCH = hb.HK_BATCH
    JOIN SILVER_TEST.SAT_DEVIATION s
        ON l.HK_DEVIATION = s.HK_DEVIATION
    GROUP BY hb.BATCH_ID
),

endotoxin AS (
    SELECT
        hb.BATCH_ID,
        COUNT(*) AS ENDO_FAIL_COUNT
    FROM SILVER_TEST.LNK_BATCH_LAB_TEST l
    JOIN SILVER_TEST.HUB_BATCH hb
        ON l.HK_BATCH = hb.HK_BATCH
    JOIN SILVER_TEST.SAT_LAB_TEST s
        ON l.HK_TEST = s.HK_TEST
    WHERE s.TEST_NAME = 'Endotoxin Test'
      AND s.TEST_STATUS IN ('FAIL','OOS')
    GROUP BY hb.BATCH_ID
),

batch_violations AS (

    -- LAB FAILURE (normalized)
    SELECT
        bc.BATCH_ID,
        'FDA-PEN-001' AS PENALTY_RULE_ID
    FROM batch_context bc
    JOIN lab_failures lf
        ON bc.BATCH_ID = lf.BATCH_ID
    WHERE lf.FAIL_COUNT >= 2

    UNION

    -- SENSOR VIOLATION (normalized by duration)
    SELECT
        bc.BATCH_ID,
        'FDA-PEN-002'
    FROM batch_context bc
    JOIN sensor_violations sv
        ON bc.BATCH_ID = sv.BATCH_ID
    WHERE (sv.TOTAL_VIOLATIONS / NULLIF(bc.BATCH_DURATION_HOURS,1)) >= 2

    UNION

    -- CRITICAL DEVIATION
    SELECT
        BATCH_ID,
        'FDA-PEN-003'
    FROM deviations
    WHERE CRITICAL_DEVIATIONS >= 1

    UNION

    -- GENERAL DEVIATION (controlled)
    SELECT
        BATCH_ID,
        'FDA-PEN-005'
    FROM deviations
    WHERE TOTAL_DEVIATIONS >= 5

    UNION

    -- ENDOTOXIN FAILURE (explicit threshold)
    SELECT
        BATCH_ID,
        'FDA-PEN-009'
    FROM endotoxin
    WHERE ENDO_FAIL_COUNT >= 1
)

SELECT
    SHA2(bv.BATCH_ID || '|' || bv.PENALTY_RULE_ID, 256) AS HK_LNK_BATCH_RULE,
    SHA2(bv.BATCH_ID, 256)                             AS HK_BATCH,
    SHA2(bv.PENALTY_RULE_ID, 256)                      AS HK_FDA_RULE,
    CURRENT_TIMESTAMP()                                AS LOAD_DATE,
    'RULES_ENGINE::FINAL_V2'                           AS RECORD_SOURCE
FROM batch_violations bv

JOIN SILVER_TEST.HUB_FDA_RULE hfr
    ON SHA2(bv.PENALTY_RULE_ID,256) = hfr.HK_FDA_RULE

JOIN SILVER_TEST.SAT_FDA_RULE sfr
    ON hfr.HK_FDA_RULE = sfr.HK_FDA_RULE

JOIN batch_context bc
    ON bc.BATCH_ID = bv.BATCH_ID

WHERE sfr.IS_ACTIVE = 'TRUE'
AND (
    sfr.APPLICABLE_PRODUCT_TYPE IS NULL
    OR sfr.APPLICABLE_PRODUCT_TYPE = bc.PRODUCT_TYPE
);

-- =============================================================================
-- SECTION 3 — SATELLITE INSERTS
-- Rule: NOT EXISTS on (HK + LOAD_DATE) to support historization
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_BATCH  ← RAW_BATCH_MASTER
-- Operational batch attributes — changes when status updates
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_BATCH
    (HK_BATCH, LOAD_DATE, RECORD_SOURCE,
     PLANT_ID, LINE_ID, BATCH_SIZE, BATCH_SIZE_UNIT,
     START_TIME, END_TIME, PROCESS_STAGE, EQUIPMENT_ID, BATCH_STATUS)
SELECT
    SHA2(BATCH_ID, 256)          AS HK_BATCH,
    _RAW_LOAD_TS                 AS LOAD_DATE,
    'MES::RAW_BATCH_MASTER',
    PLANT_ID,
    LINE_ID,
    BATCH_SIZE,
    BATCH_SIZE_UNIT,
    START_TIME,
    END_TIME,
    PROCESS_STAGE,
    EQUIPMENT_ID,
    BATCH_STATUS
FROM RAW.RAW_BATCH_MASTER src
WHERE NOT EXISTS (
    SELECT 1 FROM SILVER_TEST.SAT_BATCH t
    WHERE t.HK_BATCH  = SHA2(src.BATCH_ID, 256)
      AND t.LOAD_DATE = src._RAW_LOAD_TS
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_PRODUCT  ← RAW_BATCH_MASTER
-- Product name and type — reference data, rarely changes
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_PRODUCT
    (HK_PRODUCT, LOAD_DATE, RECORD_SOURCE,
     PRODUCT_NAME, PRODUCT_TYPE)
SELECT DISTINCT
    SHA2(PRODUCT_ID, 256)       AS HK_PRODUCT,
    MIN(_RAW_LOAD_TS)           AS LOAD_DATE,
    'MES::RAW_BATCH_MASTER',
    PRODUCT_NAME,
    PRODUCT_TYPE
FROM RAW.RAW_BATCH_MASTER src
GROUP BY PRODUCT_ID, PRODUCT_NAME, PRODUCT_TYPE
HAVING NOT EXISTS (
    SELECT 1 FROM SILVER_TEST.SAT_PRODUCT t
    WHERE t.HK_PRODUCT = SHA2(src.PRODUCT_ID, 256)
      AND t.PRODUCT_NAME = src.PRODUCT_NAME
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_CUSTOMER  ← RAW_CUSTOMER_AGREEMENTS
-- Customer profile — changes if customer type or market changes
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_CUSTOMER
    (HK_CUSTOMER, LOAD_DATE, RECORD_SOURCE,
     CUSTOMER_NAME, CUSTOMER_TYPE, REGULATORY_MARKET)
SELECT DISTINCT
    SHA2(CUSTOMER_ID, 256)          AS HK_CUSTOMER,
    MIN(_RAW_LOAD_TS)               AS LOAD_DATE,
    'CRM::RAW_CUSTOMER_AGREEMENTS',
    CUSTOMER_NAME,
    CUSTOMER_TYPE,
    REGULATORY_MARKET
FROM RAW.RAW_CUSTOMER_AGREEMENTS src
GROUP BY CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_TYPE, REGULATORY_MARKET
HAVING NOT EXISTS (
    SELECT 1 FROM SILVER_TEST.SAT_CUSTOMER t
    WHERE t.HK_CUSTOMER   = SHA2(src.CUSTOMER_ID, 256)
      AND t.CUSTOMER_NAME = src.CUSTOMER_NAME
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_AGREEMENT  ← RAW_CUSTOMER_AGREEMENTS
-- Contract terms — changes when agreement is amended
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_AGREEMENT
    (HK_AGREEMENT, LOAD_DATE, RECORD_SOURCE,
     AGREED_QTY, UNIT_PRICE, TOTAL_VALUE,
     DELIVERY_DEADLINE, PENALTY_PCT_PER_DAY, MAX_PENALTY_PCT, STATUS)
SELECT
    SHA2(AGREEMENT_ID, 256)         AS HK_AGREEMENT,
    _RAW_LOAD_TS                    AS LOAD_DATE,
    'CRM::RAW_CUSTOMER_AGREEMENTS',
    AGREED_QTY,
    UNIT_PRICE,
    TOTAL_VALUE,
    DELIVERY_DEADLINE,
    PENALTY_PCT_PER_DAY,
    MAX_PENALTY_PCT,
    STATUS
FROM RAW.RAW_CUSTOMER_AGREEMENTS src
WHERE NOT EXISTS (
    SELECT 1 FROM SILVER_TEST.SAT_AGREEMENT t
    WHERE t.HK_AGREEMENT = SHA2(src.AGREEMENT_ID, 256)
      AND t.LOAD_DATE    = src._RAW_LOAD_TS
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_BATCH_FULFILLMENT  ← RAW_BATCH_FULFILLMENT
-- Delivery outcome per batch-agreement — changes as delivery status updates
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_BATCH_FULFILLMENT
    (HK_LNK_BATCH_AGR, LOAD_DATE, RECORD_SOURCE,
     FULFILLED_QTY, DELIVERY_STATUS, DELAY_DAYS, FULFILLMENT_DATE)
SELECT
    SHA2(BATCH_ID || '|' || AGREEMENT_ID || '|' || PRODUCT_ID, 256)
                                    AS HK_LNK_BATCH_AGR,
    _RAW_LOAD_TS                    AS LOAD_DATE,
    'ERP::RAW_BATCH_FULFILLMENT',
    FULFILLED_QTY,
    DELIVERY_STATUS,
    DELAY_DAYS,
    TRY_TO_DATE(FULFILLMENT_DATE)   AS FULFILLMENT_DATE
FROM RAW.RAW_BATCH_FULFILLMENT src
WHERE BATCH_ID <> 'NO_BATCH_AVAILABLE'
  AND NOT EXISTS (
    SELECT 1 FROM SILVER_TEST.SAT_BATCH_FULFILLMENT t
    WHERE t.HK_LNK_BATCH_AGR = SHA2(
              src.BATCH_ID    || '|' ||
              src.AGREEMENT_ID || '|' ||
              src.PRODUCT_ID, 256)
      AND t.LOAD_DATE = src._RAW_LOAD_TS
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_MATERIAL_COST  ← RAW_MATERIAL_ACQUISITION
-- Cost per batch per material category
-- PK is (HK_BATCH + LOAD_DATE + MATERIAL_CATEGORY)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_MATERIAL_COST
    (HK_BATCH, LOAD_DATE, RECORD_SOURCE,
     MATERIAL_CATEGORY, TOTAL_MATERIAL_COST, COST_PER_UNIT)
SELECT
    SHA2(BATCH_ID, 256) AS HK_BATCH,
    _RAW_LOAD_TS AS LOAD_DATE,
    'ERP::RAW_MATERIAL_ACQUISITION',
    MATERIAL_CATEGORY,
    TOTAL_COST AS TOTAL_MATERIAL_COST,
    TOTAL_COST / NULLIF(QUANTITY,0) AS COST_PER_UNIT
FROM RAW.RAW_MATERIAL_ACQUISITION src
WHERE NOT EXISTS (
    SELECT 1
    FROM SILVER_TEST.SAT_MATERIAL_COST t
    WHERE t.HK_BATCH = SHA2(src.BATCH_ID, 256)
      AND t.LOAD_DATE = src._RAW_LOAD_TS
      AND t.MATERIAL_CATEGORY = src.MATERIAL_CATEGORY
);
-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_FDA_RULE  ← RAW_FDA_PENALTIES
-- Violation rule attributes — reference data, versioned by load date
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_FDA_RULE
    (HK_FDA_RULE, LOAD_DATE, RECORD_SOURCE,
     CFR_REFERENCE, VIOLATION_TYPE, VIOLATION_CATEGORY,
     APPLICABLE_PRODUCT_TYPE, PENALTY_TYPE,
     MIN_PENALTY_USD, MAX_PENALTY_USD, RECALL_CLASS,
     BUSINESS_IMPACT, AUTO_BLOCK_RELEASE, MANDATORY_CAPA,
     REGULATORY_HOLD_DAYS, EFFECTIVE_DATE, IS_ACTIVE)
SELECT
    SHA2(PENALTY_RULE_ID, 256)  AS HK_FDA_RULE,
    _RAW_LOAD_TS                AS LOAD_DATE,
    'FDA::RAW_FDA_PENALTIES',
    CFR_REFERENCE,
    VIOLATION_TYPE,
    VIOLATION_CATEGORY,
    APPLICABLE_PRODUCT_TYPE,
    PENALTY_TYPE,
    MIN_PENALTY_USD,
    MAX_PENALTY_USD,
    RECALL_CLASS,
    BUSINESS_IMPACT,
    AUTO_BLOCK_RELEASE,
    MANDATORY_CAPA,
    REGULATORY_HOLD_DAYS,
    EFFECTIVE_DATE,
    IS_ACTIVE
FROM RAW.RAW_FDA_PENALTIES src
WHERE NOT EXISTS (
    SELECT 1 FROM SILVER_TEST.SAT_FDA_RULE t
    WHERE t.HK_FDA_RULE = SHA2(src.PENALTY_RULE_ID, 256)
      AND t.LOAD_DATE   = src._RAW_LOAD_TS
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_SENSOR  ← RAW_SENSOR_READINGS
-- Sensor identity and location — distinct per sensor type and location
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_SENSOR
    (HK_SENSOR, LOAD_DATE, RECORD_SOURCE, SENSOR_TYPE, LOCATION)
SELECT DISTINCT
    SHA2(SENSOR_ID, 256)        AS HK_SENSOR,
    MIN(_RAW_LOAD_TS)           AS LOAD_DATE,
    'IOT::RAW_SENSOR_READINGS',
    SENSOR_TYPE,
    LOCATION
FROM RAW.RAW_SENSOR_READINGS src
GROUP BY SENSOR_ID, SENSOR_TYPE, LOCATION
HAVING NOT EXISTS (
    SELECT 1 FROM SILVER_TEST.SAT_SENSOR t
    WHERE t.HK_SENSOR   = SHA2(src.SENSOR_ID, 256)
      AND t.SENSOR_TYPE = src.SENSOR_TYPE
      AND t.LOCATION    = src.LOCATION
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_LAB_TEST  ← RAW_LAB_TESTS
-- Test results — immutable once approved by analyst
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_LAB_TEST
    (HK_TEST, LOAD_DATE, RECORD_SOURCE,
     TEST_NAME, TEST_RESULT, TEST_STATUS, SPEC_MIN, SPEC_MAX)
SELECT
    SHA2(TEST_ID, 256)          AS HK_TEST,
    _RAW_LOAD_TS                AS LOAD_DATE,
    'LIMS::RAW_LAB_TESTS',
    TEST_NAME,
    TEST_RESULT,
    RESULT_STATUS               AS TEST_STATUS,
    SPEC_MIN,
    SPEC_MAX
FROM RAW.RAW_LAB_TESTS src
WHERE NOT EXISTS (
    SELECT 1 FROM SILVER_TEST.SAT_LAB_TEST t
    WHERE t.HK_TEST   = SHA2(src.TEST_ID, 256)
      AND t.LOAD_DATE = src._RAW_LOAD_TS
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SAT_DEVIATION  ← RAW_DEVIATIONS
-- Deviation records — mutable as CAPA progresses
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO SILVER_TEST.SAT_DEVIATION
    (HK_DEVIATION, LOAD_DATE, RECORD_SOURCE,
     DEVIATION_TYPE, SEVERITY, ROOT_CAUSE, STATUS)
SELECT
    SHA2(DEVIATION_ID, 256)     AS HK_DEVIATION,
    _RAW_LOAD_TS                AS LOAD_DATE,
    'QA::RAW_DEVIATIONS',
    DEVIATION_TYPE,
    SEVERITY,
    ROOT_CAUSE,
    CAPA_STATUS                 AS STATUS
FROM RAW.RAW_DEVIATIONS src
WHERE NOT EXISTS (
    SELECT 1 FROM SILVER_TEST.SAT_DEVIATION t
    WHERE t.HK_DEVIATION = SHA2(src.DEVIATION_ID, 256)
      AND t.LOAD_DATE    = src._RAW_LOAD_TS
);