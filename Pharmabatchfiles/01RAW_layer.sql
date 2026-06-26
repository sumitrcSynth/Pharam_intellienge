-- PURPOSE: Create RAW tables (exact mirror of source files)
-- LAYER: RAW
-- Contains only table definitions.
-- Data ingestion handled through stored procedures.
-- =============================================================================
-- FILE: 01_raw_layer.sql
-- PURPOSE: Create RAW tables (exact mirror of source CSV files) and load data
-- LAYER: RAW — no transformation, audit columns only appended
-- RUN AS: PHARMA_ADMIN  |  WH: PHARMA_INGEST_WH
-- =============================================================================
-- select  from list @STAGING.pharma_data_stage/erp/audit_trail.csv;
-- ─────────────────────────────────────────────────────────────────────────────
-- TABLE 1: RAW_BATCH_MASTER
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
    _RAW_LOAD_TS          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);
-- ─────────────────────────────────────────────────────────────────────────────
-- TABLE 2: RAW_SENSOR_READINGS
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
    _RAW_LOAD_TS          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- TABLE 3: RAW_LAB_TESTS
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
    _RAW_LOAD_TS          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- TABLE 4: RAW_DEVIATIONS
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
    _RAW_LOAD_TS          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- ─────────────────────────────────────────────────────────────────────────────
-- TABLE 9: RAW_AUDIT_TRAIL
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
    _RAW_LOAD_TS          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);


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

    _RAW_LOAD_TS              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE              VARCHAR(500),
    _ROW_HASH                 VARCHAR(64)
);


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

    _RAW_LOAD_TS          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

CREATE TABLE IF NOT EXISTS RAW.RAW_FDA_PENALTIES (
    PENALTY_RULE_ID       VARCHAR(50),
    CFR_REFERENCE         VARCHAR(100),
    VIOLATION_TYPE        VARCHAR(200),
    VIOLATION_CATEGORY    VARCHAR(50),
    APPLICABLE_PRODUCT_TYPE VARCHAR(50),   -- ✅ FIXED (was wrong)
    PENALTY_TYPE          VARCHAR(100),

    MIN_PENALTY_USD       FLOAT,
    MAX_PENALTY_USD       FLOAT,

    RECALL_CLASS          VARCHAR(20),
    BUSINESS_IMPACT       VARCHAR(200),

    AUTO_BLOCK_RELEASE    VARCHAR(10),
    MANDATORY_CAPA        VARCHAR(10),

    REGULATORY_HOLD_DAYS  INT,

    EFFECTIVE_DATE        DATE,
    IS_ACTIVE             VARCHAR(10),

    CREATED_AT            TIMESTAMP_NTZ,

    _RAW_LOAD_TS          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE          VARCHAR(500),
    _ROW_HASH             VARCHAR(64)
);

CREATE TABLE IF NOT EXISTS RAW.RAW_BATCH_FULFILLMENT (
    FULFILLMENT_ID     VARCHAR(50),
    BATCH_ID           VARCHAR(50),
    AGREEMENT_ID       VARCHAR(50),
    PRODUCT_ID         VARCHAR(50),

    FULFILLED_QTY      FLOAT,
    FULFILLMENT_DATE   DATE,
    DELIVERY_STATUS    VARCHAR(30),
    DELAY_DAYS         NUMBER,

    CREATED_AT         TIMESTAMP_NTZ,

    _RAW_LOAD_TS       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _SOURCE_FILE       VARCHAR(500),
    _ROW_HASH          VARCHAR(64)
);
