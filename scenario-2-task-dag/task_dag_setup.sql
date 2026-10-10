-- ============================================================
-- Two Separate NPOs + Task DAG with Parameter Passing
-- ============================================================
-- 
-- Architecture:
--
--   TASK_DATA_PREP (root, scheduled)
--       │  Runs data_prep.ipynb NPO
--       │  Calls SYSTEM$SET_RETURN_VALUE(json_payload)
--       │
--       ▼
--   TASK_REPORT (child, AFTER root)
--       │  Reads SYSTEM$GET_PREDECESSOR_RETURN_VALUE('TASK_DATA_PREP')
--       │  Passes JSON as ARGUMENTS to report.ipynb NPO
--       │  report.ipynb parses JSON via sys.argv[1]
--
-- Parameter flow:
--   data_prep.ipynb → SYSTEM$SET_RETURN_VALUE(json) → Task engine
--   Task engine → SYSTEM$GET_PREDECESSOR_RETURN_VALUE → ARGUMENTS → report.ipynb
-- ============================================================

USE DATABASE AGENTHIVE_LINEAGE;
USE SCHEMA NPO_DEMO;

-- ============================================================
-- Step 1: Create internal stage for notebook files
-- ============================================================
CREATE STAGE IF NOT EXISTS AGENTHIVE_LINEAGE.NPO_DEMO.NOTEBOOK_STAGE;

-- Upload notebooks from local (run in SnowSQL or snow CLI):
-- PUT file:///Users/swatigoel/Providence\ Notebook/npo_demo/data_prep.ipynb @AGENTHIVE_LINEAGE.NPO_DEMO.NOTEBOOK_STAGE/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
-- PUT file:///Users/swatigoel/Providence\ Notebook/npo_demo/report.ipynb @AGENTHIVE_LINEAGE.NPO_DEMO.NOTEBOOK_STAGE/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- OR if notebooks are already in a Workspace, skip the stage and 
-- create the NPO using the Schedule button in Snowsight.

-- ============================================================
-- Step 2: Create separate NPO for each notebook
-- ============================================================

-- NPO 1: Data Preparation
CREATE OR REPLACE NOTEBOOK PROJECT AGENTHIVE_LINEAGE.NPO_DEMO.DATA_PREP_NPO
  FROM '@AGENTHIVE_LINEAGE.NPO_DEMO.NOTEBOOK_STAGE/'
  MAIN_FILE = 'data_prep.ipynb'
  QUERY_WAREHOUSE = 'COMPUTE_WH'
  COMPUTE_POOL = 'SYSTEM_COMPUTE_POOL_CPU'       -- Replace with your compute pool
  RUNTIME = 'V2.2-CPU-PY3.11';           -- Replace with your runtime version

-- NPO 2: Report Generator
CREATE OR REPLACE NOTEBOOK PROJECT AGENTHIVE_LINEAGE.NPO_DEMO.REPORT_NPO
  FROM '@AGENTHIVE_LINEAGE.NPO_DEMO.NOTEBOOK_STAGE/'
  MAIN_FILE = 'report.ipynb'
  QUERY_WAREHOUSE = 'COMPUTE_WH'
  COMPUTE_POOL = 'SYSTEM_COMPUTE_POOL_CPU'       -- Replace with your compute pool
  RUNTIME = 'V2.2-CPU-PY3.11';           -- Replace with your runtime version


-- ============================================================
-- Step 3: Create Task DAG (root → child)
-- ============================================================

-- ROOT TASK: Runs data_prep.ipynb
-- Passes RUN_DATE and TARGET_DB as ARGUMENTS
-- data_prep.ipynb calls SYSTEM$SET_RETURN_VALUE(json) at the end
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP
  WAREHOUSE = 'COMPUTE_WH'
  SCHEDULE = 'USING CRON 0 8 * * 1 America/Los_Angeles'  -- Every Monday 8am
AS
BEGIN
  EXECUTE NOTEBOOK PROJECT AGENTHIVE_LINEAGE.NPO_DEMO.DATA_PREP_NPO
    MAIN_FILE = 'data_prep.ipynb'
    COMPUTE_POOL = 'SYSTEM_COMPUTE_POOL_CPU'
    QUERY_WAREHOUSE = 'COMPUTE_WH'
    RUNTIME = 'V2.2-CPU-PY3.11'
    ARGUMENTS = '2026-09-30 AGENTHIVE_LINEAGE';
    -- data_prep.ipynb reads: sys.argv[1] = '2026-09-30', sys.argv[2] = 'AGENTHIVE_LINEAGE'
    -- At the end, it calls SYSTEM$SET_RETURN_VALUE with a JSON payload
END;


-- CHILD TASK: Runs report.ipynb AFTER data_prep completes
-- Reads the JSON return value from TASK_DATA_PREP
-- Passes it as ARGUMENTS to report.ipynb
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_REPORT
  WAREHOUSE = 'COMPUTE_WH'
  AFTER AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP
AS
BEGIN
  -- Read the JSON payload set by data_prep.ipynb via SYSTEM$SET_RETURN_VALUE
  LET predecessor_output VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE(
    'AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP'
  );

  -- Pass the entire JSON string as a single argument to report.ipynb
  -- report.ipynb parses it with: json.loads(sys.argv[1])
  EXECUTE NOTEBOOK PROJECT AGENTHIVE_LINEAGE.NPO_DEMO.REPORT_NPO
    MAIN_FILE = 'report.ipynb'
    COMPUTE_POOL = 'SYSTEM_COMPUTE_POOL_CPU'
    QUERY_WAREHOUSE = 'COMPUTE_WH'
    RUNTIME = 'V2.2-CPU-PY3.11'
    ARGUMENTS = :predecessor_output;
    -- report.ipynb reads: sys.argv[1] = '{"output_table": "...", "category_count": 5, ...}'
END;


-- ============================================================
-- Step 4: Activate the DAG
-- ============================================================
-- IMPORTANT: Resume child task FIRST, then root task
ALTER TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_REPORT RESUME;
ALTER TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP RESUME;


-- ============================================================
-- Manual Test: Run the DAG immediately (without waiting for CRON)
-- ============================================================
-- EXECUTE TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP;


-- ============================================================
-- Monitor Task Runs
-- ============================================================
-- Check task run history
-- SELECT *
-- FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--   SCHEDULED_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP())
-- ))
-- WHERE DATABASE_NAME = 'AGENTHIVE_LINEAGE'
-- ORDER BY SCHEDULED_TIME DESC;


-- ============================================================
-- Cleanup (if needed)
-- ============================================================
-- ALTER TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP SUSPEND;
-- ALTER TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_REPORT SUSPEND;
-- DROP TASK IF EXISTS AGENTHIVE_LINEAGE.NPO_DEMO.TASK_REPORT;
-- DROP TASK IF EXISTS AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP;
-- DROP NOTEBOOK PROJECT IF EXISTS AGENTHIVE_LINEAGE.NPO_DEMO.DATA_PREP_NPO;
-- DROP NOTEBOOK PROJECT IF EXISTS AGENTHIVE_LINEAGE.NPO_DEMO.REPORT_NPO;
