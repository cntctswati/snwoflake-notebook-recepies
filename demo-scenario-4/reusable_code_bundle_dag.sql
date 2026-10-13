-- ============================================================
-- Scenario 4: Same Code Bundle Reused Across Different DAGs
-- ============================================================
--
-- DAG 1 (Sales):                    DAG 2 (Marketing):
--   sales_prep ──► sales_report       marketing_prep ──► marketing_report
--                       \                          /
--                        \________________________/
--                               Same REPORT_BUNDLE
--
-- The report notebook is generic - it just reads sys.argv[1]
-- and processes whatever table name it receives.
-- ============================================================

USE DATABASE AGENTHIVE_LINEAGE;
USE SCHEMA CODE_BUNDLE_DEMO;

-- Step 1: Create sample source tables for both DAGs
CREATE OR REPLACE TABLE AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.SALES_SUMMARY AS
SELECT 
  'Sales' AS DOMAIN,
  CATEGORY,
  COUNT(*) AS ORDER_COUNT,
  SUM(AMOUNT) AS TOTAL_REVENUE,
  ROUND(AVG(AMOUNT), 2) AS AVG_ORDER_VALUE,
  COUNT(DISTINCT CUSTOMER_ID) AS UNIQUE_CUSTOMERS,
  CURRENT_DATE() AS REPORT_DATE
FROM AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.RAW_ORDERS
WHERE CATEGORY IN ('Electronics', 'Home')
GROUP BY CATEGORY;

CREATE OR REPLACE TABLE AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.MARKETING_SUMMARY AS
SELECT 
  'Marketing' AS DOMAIN,
  CATEGORY,
  COUNT(*) AS ORDER_COUNT,
  SUM(AMOUNT) AS TOTAL_REVENUE,
  ROUND(AVG(AMOUNT), 2) AS AVG_ORDER_VALUE,
  COUNT(DISTINCT CUSTOMER_ID) AS UNIQUE_CUSTOMERS,
  CURRENT_DATE() AS REPORT_DATE
FROM AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.RAW_ORDERS
WHERE CATEGORY IN ('Clothing', 'Sports', 'Food')
GROUP BY CATEGORY;


-- Step 2: DAG 1 - Sales Pipeline
-- Root task: prepares sales data and sets return value
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.SALES_PREP
  WAREHOUSE = 'COMPUTE_WH'
  SCHEDULE = 'USING CRON 0 8 * * 1 America/Los_Angeles'
AS
BEGIN
  -- In a real scenario, this would run a sales-specific Code Bundle
  -- Here we simulate by setting the return value directly
  SYSTEM$SET_RETURN_VALUE('AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.SALES_SUMMARY|2|2026-09-30|SUCCESS');
END;

-- Child task: runs the SAME report Code Bundle as Marketing
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.SALES_REPORT
  WAREHOUSE = 'COMPUTE_WH'
  AFTER AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.SALES_PREP
AS
BEGIN
  LET val VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('SALES_PREP');
  
  EXECUTE CODE BUNDLE "AGENTHIVE_LINEAGE"."CODE_BUNDLE_DEMO"."REPORT_BUNDLE"
    ENTRYPOINT = 'report.ipynb'
    ARGUMENTS = (:val)
    WITH SPECIFICATION $$
    bundle:
      type: custom
      compute_type: compute_pool
      language: python
      compute_options:
        runtime_version: V2.4-CPU-PY3.12
        compute_pool: SYSTEM_COMPUTE_POOL_CPU
        query_warehouse: COMPUTE_WH
    $$;
END;


-- Step 3: DAG 2 - Marketing Pipeline
-- Root task: prepares marketing data and sets return value
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.MARKETING_PREP
  WAREHOUSE = 'COMPUTE_WH'
  SCHEDULE = 'USING CRON 0 9 * * 1 America/Los_Angeles'
AS
BEGIN
  SYSTEM$SET_RETURN_VALUE('AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.MARKETING_SUMMARY|3|2026-09-30|SUCCESS');
END;

-- Child task: runs the SAME report Code Bundle as Sales
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.MARKETING_REPORT
  WAREHOUSE = 'COMPUTE_WH'
  AFTER AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.MARKETING_PREP
AS
BEGIN
  LET val VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('MARKETING_PREP');
  
  EXECUTE CODE BUNDLE "AGENTHIVE_LINEAGE"."CODE_BUNDLE_DEMO"."REPORT_BUNDLE"
    ENTRYPOINT = 'report.ipynb'
    ARGUMENTS = (:val)
    WITH SPECIFICATION $$
    bundle:
      type: custom
      compute_type: compute_pool
      language: python
      compute_options:
        runtime_version: V2.4-CPU-PY3.12
        compute_pool: SYSTEM_COMPUTE_POOL_CPU
        query_warehouse: COMPUTE_WH
    $$;
END;


-- Step 4: Variant - Using Task CONFIG for static parameters
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.CONFIGURABLE_REPORT
  WAREHOUSE = 'COMPUTE_WH'
  SCHEDULE = 'USING CRON 0 10 * * 1 America/Los_Angeles'
  CONFIG = $${"source_table": "AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.SALES_SUMMARY", "row_count": "2", "run_date": "2026-09-30", "status": "SUCCESS"}$$
AS
BEGIN
  LET src VARCHAR := SYSTEM$GET_TASK_GRAPH_CONFIG('source_table')::VARCHAR;
  LET cnt VARCHAR := SYSTEM$GET_TASK_GRAPH_CONFIG('row_count')::VARCHAR;
  LET dt VARCHAR := SYSTEM$GET_TASK_GRAPH_CONFIG('run_date')::VARCHAR;
  LET st VARCHAR := SYSTEM$GET_TASK_GRAPH_CONFIG('status')::VARCHAR;
  LET args VARCHAR := :src || '|' || :cnt || '|' || :dt || '|' || :st;
  
  EXECUTE CODE BUNDLE "AGENTHIVE_LINEAGE"."CODE_BUNDLE_DEMO"."REPORT_BUNDLE"
    ENTRYPOINT = 'report.ipynb'
    ARGUMENTS = (:args)
    WITH SPECIFICATION $$
    bundle:
      type: custom
      compute_type: compute_pool
      language: python
      compute_options:
        runtime_version: V2.4-CPU-PY3.12
        compute_pool: SYSTEM_COMPUTE_POOL_CPU
        query_warehouse: COMPUTE_WH
    $$;
END;

-- Switch to marketing data without recreating the task
-- ALTER TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.CONFIGURABLE_REPORT SET
--   CONFIG = $${"source_table": "AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.MARKETING_SUMMARY", "row_count": "3", "run_date": "2026-09-30", "status": "SUCCESS"}$$;


-- Step 5: Activate DAGs
ALTER TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.SALES_REPORT RESUME;
ALTER TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.SALES_PREP RESUME;
ALTER TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.MARKETING_REPORT RESUME;
ALTER TASK AGENTHIVE_LINEAGE.CODE_BUNDLE_DEMO.MARKETING_PREP RESUME;
