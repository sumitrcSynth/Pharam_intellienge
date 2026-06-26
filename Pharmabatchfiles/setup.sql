-- =============================================================================
-- PharmaCopilot Native App setup with full pipeline DML in SP_BUILD_SILVER/FEATURE/GOLD
-- Co-authored with CoCo
-- FILE        : setup.sql
-- APPLICATION : PharmaCopilot — Pharmaceutical Manufacturing Intelligence
-- FRAMEWORK   : Snowflake Native App Framework
-- PURPOSE     : Idempotent installation DDL for all schemas, stages, file
--               formats, tables, views, UDF, application roles, and grants.
--
-- SCHEMA MAP  : APP_CONFIG   — application metadata and pipeline config
--               RAW          — exact mirror of source system CSV files
--               SILVER_TEST  — Data Vault 2.0 (Hubs, Links, Satellites)
--               FEATURE_TEST — ML feature engineering tables
--               GOLD_V2      — Gold facts, views, and simulation log
--               ML_CODE      — Versioned schema for ML UDF (IMPORTS support)
--
-- EXECUTION   : Run once at install time by Snowflake Native App Framework.
--               All statements are idempotent (IF NOT EXISTS / OR REPLACE).
--
-- IMPORTANT   : Do not switch database, schema, or warehouse context in this script.
--               The Native App Framework executes this file in the context of
--               the installed application database automatically.
--
-- INSTALL ORDER (within this file):
--   1.  Application Roles
--   2.  Schemas
--   3.  Stages
--   4.  File Formats
--   5.  APP_CONFIG Tables
--   6.  RAW Tables
--   7.  SILVER_TEST Tables  (Hubs → Satellites → Links Tier 1 → Links Tier 2)
--   8.  FEATURE_TEST Tables
--   9.  FEATURE_TEST UDF
--   10. GOLD_V2 Tables
--   11. GOLD_V2 Views
--   12. Role Grants
-- =============================================================================


-- =============================================================================
-- SECTION 1 — APPLICATION ROLES
-- =============================================================================
-- Two roles: ADMIN (full pipeline + simulation write) and VIEWER (read-only).
-- Roles are granted object privileges at the end of this file after all
-- objects exist.

CREATE APPLICATION ROLE IF NOT EXISTS PHARMA_ADMIN_ROLE;
CREATE APPLICATION ROLE IF NOT EXISTS PHARMA_VIEWER_ROLE;


-- =============================================================================
-- SECTION 2 — SCHEMAS
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS APP_CONFIG;
CREATE SCHEMA IF NOT EXISTS RAW;
CREATE SCHEMA IF NOT EXISTS SILVER_TEST;
CREATE SCHEMA IF NOT EXISTS FEATURE_TEST;
CREATE SCHEMA IF NOT EXISTS GOLD_V2;
CREATE OR ALTER VERSIONED SCHEMA ML_CODE;


-- =============================================================================
-- SECTION 3 — STAGES
-- =============================================================================
-- PHARMA_MODEL_STAGE : optional runtime stage for model metadata and smoke-test copies.
--                      The production UDF imports the bundled version artifact
--                      at /artifacts/pharma_batch_model.pkl.
-- PHARMA_UI_STAGE    : holds the Cortex semantic model YAML and static assets
--                      (images) consumed by the Streamlit application.

CREATE STAGE IF NOT EXISTS FEATURE_TEST.PHARMA_MODEL_STAGE
    COMMENT = 'Optional runtime stage for model metadata and smoke-test copies. PREDICT_BATCH_FAILURE_PROB imports the bundled /artifacts/pharma_batch_model.pkl artifact.';

CREATE STAGE IF NOT EXISTS GOLD_V2.PHARMA_UI_STAGE
    COMMENT = 'Cortex Analyst semantic model YAML and Streamlit static assets (stagesvg.png).';


-- =============================================================================
-- SECTION 4 — FILE FORMATS
-- =============================================================================
-- Used when the consumer loads source CSV files into RAW tables via COPY INTO.

CREATE FILE FORMAT IF NOT EXISTS RAW.FF_CSV_STANDARD
    TYPE                = CSV
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF             = ('NULL', 'null', '', 'N/A')
    EMPTY_FIELD_AS_NULL = TRUE
    SKIP_HEADER         = 1
    DATE_FORMAT         = 'AUTO'
    TIMESTAMP_FORMAT    = 'AUTO'
    TRIM_SPACE          = TRUE
    COMMENT             = 'Standard CSV format for all RAW layer COPY INTO operations.';


-- =============================================================================
-- SECTION 5 — APP_CONFIG TABLES
-- =============================================================================
-- Lightweight application metadata tables: pipeline run log and configuration
-- key-value store. Not part of the analytical pipeline but used for operational
-- visibility and parameterisation within the Native App context.

CREATE TABLE IF NOT EXISTS APP_CONFIG.PIPELINE_CONFIG (
    CONFIG_KEY          VARCHAR(200)        NOT NULL,
    CONFIG_VALUE        VARCHAR(2000),
    CONFIG_DESCRIPTION  VARCHAR(1000),
    IS_ACTIVE           BOOLEAN             DEFAULT TRUE,
    CREATED_AT          TIMESTAMP_NTZ       DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT          TIMESTAMP_NTZ       DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_PIPELINE_CONFIG PRIMARY KEY (CONFIG_KEY)
);

CREATE TABLE IF NOT EXISTS APP_CONFIG.PIPELINE_RUN_LOG (
    RUN_ID              VARCHAR(64)         DEFAULT SHA2(UUID_STRING(), 256),
    PIPELINE_LAYER      VARCHAR(50)         NOT NULL,   -- RAW | SILVER | FEATURE | GOLD
    RUN_STATUS          VARCHAR(20)         NOT NULL,   -- STARTED | COMPLETED | FAILED
    ROWS_PROCESSED      NUMBER,
    ERROR_MESSAGE       VARCHAR(4000),
    STARTED_AT          TIMESTAMP_NTZ       DEFAULT CURRENT_TIMESTAMP(),
    COMPLETED_AT        TIMESTAMP_NTZ,
    TRIGGERED_BY        VARCHAR(200)        DEFAULT CURRENT_USER()
);

INSERT INTO APP_CONFIG.PIPELINE_CONFIG (CONFIG_KEY, CONFIG_VALUE, CONFIG_DESCRIPTION)
    SELECT 'APP_VERSION',           '1.0.0',           'PharmaCopilot application version'
    WHERE NOT EXISTS (SELECT 1 FROM APP_CONFIG.PIPELINE_CONFIG WHERE CONFIG_KEY = 'APP_VERSION');

INSERT INTO APP_CONFIG.PIPELINE_CONFIG (CONFIG_KEY, CONFIG_VALUE, CONFIG_DESCRIPTION)
    SELECT 'CORTEX_MODEL',          'mistral-large2',   'Snowflake Cortex LLM model identifier for AI Co-Pilot'
    WHERE NOT EXISTS (SELECT 1 FROM APP_CONFIG.PIPELINE_CONFIG WHERE CONFIG_KEY = 'CORTEX_MODEL');

INSERT INTO APP_CONFIG.PIPELINE_CONFIG (CONFIG_KEY, CONFIG_VALUE, CONFIG_DESCRIPTION)
    SELECT 'ML_FAILURE_THRESH_RELEASE', '0.20',         'ML probability threshold: below this → RELEASE decision'
    WHERE NOT EXISTS (SELECT 1 FROM APP_CONFIG.PIPELINE_CONFIG WHERE CONFIG_KEY = 'ML_FAILURE_THRESH_RELEASE');

INSERT INTO APP_CONFIG.PIPELINE_CONFIG (CONFIG_KEY, CONFIG_VALUE, CONFIG_DESCRIPTION)
    SELECT 'ML_FAILURE_THRESH_RETEST',  '0.40',         'ML probability threshold: below this → RETEST decision'
    WHERE NOT EXISTS (SELECT 1 FROM APP_CONFIG.PIPELINE_CONFIG WHERE CONFIG_KEY = 'ML_FAILURE_THRESH_RETEST');

INSERT INTO APP_CONFIG.PIPELINE_CONFIG (CONFIG_KEY, CONFIG_VALUE, CONFIG_DESCRIPTION)
    SELECT 'ML_FAILURE_THRESH_HOLD',    '0.65',         'ML probability threshold: below this → HOLD decision; above → REJECT'
    WHERE NOT EXISTS (SELECT 1 FROM APP_CONFIG.PIPELINE_CONFIG WHERE CONFIG_KEY = 'ML_FAILURE_THRESH_HOLD');


-- =============================================================================
-- SECTION 6 — RAW TABLES
-- =============================================================================
-- Exact mirror of source CSV files. No transformation. Audit columns appended.
-- Data is loaded by the consumer via COPY INTO using FF_CSV_STANDARD.

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW.RAW_BATCH_MASTER
-- Source: MES (Manufacturing Execution System)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS RAW.RAW_BATCH_MASTER (
    BATCH_ID              VARCHAR(50),
    PRODUCT_ID            VARCHAR(50),
    PRODUCT_NAME          VARCHAR(200),
    PRODUCT_TYPE          VARCHAR(50),
    PLANT_ID              VARCHAR(50),
    LINE_ID               VARCHAR(50),
    BATCH_SIZE            NUMBER(12,3),
    BATCH_SIZE_UNIT       VARCHAR(20),
    START_TIME            TIMESTAMP_NTZ,
    END_TIME              TIMESTAMP_NTZ,
    PLANNED_RELEASE_DATE  DATE,
    PROCESS_STAGE         VARCHAR(50),
    OPERATOR_ID           VARCHAR(50),
    EQUIPMENT_ID          VARCHAR(50),
    BATCH_STATUS          VARCHAR(50),
    ERP_ORDER_ID          VARCHAR(50),
    MES_RECORD_ID         VARCHAR(50),
    SCENARIO_PROFILE      VARCHAR(20),
    CREATED_AT            TIMESTAMP_NTZ,
    UPDATED_AT            TIMESTAMP_NTZ,
    -- RAW audit columns
    _RAW_LOAD_TS          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW.RAW_SENSOR_READINGS
-- Source: IoT / SCADA
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS RAW.RAW_SENSOR_READINGS (
    READING_ID            VARCHAR(50),
    SENSOR_ID             VARCHAR(50),
    SENSOR_TYPE           VARCHAR(20),
    BATCH_ID              VARCHAR(50),
    LOCATION              VARCHAR(50),
    SENSOR_VALUE          FLOAT,
    THRESHOLD_MIN         FLOAT,
    THRESHOLD_MAX         FLOAT,
    UNIT                  VARCHAR(20),
    EVENT_TIMESTAMP       TIMESTAMP_NTZ,
    IS_OUT_OF_RANGE       VARCHAR(10),
    CALIBRATION_STATUS    VARCHAR(30),
    INGESTED_AT           TIMESTAMP_NTZ,
    _RAW_LOAD_TS          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW.RAW_LAB_TESTS
-- Source: LIMS (Laboratory Information Management System)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS RAW.RAW_LAB_TESTS (
    TEST_ID               VARCHAR(50),
    BATCH_ID              VARCHAR(50),
    TEST_NAME             VARCHAR(100),
    TEST_METHOD           VARCHAR(50),
    TEST_CATEGORY         VARCHAR(50),
    TEST_RESULT           FLOAT,
    RESULT_UNIT           VARCHAR(20),
    SPEC_MIN              FLOAT,
    SPEC_MAX              FLOAT,
    RESULT_STATUS         VARCHAR(20),
    TEST_TIMESTAMP        TIMESTAMP_NTZ,
    ANALYST_ID            VARCHAR(50),
    INSTRUMENT_ID         VARCHAR(50),
    REPEAT_TEST_FLAG      VARCHAR(10),
    APPROVED_BY           VARCHAR(50),
    APPROVED_AT           TIMESTAMP_NTZ,
    LIMS_RECORD_ID        VARCHAR(50),
    NOTES                 VARCHAR(500),
    CREATED_AT            TIMESTAMP_NTZ,
    _RAW_LOAD_TS          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW.RAW_DEVIATIONS
-- Source: QA / ERP deviation management
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS RAW.RAW_DEVIATIONS (
    DEVIATION_ID          VARCHAR(50),
    BATCH_ID              VARCHAR(50),
    DEVIATION_TYPE        VARCHAR(50),
    DESCRIPTION           VARCHAR(2000),
    SEVERITY              VARCHAR(20),
    DETECTED_STAGE        VARCHAR(50),
    REPORTED_BY           VARCHAR(50),
    REPORTED_AT           TIMESTAMP_NTZ,
    ROOT_CAUSE            VARCHAR(200),
    CORRECTIVE_ACTION     VARCHAR(200),
    CAPA_DUE_DATE         DATE,
    CAPA_STATUS           VARCHAR(20),
    APPROVED_BY           VARCHAR(50),
    APPROVED_AT           TIMESTAMP_NTZ,
    LINKED_SENSOR_ID      VARCHAR(50),
    CREATED_AT            TIMESTAMP_NTZ,
    _RAW_LOAD_TS          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW.RAW_AUDIT_TRAIL
-- Source: ERP / MES electronic audit trail (21 CFR Part 11)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS RAW.RAW_AUDIT_TRAIL (
    AUDIT_ID              VARCHAR(50),
    BATCH_ID              VARCHAR(50),
    ACTION_TYPE           VARCHAR(20),
    ENTITY_TYPE           VARCHAR(30),
    ENTITY_ID             VARCHAR(50),
    USER_ID               VARCHAR(50),
    USER_ROLE             VARCHAR(30),
    SYSTEM_SOURCE         VARCHAR(30),
    FIELD_CHANGED         VARCHAR(100),
    OLD_VALUE             VARCHAR(200),
    NEW_VALUE             VARCHAR(200),
    CHANGE_REASON         VARCHAR(500),
    ELECTRONIC_SIGNATURE  VARCHAR(10),
    IP_ADDRESS            VARCHAR(20),
    SESSION_ID            VARCHAR(50),
    EVENT_TIMESTAMP       TIMESTAMP_NTZ,
    CREATED_AT            TIMESTAMP_NTZ,
    _RAW_LOAD_TS          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW.RAW_CUSTOMER_AGREEMENTS
-- Source: CRM / Contract management
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS RAW.RAW_CUSTOMER_AGREEMENTS (
    AGREEMENT_ID              VARCHAR(50),
    CUSTOMER_ID               VARCHAR(50),
    CUSTOMER_NAME             VARCHAR(200),
    CUSTOMER_TYPE             VARCHAR(50),
    PRODUCT_ID                VARCHAR(50),
    PRODUCT_NAME              VARCHAR(200),
    PRODUCT_TYPE              VARCHAR(50),
    AGREED_QTY                NUMBER(18,2),
    QTY_UNIT                  VARCHAR(20),
    UNIT_PRICE                FLOAT,
    TOTAL_VALUE               FLOAT,
    CURRENCY                  VARCHAR(10),
    CONTRACT_START_DATE       DATE,
    CONTRACT_END_DATE         DATE,
    DELIVERY_DEADLINE         DATE,
    DELIVERY_TERMS            VARCHAR(20),
    PENALTY_CLAUSE            VARCHAR(10),
    PENALTY_PCT_PER_DAY       FLOAT,
    MAX_PENALTY_PCT           FLOAT,
    PAYMENT_TERMS             VARCHAR(50),
    REGULATORY_MARKET         VARCHAR(50),
    FDA_APPROVAL_REQUIRED     VARCHAR(10),
    STATUS                    VARCHAR(20),
    CREATED_AT                TIMESTAMP_NTZ,
    _RAW_LOAD_TS              TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE              VARCHAR(500),
    _ROW_HASH                 VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW.RAW_MATERIAL_ACQUISITION
-- Source: ERP procurement / materials management
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS RAW.RAW_MATERIAL_ACQUISITION (
    MATERIAL_ID           VARCHAR(50),
    BATCH_ID              VARCHAR(50),
    PRODUCT_ID            VARCHAR(50),
    MATERIAL_CATEGORY     VARCHAR(50),
    MATERIAL_NAME         VARCHAR(200),
    QUANTITY              FLOAT,
    UNIT                  VARCHAR(20),
    UNIT_COST             FLOAT,
    TOTAL_COST            FLOAT,
    SUPPLIER_NAME         VARCHAR(200),
    PURCHASE_DATE         DATE,
    _RAW_LOAD_TS          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW.RAW_FDA_PENALTIES
-- Source: FDA CFR reference data (managed by QA team)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS RAW.RAW_FDA_PENALTIES (
    PENALTY_RULE_ID         VARCHAR(50),
    CFR_REFERENCE           VARCHAR(100),
    VIOLATION_TYPE          VARCHAR(200),
    VIOLATION_CATEGORY      VARCHAR(50),
    APPLICABLE_PRODUCT_TYPE VARCHAR(50),
    PENALTY_TYPE            VARCHAR(100),
    MIN_PENALTY_USD         FLOAT,
    MAX_PENALTY_USD         FLOAT,
    RECALL_CLASS            VARCHAR(20),
    BUSINESS_IMPACT         VARCHAR(200),
    AUTO_BLOCK_RELEASE      VARCHAR(10),
    MANDATORY_CAPA          VARCHAR(10),
    REGULATORY_HOLD_DAYS    INT,
    EFFECTIVE_DATE          DATE,
    IS_ACTIVE               VARCHAR(10),
    CREATED_AT              TIMESTAMP_NTZ,
    _RAW_LOAD_TS            TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE            VARCHAR(500),
    _ROW_HASH               VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW.RAW_BATCH_FULFILLMENT
-- Source: ERP dispatch / delivery management
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS RAW.RAW_BATCH_FULFILLMENT (
    FULFILLMENT_ID        VARCHAR(50),
    BATCH_ID              VARCHAR(50),
    AGREEMENT_ID          VARCHAR(50),
    PRODUCT_ID            VARCHAR(50),
    FULFILLED_QTY         FLOAT,
    FULFILLMENT_DATE      DATE,
    DELIVERY_STATUS       VARCHAR(30),
    DELAY_DAYS            NUMBER,
    CREATED_AT            TIMESTAMP_NTZ,
    _RAW_LOAD_TS          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);


-- =============================================================================
-- SECTION 7 — SILVER_TEST TABLES  (Data Vault 2.0)
-- =============================================================================
-- Install order: Hubs → Satellites → Links Tier 1 → Links Tier 2
-- Links Tier 2 (LNK_BATCH_FDA_RULE) depends on SATs being populated at runtime
-- but its DDL has no FK constraints, so it can be created in any order.

-- ─────────────────────────────────────────────────────────────────────────────
-- HUBS  (business keys + hash key + load date + record source)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_BATCH (
    HK_BATCH        VARCHAR         NOT NULL,
    BATCH_ID        VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    CONSTRAINT PK_HUB_BATCH PRIMARY KEY (HK_BATCH)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_PRODUCT (
    HK_PRODUCT      VARCHAR         NOT NULL,
    PRODUCT_ID      VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    CONSTRAINT PK_HUB_PRODUCT PRIMARY KEY (HK_PRODUCT)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_CUSTOMER (
    HK_CUSTOMER     VARCHAR         NOT NULL,
    CUSTOMER_ID     VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    CONSTRAINT PK_HUB_CUSTOMER PRIMARY KEY (HK_CUSTOMER)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_AGREEMENT (
    HK_AGREEMENT    VARCHAR         NOT NULL,
    AGREEMENT_ID    VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    CONSTRAINT PK_HUB_AGREEMENT PRIMARY KEY (HK_AGREEMENT)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_SENSOR (
    HK_SENSOR       VARCHAR         NOT NULL,
    SENSOR_ID       VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    CONSTRAINT PK_HUB_SENSOR PRIMARY KEY (HK_SENSOR)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_LAB_TEST (
    HK_TEST         VARCHAR         NOT NULL,
    TEST_ID         VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    CONSTRAINT PK_HUB_LAB_TEST PRIMARY KEY (HK_TEST)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_DEVIATION (
    HK_DEVIATION    VARCHAR         NOT NULL,
    DEVIATION_ID    VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    CONSTRAINT PK_HUB_DEVIATION PRIMARY KEY (HK_DEVIATION)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.HUB_FDA_RULE (
    HK_FDA_RULE         VARCHAR         NOT NULL,
    PENALTY_RULE_ID     VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    CONSTRAINT PK_HUB_FDA_RULE PRIMARY KEY (HK_FDA_RULE)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SATELLITES  (business attributes, historised by load date)
-- PK is composite (HK + LOAD_DATE) to support SCD Type 2 historisation.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_BATCH (
    HK_BATCH            VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    PLANT_ID            VARCHAR,
    LINE_ID             VARCHAR,
    BATCH_SIZE          NUMBER(12,3),
    BATCH_SIZE_UNIT     VARCHAR,
    START_TIME          TIMESTAMP_NTZ,
    END_TIME            TIMESTAMP_NTZ,
    PROCESS_STAGE       VARCHAR,
    EQUIPMENT_ID        VARCHAR,
    BATCH_STATUS        VARCHAR,
    CONSTRAINT PK_SAT_BATCH PRIMARY KEY (HK_BATCH, LOAD_DATE)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_PRODUCT (
    HK_PRODUCT          VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    PRODUCT_NAME        VARCHAR,
    PRODUCT_TYPE        VARCHAR,
    CONSTRAINT PK_SAT_PRODUCT PRIMARY KEY (HK_PRODUCT, LOAD_DATE)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_CUSTOMER (
    HK_CUSTOMER         VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    CUSTOMER_NAME       VARCHAR,
    CUSTOMER_TYPE       VARCHAR,
    REGULATORY_MARKET   VARCHAR,
    CONSTRAINT PK_SAT_CUSTOMER PRIMARY KEY (HK_CUSTOMER, LOAD_DATE)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_AGREEMENT (
    HK_AGREEMENT            VARCHAR         NOT NULL,
    LOAD_DATE               TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE           VARCHAR         NOT NULL,
    AGREED_QTY              NUMBER(18,2),
    UNIT_PRICE              FLOAT,
    TOTAL_VALUE             FLOAT,
    DELIVERY_DEADLINE       DATE,
    PENALTY_PCT_PER_DAY     FLOAT,
    MAX_PENALTY_PCT         FLOAT,
    STATUS                  VARCHAR,
    CONSTRAINT PK_SAT_AGREEMENT PRIMARY KEY (HK_AGREEMENT, LOAD_DATE)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_BATCH_FULFILLMENT (
    HK_LNK_BATCH_AGR    VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    FULFILLED_QTY       FLOAT,
    DELIVERY_STATUS     VARCHAR(30),
    DELAY_DAYS          NUMBER,
    FULFILLMENT_DATE    DATE,
    CONSTRAINT PK_SAT_BATCH_FULFILLMENT PRIMARY KEY (HK_LNK_BATCH_AGR, LOAD_DATE)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_MATERIAL_COST (
    HK_BATCH                VARCHAR         NOT NULL,
    LOAD_DATE               TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE           VARCHAR         NOT NULL,
    MATERIAL_CATEGORY       VARCHAR,
    TOTAL_MATERIAL_COST     FLOAT,
    COST_PER_UNIT           FLOAT,
    CONSTRAINT PK_SAT_MATERIAL_COST PRIMARY KEY (HK_BATCH, LOAD_DATE, MATERIAL_CATEGORY)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_FDA_RULE (
    HK_FDA_RULE                 VARCHAR         NOT NULL,
    LOAD_DATE                   TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE               VARCHAR         NOT NULL,
    CFR_REFERENCE               VARCHAR,
    VIOLATION_TYPE              VARCHAR,
    VIOLATION_CATEGORY          VARCHAR,
    APPLICABLE_PRODUCT_TYPE     VARCHAR,
    PENALTY_TYPE                VARCHAR,
    MIN_PENALTY_USD             FLOAT,
    MAX_PENALTY_USD             FLOAT,
    RECALL_CLASS                VARCHAR,
    BUSINESS_IMPACT             VARCHAR,
    AUTO_BLOCK_RELEASE          VARCHAR,
    MANDATORY_CAPA              VARCHAR,
    REGULATORY_HOLD_DAYS        NUMBER,
    EFFECTIVE_DATE              DATE,
    IS_ACTIVE                   VARCHAR,
    CONSTRAINT PK_SAT_FDA_RULE PRIMARY KEY (HK_FDA_RULE, LOAD_DATE)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_SENSOR (
    HK_SENSOR       VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    SENSOR_TYPE     VARCHAR,
    LOCATION        VARCHAR,
    CONSTRAINT PK_SAT_SENSOR PRIMARY KEY (HK_SENSOR, LOAD_DATE)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_LAB_TEST (
    HK_TEST         VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    TEST_NAME       VARCHAR,
    TEST_RESULT     FLOAT,
    TEST_STATUS     VARCHAR,
    SPEC_MIN        FLOAT,
    SPEC_MAX        FLOAT,
    CONSTRAINT PK_SAT_LAB_TEST PRIMARY KEY (HK_TEST, LOAD_DATE)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.SAT_DEVIATION (
    HK_DEVIATION    VARCHAR         NOT NULL,
    LOAD_DATE       TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE   VARCHAR         NOT NULL,
    DEVIATION_TYPE  VARCHAR,
    SEVERITY        VARCHAR,
    ROOT_CAUSE      VARCHAR,
    STATUS          VARCHAR,
    CONSTRAINT PK_SAT_DEVIATION PRIMARY KEY (HK_DEVIATION, LOAD_DATE)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- LINKS TIER 1  (depend on Hubs only — no rule-engine logic)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_PRODUCT (
    HK_LNK_BATCH_PRODUCT    VARCHAR         NOT NULL,
    HK_BATCH                VARCHAR         NOT NULL,
    HK_PRODUCT              VARCHAR         NOT NULL,
    LOAD_DATE               TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE           VARCHAR         NOT NULL,
    CONSTRAINT PK_LNK_BATCH_PRODUCT PRIMARY KEY (HK_LNK_BATCH_PRODUCT)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_CUSTOMER_AGREEMENT (
    HK_LNK_CUST_AGR     VARCHAR         NOT NULL,
    HK_CUSTOMER         VARCHAR         NOT NULL,
    HK_AGREEMENT        VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    CONSTRAINT PK_LNK_CUSTOMER_AGREEMENT PRIMARY KEY (HK_LNK_CUST_AGR)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_AGREEMENT_PRODUCT (
    HK_LNK_AGR_PROD     VARCHAR         NOT NULL,
    HK_AGREEMENT        VARCHAR         NOT NULL,
    HK_PRODUCT          VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    CONSTRAINT PK_LNK_AGREEMENT_PRODUCT PRIMARY KEY (HK_LNK_AGR_PROD)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_AGREEMENT (
    HK_LNK_BATCH_AGR    VARCHAR         NOT NULL,
    HK_BATCH            VARCHAR         NOT NULL,
    HK_AGREEMENT        VARCHAR         NOT NULL,
    HK_PRODUCT          VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    CONSTRAINT PK_LNK_BATCH_AGREEMENT PRIMARY KEY (HK_LNK_BATCH_AGR)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_SENSOR (
    HK_LNK_BATCH_SENSOR     VARCHAR         NOT NULL,
    HK_BATCH                VARCHAR         NOT NULL,
    HK_SENSOR               VARCHAR         NOT NULL,
    LOAD_DATE               TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE           VARCHAR         NOT NULL,
    CONSTRAINT PK_LNK_BATCH_SENSOR PRIMARY KEY (HK_LNK_BATCH_SENSOR)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_LAB_TEST (
    HK_LNK_BATCH_TEST   VARCHAR         NOT NULL,
    HK_BATCH            VARCHAR         NOT NULL,
    HK_TEST             VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    CONSTRAINT PK_LNK_BATCH_LAB_TEST PRIMARY KEY (HK_LNK_BATCH_TEST)
);

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_DEVIATION (
    HK_LNK_BATCH_DEV    VARCHAR         NOT NULL,
    HK_BATCH            VARCHAR         NOT NULL,
    HK_DEVIATION        VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    CONSTRAINT PK_LNK_BATCH_DEVIATION PRIMARY KEY (HK_LNK_BATCH_DEV)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- LINKS TIER 2  (populated by rule engine — requires SATs to be populated
--                at runtime, but DDL has no dependency on them)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS SILVER_TEST.LNK_BATCH_FDA_RULE (
    HK_LNK_BATCH_RULE   VARCHAR         NOT NULL,
    HK_BATCH            VARCHAR         NOT NULL,
    HK_FDA_RULE         VARCHAR         NOT NULL,
    LOAD_DATE           TIMESTAMP_NTZ   NOT NULL,
    RECORD_SOURCE       VARCHAR         NOT NULL,
    CONSTRAINT PK_LNK_BATCH_FDA_RULE PRIMARY KEY (HK_LNK_BATCH_RULE)
);


-- =============================================================================
-- SECTION 8 — FEATURE_TEST TABLES
-- =============================================================================
-- Empty shells — populated by pipeline execution after RAW and Silver are loaded.
-- Using CREATE TABLE IF NOT EXISTS so upgrades do not truncate existing data.
-- Column definitions mirror the SELECT list of each CREATE OR REPLACE AS SELECT
-- in 01Featureenng_layer.sql, ensuring schema compatibility.

-- ─────────────────────────────────────────────────────────────────────────────
-- FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES
-- Step 1 of feature pipeline — built from Silver + RAW
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES (
    BATCH_ID                        VARCHAR,
    PLANT_ID                        VARCHAR,
    PROCESS_STAGE                   VARCHAR,
    PRODUCT_TYPE                    VARCHAR,
    PRODUCT_NAME                    VARCHAR,
    BATCH_DURATION_HOURS            FLOAT,
    BATCH_SIZE                      FLOAT,
    -- Lab quality counts
    TOTAL_TESTS                     NUMBER,
    FAILED_TESTS                    NUMBER,
    OOS_COUNT                       NUMBER,
    BORDERLINE_COUNT                NUMBER,
    PASSED_TESTS                    NUMBER,
    -- Lab quality rates
    PASS_RATE_PCT                   FLOAT,
    OOS_RATE_PCT                    FLOAT,
    FAIL_RATE_PCT                   FLOAT,
    -- Critical test flags
    STERILITY_FAIL_FLAG             NUMBER,
    ENDOTOXIN_FAIL_FLAG             NUMBER,
    POTENCY_FAIL_FLAG               NUMBER,
    STERILITY_X_ENDOTOXIN           NUMBER,
    -- Spec distance
    AVG_SPEC_DISTANCE_NORMALIZED    FLOAT,
    REPEAT_TEST_COUNT               NUMBER,
    -- IoT / Sensor
    TEMP_VIOLATION_COUNT            NUMBER,
    HUMIDITY_VIOLATION_COUNT        NUMBER,
    PRESSURE_VIOLATION_COUNT        NUMBER,
    TOTAL_IOT_VIOLATIONS            NUMBER,
    AVG_TEMP_DEVIATION_C            FLOAT,
    TEMP_MAX_EXCURSION_MINS         FLOAT,
    TOTAL_SENSOR_READINGS           NUMBER,
    IOT_VIOLATION_DENSITY           FLOAT,
    TEMP_X_DURATION                 FLOAT,
    -- Deviations
    TOTAL_DEVIATIONS                NUMBER,
    CRITICAL_DEVIATION_COUNT        NUMBER,
    HIGH_DEVIATION_COUNT            NUMBER,
    LOW_MED_DEVIATION_COUNT         NUMBER,
    WEIGHTED_DEVIATION_SCORE        FLOAT,
    PROCESS_DEVIATION_COUNT         NUMBER,
    EQUIPMENT_DEVIATION_COUNT       NUMBER,
    HUMAN_DEVIATION_COUNT           NUMBER,
    ENV_DEVIATION_COUNT             NUMBER,
    DEVIATION_DENSITY               FLOAT,
    CRITICAL_DEV_RATE               FLOAT,
    TEMP_X_CRITICAL_DEV             FLOAT,
    PROCESS_VARIANCE                FLOAT,
    FEATURE_COMPUTED_AT             TIMESTAMP_NTZ
);

-- ─────────────────────────────────────────────────────────────────────────────
-- FEATURE_TEST.FEAT_ML_INPUT
-- Step 2 — ML-ready feature set; direct input to XGBoost UDF
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS FEATURE_TEST.FEAT_ML_INPUT (
    BATCH_ID                        VARCHAR,
    PRODUCT_TYPE                    VARCHAR,
    PLANT_ID                        VARCHAR,
    -- Bucketed categorical features
    BATCH_SIZE_BUCKET               VARCHAR,
    DURATION_BUCKET                 VARCHAR,
    -- Lab features
    TOTAL_TESTS                     NUMBER,
    FAILED_TESTS                    NUMBER,
    OOS_COUNT                       NUMBER,
    BORDERLINE_COUNT                NUMBER,
    PASS_RATE_PCT                   FLOAT,
    OOS_RATE_PCT                    FLOAT,
    FAIL_RATE_PCT                   FLOAT,
    STERILITY_FAIL_FLAG             NUMBER,
    ENDOTOXIN_FAIL_FLAG             NUMBER,
    STERILITY_X_ENDOTOXIN           NUMBER,
    -- Sensor features
    TEMP_VIOLATION_COUNT            NUMBER,
    TEMP_MAX_EXCURSION_MINS         FLOAT,
    AVG_TEMP_DEVIATION_C            FLOAT,
    HUMIDITY_VIOLATION_COUNT        NUMBER,
    PRESSURE_VIOLATION_COUNT        NUMBER,
    TOTAL_IOT_VIOLATIONS            NUMBER,
    IOT_VIOLATION_DENSITY           FLOAT,
    TEMP_X_DURATION                 FLOAT,
    -- Deviation features
    TOTAL_DEVIATIONS                NUMBER,
    CRITICAL_DEVIATION_COUNT        NUMBER,
    HIGH_DEVIATION_COUNT            NUMBER,
    WEIGHTED_DEVIATION_SCORE        FLOAT,
    PROCESS_DEVIATION_COUNT         NUMBER,
    EQUIPMENT_DEVIATION_COUNT       NUMBER,
    HUMAN_DEVIATION_COUNT           NUMBER,
    DEVIATION_DENSITY               FLOAT,
    CRITICAL_DEV_RATE               FLOAT,
    TEMP_X_CRITICAL_DEV             FLOAT,
    -- Process / size
    BATCH_SIZE                      FLOAT,
    BATCH_DURATION_HOURS            FLOAT,
    PROCESS_VARIANCE                FLOAT,
    -- Temporal
    BATCH_START_HOUR                NUMBER,
    BATCH_START_DOW                 NUMBER,
    IS_WEEKEND_BATCH                NUMBER,
    IS_NIGHT_SHIFT                  NUMBER,
    FEATURE_COMPUTED_AT             TIMESTAMP_NTZ
);

-- ─────────────────────────────────────────────────────────────────────────────
-- FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS
-- Step 3 — per-batch triggered FDA penalty rules
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS (
    BATCH_ID                VARCHAR,
    PENALTY_RULE_ID         VARCHAR,
    CFR_REFERENCE           VARCHAR,
    VIOLATION_TYPE          VARCHAR,
    VIOLATION_CATEGORY      VARCHAR,
    PENALTY_TYPE            VARCHAR,
    AUTO_BLOCK_RELEASE      BOOLEAN,
    MANDATORY_CAPA          BOOLEAN,
    REGULATORY_HOLD_DAYS    NUMBER,
    RECALL_CLASS            VARCHAR,
    BUSINESS_IMPACT         VARCHAR,
    ESTIMATED_PENALTY_USD   FLOAT,
    FEATURE_COMPUTED_AT     TIMESTAMP_NTZ
);

-- ─────────────────────────────────────────────────────────────────────────────
-- FEATURE_TEST.FEAT_FINANCIAL_FEATURES
-- Step 4 — revenue, cost, margin, penalty per batch
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS FEATURE_TEST.FEAT_FINANCIAL_FEATURES (
    BATCH_ID                    VARCHAR,
    TOTAL_COMMITTED_REVENUE     FLOAT,
    TOTAL_MATERIAL_COST         FLOAT,
    GROSS_MARGIN                FLOAT,
    GROSS_MARGIN_PCT            FLOAT,
    TOTAL_PENALTY_EXPOSURE      FLOAT,
    COST_PER_BATCH_UNIT         FLOAT,
    PENALTY_TO_REVENUE_RATIO    FLOAT,
    FEATURE_COMPUTED_AT         TIMESTAMP_NTZ
);

-- ─────────────────────────────────────────────────────────────────────────────
-- FEATURE_TEST.FEAT_ML_ENHANCED
-- Step 5 — delivery metrics and temporal features for BATCH_FACT
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS FEATURE_TEST.FEAT_ML_ENHANCED (
    BATCH_ID                VARCHAR,
    BATCH_START_HOUR        NUMBER,
    BATCH_START_DOW         NUMBER,
    IS_WEEKEND_BATCH        NUMBER,
    IS_NIGHT_SHIFT          NUMBER,
    TOTAL_DELIVERIES        NUMBER,
    DELAYED_DELIVERIES      NUMBER,
    FAILED_DELIVERIES       NUMBER,
    ON_TIME_RATE_PCT        FLOAT,
    FEATURE_COMPUTED_AT     TIMESTAMP_NTZ
);


-- =============================================================================
-- SECTION 9 — FEATURE_TEST UDF  (Python / XGBoost)
-- =============================================================================
-- PREDICT_BATCH_FAILURE_PROB: 40-parameter Python UDF wrapping the pre-trained
-- XGBoost model. Created in versioned schema ML_CODE to satisfy Native App
-- Framework requirement for IMPORTS. Model loaded from bundled version artifacts
-- via relative path '/artifacts/pharma_batch_model.pkl'.
--
-- Package versions are pinned to the versions used to serialize
-- artifacts/pharma_batch_model.pkl. NumPy must stay on 1.26.x; pickles
-- created under NumPy 2.x reference numpy._core and fail in Snowflake
-- runtimes that provide NumPy 1.x.

CREATE OR REPLACE FUNCTION ML_CODE.PREDICT_BATCH_FAILURE_PROB(
    PRODUCT_TYPE                VARCHAR,
    PLANT_ID                    VARCHAR,
    BATCH_STATUS                VARCHAR,
    BATCH_SIZE_BUCKET           VARCHAR,
    DURATION_BUCKET             VARCHAR,
    TOTAL_TESTS                 NUMBER,
    FAILED_TESTS                NUMBER,
    OOS_COUNT                   NUMBER,
    BORDERLINE_COUNT            NUMBER,
    PASS_RATE_PCT               FLOAT,
    OOS_RATE_PCT                FLOAT,
    FAIL_RATE_PCT               FLOAT,
    STERILITY_FAIL_FLAG         NUMBER,
    ENDOTOXIN_FAIL_FLAG         NUMBER,
    STERILITY_X_ENDOTOXIN       NUMBER,
    TEMP_VIOLATION_COUNT        NUMBER,
    TEMP_MAX_EXCURSION_MINS     FLOAT,
    AVG_TEMP_DEVIATION_C        FLOAT,
    HUMIDITY_VIOLATION_COUNT    NUMBER,
    PRESSURE_VIOLATION_COUNT    NUMBER,
    TOTAL_IOT_VIOLATIONS        NUMBER,
    IOT_VIOLATION_DENSITY       FLOAT,
    TEMP_X_DURATION             FLOAT,
    TOTAL_DEVIATIONS            NUMBER,
    CRITICAL_DEVIATION_COUNT    NUMBER,
    HIGH_DEVIATION_COUNT        NUMBER,
    WEIGHTED_DEVIATION_SCORE    FLOAT,
    PROCESS_DEVIATION_COUNT     NUMBER,
    EQUIPMENT_DEVIATION_COUNT   NUMBER,
    HUMAN_DEVIATION_COUNT       NUMBER,
    DEVIATION_DENSITY           FLOAT,
    CRITICAL_DEV_RATE           FLOAT,
    TEMP_X_CRITICAL_DEV         NUMBER,
    BATCH_SIZE                  FLOAT,
    BATCH_DURATION_HOURS        FLOAT,
    PROCESS_VARIANCE            FLOAT,
    BATCH_START_HOUR            NUMBER,
    BATCH_START_DOW             NUMBER,
    IS_WEEKEND_BATCH            NUMBER,
    IS_NIGHT_SHIFT              NUMBER
)
RETURNS FLOAT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('xgboost==1.7.6', 'scikit-learn==1.3.0', 'pandas==2.1.4', 'numpy==1.26.4', 'joblib==1.5.1')
IMPORTS = ('/artifacts/pharma_batch_model.pkl')
HANDLER = 'predict'
COMMENT = 'XGBoost batch failure probability scorer. Returns float in [0.0, 1.0]. Sterility+Endotoxin co-failure returns 1.0 (hard rule). Model loaded from version artifacts on first call per worker.'
AS $$
import sys
import os
import joblib
import pandas as pd
import numpy as np

_MODEL = None

def _load_model():
    global _MODEL
    if _MODEL is None:
        import_dir = sys._xoptions.get("snowflake_import_directory", "/tmp/")
        path = os.path.join(import_dir, "pharma_batch_model.pkl")
        _MODEL = joblib.load(path)
    return _MODEL

def predict(
    product_type, plant_id, batch_status, batch_size_bucket, duration_bucket,
    total_tests, failed_tests, oos_count, borderline_count,
    pass_rate_pct, oos_rate_pct, fail_rate_pct,
    sterility_fail_flag, endotoxin_fail_flag, sterility_x_endotoxin,
    temp_violation_count, temp_max_excursion_mins, avg_temp_deviation_c,
    humidity_violation_count, pressure_violation_count,
    total_iot_violations, iot_violation_density, temp_x_duration,
    total_deviations, critical_deviation_count, high_deviation_count,
    weighted_deviation_score, process_deviation_count,
    equipment_deviation_count, human_deviation_count,
    deviation_density, critical_dev_rate, temp_x_critical_dev,
    batch_size, batch_duration_hours, process_variance,
    batch_start_hour, batch_start_dow, is_weekend_batch, is_night_shift
):
    # Hard safety rule: sterility + endotoxin co-failure is always 1.0
    if sterility_fail_flag == 1 and endotoxin_fail_flag == 1:
        return 1.0

    model = _load_model()

    row = pd.DataFrame([{
        "PRODUCT_TYPE"             : product_type,
        "PLANT_ID"                 : plant_id,
        "BATCH_SIZE_BUCKET"        : batch_size_bucket,
        "DURATION_BUCKET"          : duration_bucket,
        "TOTAL_TESTS"              : total_tests,
        "FAILED_TESTS"             : failed_tests,
        "OOS_COUNT"                : oos_count,
        "BORDERLINE_COUNT"         : borderline_count,
        "PASS_RATE_PCT"            : pass_rate_pct,
        "OOS_RATE_PCT"             : oos_rate_pct,
        "FAIL_RATE_PCT"            : fail_rate_pct,
        "STERILITY_FAIL_FLAG"      : sterility_fail_flag,
        "ENDOTOXIN_FAIL_FLAG"      : endotoxin_fail_flag,
        "STERILITY_X_ENDOTOXIN"    : sterility_x_endotoxin,
        "TEMP_VIOLATION_COUNT"     : temp_violation_count,
        "TEMP_MAX_EXCURSION_MINS"  : temp_max_excursion_mins,
        "AVG_TEMP_DEVIATION_C"     : avg_temp_deviation_c,
        "HUMIDITY_VIOLATION_COUNT" : humidity_violation_count,
        "PRESSURE_VIOLATION_COUNT" : pressure_violation_count,
        "TOTAL_IOT_VIOLATIONS"     : total_iot_violations,
        "IOT_VIOLATION_DENSITY"    : iot_violation_density,
        "TEMP_X_DURATION"          : temp_x_duration,
        "TOTAL_DEVIATIONS"         : total_deviations,
        "CRITICAL_DEVIATION_COUNT" : critical_deviation_count,
        "HIGH_DEVIATION_COUNT"     : high_deviation_count,
        "WEIGHTED_DEVIATION_SCORE" : weighted_deviation_score,
        "PROCESS_DEVIATION_COUNT"  : process_deviation_count,
        "EQUIPMENT_DEVIATION_COUNT": equipment_deviation_count,
        "HUMAN_DEVIATION_COUNT"    : human_deviation_count,
        "DEVIATION_DENSITY"        : deviation_density,
        "CRITICAL_DEV_RATE"        : critical_dev_rate,
        "TEMP_X_CRITICAL_DEV"      : temp_x_critical_dev,
        "BATCH_SIZE"               : batch_size,
        "BATCH_DURATION_HOURS"     : batch_duration_hours,
        "PROCESS_VARIANCE"         : process_variance,
        "BATCH_START_HOUR"         : batch_start_hour,
        "BATCH_START_DOW"          : batch_start_dow,
        "IS_WEEKEND_BATCH"         : is_weekend_batch,
        "IS_NIGHT_SHIFT"           : is_night_shift,
    }])

    prob = float(model.predict_proba(row)[0, 1])
    return round(min(max(prob, 0.0), 1.0), 6)
$$;


-- =============================================================================
-- SECTION 10 — GOLD_V2 TABLES
-- =============================================================================
-- Install order:
--   ML_PREDICTIONS → RULE_ENGINE_OVERRIDES → BATCH_FACT → BATCH_SIMULATION_LOG
--
-- All three analytical tables use CREATE TABLE IF NOT EXISTS.
-- The pipeline execution (not this file) runs CREATE OR REPLACE AS SELECT
-- to refresh them on each pipeline run.

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLD_V2.ML_PREDICTIONS
-- Raw XGBoost scores before rule engine override
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS GOLD_V2.ML_PREDICTIONS (
    BATCH_ID                VARCHAR,
    PREDICTION_TS           TIMESTAMP_NTZ,
    ML_FAILURE_PROB         FLOAT,
    ML_RELEASE_SCORE        FLOAT,
    ML_PREDICTED_ACTION     VARCHAR(20)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLD_V2.RULE_ENGINE_OVERRIDES
-- Aggregated FDA rule engine flags per batch
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS GOLD_V2.RULE_ENGINE_OVERRIDES (
    BATCH_ID                        VARCHAR,
    HAS_AUTO_BLOCK_RULE             NUMBER,
    HAS_MANDATORY_CAPA              NUMBER,
    MAX_HOLD_DAYS                   NUMBER,
    FDA_VIOLATION_COUNT             NUMBER,
    FDA_CRITICAL_VIOLATIONS         NUMBER,
    FDA_MAJOR_VIOLATIONS            NUMBER,
    TOTAL_ESTIMATED_PENALTY_USD     FLOAT,
    CRITICAL_CFR_REFERENCE          VARCHAR,
    FDA_CRITICAL_RATE               FLOAT
);

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLD_V2.BATCH_FACT
-- Core gold table: ML + rule engine + financial + quality + risk tags
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS GOLD_V2.BATCH_FACT (
    -- Identity
    BATCH_ID                        VARCHAR,
    PRODUCT_NAME                    VARCHAR,
    PRODUCT_TYPE                    VARCHAR,
    DOSAGE_FORM                     VARCHAR,
    THERAPEUTIC_AREA                VARCHAR,
    PLANT_ID                        VARCHAR,
    BATCH_SIZE                      FLOAT,
    BATCH_DATE                      DATE,
    BATCH_STATUS                    VARCHAR,
    -- ML outputs
    FAILURE_PROBABILITY             FLOAT,
    RELEASE_SCORE                   FLOAT,
    ML_PREDICTED_ACTION             VARCHAR(20),
    -- FDA rule engine
    HAS_AUTO_BLOCK_RULE             NUMBER,
    FDA_VIOLATION_COUNT             NUMBER,
    FDA_CRITICAL_VIOLATIONS         NUMBER,
    FDA_MAJOR_VIOLATIONS            NUMBER,
    TOTAL_ESTIMATED_PENALTY_USD     FLOAT,
    REGULATORY_HOLD_DAYS            NUMBER,
    FDA_CRITICAL_RATE               FLOAT,
    CRITICAL_CFR_REFERENCE          VARCHAR,
    -- Final decision
    FINAL_DECISION                  VARCHAR(20),
    RULE_OVERRIDE_REASON            VARCHAR(50),
    -- Quality features
    TOTAL_TESTS                     NUMBER,
    FAILED_TEST_COUNT               NUMBER,
    OOS_COUNT                       NUMBER,
    BORDERLINE_COUNT                NUMBER,
    FE_PASS_RATE_PCT                FLOAT,
    STERILITY_FAIL_FLAG             NUMBER,
    ENDOTOXIN_FAIL_FLAG             NUMBER,
    TEMP_VIOLATION_COUNT            NUMBER,
    HUMIDITY_VIOLATION_COUNT        NUMBER,
    PRESSURE_VIOLATION_COUNT        NUMBER,
    CRITICAL_DEVIATION_COUNT        NUMBER,
    HIGH_DEVIATION_COUNT            NUMBER,
    TOTAL_DEVIATIONS                NUMBER,
    PROCESS_VARIANCE                FLOAT,
    WEIGHTED_DEVIATION_SCORE        FLOAT,
    PROCESS_DEVIATION_COUNT         NUMBER,
    EQUIPMENT_DEVIATION_COUNT       NUMBER,
    HUMAN_DEVIATION_COUNT           NUMBER,
    AVG_TEMP_DEVIATION_C            FLOAT,
    BATCH_DURATION_HOURS            FLOAT,
    BATCH_START_HOUR                NUMBER,
    BATCH_START_DOW                 NUMBER,
    IS_WEEKEND_BATCH                NUMBER,
    IS_NIGHT_SHIFT                  NUMBER,
    -- Financial
    TOTAL_COMMITTED_REVENUE         FLOAT,
    TOTAL_MATERIAL_COST             FLOAT,
    GROSS_MARGIN                    FLOAT,
    GROSS_MARGIN_PCT                FLOAT,
    TOTAL_PENALTY_EXPOSURE          FLOAT,
    ON_TIME_RATE_PCT                FLOAT,
    DELAYED_DELIVERIES              NUMBER,
    FAILED_DELIVERIES               NUMBER,
    FINANCIAL_RISK_SCORE            FLOAT,
    COST_PER_BATCH_UNIT             FLOAT,
    PENALTY_TO_REVENUE_RATIO        FLOAT,
    -- P&L by decision
    FINAL_REVENUE                   FLOAT,
    FINAL_PROFIT                    FLOAT,
    PENALTY_APPLIED                 FLOAT,
    -- Blended risk
    OVERALL_RISK_SCORE              FLOAT,
    -- Deviation detail
    DEVIATION_1_NAME                VARCHAR,
    DEVIATION_2_NAME                VARCHAR,
    DEVIATION_3_NAME                VARCHAR,
    -- Risk tags
    TOP_RISK_FACTOR_1               VARCHAR,
    TOP_RISK_FACTOR_2               VARCHAR,
    TOP_RISK_FACTOR_3               VARCHAR,
    -- AI narrative
    AI_DECISION_REASON              VARCHAR,
    -- Audit
    GOLD_CALC_TS                    TIMESTAMP_NTZ
);

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLD_V2.BATCH_SIMULATION_LOG
-- Audit trail for Streamlit simulation lab runs (INSERT by application)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS GOLD_V2.BATCH_SIMULATION_LOG (
    SIM_ID                  VARCHAR(64)     DEFAULT SHA2(UUID_STRING(), 256),
    BATCH_ID                VARCHAR(50),
    SIM_TS                  TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    SIMULATED_BY            VARCHAR(200)    DEFAULT CURRENT_USER(),
    -- Mutable parameter snapshot
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
    -- Financial recalculation
    SIM_FINAL_REVENUE       FLOAT,
    SIM_FINAL_PROFIT        FLOAT,
    SIM_PENALTY_APPLIED     FLOAT,
    -- Delta vs original
    DELTA_FAILURE_PROB_PP   FLOAT,
    DECISION_CHANGED        BOOLEAN,
    ORIG_DECISION           VARCHAR(20),
    NOTES                   VARCHAR(1000)
);


-- =============================================================================
-- SECTION 11 — GOLD_V2 VIEWS
-- =============================================================================
-- Views read from GOLD_V2.BATCH_FACT (and FEATURE_TEST.FEAT_ML_INPUT for
-- VW_UI_SIMULATION_BASE). All use CREATE OR REPLACE so upgrade deployments
-- automatically pick up view definition changes.

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLD_V2.VW_UI_BATCH_LIST
-- Consumed by Streamlit dashboard sidebar / batch queue panel
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW GOLD_V2.VW_UI_BATCH_LIST
    COMMENT = 'Batch queue view for Streamlit dashboard. Ordered by date desc, failure probability desc.'
AS
SELECT
    BATCH_ID,
    PRODUCT_NAME,
    PRODUCT_TYPE,
    PLANT_ID,
    DOSAGE_FORM,
    DATE(BATCH_DATE)                        AS BATCH_DATE,
    FINAL_DECISION,
    ML_PREDICTED_ACTION,
    RULE_OVERRIDE_REASON,
    ROUND(FAILURE_PROBABILITY, 4)           AS FAILURE_PROBABILITY,
    ROUND(RELEASE_SCORE, 4)                 AS RELEASE_SCORE,
    OVERALL_RISK_SCORE,
    TOP_RISK_FACTOR_1,
    TOTAL_COMMITTED_REVENUE,
    TOTAL_PENALTY_EXPOSURE,
    FINAL_REVENUE,
    FINAL_PROFIT,
    PENALTY_APPLIED
FROM GOLD_V2.BATCH_FACT
ORDER BY BATCH_DATE DESC, FAILURE_PROBABILITY DESC;

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLD_V2.VW_UI_KPI
-- Consumed by Streamlit KPI strip (top of dashboard)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW GOLD_V2.VW_UI_KPI
    COMMENT = 'Aggregate KPI view for Streamlit dashboard header strip.'
AS
SELECT
    COUNT(*)                                                        AS TOTAL_BATCHES,
    COUNT(CASE WHEN FINAL_DECISION = 'RELEASE' THEN 1 END)         AS RELEASE_READY,
    COUNT(CASE WHEN FINAL_DECISION = 'REJECT'  THEN 1 END)         AS REJECTED,
    COUNT(CASE WHEN FINAL_DECISION = 'HOLD'    THEN 1 END)         AS ON_HOLD,
    COUNT(CASE WHEN FINAL_DECISION = 'RETEST'  THEN 1 END)         AS RETEST_REQUIRED,
    COUNT(CASE WHEN RULE_OVERRIDE_REASON IS NOT NULL THEN 1 END)   AS ML_OVERRIDES,
    -- Financial KPIs
    ROUND(SUM(TOTAL_COMMITTED_REVENUE), 2)                         AS TOTAL_REVENUE,
    ROUND(SUM(TOTAL_MATERIAL_COST), 2)                             AS TOTAL_MATERIAL_COST,
    ROUND(SUM(FINAL_REVENUE), 2)                                   AS NET_REALISED_REVENUE,
    ROUND(SUM(FINAL_PROFIT), 2)                                    AS NET_PROFIT,
    ROUND(SUM(PENALTY_APPLIED), 2)                                 AS TOTAL_PENALTY,
    ROUND(SUM(TOTAL_PENALTY_EXPOSURE), 2)                          AS TOTAL_PENALTY_EXPOSURE,
    -- Quality KPIs
    ROUND(
        COUNT(CASE WHEN FINAL_DECISION = 'RELEASE' THEN 1 END)
        / NULLIF(COUNT(*), 0) * 100, 1
    )                                                               AS BATCH_PASS_RATE_PCT,
    ROUND(AVG(FAILURE_PROBABILITY) * 100, 1)                       AS AVG_FAILURE_PROBABILITY_PCT,
    ROUND(AVG(RELEASE_SCORE) * 100, 1)                             AS AVG_RELEASE_SCORE_PCT
FROM GOLD_V2.BATCH_FACT;

-- ─────────────────────────────────────────────────────────────────────────────
-- GOLD_V2.VW_UI_SIMULATION_BASE
-- Consumed by Streamlit Simulation Lab — provides mutable + fixed parameters
-- for a batch. Joins BATCH_FACT to FEAT_ML_INPUT for derived bucketed features.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW GOLD_V2.VW_UI_SIMULATION_BASE
    COMMENT = 'Simulation Lab base view. Exposes mutable quality parameters alongside fixed financial and FDA context for each batch.'
AS
SELECT
    bf.BATCH_ID,
    bf.PRODUCT_NAME,
    bf.PRODUCT_TYPE,
    bf.DOSAGE_FORM,
    bf.PLANT_ID,
    bf.BATCH_SIZE,
    bf.BATCH_DURATION_HOURS,
    bf.BATCH_DATE,
    -- ML baseline (original)
    bf.FAILURE_PROBABILITY          AS ORIG_FAILURE_PROB,
    bf.RELEASE_SCORE                AS ORIG_RELEASE_SCORE,
    bf.ML_PREDICTED_ACTION          AS ORIG_ML_DECISION,
    bf.FINAL_DECISION               AS ORIG_FINAL_DECISION,
    bf.RULE_OVERRIDE_REASON,
    -- Mutable quality parameters (changed in simulation)
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
    -- Fixed features (held constant during simulation)
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
    -- Fixed financial
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
    -- Fixed FDA
    bf.FDA_VIOLATION_COUNT,
    bf.FDA_CRITICAL_VIOLATIONS,
    bf.FDA_MAJOR_VIOLATIONS,
    bf.TOTAL_ESTIMATED_PENALTY_USD,
    bf.HAS_AUTO_BLOCK_RULE,
    bf.FDA_CRITICAL_RATE,
    -- Derived fixed features from FEAT_ML_INPUT (UDF needs these precomputed)
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
    -- P&L baseline
    bf.FINAL_REVENUE                AS ORIG_FINAL_REVENUE,
    bf.FINAL_PROFIT                 AS ORIG_FINAL_PROFIT,
    bf.PENALTY_APPLIED              AS ORIG_PENALTY_APPLIED,
    bf.OVERALL_RISK_SCORE,
    -- Revenue data quality flag
    CASE
        WHEN COALESCE(bf.TOTAL_COMMITTED_REVENUE, 0) > 0 THEN 'ACTUAL'
        ELSE 'ESTIMATED'
    END                             AS REVENUE_DATA_QUALITY
FROM GOLD_V2.BATCH_FACT bf
JOIN FEATURE_TEST.FEAT_ML_INPUT mi ON bf.BATCH_ID = mi.BATCH_ID;


-- =============================================================================
-- SECTION 12 — APPLICATION ROLE GRANTS
-- =============================================================================
-- PHARMA_ADMIN_ROLE : full read/write access including simulation log inserts
--                     and pipeline config management.
-- PHARMA_VIEWER_ROLE: read-only access to Gold views and KPI; cannot modify
--                     configuration or write to simulation log.
--
-- Schema USAGE grants allow navigation; object grants control actual access.

-- ── Schema USAGE ─────────────────────────────────────────────────────────────

GRANT USAGE ON SCHEMA APP_CONFIG   TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON SCHEMA RAW          TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON SCHEMA SILVER_TEST  TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON SCHEMA FEATURE_TEST TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON SCHEMA GOLD_V2      TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

GRANT USAGE ON SCHEMA GOLD_V2      TO APPLICATION ROLE PHARMA_VIEWER_ROLE;

-- ── Stage access ─────────────────────────────────────────────────────────────

GRANT READ   ON STAGE FEATURE_TEST.PHARMA_MODEL_STAGE TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT WRITE  ON STAGE FEATURE_TEST.PHARMA_MODEL_STAGE TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT READ   ON STAGE GOLD_V2.PHARMA_UI_STAGE          TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT WRITE  ON STAGE GOLD_V2.PHARMA_UI_STAGE          TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

GRANT READ   ON STAGE GOLD_V2.PHARMA_UI_STAGE          TO APPLICATION ROLE PHARMA_VIEWER_ROLE;

-- ── File format ──────────────────────────────────────────────────────────────

GRANT USAGE ON FILE FORMAT RAW.FF_CSV_STANDARD TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

-- ── APP_CONFIG grants ─────────────────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE ON TABLE APP_CONFIG.PIPELINE_CONFIG   TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT         ON TABLE APP_CONFIG.PIPELINE_RUN_LOG  TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

-- ── RAW table grants ─────────────────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE ON TABLE RAW.RAW_BATCH_MASTER         TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE ON TABLE RAW.RAW_SENSOR_READINGS      TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE ON TABLE RAW.RAW_LAB_TESTS            TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE ON TABLE RAW.RAW_DEVIATIONS           TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE ON TABLE RAW.RAW_AUDIT_TRAIL          TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE ON TABLE RAW.RAW_CUSTOMER_AGREEMENTS  TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE ON TABLE RAW.RAW_MATERIAL_ACQUISITION TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE ON TABLE RAW.RAW_FDA_PENALTIES        TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE ON TABLE RAW.RAW_BATCH_FULFILLMENT    TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

-- ── SILVER_TEST table grants ─────────────────────────────────────────────────

GRANT SELECT, INSERT ON TABLE SILVER_TEST.HUB_BATCH               TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.HUB_PRODUCT             TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.HUB_CUSTOMER            TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.HUB_AGREEMENT           TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.HUB_SENSOR              TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.HUB_LAB_TEST            TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.HUB_DEVIATION           TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.HUB_FDA_RULE            TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_BATCH               TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_PRODUCT             TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_CUSTOMER            TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_AGREEMENT           TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_BATCH_FULFILLMENT   TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_MATERIAL_COST       TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_FDA_RULE            TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_SENSOR              TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_LAB_TEST            TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.SAT_DEVIATION           TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

GRANT SELECT, INSERT ON TABLE SILVER_TEST.LNK_BATCH_PRODUCT       TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.LNK_CUSTOMER_AGREEMENT  TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.LNK_AGREEMENT_PRODUCT   TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.LNK_BATCH_AGREEMENT     TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.LNK_BATCH_SENSOR        TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.LNK_BATCH_LAB_TEST      TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.LNK_BATCH_DEVIATION     TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT ON TABLE SILVER_TEST.LNK_BATCH_FDA_RULE      TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

-- ── FEATURE_TEST table + UDF grants ──────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE FEATURE_TEST.FEAT_ML_INPUT               TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS    TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE FEATURE_TEST.FEAT_FINANCIAL_FEATURES     TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE FEATURE_TEST.FEAT_ML_ENHANCED            TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

-- NOTE: ML_CODE.PREDICT_BATCH_FAILURE_PROB resides in a versioned schema.
-- Objects in versioned schemas are automatically accessible to all application
-- roles — explicit GRANT statements are not supported and not needed.

-- ── GOLD_V2 table + view grants ───────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GOLD_V2.ML_PREDICTIONS       TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GOLD_V2.RULE_ENGINE_OVERRIDES TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE GOLD_V2.BATCH_FACT            TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT, INSERT                 ON TABLE GOLD_V2.BATCH_SIMULATION_LOG  TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

GRANT SELECT ON TABLE GOLD_V2.ML_PREDICTIONS        TO APPLICATION ROLE PHARMA_VIEWER_ROLE;
GRANT SELECT ON TABLE GOLD_V2.RULE_ENGINE_OVERRIDES TO APPLICATION ROLE PHARMA_VIEWER_ROLE;
GRANT SELECT ON TABLE GOLD_V2.BATCH_FACT            TO APPLICATION ROLE PHARMA_VIEWER_ROLE;

GRANT SELECT ON VIEW GOLD_V2.VW_UI_BATCH_LIST        TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT ON VIEW GOLD_V2.VW_UI_KPI               TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT SELECT ON VIEW GOLD_V2.VW_UI_SIMULATION_BASE   TO APPLICATION ROLE PHARMA_ADMIN_ROLE;

GRANT SELECT ON VIEW GOLD_V2.VW_UI_BATCH_LIST        TO APPLICATION ROLE PHARMA_VIEWER_ROLE;
GRANT SELECT ON VIEW GOLD_V2.VW_UI_KPI               TO APPLICATION ROLE PHARMA_VIEWER_ROLE;
GRANT SELECT ON VIEW GOLD_V2.VW_UI_SIMULATION_BASE   TO APPLICATION ROLE PHARMA_VIEWER_ROLE;

-- ── PHARMA_VIEWER_ROLE also needs READ on feature tables for Streamlit ────────

GRANT SELECT ON TABLE FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS TO APPLICATION ROLE PHARMA_VIEWER_ROLE;
GRANT SELECT ON TABLE FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES TO APPLICATION ROLE PHARMA_VIEWER_ROLE;

-- =============================================================================
-- SECTION 13 — STORED PROCEDURES
-- =============================================================================
-- SP_POST_INSTALL_SETUP  : Must be called once by the consumer immediately
--                          after installation. Copies the bundled model artefact
--                          from the app package read-only stage into the writable
--                          the bundled /artifacts/pharma_batch_model.pkl can be imported by the UDF.
--
-- SP_BUILD_SILVER        : Orchestrates the full Silver layer load in correct
--                          dependency order (Hubs → Sats → Links T1 → Links T2).
--                          Calls individual MERGE procedures per object.
--                          Logs each run to APP_CONFIG.PIPELINE_RUN_LOG.
--
-- SP_BUILD_FEATURE       : Orchestrates the Feature Engineering layer in correct
--                          dependency order (Steps 1-5 as per Phase 3 report).
--                          Logs each run to APP_CONFIG.PIPELINE_RUN_LOG.
--
-- SP_BUILD_GOLD          : Orchestrates the Gold layer refresh in correct
--                          dependency order: ML_PREDICTIONS → RULE_ENGINE_OVERRIDES
--                          → BATCH_FACT. Refreshes views (no-op — views are live).
--                          Logs each run to APP_CONFIG.PIPELINE_RUN_LOG.
--
-- SP_RUN_FULL_PIPELINE   : Top-level orchestrator. Calls Silver → Feature → Gold
--                          in sequence. Entry point for scheduled execution.
--
-- NOTE: All three pipeline procedures (SP_BUILD_SILVER, SP_BUILD_FEATURE,
--       SP_BUILD_GOLD) contain the complete transformation DML integrated from
--       01Silver_layer.sql, 01Featureenng_layer.sql, and 01Gold_LAYER.sql.
--       The full pipeline can be executed via:
--         CALL APP_CONFIG.SP_RUN_FULL_PIPELINE();
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SP_POST_INSTALL_SETUP
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE APP_CONFIG.SP_POST_INSTALL_SETUP()
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
COMMENT = 'Post-install setup: validates stage reachability, verifies ML UDF availability via versioned schema, confirms Streamlit assets, and logs the installation event. Call once after app installation before running any pipeline.'
EXECUTE AS OWNER
AS $$
    var steps = [];
    var errors = [];

    // ── Step 1: Verify PHARMA_MODEL_STAGE is accessible ──────────────────────
    try {
        var stageCheck = snowflake.execute({
            sqlText: "LIST @FEATURE_TEST.PHARMA_MODEL_STAGE"
        });
        steps.push("PHARMA_MODEL_STAGE: reachable");
    } catch (e) {
        errors.push("PHARMA_MODEL_STAGE not reachable: " + e.message);
    }

    // ── Step 2: Verify PHARMA_UI_STAGE is accessible ─────────────────────────
    try {
        var uiStageCheck = snowflake.execute({
            sqlText: "LIST @GOLD_V2.PHARMA_UI_STAGE"
        });
        steps.push("PHARMA_UI_STAGE: reachable");
    } catch (e) {
        errors.push("PHARMA_UI_STAGE not reachable: " + e.message);
    }

    // Step 3: Validate the ML UDF and force-load the bundled pickle artifact.
    try {
        snowflake.execute({
            sqlText: "DESCRIBE FUNCTION ML_CODE.PREDICT_BATCH_FAILURE_PROB(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,NUMBER,NUMBER,NUMBER,NUMBER,FLOAT,FLOAT,FLOAT,NUMBER,NUMBER,NUMBER,NUMBER,FLOAT,FLOAT,NUMBER,NUMBER,NUMBER,FLOAT,FLOAT,NUMBER,NUMBER,NUMBER,FLOAT,NUMBER,NUMBER,NUMBER,FLOAT,FLOAT,NUMBER,FLOAT,FLOAT,FLOAT,NUMBER,NUMBER,NUMBER,NUMBER)"
        });
        var udfSmoke = snowflake.execute({
            sqlText: "SELECT ML_CODE.PREDICT_BATCH_FAILURE_PROB('Oral Solid','PLT-MUMBAI','QA_REVIEW','LARGE','NORMAL',25,3,1,2,88.0,4.0,12.0,0,0,0,2,10.0,1.5,1,0,3,0.125,48.0,4,1,2,7.0,1,1,1,0.0008,0.25,2,5000.0,24.0,0.08,8,1,0,0) AS PROB"
        });
        udfSmoke.next();
        var smokeProb = udfSmoke.getColumnValue(1);
        if (smokeProb < 0 || smokeProb > 1) {
            errors.push("ML UDF smoke test returned out-of-range probability: " + smokeProb);
        } else {
            steps.push("ML_CODE.PREDICT_BATCH_FAILURE_PROB: UDF smoke test passed with bundled artifact");
        }
    } catch (e) {
        errors.push("ML UDF smoke test failed: " + e.message);
    }

    // Step 4: Confirm UI stage assets are present using LIST, not DIRECTORY().
    try {
        var uiFiles = snowflake.execute({ sqlText: "LIST @GOLD_V2.PHARMA_UI_STAGE" });
        var foundYaml = false;
        var foundImage = false;
        while (uiFiles.next()) {
            var listedName = String(uiFiles.getColumnValue(1)).toLowerCase();
            if (listedName.endsWith('/pharma_semantic_model.yaml') || listedName.endsWith('pharma_semantic_model.yaml')) {
                foundYaml = true;
            }
            if (listedName.endsWith('/stagesvg.png') || listedName.endsWith('stagesvg.png')) {
                foundImage = true;
            }
        }
        if (foundYaml) {
            steps.push("pharma_semantic_model.yaml: FOUND in PHARMA_UI_STAGE");
        } else {
            errors.push("pharma_semantic_model.yaml NOT FOUND in PHARMA_UI_STAGE. AI Co-Pilot feature will not function until this file is uploaded.");
        }
        if (foundImage) {
            steps.push("stagesvg.png: FOUND in PHARMA_UI_STAGE");
        } else {
            errors.push("stagesvg.png NOT FOUND in PHARMA_UI_STAGE. Landing page will use the bundled Streamlit copy if available.");
        }
    } catch (e) {
        errors.push("UI asset LIST check failed: " + e.message);
    }
    // Step 5: Log installation event ───────────────────────────────────────
    try {
        snowflake.execute({
            sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG (PIPELINE_LAYER, RUN_STATUS, ROWS_PROCESSED, COMPLETED_AT) VALUES ('INSTALL', 'COMPLETED', " + steps.length + ", CURRENT_TIMESTAMP())"
        });
        steps.push("Installation event logged to PIPELINE_RUN_LOG");
    } catch (e) {
        errors.push("Failed to write install log: " + e.message);
    }

    // ── Summary ───────────────────────────────────────────────────────────────
    var summary = "POST_INSTALL_SETUP COMPLETE\n";
    summary += "Steps completed: " + steps.length + "\n";
    summary += steps.join("\n") + "\n";
    if (errors.length > 0) {
        summary += "\nWARNINGS (" + errors.length + "):\n" + errors.join("\n");
    } else {
        summary += "\nAll checks passed. Application is ready to use.";
    }
    return summary;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- SP_BUILD_SILVER  (full DML implementation)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE APP_CONFIG.SP_BUILD_SILVER()
RETURNS VARIANT
LANGUAGE JAVASCRIPT
COMMENT = 'Orchestrates Silver layer load: Hubs → Satellites → Links Tier 1 → Links Tier 2. Full incremental DML from 01Silver_layer.sql.'
EXECUTE AS OWNER
AS $$
    var result = { layer: "SILVER", steps: [], errors: [], status: "STARTED" };
    var totalRows = 0;

    function execDML(label, sql) {
        var rs = snowflake.execute({ sqlText: sql });
        rs.next();
        var rowCount = rs.getColumnValue(1);
        totalRows += rowCount;
        result.steps.push({ object: label, status: "COMPLETED", rows_inserted: rowCount });
    }

    try {
        // Log start
        snowflake.execute({
            sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG (PIPELINE_LAYER, RUN_STATUS) VALUES ('SILVER', 'STARTED')"
        });

        // ══════════════════════════════════════════════════════════════════════
        // HUBS — DISTINCT business keys, no duplicates
        // ══════════════════════════════════════════════════════════════════════

        // ── HUB_BATCH ← RAW_BATCH_MASTER ────────────────────────────────────
        execDML("SILVER_TEST.HUB_BATCH",
            "INSERT INTO SILVER_TEST.HUB_BATCH (HK_BATCH, BATCH_ID, LOAD_DATE, RECORD_SOURCE) " +
            "SELECT SHA2(COALESCE(src.BATCH_ID, ''), 256) AS HK_BATCH, " +
            "src.BATCH_ID, src._RAW_LOAD_TS AS LOAD_DATE, 'MES::RAW_BATCH_MASTER' AS RECORD_SOURCE " +
            "FROM RAW.RAW_BATCH_MASTER src " +
            "WHERE src._RAW_LOAD_TS > (SELECT COALESCE(MAX(LOAD_DATE), '1900-01-01') FROM SILVER_TEST.HUB_BATCH) " +
            "AND NOT EXISTS (SELECT 1 FROM SILVER_TEST.HUB_BATCH tgt WHERE tgt.HK_BATCH = SHA2(COALESCE(src.BATCH_ID, ''), 256))"
        );

        // ── HUB_PRODUCT ← RAW_BATCH_MASTER ──────────────────────────────────
        execDML("SILVER_TEST.HUB_PRODUCT",
            "INSERT INTO SILVER_TEST.HUB_PRODUCT(HK_PRODUCT, PRODUCT_ID, LOAD_DATE, RECORD_SOURCE) " +
            "SELECT DISTINCT SHA2(PRODUCT_ID, 256) AS HK_PRODUCT, PRODUCT_ID, MIN(_RAW_LOAD_TS) AS LOAD_DATE, " +
            "'MES::RAW_BATCH_MASTER' AS RECORD_SOURCE FROM RAW.RAW_BATCH_MASTER " +
            "GROUP BY PRODUCT_ID HAVING SHA2(PRODUCT_ID, 256) NOT IN (SELECT HK_PRODUCT FROM SILVER_TEST.HUB_PRODUCT)"
        );

        // ── HUB_CUSTOMER ← RAW_CUSTOMER_AGREEMENTS ──────────────────────────
        execDML("SILVER_TEST.HUB_CUSTOMER",
            "INSERT INTO SILVER_TEST.HUB_CUSTOMER(HK_CUSTOMER, CUSTOMER_ID, LOAD_DATE, RECORD_SOURCE) " +
            "SELECT DISTINCT SHA2(CUSTOMER_ID, 256) AS HK_CUSTOMER, CUSTOMER_ID, MIN(_RAW_LOAD_TS) AS LOAD_DATE, " +
            "'CRM::RAW_CUSTOMER_AGREEMENTS' AS RECORD_SOURCE FROM RAW.RAW_CUSTOMER_AGREEMENTS " +
            "GROUP BY CUSTOMER_ID HAVING SHA2(CUSTOMER_ID, 256) NOT IN (SELECT HK_CUSTOMER FROM SILVER_TEST.HUB_CUSTOMER)"
        );

        // ── HUB_AGREEMENT ← RAW_CUSTOMER_AGREEMENTS ─────────────────────────
        execDML("SILVER_TEST.HUB_AGREEMENT",
            "INSERT INTO SILVER_TEST.HUB_AGREEMENT (HK_AGREEMENT, AGREEMENT_ID, LOAD_DATE, RECORD_SOURCE) " +
            "SELECT DISTINCT SHA2(AGREEMENT_ID, 256) AS HK_AGREEMENT, AGREEMENT_ID, _RAW_LOAD_TS AS LOAD_DATE, " +
            "'CRM::RAW_CUSTOMER_AGREEMENTS' AS RECORD_SOURCE FROM RAW.RAW_CUSTOMER_AGREEMENTS " +
            "WHERE SHA2(AGREEMENT_ID, 256) NOT IN (SELECT HK_AGREEMENT FROM SILVER_TEST.HUB_AGREEMENT)"
        );

        // ── HUB_SENSOR ← RAW_SENSOR_READINGS ────────────────────────────────
        execDML("SILVER_TEST.HUB_SENSOR",
            "INSERT INTO SILVER_TEST.HUB_SENSOR (HK_SENSOR, SENSOR_ID, LOAD_DATE, RECORD_SOURCE) " +
            "SELECT DISTINCT SHA2(SENSOR_ID, 256) AS HK_SENSOR, SENSOR_ID, MIN(_RAW_LOAD_TS) AS LOAD_DATE, " +
            "'IOT::RAW_SENSOR_READINGS' AS RECORD_SOURCE FROM RAW.RAW_SENSOR_READINGS " +
            "GROUP BY SENSOR_ID HAVING SHA2(SENSOR_ID, 256) NOT IN (SELECT HK_SENSOR FROM SILVER_TEST.HUB_SENSOR)"
        );

        // ── HUB_LAB_TEST ← RAW_LAB_TESTS ────────────────────────────────────
        execDML("SILVER_TEST.HUB_LAB_TEST",
            "INSERT INTO SILVER_TEST.HUB_LAB_TEST (HK_TEST, TEST_ID, LOAD_DATE, RECORD_SOURCE) " +
            "SELECT DISTINCT SHA2(TEST_ID, 256) AS HK_TEST, TEST_ID, _RAW_LOAD_TS AS LOAD_DATE, " +
            "'LIMS::RAW_LAB_TESTS' AS RECORD_SOURCE FROM RAW.RAW_LAB_TESTS " +
            "WHERE SHA2(TEST_ID, 256) NOT IN (SELECT HK_TEST FROM SILVER_TEST.HUB_LAB_TEST)"
        );

        // ── HUB_DEVIATION ← RAW_DEVIATIONS ──────────────────────────────────
        execDML("SILVER_TEST.HUB_DEVIATION",
            "INSERT INTO SILVER_TEST.HUB_DEVIATION (HK_DEVIATION, DEVIATION_ID, LOAD_DATE, RECORD_SOURCE) " +
            "SELECT DISTINCT SHA2(DEVIATION_ID, 256) AS HK_DEVIATION, DEVIATION_ID, _RAW_LOAD_TS AS LOAD_DATE, " +
            "'QA::RAW_DEVIATIONS' AS RECORD_SOURCE FROM RAW.RAW_DEVIATIONS " +
            "WHERE SHA2(DEVIATION_ID, 256) NOT IN (SELECT HK_DEVIATION FROM SILVER_TEST.HUB_DEVIATION)"
        );

        // ── HUB_FDA_RULE ← RAW_FDA_PENALTIES ────────────────────────────────
        execDML("SILVER_TEST.HUB_FDA_RULE",
            "INSERT INTO SILVER_TEST.HUB_FDA_RULE (HK_FDA_RULE, PENALTY_RULE_ID, LOAD_DATE, RECORD_SOURCE) " +
            "SELECT DISTINCT SHA2(PENALTY_RULE_ID, 256) AS HK_FDA_RULE, PENALTY_RULE_ID, _RAW_LOAD_TS AS LOAD_DATE, " +
            "'FDA::RAW_FDA_PENALTIES' AS RECORD_SOURCE FROM RAW.RAW_FDA_PENALTIES " +
            "WHERE SHA2(PENALTY_RULE_ID, 256) NOT IN (SELECT HK_FDA_RULE FROM SILVER_TEST.HUB_FDA_RULE)"
        );

        // ══════════════════════════════════════════════════════════════════════
        // SATELLITES — NOT EXISTS on (HK + LOAD_DATE) for historization
        // ══════════════════════════════════════════════════════════════════════

        // ── SAT_BATCH ← RAW_BATCH_MASTER ────────────────────────────────────
        execDML("SILVER_TEST.SAT_BATCH",
            "INSERT INTO SILVER_TEST.SAT_BATCH " +
            "(HK_BATCH, LOAD_DATE, RECORD_SOURCE, PLANT_ID, LINE_ID, BATCH_SIZE, BATCH_SIZE_UNIT, " +
            "START_TIME, END_TIME, PROCESS_STAGE, EQUIPMENT_ID, BATCH_STATUS) " +
            "SELECT SHA2(BATCH_ID, 256) AS HK_BATCH, _RAW_LOAD_TS AS LOAD_DATE, 'MES::RAW_BATCH_MASTER', " +
            "PLANT_ID, LINE_ID, BATCH_SIZE, BATCH_SIZE_UNIT, START_TIME, END_TIME, PROCESS_STAGE, EQUIPMENT_ID, BATCH_STATUS " +
            "FROM RAW.RAW_BATCH_MASTER src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.SAT_BATCH t WHERE t.HK_BATCH = SHA2(src.BATCH_ID, 256) AND t.LOAD_DATE = src._RAW_LOAD_TS)"
        );

        // ── SAT_PRODUCT ← RAW_BATCH_MASTER ──────────────────────────────────
        execDML("SILVER_TEST.SAT_PRODUCT",
            "INSERT INTO SILVER_TEST.SAT_PRODUCT (HK_PRODUCT, LOAD_DATE, RECORD_SOURCE, PRODUCT_NAME, PRODUCT_TYPE) " +
            "SELECT DISTINCT SHA2(PRODUCT_ID, 256) AS HK_PRODUCT, MIN(_RAW_LOAD_TS) AS LOAD_DATE, " +
            "'MES::RAW_BATCH_MASTER', PRODUCT_NAME, PRODUCT_TYPE FROM RAW.RAW_BATCH_MASTER src " +
            "GROUP BY PRODUCT_ID, PRODUCT_NAME, PRODUCT_TYPE " +
            "HAVING NOT EXISTS (SELECT 1 FROM SILVER_TEST.SAT_PRODUCT t WHERE t.HK_PRODUCT = SHA2(src.PRODUCT_ID, 256) AND t.PRODUCT_NAME = src.PRODUCT_NAME)"
        );

        // ── SAT_CUSTOMER ← RAW_CUSTOMER_AGREEMENTS ──────────────────────────
        execDML("SILVER_TEST.SAT_CUSTOMER",
            "INSERT INTO SILVER_TEST.SAT_CUSTOMER (HK_CUSTOMER, LOAD_DATE, RECORD_SOURCE, CUSTOMER_NAME, CUSTOMER_TYPE, REGULATORY_MARKET) " +
            "SELECT DISTINCT SHA2(CUSTOMER_ID, 256) AS HK_CUSTOMER, MIN(_RAW_LOAD_TS) AS LOAD_DATE, " +
            "'CRM::RAW_CUSTOMER_AGREEMENTS', CUSTOMER_NAME, CUSTOMER_TYPE, REGULATORY_MARKET " +
            "FROM RAW.RAW_CUSTOMER_AGREEMENTS src " +
            "GROUP BY CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_TYPE, REGULATORY_MARKET " +
            "HAVING NOT EXISTS (SELECT 1 FROM SILVER_TEST.SAT_CUSTOMER t WHERE t.HK_CUSTOMER = SHA2(src.CUSTOMER_ID, 256) AND t.CUSTOMER_NAME = src.CUSTOMER_NAME)"
        );

        // ── SAT_AGREEMENT ← RAW_CUSTOMER_AGREEMENTS ─────────────────────────
        execDML("SILVER_TEST.SAT_AGREEMENT",
            "INSERT INTO SILVER_TEST.SAT_AGREEMENT " +
            "(HK_AGREEMENT, LOAD_DATE, RECORD_SOURCE, AGREED_QTY, UNIT_PRICE, TOTAL_VALUE, " +
            "DELIVERY_DEADLINE, PENALTY_PCT_PER_DAY, MAX_PENALTY_PCT, STATUS) " +
            "SELECT SHA2(AGREEMENT_ID, 256) AS HK_AGREEMENT, _RAW_LOAD_TS AS LOAD_DATE, " +
            "'CRM::RAW_CUSTOMER_AGREEMENTS', AGREED_QTY, UNIT_PRICE, TOTAL_VALUE, " +
            "DELIVERY_DEADLINE, PENALTY_PCT_PER_DAY, MAX_PENALTY_PCT, STATUS " +
            "FROM RAW.RAW_CUSTOMER_AGREEMENTS src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.SAT_AGREEMENT t WHERE t.HK_AGREEMENT = SHA2(src.AGREEMENT_ID, 256) AND t.LOAD_DATE = src._RAW_LOAD_TS)"
        );

        // ── SAT_BATCH_FULFILLMENT ← RAW_BATCH_FULFILLMENT ───────────────────
        execDML("SILVER_TEST.SAT_BATCH_FULFILLMENT",
            "INSERT INTO SILVER_TEST.SAT_BATCH_FULFILLMENT " +
            "(HK_LNK_BATCH_AGR, LOAD_DATE, RECORD_SOURCE, FULFILLED_QTY, DELIVERY_STATUS, DELAY_DAYS, FULFILLMENT_DATE) " +
            "SELECT SHA2(BATCH_ID || '|' || AGREEMENT_ID || '|' || PRODUCT_ID, 256) AS HK_LNK_BATCH_AGR, " +
            "_RAW_LOAD_TS AS LOAD_DATE, 'ERP::RAW_BATCH_FULFILLMENT', FULFILLED_QTY, DELIVERY_STATUS, DELAY_DAYS, " +
            "TRY_TO_DATE(FULFILLMENT_DATE) AS FULFILLMENT_DATE FROM RAW.RAW_BATCH_FULFILLMENT src " +
            "WHERE BATCH_ID <> 'NO_BATCH_AVAILABLE' AND NOT EXISTS (" +
            "SELECT 1 FROM SILVER_TEST.SAT_BATCH_FULFILLMENT t " +
            "WHERE t.HK_LNK_BATCH_AGR = SHA2(src.BATCH_ID || '|' || src.AGREEMENT_ID || '|' || src.PRODUCT_ID, 256) " +
            "AND t.LOAD_DATE = src._RAW_LOAD_TS)"
        );

        // ── SAT_MATERIAL_COST ← RAW_MATERIAL_ACQUISITION ────────────────────
        execDML("SILVER_TEST.SAT_MATERIAL_COST",
            "INSERT INTO SILVER_TEST.SAT_MATERIAL_COST " +
            "(HK_BATCH, LOAD_DATE, RECORD_SOURCE, MATERIAL_CATEGORY, TOTAL_MATERIAL_COST, COST_PER_UNIT) " +
            "SELECT SHA2(BATCH_ID, 256) AS HK_BATCH, _RAW_LOAD_TS AS LOAD_DATE, " +
            "'ERP::RAW_MATERIAL_ACQUISITION', MATERIAL_CATEGORY, TOTAL_COST AS TOTAL_MATERIAL_COST, " +
            "TOTAL_COST / NULLIF(QUANTITY,0) AS COST_PER_UNIT FROM RAW.RAW_MATERIAL_ACQUISITION src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.SAT_MATERIAL_COST t " +
            "WHERE t.HK_BATCH = SHA2(src.BATCH_ID, 256) AND t.LOAD_DATE = src._RAW_LOAD_TS AND t.MATERIAL_CATEGORY = src.MATERIAL_CATEGORY)"
        );

        // ── SAT_FDA_RULE ← RAW_FDA_PENALTIES ────────────────────────────────
        execDML("SILVER_TEST.SAT_FDA_RULE",
            "INSERT INTO SILVER_TEST.SAT_FDA_RULE " +
            "(HK_FDA_RULE, LOAD_DATE, RECORD_SOURCE, CFR_REFERENCE, VIOLATION_TYPE, VIOLATION_CATEGORY, " +
            "APPLICABLE_PRODUCT_TYPE, PENALTY_TYPE, MIN_PENALTY_USD, MAX_PENALTY_USD, RECALL_CLASS, " +
            "BUSINESS_IMPACT, AUTO_BLOCK_RELEASE, MANDATORY_CAPA, REGULATORY_HOLD_DAYS, EFFECTIVE_DATE, IS_ACTIVE) " +
            "SELECT SHA2(PENALTY_RULE_ID, 256) AS HK_FDA_RULE, _RAW_LOAD_TS AS LOAD_DATE, " +
            "'FDA::RAW_FDA_PENALTIES', CFR_REFERENCE, VIOLATION_TYPE, VIOLATION_CATEGORY, " +
            "APPLICABLE_PRODUCT_TYPE, PENALTY_TYPE, MIN_PENALTY_USD, MAX_PENALTY_USD, RECALL_CLASS, " +
            "BUSINESS_IMPACT, AUTO_BLOCK_RELEASE, MANDATORY_CAPA, REGULATORY_HOLD_DAYS, EFFECTIVE_DATE, IS_ACTIVE " +
            "FROM RAW.RAW_FDA_PENALTIES src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.SAT_FDA_RULE t WHERE t.HK_FDA_RULE = SHA2(src.PENALTY_RULE_ID, 256) AND t.LOAD_DATE = src._RAW_LOAD_TS)"
        );

        // ── SAT_SENSOR ← RAW_SENSOR_READINGS ────────────────────────────────
        execDML("SILVER_TEST.SAT_SENSOR",
            "INSERT INTO SILVER_TEST.SAT_SENSOR (HK_SENSOR, LOAD_DATE, RECORD_SOURCE, SENSOR_TYPE, LOCATION) " +
            "SELECT DISTINCT SHA2(SENSOR_ID, 256) AS HK_SENSOR, MIN(_RAW_LOAD_TS) AS LOAD_DATE, " +
            "'IOT::RAW_SENSOR_READINGS', SENSOR_TYPE, LOCATION FROM RAW.RAW_SENSOR_READINGS src " +
            "GROUP BY SENSOR_ID, SENSOR_TYPE, LOCATION " +
            "HAVING NOT EXISTS (SELECT 1 FROM SILVER_TEST.SAT_SENSOR t WHERE t.HK_SENSOR = SHA2(src.SENSOR_ID, 256) AND t.SENSOR_TYPE = src.SENSOR_TYPE AND t.LOCATION = src.LOCATION)"
        );

        // ── SAT_LAB_TEST ← RAW_LAB_TESTS ────────────────────────────────────
        execDML("SILVER_TEST.SAT_LAB_TEST",
            "INSERT INTO SILVER_TEST.SAT_LAB_TEST " +
            "(HK_TEST, LOAD_DATE, RECORD_SOURCE, TEST_NAME, TEST_RESULT, TEST_STATUS, SPEC_MIN, SPEC_MAX) " +
            "SELECT SHA2(TEST_ID, 256) AS HK_TEST, _RAW_LOAD_TS AS LOAD_DATE, " +
            "'LIMS::RAW_LAB_TESTS', TEST_NAME, TEST_RESULT, RESULT_STATUS AS TEST_STATUS, SPEC_MIN, SPEC_MAX " +
            "FROM RAW.RAW_LAB_TESTS src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.SAT_LAB_TEST t WHERE t.HK_TEST = SHA2(src.TEST_ID, 256) AND t.LOAD_DATE = src._RAW_LOAD_TS)"
        );

        // ── SAT_DEVIATION ← RAW_DEVIATIONS ──────────────────────────────────
        execDML("SILVER_TEST.SAT_DEVIATION",
            "INSERT INTO SILVER_TEST.SAT_DEVIATION " +
            "(HK_DEVIATION, LOAD_DATE, RECORD_SOURCE, DEVIATION_TYPE, SEVERITY, ROOT_CAUSE, STATUS) " +
            "SELECT SHA2(DEVIATION_ID, 256) AS HK_DEVIATION, _RAW_LOAD_TS AS LOAD_DATE, " +
            "'QA::RAW_DEVIATIONS', DEVIATION_TYPE, SEVERITY, ROOT_CAUSE, CAPA_STATUS AS STATUS " +
            "FROM RAW.RAW_DEVIATIONS src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.SAT_DEVIATION t WHERE t.HK_DEVIATION = SHA2(src.DEVIATION_ID, 256) AND t.LOAD_DATE = src._RAW_LOAD_TS)"
        );

        // ══════════════════════════════════════════════════════════════════════
        // LINKS TIER 1 — Composite hash keys, no duplicates
        // ══════════════════════════════════════════════════════════════════════

        // ── LNK_BATCH_PRODUCT ← RAW_BATCH_MASTER ────────────────────────────
        execDML("SILVER_TEST.LNK_BATCH_PRODUCT",
            "INSERT INTO SILVER_TEST.LNK_BATCH_PRODUCT " +
            "SELECT SHA2(src.BATCH_ID || '|' || src.PRODUCT_ID, 256), SHA2(src.BATCH_ID, 256), " +
            "SHA2(src.PRODUCT_ID, 256), src._RAW_LOAD_TS, 'MES::RAW_BATCH_MASTER' " +
            "FROM RAW.RAW_BATCH_MASTER src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.LNK_BATCH_PRODUCT tgt " +
            "WHERE tgt.HK_LNK_BATCH_PRODUCT = SHA2(src.BATCH_ID || '|' || src.PRODUCT_ID, 256))"
        );

        // ── LNK_CUSTOMER_AGREEMENT ← RAW_CUSTOMER_AGREEMENTS ────────────────
        execDML("SILVER_TEST.LNK_CUSTOMER_AGREEMENT",
            "INSERT INTO SILVER_TEST.LNK_CUSTOMER_AGREEMENT " +
            "SELECT SHA2(src.CUSTOMER_ID || '|' || src.AGREEMENT_ID, 256), SHA2(src.CUSTOMER_ID, 256), " +
            "SHA2(src.AGREEMENT_ID, 256), src._RAW_LOAD_TS, 'CRM::RAW_CUSTOMER_AGREEMENTS' " +
            "FROM RAW.RAW_CUSTOMER_AGREEMENTS src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.LNK_CUSTOMER_AGREEMENT tgt " +
            "WHERE tgt.HK_LNK_CUST_AGR = SHA2(src.CUSTOMER_ID || '|' || src.AGREEMENT_ID, 256))"
        );

        // ── LNK_AGREEMENT_PRODUCT ← RAW_CUSTOMER_AGREEMENTS ─────────────────
        execDML("SILVER_TEST.LNK_AGREEMENT_PRODUCT",
            "INSERT INTO SILVER_TEST.LNK_AGREEMENT_PRODUCT " +
            "SELECT SHA2(src.AGREEMENT_ID || '|' || src.PRODUCT_ID, 256), SHA2(src.AGREEMENT_ID, 256), " +
            "SHA2(src.PRODUCT_ID, 256), src._RAW_LOAD_TS, 'CRM::RAW_CUSTOMER_AGREEMENTS' " +
            "FROM RAW.RAW_CUSTOMER_AGREEMENTS src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.LNK_AGREEMENT_PRODUCT tgt " +
            "WHERE tgt.HK_LNK_AGR_PROD = SHA2(src.AGREEMENT_ID || '|' || src.PRODUCT_ID, 256))"
        );

        // ── LNK_BATCH_AGREEMENT ← RAW_BATCH_FULFILLMENT ─────────────────────
        execDML("SILVER_TEST.LNK_BATCH_AGREEMENT",
            "INSERT INTO SILVER_TEST.LNK_BATCH_AGREEMENT " +
            "SELECT SHA2(src.BATCH_ID || '|' || src.AGREEMENT_ID || '|' || src.PRODUCT_ID, 256), " +
            "SHA2(src.BATCH_ID, 256), SHA2(src.AGREEMENT_ID, 256), SHA2(src.PRODUCT_ID, 256), " +
            "src._RAW_LOAD_TS, 'ERP::RAW_BATCH_FULFILLMENT' " +
            "FROM RAW.RAW_BATCH_FULFILLMENT src " +
            "WHERE src.BATCH_ID <> 'NO_BATCH_AVAILABLE' AND NOT EXISTS (" +
            "SELECT 1 FROM SILVER_TEST.LNK_BATCH_AGREEMENT tgt " +
            "WHERE tgt.HK_LNK_BATCH_AGR = SHA2(src.BATCH_ID || '|' || src.AGREEMENT_ID || '|' || src.PRODUCT_ID, 256))"
        );

        // ── LNK_BATCH_SENSOR ← RAW_SENSOR_READINGS (AGG) ────────────────────
        execDML("SILVER_TEST.LNK_BATCH_SENSOR",
            "INSERT INTO SILVER_TEST.LNK_BATCH_SENSOR " +
            "SELECT SHA2(src.BATCH_ID || '|' || src.SENSOR_ID, 256), SHA2(src.BATCH_ID, 256), " +
            "SHA2(src.SENSOR_ID, 256), MIN(src._RAW_LOAD_TS), 'IOT::RAW_SENSOR_READINGS' " +
            "FROM RAW.RAW_SENSOR_READINGS src GROUP BY src.BATCH_ID, src.SENSOR_ID " +
            "HAVING NOT EXISTS (SELECT 1 FROM SILVER_TEST.LNK_BATCH_SENSOR tgt " +
            "WHERE tgt.HK_LNK_BATCH_SENSOR = SHA2(src.BATCH_ID || '|' || src.SENSOR_ID, 256))"
        );

        // ── LNK_BATCH_LAB_TEST ← RAW_LAB_TESTS ─────────────────────────────
        execDML("SILVER_TEST.LNK_BATCH_LAB_TEST",
            "INSERT INTO SILVER_TEST.LNK_BATCH_LAB_TEST " +
            "SELECT SHA2(src.BATCH_ID || '|' || src.TEST_ID, 256), SHA2(src.BATCH_ID, 256), " +
            "SHA2(src.TEST_ID, 256), src._RAW_LOAD_TS, 'LIMS::RAW_LAB_TESTS' " +
            "FROM RAW.RAW_LAB_TESTS src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.LNK_BATCH_LAB_TEST tgt " +
            "WHERE tgt.HK_LNK_BATCH_TEST = SHA2(src.BATCH_ID || '|' || src.TEST_ID, 256))"
        );

        // ── LNK_BATCH_DEVIATION ← RAW_DEVIATIONS ────────────────────────────
        execDML("SILVER_TEST.LNK_BATCH_DEVIATION",
            "INSERT INTO SILVER_TEST.LNK_BATCH_DEVIATION " +
            "SELECT SHA2(src.BATCH_ID || '|' || src.DEVIATION_ID, 256), SHA2(src.BATCH_ID, 256), " +
            "SHA2(src.DEVIATION_ID, 256), src._RAW_LOAD_TS, 'QA::RAW_DEVIATIONS' " +
            "FROM RAW.RAW_DEVIATIONS src " +
            "WHERE NOT EXISTS (SELECT 1 FROM SILVER_TEST.LNK_BATCH_DEVIATION tgt " +
            "WHERE tgt.HK_LNK_BATCH_DEV = SHA2(src.BATCH_ID || '|' || src.DEVIATION_ID, 256))"
        );

        // ══════════════════════════════════════════════════════════════════════
        // LINKS TIER 2 — Rule engine (depends on all Hubs + Sats + Links T1)
        // ══════════════════════════════════════════════════════════════════════

        // ── LNK_BATCH_FDA_RULE ← Rule engine logic ──────────────────────────
        execDML("SILVER_TEST.LNK_BATCH_FDA_RULE",
            "INSERT INTO SILVER_TEST.LNK_BATCH_FDA_RULE " +
            "WITH batch_context AS ( " +
            "    SELECT hb.BATCH_ID, sp.PRODUCT_TYPE, sb.START_TIME, sb.END_TIME, " +
            "        COALESCE(DATEDIFF(HOUR, sb.START_TIME, sb.END_TIME), 1) AS BATCH_DURATION_HOURS " +
            "    FROM SILVER_TEST.HUB_BATCH hb " +
            "    JOIN SILVER_TEST.SAT_BATCH sb ON hb.HK_BATCH = sb.HK_BATCH " +
            "    LEFT JOIN SILVER_TEST.LNK_BATCH_PRODUCT lbp ON hb.HK_BATCH = lbp.HK_BATCH " +
            "    LEFT JOIN SILVER_TEST.SAT_PRODUCT sp ON lbp.HK_PRODUCT = sp.HK_PRODUCT " +
            "), " +
            "lab_failures AS ( " +
            "    SELECT hb.BATCH_ID, COUNT(*) AS FAIL_COUNT " +
            "    FROM SILVER_TEST.LNK_BATCH_LAB_TEST l " +
            "    JOIN SILVER_TEST.HUB_BATCH hb ON l.HK_BATCH = hb.HK_BATCH " +
            "    JOIN SILVER_TEST.SAT_LAB_TEST s ON l.HK_TEST = s.HK_TEST " +
            "    WHERE s.TEST_STATUS IN ('FAIL','OOS') GROUP BY hb.BATCH_ID " +
            "), " +
            "sensor_violations AS ( " +
            "    SELECT hb.BATCH_ID, COUNT(*) AS TOTAL_VIOLATIONS, " +
            "        COUNT_IF(s.SENSOR_TYPE = 'TEMP') AS TEMP_VIOLATIONS, " +
            "        COUNT_IF(s.SENSOR_TYPE = 'HUMIDITY') AS HUMIDITY_VIOLATIONS, " +
            "        COUNT_IF(s.SENSOR_TYPE = 'PRESSURE') AS PRESSURE_VIOLATIONS " +
            "    FROM SILVER_TEST.LNK_BATCH_SENSOR l " +
            "    JOIN SILVER_TEST.HUB_BATCH hb ON l.HK_BATCH = hb.HK_BATCH " +
            "    JOIN SILVER_TEST.SAT_SENSOR s ON l.HK_SENSOR = s.HK_SENSOR " +
            "    WHERE s.SENSOR_TYPE IS NOT NULL GROUP BY hb.BATCH_ID " +
            "), " +
            "deviations AS ( " +
            "    SELECT hb.BATCH_ID, COUNT(*) AS TOTAL_DEVIATIONS, " +
            "        COUNT_IF(s.SEVERITY = 'Critical') AS CRITICAL_DEVIATIONS, " +
            "        SUM(CASE WHEN s.SEVERITY = 'Critical' THEN 3 WHEN s.SEVERITY = 'High' THEN 2 ELSE 1 END) AS WEIGHTED_DEVIATION_SCORE " +
            "    FROM SILVER_TEST.LNK_BATCH_DEVIATION l " +
            "    JOIN SILVER_TEST.HUB_BATCH hb ON l.HK_BATCH = hb.HK_BATCH " +
            "    JOIN SILVER_TEST.SAT_DEVIATION s ON l.HK_DEVIATION = s.HK_DEVIATION " +
            "    GROUP BY hb.BATCH_ID " +
            "), " +
            "endotoxin AS ( " +
            "    SELECT hb.BATCH_ID, COUNT(*) AS ENDO_FAIL_COUNT " +
            "    FROM SILVER_TEST.LNK_BATCH_LAB_TEST l " +
            "    JOIN SILVER_TEST.HUB_BATCH hb ON l.HK_BATCH = hb.HK_BATCH " +
            "    JOIN SILVER_TEST.SAT_LAB_TEST s ON l.HK_TEST = s.HK_TEST " +
            "    WHERE s.TEST_NAME = 'Endotoxin Test' AND s.TEST_STATUS IN ('FAIL','OOS') " +
            "    GROUP BY hb.BATCH_ID " +
            "), " +
            "batch_violations AS ( " +
            "    SELECT bc.BATCH_ID, 'FDA-PEN-001' AS PENALTY_RULE_ID " +
            "    FROM batch_context bc JOIN lab_failures lf ON bc.BATCH_ID = lf.BATCH_ID " +
            "    WHERE lf.FAIL_COUNT >= 2 " +
            "    UNION " +
            "    SELECT bc.BATCH_ID, 'FDA-PEN-002' " +
            "    FROM batch_context bc JOIN sensor_violations sv ON bc.BATCH_ID = sv.BATCH_ID " +
            "    WHERE (sv.TOTAL_VIOLATIONS / NULLIF(bc.BATCH_DURATION_HOURS,1)) >= 2 " +
            "    UNION " +
            "    SELECT BATCH_ID, 'FDA-PEN-003' FROM deviations WHERE CRITICAL_DEVIATIONS >= 1 " +
            "    UNION " +
            "    SELECT BATCH_ID, 'FDA-PEN-005' FROM deviations WHERE TOTAL_DEVIATIONS >= 5 " +
            "    UNION " +
            "    SELECT BATCH_ID, 'FDA-PEN-009' FROM endotoxin WHERE ENDO_FAIL_COUNT >= 1 " +
            ") " +
            "SELECT SHA2(bv.BATCH_ID || '|' || bv.PENALTY_RULE_ID, 256) AS HK_LNK_BATCH_RULE, " +
            "    SHA2(bv.BATCH_ID, 256) AS HK_BATCH, " +
            "    SHA2(bv.PENALTY_RULE_ID, 256) AS HK_FDA_RULE, " +
            "    CURRENT_TIMESTAMP() AS LOAD_DATE, " +
            "    'RULES_ENGINE::FINAL_V2' AS RECORD_SOURCE " +
            "FROM batch_violations bv " +
            "JOIN SILVER_TEST.HUB_FDA_RULE hfr ON SHA2(bv.PENALTY_RULE_ID,256) = hfr.HK_FDA_RULE " +
            "JOIN SILVER_TEST.SAT_FDA_RULE sfr ON hfr.HK_FDA_RULE = sfr.HK_FDA_RULE " +
            "JOIN batch_context bc ON bc.BATCH_ID = bv.BATCH_ID " +
            "WHERE sfr.IS_ACTIVE = 'TRUE' " +
            "AND (sfr.APPLICABLE_PRODUCT_TYPE IS NULL OR sfr.APPLICABLE_PRODUCT_TYPE = bc.PRODUCT_TYPE)"
        );

        // ── Summary ─────────────────────────────────────────────────────────
        result.status = "COMPLETED";

        snowflake.execute({
            sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG " +
                     "(PIPELINE_LAYER, RUN_STATUS, ROWS_PROCESSED, COMPLETED_AT) " +
                     "VALUES ('SILVER', 'COMPLETED', " + totalRows + ", CURRENT_TIMESTAMP())"
        });

    } catch (e) {
        result.status = "FAILED";
        result.errors.push(e.message);
        try {
            snowflake.execute({
                sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG " +
                         "(PIPELINE_LAYER, RUN_STATUS, ERROR_MESSAGE, COMPLETED_AT) " +
                         "VALUES ('SILVER', 'FAILED', '" + e.message.replace(/'/g, "''") + "', CURRENT_TIMESTAMP())"
            });
        } catch (logErr) { /* logging should not mask original error */ }
    }

    return result;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- SP_BUILD_FEATURE  (full DML implementation)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE APP_CONFIG.SP_BUILD_FEATURE()
RETURNS VARIANT
LANGUAGE JAVASCRIPT
COMMENT = 'Orchestrates Feature Engineering layer in dependency order: FEAT_BATCH_QUALITY_FEATURES → FEAT_ML_INPUT → [FEAT_FDA_RULE_VIOLATIONS, FEAT_FINANCIAL_FEATURES, FEAT_ML_ENHANCED]. Full CTAS DML from 01Featureenng_layer.sql.'
EXECUTE AS OWNER
AS $$
    var result = { layer: "FEATURE", steps: [], errors: [], status: "STARTED" };
    var totalRows = 0;

    function execCTAS(label, sql) {
        snowflake.execute({ sqlText: sql });
        var cnt = snowflake.execute({ sqlText: "SELECT COUNT(*) FROM " + label });
        cnt.next();
        var rowCount = cnt.getColumnValue(1);
        totalRows += rowCount;
        result.steps.push({ object: label, status: "COMPLETED", rows_created: rowCount });
    }

    try {
        snowflake.execute({
            sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG (PIPELINE_LAYER, RUN_STATUS) VALUES ('FEATURE', 'STARTED')"
        });

        // ══════════════════════════════════════════════════════════════════════
        // Step 1 — FEAT_BATCH_QUALITY_FEATURES (must complete before Step 2)
        // ══════════════════════════════════════════════════════════════════════
        execCTAS("FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES",
            "CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES AS " +
            "WITH " +
            "lab_agg AS ( " +
            "    SELECT hb.BATCH_ID, COUNT(*) AS TOTAL_TESTS, " +
            "        SUM(CASE WHEN slt.TEST_STATUS = 'FAIL' THEN 1 ELSE 0 END) AS FAILED_TESTS, " +
            "        SUM(CASE WHEN slt.TEST_STATUS = 'OOS' THEN 1 ELSE 0 END) AS OOS_COUNT, " +
            "        SUM(CASE WHEN slt.TEST_STATUS = 'BORDERLINE' THEN 1 ELSE 0 END) AS BORDERLINE_COUNT, " +
            "        SUM(CASE WHEN slt.TEST_STATUS = 'PASS' THEN 1 ELSE 0 END) AS PASSED_TESTS, " +
            "        MAX(CASE WHEN UPPER(slt.TEST_NAME) LIKE '%STERILITY%' AND slt.TEST_STATUS IN ('FAIL','OOS') THEN 1 ELSE 0 END) AS STERILITY_FAIL_FLAG, " +
            "        MAX(CASE WHEN UPPER(slt.TEST_NAME) LIKE '%ENDOTOXIN%' AND slt.TEST_STATUS IN ('FAIL','OOS') THEN 1 ELSE 0 END) AS ENDOTOXIN_FAIL_FLAG, " +
            "        MAX(CASE WHEN UPPER(slt.TEST_NAME) LIKE '%POTENCY%' AND slt.TEST_STATUS IN ('FAIL','OOS') THEN 1 ELSE 0 END) AS POTENCY_FAIL_FLAG, " +
            "        AVG(CASE WHEN (slt.SPEC_MAX - slt.SPEC_MIN) > 0 THEN ABS(slt.TEST_RESULT - ((slt.SPEC_MAX + slt.SPEC_MIN) / 2.0)) / ((slt.SPEC_MAX - slt.SPEC_MIN) / 2.0) ELSE 0 END) AS AVG_SPEC_DISTANCE_NORMALIZED, " +
            "        0 AS REPEAT_TEST_COUNT " +
            "    FROM SILVER_TEST.HUB_BATCH hb " +
            "    JOIN SILVER_TEST.LNK_BATCH_LAB_TEST lblt ON hb.HK_BATCH = lblt.HK_BATCH " +
            "    JOIN SILVER_TEST.SAT_LAB_TEST slt ON lblt.HK_TEST = slt.HK_TEST " +
            "    GROUP BY hb.BATCH_ID " +
            "), " +
            "repeat_tests AS ( " +
            "    SELECT BATCH_ID, SUM(CASE WHEN UPPER(TRIM(REPEAT_TEST_FLAG)) = 'TRUE' THEN 1 ELSE 0 END) AS REPEAT_TEST_COUNT " +
            "    FROM RAW.RAW_LAB_TESTS GROUP BY BATCH_ID " +
            "), " +
            "sensor_agg AS ( " +
            "    SELECT hb.BATCH_ID, " +
            "        AVG(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP' THEN rsr.SENSOR_VALUE END) AS TEMP_AVG, " +
            "        STDDEV(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP' THEN rsr.SENSOR_VALUE END) AS TEMP_STDDEV, " +
            "        SUM(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP' AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE' THEN 1 ELSE 0 END) AS TEMP_VIOLATION_COUNT, " +
            "        AVG(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP' AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE' AND (rsr.THRESHOLD_MAX - rsr.THRESHOLD_MIN) > 0 THEN ABS(rsr.SENSOR_VALUE - ((rsr.THRESHOLD_MAX + rsr.THRESHOLD_MIN) / 2.0)) ELSE 0 END) AS AVG_TEMP_DEVIATION_C, " +
            "        SUM(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'TEMP' AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE' THEN 5 ELSE 0 END) AS TEMP_MAX_EXCURSION_MINS, " +
            "        SUM(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'HUMIDITY' AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE' THEN 1 ELSE 0 END) AS HUMIDITY_VIOLATION_COUNT, " +
            "        SUM(CASE WHEN UPPER(sr.SENSOR_TYPE) = 'PRESSURE' AND UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE' THEN 1 ELSE 0 END) AS PRESSURE_VIOLATION_COUNT, " +
            "        SUM(CASE WHEN UPPER(rsr.IS_OUT_OF_RANGE) = 'TRUE' THEN 1 ELSE 0 END) AS TOTAL_IOT_VIOLATIONS, " +
            "        COUNT(*) AS TOTAL_SENSOR_READINGS " +
            "    FROM SILVER_TEST.HUB_BATCH hb " +
            "    JOIN SILVER_TEST.LNK_BATCH_SENSOR lbs ON hb.HK_BATCH = lbs.HK_BATCH " +
            "    JOIN SILVER_TEST.HUB_SENSOR hs ON lbs.HK_SENSOR = hs.HK_SENSOR " +
            "    JOIN SILVER_TEST.SAT_SENSOR sr ON hs.HK_SENSOR = sr.HK_SENSOR " +
            "    JOIN RAW.RAW_SENSOR_READINGS rsr ON rsr.SENSOR_ID = hs.SENSOR_ID AND rsr.BATCH_ID = hb.BATCH_ID " +
            "    GROUP BY hb.BATCH_ID " +
            "), " +
            "deviation_agg AS ( " +
            "    SELECT hb.BATCH_ID, COUNT(*) AS TOTAL_DEVIATIONS, " +
            "        SUM(CASE WHEN UPPER(sd.SEVERITY) = 'CRITICAL' THEN 1 ELSE 0 END) AS CRITICAL_DEVIATION_COUNT, " +
            "        SUM(CASE WHEN UPPER(sd.SEVERITY) = 'HIGH' THEN 1 ELSE 0 END) AS HIGH_DEVIATION_COUNT, " +
            "        SUM(CASE WHEN UPPER(sd.SEVERITY) IN ('MEDIUM','LOW') THEN 1 ELSE 0 END) AS LOW_MED_DEVIATION_COUNT, " +
            "        SUM(CASE UPPER(sd.SEVERITY) WHEN 'CRITICAL' THEN 3 WHEN 'HIGH' THEN 2 ELSE 1 END) AS WEIGHTED_DEVIATION_SCORE, " +
            "        SUM(CASE WHEN UPPER(sd.DEVIATION_TYPE) LIKE '%PROCESS%' THEN 1 ELSE 0 END) AS PROCESS_DEVIATION_COUNT, " +
            "        SUM(CASE WHEN UPPER(sd.DEVIATION_TYPE) LIKE '%EQUIPMENT%' THEN 1 ELSE 0 END) AS EQUIPMENT_DEVIATION_COUNT, " +
            "        SUM(CASE WHEN UPPER(sd.DEVIATION_TYPE) LIKE '%HUMAN%' OR UPPER(sd.DEVIATION_TYPE) LIKE '%OPERATOR%' THEN 1 ELSE 0 END) AS HUMAN_DEVIATION_COUNT, " +
            "        SUM(CASE WHEN UPPER(sd.DEVIATION_TYPE) LIKE '%ENVIRONMENT%' THEN 1 ELSE 0 END) AS ENV_DEVIATION_COUNT " +
            "    FROM SILVER_TEST.HUB_BATCH hb " +
            "    JOIN SILVER_TEST.LNK_BATCH_DEVIATION lbd ON hb.HK_BATCH = lbd.HK_BATCH " +
            "    JOIN SILVER_TEST.SAT_DEVIATION sd ON lbd.HK_DEVIATION = sd.HK_DEVIATION " +
            "    GROUP BY hb.BATCH_ID " +
            "), " +
            "batch_duration AS ( " +
            "    SELECT hb.BATCH_ID, COALESCE(DATEDIFF(HOUR, sb.START_TIME, sb.END_TIME), 8) AS BATCH_DURATION_HOURS, " +
            "        sb.BATCH_SIZE, sb.BATCH_SIZE_UNIT, sb.PROCESS_STAGE, sb.PLANT_ID, sb.LINE_ID " +
            "    FROM SILVER_TEST.HUB_BATCH hb JOIN SILVER_TEST.SAT_BATCH sb ON hb.HK_BATCH = sb.HK_BATCH " +
            "    QUALIFY ROW_NUMBER() OVER (PARTITION BY hb.BATCH_ID ORDER BY sb.LOAD_DATE DESC) = 1 " +
            "), " +
            "product_info AS ( " +
            "    SELECT hb.BATCH_ID, sp.PRODUCT_TYPE, sp.PRODUCT_NAME " +
            "    FROM SILVER_TEST.HUB_BATCH hb " +
            "    JOIN SILVER_TEST.LNK_BATCH_PRODUCT lbp ON hb.HK_BATCH = lbp.HK_BATCH " +
            "    JOIN SILVER_TEST.SAT_PRODUCT sp ON lbp.HK_PRODUCT = sp.HK_PRODUCT " +
            "    QUALIFY ROW_NUMBER() OVER (PARTITION BY hb.BATCH_ID ORDER BY sp.LOAD_DATE DESC) = 1 " +
            ") " +
            "SELECT bd.BATCH_ID, bd.PLANT_ID, bd.PROCESS_STAGE, pi.PRODUCT_TYPE, pi.PRODUCT_NAME, bd.BATCH_DURATION_HOURS, bd.BATCH_SIZE, " +
            "    COALESCE(la.TOTAL_TESTS, 0) AS TOTAL_TESTS, COALESCE(la.FAILED_TESTS, 0) AS FAILED_TESTS, " +
            "    COALESCE(la.OOS_COUNT, 0) AS OOS_COUNT, COALESCE(la.BORDERLINE_COUNT, 0) AS BORDERLINE_COUNT, " +
            "    COALESCE(la.PASSED_TESTS, 0) AS PASSED_TESTS, " +
            "    ROUND(COALESCE(la.PASSED_TESTS, 0) / NULLIF(COALESCE(la.TOTAL_TESTS, 0), 0) * 100.0, 2) AS PASS_RATE_PCT, " +
            "    ROUND(COALESCE(la.OOS_COUNT, 0) / NULLIF(COALESCE(la.TOTAL_TESTS, 0), 0), 4) AS OOS_RATE_PCT, " +
            "    ROUND(COALESCE(la.FAILED_TESTS, 0) / NULLIF(COALESCE(la.TOTAL_TESTS, 0), 0), 4) AS FAIL_RATE_PCT, " +
            "    COALESCE(la.STERILITY_FAIL_FLAG, 0) AS STERILITY_FAIL_FLAG, " +
            "    COALESCE(la.ENDOTOXIN_FAIL_FLAG, 0) AS ENDOTOXIN_FAIL_FLAG, " +
            "    COALESCE(la.POTENCY_FAIL_FLAG, 0) AS POTENCY_FAIL_FLAG, " +
            "    COALESCE(la.STERILITY_FAIL_FLAG, 0) * COALESCE(la.ENDOTOXIN_FAIL_FLAG, 0) AS STERILITY_X_ENDOTOXIN, " +
            "    COALESCE(la.AVG_SPEC_DISTANCE_NORMALIZED, 0) AS AVG_SPEC_DISTANCE_NORMALIZED, " +
            "    COALESCE(rt.REPEAT_TEST_COUNT, 0) AS REPEAT_TEST_COUNT, " +
            "    COALESCE(sa.TEMP_VIOLATION_COUNT, 0) AS TEMP_VIOLATION_COUNT, " +
            "    COALESCE(sa.HUMIDITY_VIOLATION_COUNT, 0) AS HUMIDITY_VIOLATION_COUNT, " +
            "    COALESCE(sa.PRESSURE_VIOLATION_COUNT, 0) AS PRESSURE_VIOLATION_COUNT, " +
            "    COALESCE(sa.TOTAL_IOT_VIOLATIONS, 0) AS TOTAL_IOT_VIOLATIONS, " +
            "    COALESCE(sa.AVG_TEMP_DEVIATION_C, 0.0) AS AVG_TEMP_DEVIATION_C, " +
            "    COALESCE(sa.TEMP_MAX_EXCURSION_MINS, 0) AS TEMP_MAX_EXCURSION_MINS, " +
            "    COALESCE(sa.TOTAL_SENSOR_READINGS, 1) AS TOTAL_SENSOR_READINGS, " +
            "    ROUND(COALESCE(sa.TOTAL_IOT_VIOLATIONS, 0) / NULLIF(COALESCE(sa.TOTAL_SENSOR_READINGS, 1), 0), 4) AS IOT_VIOLATION_DENSITY, " +
            "    ROUND(COALESCE(sa.TEMP_VIOLATION_COUNT, 0) * COALESCE(bd.BATCH_DURATION_HOURS, 8.0), 2) AS TEMP_X_DURATION, " +
            "    COALESCE(da.TOTAL_DEVIATIONS, 0) AS TOTAL_DEVIATIONS, " +
            "    COALESCE(da.CRITICAL_DEVIATION_COUNT, 0) AS CRITICAL_DEVIATION_COUNT, " +
            "    COALESCE(da.HIGH_DEVIATION_COUNT, 0) AS HIGH_DEVIATION_COUNT, " +
            "    COALESCE(da.LOW_MED_DEVIATION_COUNT, 0) AS LOW_MED_DEVIATION_COUNT, " +
            "    COALESCE(da.WEIGHTED_DEVIATION_SCORE, 0) AS WEIGHTED_DEVIATION_SCORE, " +
            "    COALESCE(da.PROCESS_DEVIATION_COUNT, 0) AS PROCESS_DEVIATION_COUNT, " +
            "    COALESCE(da.EQUIPMENT_DEVIATION_COUNT, 0) AS EQUIPMENT_DEVIATION_COUNT, " +
            "    COALESCE(da.HUMAN_DEVIATION_COUNT, 0) AS HUMAN_DEVIATION_COUNT, " +
            "    COALESCE(da.ENV_DEVIATION_COUNT, 0) AS ENV_DEVIATION_COUNT, " +
            "    ROUND(COALESCE(da.TOTAL_DEVIATIONS, 0) / NULLIF(COALESCE(bd.BATCH_DURATION_HOURS, 8.0), 0), 4) AS DEVIATION_DENSITY, " +
            "    ROUND(COALESCE(da.CRITICAL_DEVIATION_COUNT, 0) / NULLIF(COALESCE(da.TOTAL_DEVIATIONS, 0), 0), 4) AS CRITICAL_DEV_RATE, " +
            "    COALESCE(sa.TEMP_VIOLATION_COUNT, 0) * COALESCE(da.CRITICAL_DEVIATION_COUNT, 0) AS TEMP_X_CRITICAL_DEV, " +
            "    ROUND(COALESCE(sa.TEMP_STDDEV, 0) / NULLIF(ABS(COALESCE(sa.TEMP_AVG, 1)), 0), 4) AS PROCESS_VARIANCE, " +
            "    CURRENT_TIMESTAMP() AS FEATURE_COMPUTED_AT " +
            "FROM batch_duration bd " +
            "LEFT JOIN product_info pi ON bd.BATCH_ID = pi.BATCH_ID " +
            "LEFT JOIN lab_agg la ON bd.BATCH_ID = la.BATCH_ID " +
            "LEFT JOIN repeat_tests rt ON bd.BATCH_ID = rt.BATCH_ID " +
            "LEFT JOIN sensor_agg sa ON bd.BATCH_ID = sa.BATCH_ID " +
            "LEFT JOIN deviation_agg da ON bd.BATCH_ID = da.BATCH_ID"
        );

        // ══════════════════════════════════════════════════════════════════════
        // Step 2 — FEAT_ML_INPUT (depends on Step 1)
        // ══════════════════════════════════════════════════════════════════════
        execCTAS("FEATURE_TEST.FEAT_ML_INPUT",
            "CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_ML_INPUT AS " +
            "WITH batch_time AS ( " +
            "    SELECT BATCH_ID, START_TIME, PRODUCT_ID, PLANT_ID, BATCH_SIZE, " +
            "        HOUR(START_TIME) AS BATCH_START_HOUR, DAYOFWEEK(START_TIME) AS BATCH_START_DOW, " +
            "        CASE WHEN DAYOFWEEK(START_TIME) IN (6, 7) THEN 1 ELSE 0 END AS IS_WEEKEND_BATCH, " +
            "        CASE WHEN HOUR(START_TIME) >= 22 OR HOUR(START_TIME) < 6 THEN 1 ELSE 0 END AS IS_NIGHT_SHIFT " +
            "    FROM RAW.RAW_BATCH_MASTER " +
            "    QUALIFY ROW_NUMBER() OVER (PARTITION BY BATCH_ID ORDER BY _RAW_LOAD_TS DESC) = 1 " +
            ") " +
            "SELECT qf.BATCH_ID, qf.PRODUCT_TYPE, qf.PLANT_ID, " +
            "    CASE WHEN qf.BATCH_SIZE < 100 THEN 'SMALL' WHEN qf.BATCH_SIZE < 500 THEN 'MEDIUM' WHEN qf.BATCH_SIZE < 1000 THEN 'LARGE' ELSE 'XLARGE' END AS BATCH_SIZE_BUCKET, " +
            "    CASE WHEN qf.BATCH_DURATION_HOURS < 4 THEN 'SHORT' WHEN qf.BATCH_DURATION_HOURS < 10 THEN 'NORMAL' WHEN qf.BATCH_DURATION_HOURS < 16 THEN 'LONG' ELSE 'EXTENDED' END AS DURATION_BUCKET, " +
            "    qf.TOTAL_TESTS, qf.FAILED_TESTS, qf.OOS_COUNT, qf.BORDERLINE_COUNT, " +
            "    qf.PASS_RATE_PCT, qf.OOS_RATE_PCT, qf.FAIL_RATE_PCT, " +
            "    qf.STERILITY_FAIL_FLAG, qf.ENDOTOXIN_FAIL_FLAG, qf.STERILITY_X_ENDOTOXIN, " +
            "    qf.TEMP_VIOLATION_COUNT, qf.TEMP_MAX_EXCURSION_MINS, qf.AVG_TEMP_DEVIATION_C, " +
            "    qf.HUMIDITY_VIOLATION_COUNT, qf.PRESSURE_VIOLATION_COUNT, " +
            "    qf.TOTAL_IOT_VIOLATIONS, qf.IOT_VIOLATION_DENSITY, qf.TEMP_X_DURATION, " +
            "    qf.TOTAL_DEVIATIONS, qf.CRITICAL_DEVIATION_COUNT, qf.HIGH_DEVIATION_COUNT, " +
            "    qf.WEIGHTED_DEVIATION_SCORE, qf.PROCESS_DEVIATION_COUNT, " +
            "    qf.EQUIPMENT_DEVIATION_COUNT, qf.HUMAN_DEVIATION_COUNT, " +
            "    qf.DEVIATION_DENSITY, qf.CRITICAL_DEV_RATE, qf.TEMP_X_CRITICAL_DEV, " +
            "    qf.BATCH_SIZE, qf.BATCH_DURATION_HOURS, qf.PROCESS_VARIANCE, " +
            "    bt.BATCH_START_HOUR, bt.BATCH_START_DOW, bt.IS_WEEKEND_BATCH, bt.IS_NIGHT_SHIFT, " +
            "    CURRENT_TIMESTAMP() AS FEATURE_COMPUTED_AT " +
            "FROM FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES qf " +
            "LEFT JOIN batch_time bt ON qf.BATCH_ID = bt.BATCH_ID"
        );

        // ══════════════════════════════════════════════════════════════════════
        // Step 3 — FEAT_FDA_RULE_VIOLATIONS (depends on Steps 1-2)
        // ══════════════════════════════════════════════════════════════════════
        execCTAS("FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS",
            "CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS AS " +
            "WITH fda_rules AS ( " +
            "    SELECT hfr.PENALTY_RULE_ID, sfr.CFR_REFERENCE, sfr.VIOLATION_TYPE, sfr.VIOLATION_CATEGORY, " +
            "        sfr.APPLICABLE_PRODUCT_TYPE, sfr.PENALTY_TYPE, sfr.MIN_PENALTY_USD, sfr.MAX_PENALTY_USD, " +
            "        CASE WHEN UPPER(sfr.AUTO_BLOCK_RELEASE) = 'TRUE' THEN TRUE ELSE FALSE END AS AUTO_BLOCK_RELEASE, " +
            "        CASE WHEN UPPER(sfr.MANDATORY_CAPA) = 'TRUE' THEN TRUE ELSE FALSE END AS MANDATORY_CAPA, " +
            "        sfr.REGULATORY_HOLD_DAYS, sfr.RECALL_CLASS, sfr.BUSINESS_IMPACT, sfr.IS_ACTIVE " +
            "    FROM SILVER_TEST.HUB_FDA_RULE hfr " +
            "    JOIN SILVER_TEST.SAT_FDA_RULE sfr ON hfr.HK_FDA_RULE = sfr.HK_FDA_RULE " +
            "    WHERE UPPER(sfr.IS_ACTIVE) = 'TRUE' " +
            "    QUALIFY ROW_NUMBER() OVER (PARTITION BY hfr.PENALTY_RULE_ID ORDER BY sfr.LOAD_DATE DESC) = 1 " +
            "), " +
            "batch_quality AS ( " +
            "    SELECT qf.BATCH_ID, qf.PRODUCT_TYPE, qf.FAILED_TESTS, qf.OOS_COUNT, " +
            "        qf.STERILITY_FAIL_FLAG, qf.ENDOTOXIN_FAIL_FLAG, qf.TEMP_VIOLATION_COUNT, " +
            "        qf.PRESSURE_VIOLATION_COUNT, qf.CRITICAL_DEVIATION_COUNT, qf.TOTAL_DEVIATIONS, " +
            "        qf.IOT_VIOLATION_DENSITY, qf.BATCH_DURATION_HOURS, qf.TOTAL_IOT_VIOLATIONS " +
            "    FROM FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES qf " +
            "), " +
            "triggered_rules AS ( " +
            "    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID FROM batch_quality bq " +
            "    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-001' " +
            "    WHERE (bq.FAILED_TESTS + bq.OOS_COUNT) >= 2 " +
            "      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE) " +
            "    UNION " +
            "    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID FROM batch_quality bq " +
            "    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-002' " +
            "    WHERE (bq.TOTAL_IOT_VIOLATIONS / NULLIF(bq.BATCH_DURATION_HOURS, 1)) >= 2 " +
            "      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE) " +
            "    UNION " +
            "    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID FROM batch_quality bq " +
            "    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-003' " +
            "    WHERE bq.CRITICAL_DEVIATION_COUNT >= 1 " +
            "      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE) " +
            "    UNION " +
            "    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID FROM batch_quality bq " +
            "    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-005' " +
            "    WHERE bq.TOTAL_DEVIATIONS >= 5 " +
            "      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE) " +
            "    UNION " +
            "    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID FROM batch_quality bq " +
            "    JOIN fda_rules fr ON fr.PENALTY_RULE_ID = 'FDA-PEN-009' " +
            "    WHERE bq.ENDOTOXIN_FAIL_FLAG = 1 " +
            "      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE) " +
            "    UNION " +
            "    SELECT bq.BATCH_ID, fr.PENALTY_RULE_ID FROM batch_quality bq " +
            "    JOIN fda_rules fr ON fr.PENALTY_RULE_ID NOT IN ('FDA-PEN-001','FDA-PEN-002','FDA-PEN-003','FDA-PEN-005','FDA-PEN-009') " +
            "      AND fr.AUTO_BLOCK_RELEASE = TRUE " +
            "    WHERE bq.STERILITY_FAIL_FLAG = 1 " +
            "      AND (fr.APPLICABLE_PRODUCT_TYPE IS NULL OR fr.APPLICABLE_PRODUCT_TYPE = bq.PRODUCT_TYPE) " +
            ") " +
            "SELECT tr.BATCH_ID, fr.PENALTY_RULE_ID, fr.CFR_REFERENCE, fr.VIOLATION_TYPE, fr.VIOLATION_CATEGORY, " +
            "    fr.PENALTY_TYPE, fr.AUTO_BLOCK_RELEASE, fr.MANDATORY_CAPA, fr.REGULATORY_HOLD_DAYS, " +
            "    fr.RECALL_CLASS, fr.BUSINESS_IMPACT, " +
            "    ROUND((COALESCE(fr.MIN_PENALTY_USD, 0) + COALESCE(fr.MAX_PENALTY_USD, 0)) / 2.0, 2) AS ESTIMATED_PENALTY_USD, " +
            "    CURRENT_TIMESTAMP() AS FEATURE_COMPUTED_AT " +
            "FROM triggered_rules tr JOIN fda_rules fr ON tr.PENALTY_RULE_ID = fr.PENALTY_RULE_ID"
        );

        // ══════════════════════════════════════════════════════════════════════
        // Step 4 — FEAT_FINANCIAL_FEATURES (depends on Steps 1-2)
        // ══════════════════════════════════════════════════════════════════════
        execCTAS("FEATURE_TEST.FEAT_FINANCIAL_FEATURES",
            "CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_FINANCIAL_FEATURES AS " +
            "WITH all_batches AS ( " +
            "    SELECT DISTINCT hb.BATCH_ID, hb.HK_BATCH FROM SILVER_TEST.HUB_BATCH hb " +
            "), " +
            "fulfillment_revenue AS ( " +
            "    SELECT rbf.BATCH_ID, " +
            "        SUM(COALESCE(rbf.FULFILLED_QTY, 0) * COALESCE(rca.UNIT_PRICE, 0)) AS FULFILLED_REVENUE, " +
            "        SUM(COALESCE(rbf.DELAY_DAYS, 0) * COALESCE(rca.PENALTY_PCT_PER_DAY, 0) / 100.0 * COALESCE(rca.TOTAL_VALUE, 0)) AS FULFILLMENT_PENALTY " +
            "    FROM RAW.RAW_BATCH_FULFILLMENT rbf " +
            "    LEFT JOIN RAW.RAW_CUSTOMER_AGREEMENTS rca ON rbf.AGREEMENT_ID = rca.AGREEMENT_ID " +
            "    WHERE rbf.BATCH_ID IS NOT NULL AND rbf.BATCH_ID <> 'NO_BATCH_AVAILABLE' " +
            "    GROUP BY rbf.BATCH_ID " +
            "), " +
            "product_batch_counts AS ( " +
            "    SELECT rbm.PRODUCT_ID, COUNT(DISTINCT rbm.BATCH_ID) AS BATCH_COUNT " +
            "    FROM RAW.RAW_BATCH_MASTER rbm WHERE rbm.PRODUCT_ID IS NOT NULL GROUP BY rbm.PRODUCT_ID " +
            "), " +
            "agreement_revenue AS ( " +
            "    SELECT rbm.BATCH_ID, " +
            "        SUM(COALESCE(rca.TOTAL_VALUE, 0) / NULLIF(pbc.BATCH_COUNT, 0)) AS AGR_COMMITTED_REVENUE, " +
            "        SUM(COALESCE(rca.TOTAL_VALUE, 0) * COALESCE(rca.MAX_PENALTY_PCT, 0) / 100.0 / NULLIF(pbc.BATCH_COUNT, 0)) AS AGR_PENALTY_EXPOSURE " +
            "    FROM RAW.RAW_BATCH_MASTER rbm " +
            "    JOIN RAW.RAW_CUSTOMER_AGREEMENTS rca ON rbm.PRODUCT_ID = rca.PRODUCT_ID AND UPPER(rca.STATUS) NOT IN ('CANCELLED', 'EXPIRED') " +
            "    JOIN product_batch_counts pbc ON rbm.PRODUCT_ID = pbc.PRODUCT_ID " +
            "    GROUP BY rbm.BATCH_ID " +
            "), " +
            "material_cost AS ( " +
            "    SELECT hb.BATCH_ID, hb.HK_BATCH, SUM(COALESCE(smc.TOTAL_MATERIAL_COST, 0)) AS TOTAL_MATERIAL_COST " +
            "    FROM SILVER_TEST.HUB_BATCH hb JOIN SILVER_TEST.SAT_MATERIAL_COST smc ON hb.HK_BATCH = smc.HK_BATCH " +
            "    GROUP BY hb.BATCH_ID, hb.HK_BATCH " +
            "), " +
            "combined AS ( " +
            "    SELECT ab.BATCH_ID, ab.HK_BATCH, " +
            "        COALESCE(NULLIF(fr.FULFILLED_REVENUE, 0), ar.AGR_COMMITTED_REVENUE, 0) AS TOTAL_COMMITTED_REVENUE, " +
            "        COALESCE(mc.TOTAL_MATERIAL_COST, 0) AS TOTAL_MATERIAL_COST, " +
            "        COALESCE(NULLIF(fr.FULFILLMENT_PENALTY, 0), ar.AGR_PENALTY_EXPOSURE, 0) AS TOTAL_PENALTY_EXPOSURE " +
            "    FROM all_batches ab " +
            "    LEFT JOIN fulfillment_revenue fr ON ab.BATCH_ID = fr.BATCH_ID " +
            "    LEFT JOIN agreement_revenue ar ON ab.BATCH_ID = ar.BATCH_ID " +
            "    LEFT JOIN material_cost mc ON ab.BATCH_ID = mc.BATCH_ID " +
            ") " +
            "SELECT c.BATCH_ID, " +
            "    ROUND(c.TOTAL_COMMITTED_REVENUE, 2) AS TOTAL_COMMITTED_REVENUE, " +
            "    ROUND(c.TOTAL_MATERIAL_COST, 2) AS TOTAL_MATERIAL_COST, " +
            "    ROUND(c.TOTAL_COMMITTED_REVENUE - c.TOTAL_MATERIAL_COST, 2) AS GROSS_MARGIN, " +
            "    ROUND(CASE WHEN c.TOTAL_COMMITTED_REVENUE > 0 THEN (c.TOTAL_COMMITTED_REVENUE - c.TOTAL_MATERIAL_COST) / c.TOTAL_COMMITTED_REVENUE * 100.0 ELSE 0 END, 2) AS GROSS_MARGIN_PCT, " +
            "    ROUND(c.TOTAL_PENALTY_EXPOSURE, 2) AS TOTAL_PENALTY_EXPOSURE, " +
            "    ROUND(CASE WHEN c.TOTAL_COMMITTED_REVENUE > 0 THEN c.TOTAL_MATERIAL_COST / c.TOTAL_COMMITTED_REVENUE ELSE 0 END, 4) AS COST_PER_BATCH_UNIT, " +
            "    ROUND(CASE WHEN c.TOTAL_COMMITTED_REVENUE > 0 THEN c.TOTAL_PENALTY_EXPOSURE / c.TOTAL_COMMITTED_REVENUE ELSE 0 END, 4) AS PENALTY_TO_REVENUE_RATIO, " +
            "    CURRENT_TIMESTAMP() AS FEATURE_COMPUTED_AT " +
            "FROM combined c"
        );

        // ══════════════════════════════════════════════════════════════════════
        // Step 5 — FEAT_ML_ENHANCED (depends on Step 2)
        // ══════════════════════════════════════════════════════════════════════
        execCTAS("FEATURE_TEST.FEAT_ML_ENHANCED",
            "CREATE OR REPLACE TABLE FEATURE_TEST.FEAT_ML_ENHANCED AS " +
            "WITH batch_time AS ( " +
            "    SELECT BATCH_ID, START_TIME, " +
            "        HOUR(START_TIME) AS BATCH_START_HOUR, DAYOFWEEK(START_TIME) AS BATCH_START_DOW, " +
            "        CASE WHEN DAYOFWEEK(START_TIME) IN (6, 7) THEN 1 ELSE 0 END AS IS_WEEKEND_BATCH, " +
            "        CASE WHEN HOUR(START_TIME) >= 22 OR HOUR(START_TIME) < 6 THEN 1 ELSE 0 END AS IS_NIGHT_SHIFT " +
            "    FROM RAW.RAW_BATCH_MASTER " +
            "    QUALIFY ROW_NUMBER() OVER (PARTITION BY BATCH_ID ORDER BY _RAW_LOAD_TS DESC) = 1 " +
            "), " +
            "fulfillment_metrics AS ( " +
            "    SELECT rbf.BATCH_ID, COUNT(*) AS TOTAL_DELIVERIES, " +
            "        SUM(CASE WHEN UPPER(COALESCE(rbf.DELIVERY_STATUS,'')) IN ('ON_TIME','DELIVERED','ON TIME') THEN 1 ELSE 0 END) AS ON_TIME_COUNT, " +
            "        SUM(CASE WHEN UPPER(COALESCE(rbf.DELIVERY_STATUS,'')) LIKE '%DELAY%' THEN 1 ELSE 0 END) AS DELAYED_DELIVERIES, " +
            "        SUM(CASE WHEN UPPER(COALESCE(rbf.DELIVERY_STATUS,'')) IN ('FAILED','REJECTED','NOT_DELIVERED') THEN 1 ELSE 0 END) AS FAILED_DELIVERIES " +
            "    FROM RAW.RAW_BATCH_FULFILLMENT rbf " +
            "    WHERE rbf.BATCH_ID IS NOT NULL AND rbf.BATCH_ID <> 'NO_BATCH_AVAILABLE' " +
            "    GROUP BY rbf.BATCH_ID " +
            ") " +
            "SELECT mi.BATCH_ID, bt.BATCH_START_HOUR, bt.BATCH_START_DOW, bt.IS_WEEKEND_BATCH, bt.IS_NIGHT_SHIFT, " +
            "    COALESCE(fm.TOTAL_DELIVERIES, 0) AS TOTAL_DELIVERIES, " +
            "    COALESCE(fm.DELAYED_DELIVERIES, 0) AS DELAYED_DELIVERIES, " +
            "    COALESCE(fm.FAILED_DELIVERIES, 0) AS FAILED_DELIVERIES, " +
            "    ROUND(COALESCE(fm.ON_TIME_COUNT, 0) / NULLIF(COALESCE(fm.TOTAL_DELIVERIES, 0), 0) * 100.0, 2) AS ON_TIME_RATE_PCT, " +
            "    CURRENT_TIMESTAMP() AS FEATURE_COMPUTED_AT " +
            "FROM FEATURE_TEST.FEAT_ML_INPUT mi " +
            "LEFT JOIN batch_time bt ON mi.BATCH_ID = bt.BATCH_ID " +
            "LEFT JOIN fulfillment_metrics fm ON mi.BATCH_ID = fm.BATCH_ID"
        );

        // ── Summary ─────────────────────────────────────────────────────────
        result.status = "COMPLETED";

        snowflake.execute({
            sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG " +
                     "(PIPELINE_LAYER, RUN_STATUS, ROWS_PROCESSED, COMPLETED_AT) " +
                     "VALUES ('FEATURE', 'COMPLETED', " + totalRows + ", CURRENT_TIMESTAMP())"
        });

    } catch (e) {
        result.status = "FAILED";
        result.errors.push(e.message);
        try {
            snowflake.execute({
                sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG " +
                         "(PIPELINE_LAYER, RUN_STATUS, ERROR_MESSAGE, COMPLETED_AT) " +
                         "VALUES ('FEATURE', 'FAILED', '" + e.message.replace(/'/g, "''") + "', CURRENT_TIMESTAMP())"
            });
        } catch (logErr) { /* logging should not mask original error */ }
    }

    return result;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- SP_BUILD_GOLD  (full DML implementation)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE APP_CONFIG.SP_BUILD_GOLD()
RETURNS VARIANT
LANGUAGE JAVASCRIPT
COMMENT = 'Orchestrates Gold layer refresh: ML_PREDICTIONS → RULE_ENGINE_OVERRIDES → BATCH_FACT. Views are live — no refresh needed. Full CTAS DML from 01Gold_LAYER.sql.'
EXECUTE AS OWNER
AS $$
    var result = { layer: "GOLD", steps: [], errors: [], status: "STARTED" };
    var totalRows = 0;

    function execCTAS(label, sql) {
        snowflake.execute({ sqlText: sql });
        var cnt = snowflake.execute({ sqlText: "SELECT COUNT(*) FROM " + label });
        cnt.next();
        var rowCount = cnt.getColumnValue(1);
        totalRows += rowCount;
        result.steps.push({ object: label, status: "COMPLETED", rows_created: rowCount });
    }

    try {
        snowflake.execute({
            sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG (PIPELINE_LAYER, RUN_STATUS) VALUES ('GOLD', 'STARTED')"
        });

        // ══════════════════════════════════════════════════════════════════════
        // Step 1 — ML_PREDICTIONS (XGBoost UDF over FEAT_ML_INPUT)
        // ══════════════════════════════════════════════════════════════════════
        execCTAS("GOLD_V2.ML_PREDICTIONS",
            "CREATE OR REPLACE TABLE GOLD_V2.ML_PREDICTIONS AS " +
            "WITH ml_base AS ( " +
            "    SELECT mi.BATCH_ID, sb.BATCH_STATUS, " +
            "        ML_CODE.PREDICT_BATCH_FAILURE_PROB( " +
            "            mi.PRODUCT_TYPE, mi.PLANT_ID, sb.BATCH_STATUS, mi.BATCH_SIZE_BUCKET, mi.DURATION_BUCKET, " +
            "            mi.TOTAL_TESTS, mi.FAILED_TESTS, mi.OOS_COUNT, mi.BORDERLINE_COUNT, " +
            "            mi.PASS_RATE_PCT, mi.OOS_RATE_PCT, mi.FAIL_RATE_PCT, " +
            "            mi.STERILITY_FAIL_FLAG, mi.ENDOTOXIN_FAIL_FLAG, mi.STERILITY_X_ENDOTOXIN, " +
            "            mi.TEMP_VIOLATION_COUNT, mi.TEMP_MAX_EXCURSION_MINS, mi.AVG_TEMP_DEVIATION_C, " +
            "            mi.HUMIDITY_VIOLATION_COUNT, mi.PRESSURE_VIOLATION_COUNT, " +
            "            mi.TOTAL_IOT_VIOLATIONS, mi.IOT_VIOLATION_DENSITY, mi.TEMP_X_DURATION, " +
            "            mi.TOTAL_DEVIATIONS, mi.CRITICAL_DEVIATION_COUNT, mi.HIGH_DEVIATION_COUNT, " +
            "            mi.WEIGHTED_DEVIATION_SCORE, mi.PROCESS_DEVIATION_COUNT, " +
            "            mi.EQUIPMENT_DEVIATION_COUNT, mi.HUMAN_DEVIATION_COUNT, " +
            "            mi.DEVIATION_DENSITY, mi.CRITICAL_DEV_RATE, mi.TEMP_X_CRITICAL_DEV, " +
            "            mi.BATCH_SIZE, mi.BATCH_DURATION_HOURS, mi.PROCESS_VARIANCE, " +
            "            mi.BATCH_START_HOUR, mi.BATCH_START_DOW, mi.IS_WEEKEND_BATCH, mi.IS_NIGHT_SHIFT " +
            "        ) AS ML_FAILURE_PROB " +
            "    FROM FEATURE_TEST.FEAT_ML_INPUT mi " +
            "    JOIN SILVER_TEST.HUB_BATCH hb ON mi.BATCH_ID = hb.BATCH_ID " +
            "    JOIN SILVER_TEST.SAT_BATCH sb ON hb.HK_BATCH = sb.HK_BATCH " +
            ") " +
            "SELECT BATCH_ID, CURRENT_TIMESTAMP() AS PREDICTION_TS, ML_FAILURE_PROB, " +
            "    1.0 - ML_FAILURE_PROB AS ML_RELEASE_SCORE, " +
            "    CASE WHEN ML_FAILURE_PROB <= 0.20 THEN 'RELEASE' " +
            "         WHEN ML_FAILURE_PROB <= 0.40 THEN 'RETEST' " +
            "         WHEN ML_FAILURE_PROB <= 0.65 THEN 'HOLD' " +
            "         ELSE 'REJECT' END AS ML_PREDICTED_ACTION " +
            "FROM ml_base"
        );

        // ══════════════════════════════════════════════════════════════════════
        // Step 2 — RULE_ENGINE_OVERRIDES (aggregates FEAT_FDA_RULE_VIOLATIONS)
        // ══════════════════════════════════════════════════════════════════════
        execCTAS("GOLD_V2.RULE_ENGINE_OVERRIDES",
            "CREATE OR REPLACE TABLE GOLD_V2.RULE_ENGINE_OVERRIDES AS " +
            "SELECT fv.BATCH_ID, " +
            "    MAX(CASE WHEN fv.AUTO_BLOCK_RELEASE THEN 1 ELSE 0 END) AS HAS_AUTO_BLOCK_RULE, " +
            "    MAX(CASE WHEN fv.MANDATORY_CAPA THEN 1 ELSE 0 END) AS HAS_MANDATORY_CAPA, " +
            "    MAX(COALESCE(fv.REGULATORY_HOLD_DAYS, 0)) AS MAX_HOLD_DAYS, " +
            "    COUNT(*) AS FDA_VIOLATION_COUNT, " +
            "    COUNT(CASE WHEN fv.VIOLATION_CATEGORY = 'CRITICAL' THEN 1 END) AS FDA_CRITICAL_VIOLATIONS, " +
            "    COUNT(CASE WHEN fv.VIOLATION_CATEGORY = 'MAJOR' THEN 1 END) AS FDA_MAJOR_VIOLATIONS, " +
            "    SUM(COALESCE(fv.ESTIMATED_PENALTY_USD, 0)) AS TOTAL_ESTIMATED_PENALTY_USD, " +
            "    MAX(CASE WHEN fv.VIOLATION_CATEGORY = 'CRITICAL' THEN fv.CFR_REFERENCE END) AS CRITICAL_CFR_REFERENCE, " +
            "    ROUND(COUNT(CASE WHEN fv.VIOLATION_CATEGORY = 'CRITICAL' THEN 1 END) / NULLIF(COUNT(*), 0), 4) AS FDA_CRITICAL_RATE " +
            "FROM FEATURE_TEST.FEAT_FDA_RULE_VIOLATIONS fv GROUP BY fv.BATCH_ID"
        );

        // ══════════════════════════════════════════════════════════════════════
        // Step 3 — BATCH_FACT (Core Gold Table — ML + Rules + Financial + Quality)
        // ══════════════════════════════════════════════════════════════════════
        execCTAS("GOLD_V2.BATCH_FACT",
            "CREATE OR REPLACE TABLE GOLD_V2.BATCH_FACT AS " +
            "WITH batch_meta AS ( " +
            "    SELECT rbm.BATCH_ID, rbm.PRODUCT_ID, rbm.BATCH_SIZE, rbm.PLANNED_RELEASE_DATE AS BATCH_DATE, rbm.BATCH_STATUS, " +
            "        COALESCE(sp.PRODUCT_NAME, rbm.PRODUCT_ID) AS PRODUCT_NAME, sp.PRODUCT_TYPE, " +
            "        CASE WHEN sp.PRODUCT_TYPE ILIKE '%Oral%' THEN 'Tablet' " +
            "             WHEN sp.PRODUCT_TYPE ILIKE '%Injection%' THEN 'Injectable' " +
            "             WHEN sp.PRODUCT_TYPE ILIKE '%Vaccine%' THEN 'Vaccine' " +
            "             WHEN sp.PRODUCT_TYPE ILIKE '%Topical%' THEN 'Topical' " +
            "             WHEN sp.PRODUCT_TYPE ILIKE '%Biologic%' THEN 'Biologic' " +
            "             ELSE 'Other' END AS DOSAGE_FORM, " +
            "        NULL AS THERAPEUTIC_AREA, rbm.PLANT_ID " +
            "    FROM RAW.RAW_BATCH_MASTER rbm " +
            "    LEFT JOIN SILVER_TEST.HUB_PRODUCT hp ON rbm.PRODUCT_ID = hp.PRODUCT_ID " +
            "    LEFT JOIN SILVER_TEST.SAT_PRODUCT sp ON hp.HK_PRODUCT = sp.HK_PRODUCT " +
            "    QUALIFY ROW_NUMBER() OVER (PARTITION BY rbm.BATCH_ID ORDER BY rbm._RAW_LOAD_TS DESC) = 1 " +
            "), " +
            "top_deviations AS ( " +
            "    SELECT hb.BATCH_ID, sd.DEVIATION_TYPE AS DEVIATION_DESCRIPTION, " +
            "        ROW_NUMBER() OVER (PARTITION BY hb.BATCH_ID ORDER BY " +
            "            CASE sd.DEVIATION_TYPE WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MAJOR' THEN 3 ELSE 4 END, " +
            "            sd.LOAD_DATE DESC) AS DEV_RANK " +
            "    FROM SILVER_TEST.HUB_BATCH hb " +
            "    JOIN SILVER_TEST.LNK_BATCH_DEVIATION lbd ON hb.HK_BATCH = lbd.HK_BATCH " +
            "    JOIN SILVER_TEST.SAT_DEVIATION sd ON lbd.HK_DEVIATION = sd.HK_DEVIATION " +
            "    QUALIFY DEV_RANK <= 3 " +
            "), " +
            "dev_pivot AS ( " +
            "    SELECT BATCH_ID, " +
            "        MAX(CASE WHEN DEV_RANK = 1 THEN DEVIATION_DESCRIPTION END) AS DEVIATION_1_NAME, " +
            "        MAX(CASE WHEN DEV_RANK = 2 THEN DEVIATION_DESCRIPTION END) AS DEVIATION_2_NAME, " +
            "        MAX(CASE WHEN DEV_RANK = 3 THEN DEVIATION_DESCRIPTION END) AS DEVIATION_3_NAME " +
            "    FROM top_deviations GROUP BY BATCH_ID " +
            "), " +
            "risk_tags AS ( " +
            "    SELECT q.BATCH_ID, " +
            "        CASE WHEN q.STERILITY_FAIL_FLAG = 1 THEN 'Sterility Failure (21 CFR 211.113)' " +
            "             WHEN q.TEMP_VIOLATION_COUNT >= 5 THEN 'Temperature Excursions (21 CFR 211.68)' " +
            "             WHEN q.CRITICAL_DEVIATION_COUNT >= 2 THEN 'Critical Deviations (ICH Q9)' " +
            "             WHEN q.OOS_COUNT >= 3 THEN 'OOS Results (21 CFR 211.192)' " +
            "             WHEN q.PASS_RATE_PCT <= 80 THEN 'High Failure Rate (21 CFR 211.165)' " +
            "             ELSE 'Process Non-Conformance' END AS TOP_RISK_FACTOR_1, " +
            "        CASE WHEN q.HUMIDITY_VIOLATION_COUNT >= 3 THEN 'Humidity Violations (21 CFR 211.68)' " +
            "             WHEN q.HIGH_DEVIATION_COUNT >= 3 THEN 'High Deviations (ICH Q10)' " +
            "             WHEN q.PROCESS_VARIANCE >= 0.3 THEN 'High Process Variance' " +
            "             WHEN q.ENDOTOXIN_FAIL_FLAG = 1 THEN 'Endotoxin Failure (USP <85>)' " +
            "             ELSE 'Borderline Quality Readings' END AS TOP_RISK_FACTOR_2, " +
            "        CASE WHEN q.PRESSURE_VIOLATION_COUNT >= 2 THEN 'Pressure Violations (21 CFR 211.68)' " +
            "             WHEN q.EQUIPMENT_DEVIATION_COUNT >= 2 THEN 'Equipment Deviations (21 CFR 211.68)' " +
            "             WHEN q.HUMAN_DEVIATION_COUNT >= 2 THEN 'Human Error Deviations (21 CFR 211.68)' " +
            "             WHEN q.BORDERLINE_COUNT >= 5 THEN 'Multiple Borderline Results' " +
            "             ELSE 'Process Monitoring Required' END AS TOP_RISK_FACTOR_3 " +
            "    FROM FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES q " +
            "), " +
            "ai_reason AS ( " +
            "    SELECT ml.BATCH_ID, " +
            "        CASE " +
            "            WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 " +
            "                THEN 'MANDATORY REJECT: Sterility and endotoxin failures detected. 21 CFR 211.113 requires immediate batch rejection. CAPA and full investigation mandatory before any future release.' " +
            "            WHEN ro.HAS_AUTO_BLOCK_RULE = 1 " +
            "                THEN 'RULE OVERRIDE: FDA auto-block rule triggered (' || COALESCE(ro.CRITICAL_CFR_REFERENCE, 'see violation log') || '). ML predicted ' || ml.ML_PREDICTED_ACTION || ' but regulatory rule mandates REJECT.' " +
            "            WHEN ro.FDA_CRITICAL_VIOLATIONS >= 3 " +
            "                THEN 'HIGH REGULATORY RISK: ' || ro.FDA_CRITICAL_VIOLATIONS::VARCHAR || ' critical FDA violations detected. Batch escalated from ML prediction of ' || ml.ML_PREDICTED_ACTION || ' to REJECT. Root cause analysis required under ICH Q9.' " +
            "            WHEN ml.ML_FAILURE_PROB <= 0.20 " +
            "                THEN 'RELEASE RECOMMENDED: XGBoost model assigns ' || ROUND(ml.ML_FAILURE_PROB * 100, 1)::VARCHAR || '% failure probability. All quality parameters within acceptable ranges. No FDA violations that override release.' " +
            "            WHEN ml.ML_FAILURE_PROB <= 0.40 " +
            "                THEN 'RETEST RECOMMENDED: Failure probability of ' || ROUND(ml.ML_FAILURE_PROB * 100, 1)::VARCHAR || '% is borderline. Additional testing recommended before final release decision.' " +
            "            WHEN ml.ML_FAILURE_PROB <= 0.65 " +
            "                THEN 'HOLD RECOMMENDED: ' || ROUND(ml.ML_FAILURE_PROB * 100, 1)::VARCHAR || '% failure probability indicates significant quality concerns. Batch held pending full QA investigation per ICH Q10.' " +
            "            ELSE 'REJECT RECOMMENDED: XGBoost model assigns ' || ROUND(ml.ML_FAILURE_PROB * 100, 1)::VARCHAR || '% failure probability - exceeds 65% rejection threshold. Multiple quality signals indicate batch does not meet release criteria.' " +
            "        END AS AI_DECISION_REASON " +
            "    FROM GOLD_V2.ML_PREDICTIONS ml " +
            "    JOIN FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES qi ON ml.BATCH_ID = qi.BATCH_ID " +
            "    LEFT JOIN GOLD_V2.RULE_ENGINE_OVERRIDES ro ON ml.BATCH_ID = ro.BATCH_ID " +
            "), " +
            "financial_impact AS ( " +
            "    SELECT ff.BATCH_ID, ff.TOTAL_COMMITTED_REVENUE, ff.TOTAL_MATERIAL_COST, " +
            "        ff.GROSS_MARGIN, ff.GROSS_MARGIN_PCT, ff.TOTAL_PENALTY_EXPOSURE, " +
            "        me.ON_TIME_RATE_PCT, me.DELAYED_DELIVERIES, me.FAILED_DELIVERIES, " +
            "        ROUND(CASE WHEN ff.TOTAL_COMMITTED_REVENUE > 0 " +
            "            THEN LEAST((ff.TOTAL_PENALTY_EXPOSURE / ff.TOTAL_COMMITTED_REVENUE) * 0.6 + (1 - COALESCE(me.ON_TIME_RATE_PCT, 100) / 100.0) * 0.4, 1.0) " +
            "            ELSE 0.5 END, 4) AS FINANCIAL_RISK_SCORE, " +
            "        CASE WHEN ff.TOTAL_COMMITTED_REVENUE > 0 THEN ROUND(ff.TOTAL_MATERIAL_COST / ff.TOTAL_COMMITTED_REVENUE, 4) ELSE 0 END AS COST_PER_BATCH_UNIT, " +
            "        CASE WHEN ff.TOTAL_COMMITTED_REVENUE > 0 THEN ROUND(ff.TOTAL_PENALTY_EXPOSURE / ff.TOTAL_COMMITTED_REVENUE, 4) ELSE 0 END AS PENALTY_TO_REVENUE_RATIO, " +
            "        NULL AS OVERALL_RISK_SCORE " +
            "    FROM FEATURE_TEST.FEAT_FINANCIAL_FEATURES ff " +
            "    LEFT JOIN FEATURE_TEST.FEAT_ML_ENHANCED me ON ff.BATCH_ID = me.BATCH_ID " +
            ") " +
            "SELECT bm.BATCH_ID, bm.PRODUCT_NAME, bm.PRODUCT_TYPE, bm.DOSAGE_FORM, bm.THERAPEUTIC_AREA, bm.PLANT_ID, bm.BATCH_SIZE, bm.BATCH_DATE, bm.BATCH_STATUS, " +
            "    ml.ML_FAILURE_PROB AS FAILURE_PROBABILITY, ml.ML_RELEASE_SCORE AS RELEASE_SCORE, ml.ML_PREDICTED_ACTION, " +
            "    COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) AS HAS_AUTO_BLOCK_RULE, " +
            "    COALESCE(ro.FDA_VIOLATION_COUNT, 0) AS FDA_VIOLATION_COUNT, " +
            "    COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) AS FDA_CRITICAL_VIOLATIONS, " +
            "    COALESCE(ro.FDA_MAJOR_VIOLATIONS, 0) AS FDA_MAJOR_VIOLATIONS, " +
            "    COALESCE(ro.TOTAL_ESTIMATED_PENALTY_USD, 0) AS TOTAL_ESTIMATED_PENALTY_USD, " +
            "    COALESCE(ro.MAX_HOLD_DAYS, 0) AS REGULATORY_HOLD_DAYS, " +
            "    COALESCE(ro.FDA_CRITICAL_RATE, 0) AS FDA_CRITICAL_RATE, " +
            "    ro.CRITICAL_CFR_REFERENCE, " +
            "    CASE " +
            "        WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT' " +
            "        WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT' " +
            "        WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT' " +
            "        WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD' " +
            "        ELSE ml.ML_PREDICTED_ACTION END AS FINAL_DECISION, " +
            "    CASE " +
            "        WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'STERILITY_HARD_RULE' " +
            "        WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'FDA_AUTO_BLOCK' " +
            "        WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'CRITICAL_VIOLATIONS' " +
            "        WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD_DAYS_APPLIED' " +
            "        ELSE NULL END AS RULE_OVERRIDE_REASON, " +
            "    qi.TOTAL_TESTS, qi.FAILED_TESTS AS FAILED_TEST_COUNT, qi.OOS_COUNT, qi.BORDERLINE_COUNT, " +
            "    qi.PASS_RATE_PCT AS FE_PASS_RATE_PCT, qi.STERILITY_FAIL_FLAG, qi.ENDOTOXIN_FAIL_FLAG, " +
            "    qi.TEMP_VIOLATION_COUNT, qi.HUMIDITY_VIOLATION_COUNT, qi.PRESSURE_VIOLATION_COUNT, " +
            "    qi.CRITICAL_DEVIATION_COUNT, qi.HIGH_DEVIATION_COUNT, qi.TOTAL_DEVIATIONS, " +
            "    qi.PROCESS_VARIANCE, qi.WEIGHTED_DEVIATION_SCORE, " +
            "    qi.PROCESS_DEVIATION_COUNT, qi.EQUIPMENT_DEVIATION_COUNT, qi.HUMAN_DEVIATION_COUNT, " +
            "    qi.AVG_TEMP_DEVIATION_C, qi.BATCH_DURATION_HOURS, " +
            "    me.BATCH_START_HOUR, me.BATCH_START_DOW, me.IS_WEEKEND_BATCH, me.IS_NIGHT_SHIFT, " +
            "    COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0) AS TOTAL_COMMITTED_REVENUE, " +
            "    COALESCE(fi.TOTAL_MATERIAL_COST, 0) AS TOTAL_MATERIAL_COST, " +
            "    COALESCE(fi.GROSS_MARGIN, 0) AS GROSS_MARGIN, " +
            "    COALESCE(fi.GROSS_MARGIN_PCT, 0) AS GROSS_MARGIN_PCT, " +
            "    COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) AS TOTAL_PENALTY_EXPOSURE, " +
            "    COALESCE(fi.ON_TIME_RATE_PCT, 100) AS ON_TIME_RATE_PCT, " +
            "    COALESCE(fi.DELAYED_DELIVERIES, 0) AS DELAYED_DELIVERIES, " +
            "    COALESCE(fi.FAILED_DELIVERIES, 0) AS FAILED_DELIVERIES, " +
            "    COALESCE(fi.FINANCIAL_RISK_SCORE, 0) AS FINANCIAL_RISK_SCORE, " +
            "    COALESCE(fi.COST_PER_BATCH_UNIT, 0) AS COST_PER_BATCH_UNIT, " +
            "    COALESCE(fi.PENALTY_TO_REVENUE_RATIO, 0) AS PENALTY_TO_REVENUE_RATIO, " +
            "    CASE " +
            "        WHEN (CASE WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT' WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT' WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT' WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD' ELSE ml.ML_PREDICTED_ACTION END) = 'RELEASE' " +
            "            THEN ROUND(COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0) - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.1, 2) " +
            "        WHEN (CASE WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT' WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT' WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT' WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD' ELSE ml.ML_PREDICTED_ACTION END) = 'RETEST' " +
            "            THEN ROUND(COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0) * 0.90 - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.3, 2) " +
            "        WHEN (CASE WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT' WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT' WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT' WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD' ELSE ml.ML_PREDICTED_ACTION END) = 'HOLD' " +
            "            THEN ROUND(0 - COALESCE(fi.TOTAL_MATERIAL_COST, 0) * 0.05, 2) " +
            "        ELSE ROUND(0 - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) - COALESCE(fi.TOTAL_MATERIAL_COST, 0), 2) " +
            "    END AS FINAL_REVENUE, " +
            "    CASE " +
            "        WHEN (CASE WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT' WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT' WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT' WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD' ELSE ml.ML_PREDICTED_ACTION END) IN ('RELEASE', 'RETEST') " +
            "            THEN ROUND((CASE WHEN (CASE WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT' WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT' WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT' WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD' ELSE ml.ML_PREDICTED_ACTION END) = 'RELEASE' THEN COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0) - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.1 ELSE COALESCE(fi.TOTAL_COMMITTED_REVENUE, 0) * 0.90 - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.3 END) - COALESCE(fi.TOTAL_MATERIAL_COST, 0), 2) " +
            "        ELSE ROUND(0 - COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) - COALESCE(fi.TOTAL_MATERIAL_COST, 0), 2) " +
            "    END AS FINAL_PROFIT, " +
            "    CASE " +
            "        WHEN (CASE WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT' WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT' WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT' WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD' ELSE ml.ML_PREDICTED_ACTION END) = 'REJECT' " +
            "            THEN COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) + COALESCE(ro.TOTAL_ESTIMATED_PENALTY_USD, 0) " +
            "        WHEN (CASE WHEN qi.STERILITY_FAIL_FLAG = 1 AND qi.ENDOTOXIN_FAIL_FLAG = 1 THEN 'REJECT' WHEN COALESCE(ro.HAS_AUTO_BLOCK_RULE, 0) = 1 THEN 'REJECT' WHEN COALESCE(ro.FDA_CRITICAL_VIOLATIONS, 0) >= 3 THEN 'REJECT' WHEN COALESCE(ro.MAX_HOLD_DAYS, 0) > 0 AND ml.ML_PREDICTED_ACTION = 'RELEASE' THEN 'HOLD' ELSE ml.ML_PREDICTED_ACTION END) IN ('HOLD', 'RETEST') " +
            "            THEN COALESCE(fi.TOTAL_PENALTY_EXPOSURE, 0) * 0.3 " +
            "        ELSE 0 END AS PENALTY_APPLIED, " +
            "    ROUND(ml.ML_FAILURE_PROB * 0.6 + COALESCE(fi.FINANCIAL_RISK_SCORE, 0) * 0.4, 4) AS OVERALL_RISK_SCORE, " +
            "    dv.DEVIATION_1_NAME, dv.DEVIATION_2_NAME, dv.DEVIATION_3_NAME, " +
            "    rt.TOP_RISK_FACTOR_1, rt.TOP_RISK_FACTOR_2, rt.TOP_RISK_FACTOR_3, " +
            "    ar.AI_DECISION_REASON, " +
            "    CURRENT_TIMESTAMP() AS GOLD_CALC_TS " +
            "FROM GOLD_V2.ML_PREDICTIONS ml " +
            "JOIN batch_meta bm ON ml.BATCH_ID = bm.BATCH_ID " +
            "JOIN FEATURE_TEST.FEAT_BATCH_QUALITY_FEATURES qi ON ml.BATCH_ID = qi.BATCH_ID " +
            "LEFT JOIN GOLD_V2.RULE_ENGINE_OVERRIDES ro ON ml.BATCH_ID = ro.BATCH_ID " +
            "LEFT JOIN financial_impact fi ON ml.BATCH_ID = fi.BATCH_ID " +
            "LEFT JOIN FEATURE_TEST.FEAT_ML_ENHANCED me ON ml.BATCH_ID = me.BATCH_ID " +
            "LEFT JOIN dev_pivot dv ON ml.BATCH_ID = dv.BATCH_ID " +
            "LEFT JOIN risk_tags rt ON ml.BATCH_ID = rt.BATCH_ID " +
            "LEFT JOIN ai_reason ar ON ml.BATCH_ID = ar.BATCH_ID"
        );

        // ── Views are live — log only ───────────────────────────────────────
        result.steps.push({ object: "GOLD_V2.VW_UI_BATCH_LIST", status: "VIEW_LIVE" });
        result.steps.push({ object: "GOLD_V2.VW_UI_KPI", status: "VIEW_LIVE" });
        result.steps.push({ object: "GOLD_V2.VW_UI_SIMULATION_BASE", status: "VIEW_LIVE" });

        // ── Summary ─────────────────────────────────────────────────────────
        result.status = "COMPLETED";

        snowflake.execute({
            sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG " +
                     "(PIPELINE_LAYER, RUN_STATUS, ROWS_PROCESSED, COMPLETED_AT) " +
                     "VALUES ('GOLD', 'COMPLETED', " + totalRows + ", CURRENT_TIMESTAMP())"
        });

    } catch (e) {
        result.status = "FAILED";
        result.errors.push(e.message);
        try {
            snowflake.execute({
                sqlText: "INSERT INTO APP_CONFIG.PIPELINE_RUN_LOG " +
                         "(PIPELINE_LAYER, RUN_STATUS, ERROR_MESSAGE, COMPLETED_AT) " +
                         "VALUES ('GOLD', 'FAILED', '" + e.message.replace(/'/g, "''") + "', CURRENT_TIMESTAMP())"
            });
        } catch (logErr) { /* logging should not mask original error */ }
    }

    return result;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- SP_RUN_FULL_PIPELINE  (top-level orchestrator)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE APP_CONFIG.SP_RUN_FULL_PIPELINE()
RETURNS VARIANT
LANGUAGE JAVASCRIPT
COMMENT = 'Full pipeline orchestrator: Silver → Feature → Gold in sequence. Entry point for scheduled Tasks. Returns a JSON summary of all layer run statuses.'
EXECUTE AS OWNER
AS $$
    var summary = {
        pipeline: "PharmaCopilot",
        started_at: new Date().toISOString(),
        layers: [],
        overall_status: "STARTED"
    };

    var layers = ["SP_BUILD_SILVER", "SP_BUILD_FEATURE", "SP_BUILD_GOLD"];

    for (var i = 0; i < layers.length; i++) {
        var sp = layers[i];
        try {
            var res = snowflake.execute({
                sqlText: "CALL APP_CONFIG." + sp + "()"
            });
            res.next();
            var layerResult = res.getColumnValue(1);
            summary.layers.push({ procedure: sp, result: layerResult });

            // Abort pipeline if a layer fails
            if (layerResult && layerResult.status === "FAILED") {
                summary.overall_status = "FAILED_AT_" + sp;
                return summary;
            }
        } catch (e) {
            summary.layers.push({ procedure: sp, error: e.message });
            summary.overall_status = "FAILED_AT_" + sp;
            return summary;
        }
    }

    summary.overall_status = "COMPLETED";
    summary.completed_at   = new Date().toISOString();
    return summary;
$$;


-- =============================================================================
-- SECTION 14 — STORED PROCEDURE GRANTS
-- =============================================================================

GRANT USAGE ON PROCEDURE APP_CONFIG.SP_POST_INSTALL_SETUP()  TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON PROCEDURE APP_CONFIG.SP_BUILD_SILVER()         TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON PROCEDURE APP_CONFIG.SP_BUILD_FEATURE()        TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON PROCEDURE APP_CONFIG.SP_BUILD_GOLD()           TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON PROCEDURE APP_CONFIG.SP_RUN_FULL_PIPELINE()    TO APPLICATION ROLE PHARMA_ADMIN_ROLE;


-- =============================================================================
-- SECTION 15 — POST-INSTALL COMMENTS  (object-level documentation)
-- =============================================================================

COMMENT ON TABLE APP_CONFIG.PIPELINE_CONFIG
    IS 'Application configuration key-value store. Modify thresholds and model parameters here without code changes.';

COMMENT ON TABLE APP_CONFIG.PIPELINE_RUN_LOG
    IS 'Append-only audit log for all pipeline layer executions. Retained indefinitely for GxP audit trail.';

COMMENT ON TABLE RAW.RAW_BATCH_MASTER
    IS 'RAW mirror of MES batch master records. No transformation applied. Load via COPY INTO using FF_CSV_STANDARD.';

COMMENT ON TABLE RAW.RAW_SENSOR_READINGS
    IS 'RAW mirror of IoT/SCADA sensor readings. Load via COPY INTO using FF_CSV_STANDARD.';

COMMENT ON TABLE RAW.RAW_LAB_TESTS
    IS 'RAW mirror of LIMS quality test results. Load via COPY INTO using FF_CSV_STANDARD.';

COMMENT ON TABLE RAW.RAW_DEVIATIONS
    IS 'RAW mirror of QA deviation records. Load via COPY INTO using FF_CSV_STANDARD.';

COMMENT ON TABLE RAW.RAW_AUDIT_TRAIL
    IS 'RAW mirror of electronic audit trail (21 CFR Part 11). Load via COPY INTO using FF_CSV_STANDARD.';

COMMENT ON TABLE RAW.RAW_FDA_PENALTIES
    IS 'FDA CFR reference data: violation types, penalty ranges, recall classes. Managed by QA team; refresh on each CFR update cycle.';

COMMENT ON TABLE FEATURE_TEST.FEAT_ML_INPUT
    IS 'ML-ready 40-feature input table. Direct input to PREDICT_BATCH_FAILURE_PROB UDF. Bucket columns (BATCH_SIZE_BUCKET, DURATION_BUCKET) must be consistent with training data encoding.';

COMMENT ON TABLE GOLD_V2.BATCH_FACT
    IS 'Core gold fact table. One row per batch. Combines ML scores, FDA rule overrides, financial metrics, and quality features. Source of truth for all Streamlit views.';

COMMENT ON TABLE GOLD_V2.BATCH_SIMULATION_LOG
    IS 'Simulation audit trail. Written by Streamlit Simulation Lab on every What-If run. Captures parameter snapshot, ML re-score, and delta vs original decision. FDA 21 CFR Part 11 relevant.';

COMMENT ON VIEW GOLD_V2.VW_UI_BATCH_LIST
    IS 'Streamlit batch queue panel view. Ordered by date desc, failure probability desc. Do not add ORDER BY in downstream queries — ordering is defined here.';

COMMENT ON VIEW GOLD_V2.VW_UI_KPI
    IS 'Streamlit KPI header strip view. Single-row aggregate. All financial figures in source currency (USD).';

COMMENT ON VIEW GOLD_V2.VW_UI_SIMULATION_BASE
    IS 'Streamlit Simulation Lab base view. Joins BATCH_FACT to FEAT_ML_INPUT. Exposes all 40 UDF input parameters for slider-driven what-if analysis.';


-- =============================================================================
-- SECTION 16 — ROLE HIERARCHY
-- =============================================================================
-- PHARMA_VIEWER_ROLE is a subset of PHARMA_ADMIN_ROLE.
-- Grant PHARMA_VIEWER_ROLE to PHARMA_ADMIN_ROLE so that admins inherit all
-- viewer permissions and can be tested with the restricted permission set
-- by switching roles.

GRANT APPLICATION ROLE PHARMA_VIEWER_ROLE TO APPLICATION ROLE PHARMA_ADMIN_ROLE;


GRANT USAGE ON SCHEMA ML_CODE TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON SCHEMA ML_CODE TO APPLICATION ROLE PHARMA_VIEWER_ROLE;
-- =============================================================================
-- SECTION 17 — REFERENCE CALLBACK
-- =============================================================================
CREATE OR REPLACE PROCEDURE APP_CONFIG.REGISTER_REFERENCE(ref_name STRING, operation STRING, ref_or_alias STRING)
RETURNS STRING
LANGUAGE SQL
AS
BEGIN
    CASE (operation)
        WHEN 'ADD' THEN
            SELECT SYSTEM$SET_REFERENCE(:ref_name, :ref_or_alias);
        WHEN 'REMOVE' THEN
            SELECT SYSTEM$REMOVE_REFERENCE(:ref_name, :ref_or_alias);
        WHEN 'CLEAR' THEN
            SELECT SYSTEM$REMOVE_ALL_REFERENCES(:ref_name);
    END CASE;
    RETURN 'Done';
END;

GRANT USAGE ON PROCEDURE APP_CONFIG.REGISTER_REFERENCE(STRING, STRING, STRING) TO APPLICATION ROLE PHARMA_ADMIN_ROLE;


-- =============================================================================
-- SECTION 18 — STREAMLIT APPLICATION
-- =============================================================================
CREATE OR REPLACE STREAMLIT GOLD_V2.PHARMA_UI
    FROM 'Streamlit/Pharma_Copilot 1'
    MAIN_FILE = 'streamlit_app.py'
    TITLE = 'PharmaCopilot'
    COMMENT = 'Pharmaceutical Manufacturing Intelligence Dashboard';

GRANT USAGE ON STREAMLIT GOLD_V2.PHARMA_UI TO APPLICATION ROLE PHARMA_ADMIN_ROLE;
GRANT USAGE ON STREAMLIT GOLD_V2.PHARMA_UI TO APPLICATION ROLE PHARMA_VIEWER_ROLE;


-- =============================================================================
-- END OF setup.sql
-- PharmaCopilot Native App — all 16 sections complete.
-- Next steps after installation:
--   1. CALL APP_CONFIG.SP_POST_INSTALL_SETUP();
--   2. Confirm artifacts/pharma_batch_model.pkl is bundled in the app version stage.
--   3. Confirm artifacts/pharma_model_meta.json is bundled in the app version stage.
--   4. Upload pharma_semantic_model.yaml -> @GOLD_V2.PHARMA_UI_STAGE if using Cortex Analyst.
--   5. Upload stagesvg.png -> @GOLD_V2.PHARMA_UI_STAGE, or rely on bundled Streamlit/stagesvg.png.
--   6. Load source CSVs into RAW tables via COPY INTO using FF_CSV_STANDARD
--   7. CALL APP_CONFIG.SP_RUN_FULL_PIPELINE();
--   8. Open Streamlit — PharmaCopilot is ready.
-- =====================