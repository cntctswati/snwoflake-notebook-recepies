-- ============================================================
-- Scenario 3: Multiple Predecessors (Fan-In) Task DAG
-- ============================================================
--
--   data_prep_task ──────┐
--                        v
--   enrichment_task ───► report_task
--                        ^
--   validation_task ────┘
--
-- Each predecessor sets SYSTEM$SET_RETURN_VALUE with pipe-delimited output.
-- The report_task reads all three and combines them into ARGUMENTS.
-- ============================================================

USE DATABASE AGENTHIVE_LINEAGE;
USE SCHEMA NPO_DEMO;

-- Step 1: Create NPOs (or use Schedule/Deploy button in Snowsight)
-- Assumes NPOs already exist: DATA_PREP_NPO, ENRICHMENT_NPO, VALIDATION_NPO, REPORT_NPO

-- Step 2: Root Task 1 - Data Preparation
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP
  WAREHOUSE = 'COMPUTE_WH'
  SCHEDULE = 'USING CRON 0 8 * * 1 America/Los_Angeles'
AS
BEGIN
  EXECUTE CODE BUNDLE "AGENTHIVE_LINEAGE"."NPO_DEMO"."DATA_PREP_NPO"
    ENTRYPOINT = 'data_prep.ipynb'
    ARGUMENTS = ('2026-09-30', 'AGENTHIVE_LINEAGE')
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

-- Step 3: Root Task 2 - Enrichment (runs in parallel with data_prep)
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_ENRICHMENT
  WAREHOUSE = 'COMPUTE_WH'
  SCHEDULE = 'USING CRON 0 8 * * 1 America/Los_Angeles'
AS
BEGIN
  EXECUTE CODE BUNDLE "AGENTHIVE_LINEAGE"."NPO_DEMO"."ENRICHMENT_NPO"
    ENTRYPOINT = 'enrichment.ipynb'
    ARGUMENTS = ('AGENTHIVE_LINEAGE')
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

-- Step 4: Root Task 3 - Validation (runs in parallel with data_prep)
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_VALIDATION
  WAREHOUSE = 'COMPUTE_WH'
  SCHEDULE = 'USING CRON 0 8 * * 1 America/Los_Angeles'
AS
BEGIN
  EXECUTE CODE BUNDLE "AGENTHIVE_LINEAGE"."NPO_DEMO"."VALIDATION_NPO"
    ENTRYPOINT = 'validation.ipynb'
    ARGUMENTS = ('AGENTHIVE_LINEAGE')
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

-- Step 5: Child Task - Report (runs AFTER all three predecessors complete)
CREATE OR REPLACE TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_REPORT_FANIN
  WAREHOUSE = 'COMPUTE_WH'
  AFTER AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP,
        AGENTHIVE_LINEAGE.NPO_DEMO.TASK_ENRICHMENT,
        AGENTHIVE_LINEAGE.NPO_DEMO.TASK_VALIDATION
AS
BEGIN
  -- Read return values from each predecessor (SHORT names only)
  LET prep_out VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('TASK_DATA_PREP');
  LET enrich_out VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('TASK_ENRICHMENT');
  LET valid_out VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('TASK_VALIDATION');
  
  -- Combine with double-pipe separator
  LET all_args VARCHAR := :prep_out || '||' || :enrich_out || '||' || :valid_out;
  
  EXECUTE CODE BUNDLE "AGENTHIVE_LINEAGE"."NPO_DEMO"."REPORT_NPO"
    ENTRYPOINT = 'report.ipynb'
    ARGUMENTS = (:all_args)
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

-- Step 6: Activate (child first, then roots)
ALTER TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_REPORT_FANIN RESUME;
ALTER TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP RESUME;
ALTER TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_ENRICHMENT RESUME;
ALTER TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_VALIDATION RESUME;
