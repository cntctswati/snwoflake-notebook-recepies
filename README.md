# Snowflake Notebook Parameter Passing - Complete Examples

Working code for the Medium article: **Passing Parameters Between Snowflake Notebooks: A Complete Guide**

## Repo Structure

```
npo_demo/
├── README.md                              (this file)
├── passing-parameters-between-snowflake-notebooks.md   (the article)
│
├── scenario-1-run/                        %run pattern (shared variables)
│   ├── main_orchestrator.ipynb            Orchestrator - calls both notebooks
│   ├── data_prep.ipynb                    Creates raw data + summary table
│   └── report.ipynb                       Reads summary, generates report
│
├── scenario-2-task-dag/                   Task DAG + SYSTEM$SET_RETURN_VALUE
│   ├── data_prep.ipynb                    Standalone NPO, sets return value
│   ├── report.ipynb                       Standalone NPO, parses sys.argv
│   └── task_dag_setup.sql                 Task DAG with parameter passing
│
├── scenario-3-multi-predecessor/          Fan-in from 3 predecessors
│   ├── data_prep.ipynb                    Prepares order summary
│   ├── enrichment.ipynb                   Adds customer segments
│   ├── validation.ipynb                   Runs data quality checks
│   ├── report.ipynb                       Receives from all 3 predecessors
│   └── multi_predecessor_dag.sql          3-root + 1-child Task DAG
│
└── scenario-4-reusable-npo/               Same notebook across different DAGs
    ├── report.ipynb                       Generic report (reads sys.argv)
    └── reusable_npo_dag.sql               Sales DAG + Marketing DAG + CONFIG variant
```

## Prerequisites

- Snowflake account with Workspaces enabled
- A compute pool (e.g. `SYSTEM_COMPUTE_POOL_CPU`)
- A warehouse (e.g. `COMPUTE_WH`)
- ACCOUNTADMIN or a role with CREATE TASK, CREATE NOTEBOOK PROJECT privileges

## Quick Start

### Scenario 1: %run (simplest)
1. Upload all 3 notebooks from `scenario-1-run/` to a Workspace
2. Open `main_orchestrator.ipynb` and run all cells
3. To schedule: click Calendar icon > Deploy Changes > set schedule

### Scenario 2: Task DAG (production)
1. Upload `data_prep.ipynb` and `report.ipynb` from `scenario-2-task-dag/` to a Workspace
2. Run each notebook interactively to verify they work
3. Deploy each as an NPO (Calendar icon > Deploy Changes)
4. Run `task_dag_setup.sql` in a SQL worksheet (update NPO names to match yours)
5. Test: `EXECUTE TASK AGENTHIVE_LINEAGE.NPO_DEMO.DATA_PREP_NPO;`

### Scenario 3: Multiple Predecessors
1. Upload all 4 notebooks from `scenario-3-multi-predecessor/` to a Workspace
2. Deploy each as a separate NPO
3. Run `multi_predecessor_dag.sql` (update NPO names)
4. Test: `EXECUTE TASK AGENTHIVE_LINEAGE.NPO_DEMO.TASK_DATA_PREP;`

### Scenario 4: Reusable NPO
1. Upload `report.ipynb` from `scenario-4-reusable-npo/` (or reuse from Scenario 2)
2. Run `reusable_npo_dag.sql` to create both Sales and Marketing DAGs
3. Test either DAG independently

## Key Gotchas

| Issue | Fix |
|-------|-----|
| `sys.argv` has kernel args interactively | Filter: `[a for a in sys.argv[1:] if not a.startswith('-') and not a.startswith('/')]` |
| `get_active_session()` fails headlessly | Fallback: `next(iter(snowpark_session._active_sessions))` |
| `SYSTEM$SET_RETURN_VALUE` fails interactively | Wrap in try/except |
| JSON gets mangled in ARGUMENTS | Use pipe-delimited format instead |
| `GET_PREDECESSOR_RETURN_VALUE` fails | Use SHORT task name, not fully qualified |
| Notebook edits don't update NPO | Click "Deploy Changes" after every edit |

## Monitoring

```sql
-- Task run history
SELECT name, state, scheduled_time, return_value, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
  SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())
))
WHERE SCHEMA_NAME = 'NPO_DEMO'
ORDER BY SCHEDULED_TIME DESC;

-- NPO versions
SHOW VERSIONS IN NOTEBOOK PROJECT my_db.my_schema.my_npo;

-- Trigger manually
EXECUTE TASK my_db.my_schema.data_prep_task;
```
