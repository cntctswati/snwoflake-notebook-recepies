# Passing Parameters Between Snowflake Notebooks: A Complete Guide

*How to build production notebook pipelines with parameter passing across every execution mode.*

> Full working code for all scenarios is available in the [GitHub repo](https://github.com/YOUR_REPO/snowflake-notebook-parameter-passing).

---

## The Challenge

You've built notebooks in Snowflake Workspaces. They work great interactively. Now you need to chain them into a production pipeline where one notebook's output feeds another's input. This turns out to be trickier than expected.

This guide covers four patterns for passing parameters between notebooks, with the real-world gotchas we discovered while building them.

---

## Before You Start: Know Your Execution Modes

The same notebook behaves differently depending on how it runs:

| Mode | How it runs | `sys.argv` contains | `SYSTEM$SET_RETURN_VALUE` works? |
|------|------------|---------------------|----------------------------------|
| **Interactive** | Run cells in Snowsight | Kernel launcher args | No |
| **Headless (Task)** | `EXECUTE CODE BUNDLE` via a Task | Your ARGUMENTS | Yes |
| **Headless (Worksheet)** | `EXECUTE CODE BUNDLE` from SQL | Your ARGUMENTS | No |

This distinction matters for every pattern below.

---

## Scenario 1: `%run` - Shared Variables in Memory

**Best for:** Sequential notebooks in the same workspace. The simplest approach.

The `%run` magic executes another notebook in the same Python process. All variables are shared automatically.

```
main_orchestrator.ipynb
    |-- %run data_prep.ipynb     → sets OUTPUT_TABLE, ROW_COUNT, STATUS
    |-- %run report.ipynb        → reads OUTPUT_TABLE, ROW_COUNT, STATUS
```

The sender sets variables in its last cell:

```python
OUTPUT_TABLE = f'{TARGET_DB}.{TARGET_SCHEMA}.ORDER_SUMMARY'
ROW_COUNT = session.sql(f'SELECT COUNT(*) AS C FROM {OUTPUT_TABLE}').collect()[0]['C']
STATUS = 'SUCCESS'
```

The orchestrator calls both and can gate between them:

```python
%run data_prep.ipynb

assert STATUS == 'SUCCESS', f"Data prep failed: {STATUS}"

%run report.ipynb
```

The receiver reads the variables directly -- no imports, no parsing:

```python
print(f"Reading from: {OUTPUT_TABLE}")   # Already in memory
report_df = session.sql(f"SELECT * FROM {OUTPUT_TABLE}")
```

**Pros:** Full variable sharing (DataFrames, objects, anything). No serialization.
**Cons:** All notebooks must be in one NPO. Single point of failure.

> Full notebook code: [GitHub repo / demo-scenario-1](https://github.com/YOUR_REPO/snowflake-notebook-parameter-passing/tree/main/demo-scenario-1)

---

## Scenario 2: Task DAG with `SYSTEM$SET_RETURN_VALUE`

**Best for:** Independent notebooks running as separate production units.

Each notebook is its own NPO. A Task DAG chains them. The first task sets a return value, the second reads it and passes it as ARGUMENTS.

```
TASK: data_prep_task (root, scheduled)
    |  SYSTEM$SET_RETURN_VALUE('TABLE_NAME|5|2026-09-30|SUCCESS')
    v
TASK: report_task (child, AFTER data_prep_task)
       SYSTEM$GET_PREDECESSOR_RETURN_VALUE('DATA_PREP_TASK')
       → passes as ARGUMENTS → report.ipynb parses sys.argv[1]
```

**The sender** sets a pipe-delimited return value (not JSON -- see Gotcha #4):

```python
return_payload = f"{OUTPUT_TABLE}|{ROW_COUNT}|{RUN_DATE}|{STATUS}"

try:
    session.sql(f"SELECT SYSTEM$SET_RETURN_VALUE('{return_payload}')").collect()
except Exception as e:
    if 'must be called from within a task' in str(e):
        print("Interactive mode - skipping")
    else:
        raise
```

**The Task DAG** reads and forwards the value:

```sql
CREATE OR REPLACE TASK report_task
  WAREHOUSE = 'COMPUTE_WH'
  AFTER data_prep_task
AS
BEGIN
  LET predecessor_output VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE(
    'DATA_PREP_TASK'    -- Short name only! See Gotcha #5
  );
  EXECUTE CODE BUNDLE "MY_DB"."MY_SCHEMA"."REPORT_NPO"
    ENTRYPOINT = 'report.ipynb'
    ARGUMENTS = (:predecessor_output);
END;
```

**The receiver** parses the pipe-delimited string:

```python
user_args = [a for a in sys.argv[1:] if not a.startswith('-') and not a.startswith('/')]

parts = user_args[0].split('|')
source_table = parts[0]    # 'MY_DB.MY_SCHEMA.ORDER_SUMMARY'
row_count = parts[1]       # '5'
run_date = parts[2]        # '2026-09-30'
status = parts[3]          # 'SUCCESS'
```

**Variant: Task CONFIG for static parameters**

If arguments are known at task creation time, use CONFIG -- it lets you update params without recreating the task:

```sql
CREATE OR REPLACE TASK nightly_run
  SCHEDULE = 'USING CRON 0 9 * * * America/Los_Angeles'
  CONFIG = $${"run_date": "2026-09-30", "target_db": "PROD_DB"}$$
AS
BEGIN
  LET run_date VARCHAR := SYSTEM$GET_TASK_GRAPH_CONFIG('run_date')::VARCHAR;
  LET target_db VARCHAR := SYSTEM$GET_TASK_GRAPH_CONFIG('target_db')::VARCHAR;
  EXECUTE CODE BUNDLE ... ARGUMENTS = (:run_date || '|' || :target_db);
END;

-- Update without recreating the task
ALTER TASK nightly_run SET CONFIG = $${"run_date": "2026-10-31", "target_db": "STAGING_DB"}$$;
```

> Full notebook + SQL code: [GitHub repo / demo-scenario-2](https://github.com/YOUR_REPO/snowflake-notebook-parameter-passing/tree/main/demo-scenario-2)

---

## Scenario 3: Multiple Predecessors (Fan-In)

**Best for:** A notebook that depends on outputs from multiple upstream notebooks.

```
data_prep_task ──────┐
                     v
enrichment_task ───► report_task
                     ^
validation_task ────┘
```

Call `SYSTEM$GET_PREDECESSOR_RETURN_VALUE` once per predecessor, combine with a double-pipe separator:

```sql
CREATE OR REPLACE TASK report_task
  AFTER data_prep_task, enrichment_task, validation_task
AS
BEGIN
  LET prep_out VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('DATA_PREP_TASK');
  LET enrich_out VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('ENRICHMENT_TASK');
  LET valid_out VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('VALIDATION_TASK');
  
  LET all_args VARCHAR := :prep_out || '||' || :enrich_out || '||' || :valid_out;
  EXECUTE CODE BUNDLE ... ARGUMENTS = (:all_args);
END;
```

The notebook splits on double-pipe first, then single-pipe for each predecessor:

```python
predecessor_outputs = user_args[0].split('||')
prep_parts = predecessor_outputs[0].split('|')       # TABLE|COUNT|DATE|STATUS
enrich_parts = predecessor_outputs[1].split('|')
valid_parts = predecessor_outputs[2].split('|')
```

---

## Scenario 4: Same Notebook Across Different DAGs

**Best for:** A generic report notebook that works with any data source.

```
DAG 1 (Sales):                     DAG 2 (Marketing):
  sales_prep ──► report_task_1       marketing_prep ──► report_task_2
                       \                          /
                        \________________________/
                               Same NPO
```

The key insight: **the notebook is decoupled from the DAG**. Each task passes different arguments to the same NPO:

```sql
-- DAG 1
CREATE OR REPLACE TASK sales_report AFTER sales_prep AS
BEGIN
  LET val VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('SALES_PREP');
  EXECUTE CODE BUNDLE "MY_DB"."MY_SCHEMA"."REPORT_NPO"
    ENTRYPOINT = 'report.ipynb'
    ARGUMENTS = (:val);
END;

-- DAG 2 (same NPO, different predecessor)
CREATE OR REPLACE TASK marketing_report AFTER marketing_prep AS
BEGIN
  LET val VARCHAR := SYSTEM$GET_PREDECESSOR_RETURN_VALUE('MARKETING_PREP');
  EXECUTE CODE BUNDLE "MY_DB"."MY_SCHEMA"."REPORT_NPO"
    ENTRYPOINT = 'report.ipynb'
    ARGUMENTS = (:val);
END;
```

The notebook just reads `sys.argv[1]` -- it doesn't know or care which DAG invoked it.

---

## Gotchas (The Hard-Won Lessons)

These are the issues that cost us hours. None are documented elsewhere.

### 1. `sys.argv` contains kernel launcher args in interactive mode

In a Snowflake Workspace notebook, `sys.argv` is:
```
['/venv/.../ipykernel_launcher.py', '-f', '/venv/runtime/kernel-xxx.json']
```

Not your arguments. **Always filter:**

```python
user_args = [a for a in sys.argv[1:] if not a.startswith('-') and not a.startswith('/')]
```

### 2. `get_active_session()` fails in headless mode

Headless execution can create multiple sessions, causing `SnowparkSessionException: More than one active session`.

```python
from snowflake.snowpark import session as snowpark_session
try:
    session = get_active_session()
except Exception:
    session = next(iter(snowpark_session._active_sessions))
```

### 3. `SYSTEM$SET_RETURN_VALUE` only works inside a Task

Running from a worksheet or interactively throws: `Function SYSTEM$SET_RETURN_VALUE must be called from within a task.`

**Always wrap in try/except** so the notebook works in both modes.

### 4. JSON gets mangled in ARGUMENTS

This was the most surprising one. If you set a JSON return value:

```python
SYSTEM$SET_RETURN_VALUE('{"output_table": "MY_TABLE"}')
```

The ARGUMENTS parser strips the double quotes. The notebook receives `{output_table: MY_TABLE}` -- not valid JSON.

**Fix: use pipe-delimited format instead of JSON:**

```python
# Sender
return_payload = f"{table_name}|{row_count}|{run_date}|{status}"

# Receiver
parts = sys.argv[1].split('|')
```

### 5. `SYSTEM$GET_PREDECESSOR_RETURN_VALUE` needs short task name

```sql
-- FAILS:
SYSTEM$GET_PREDECESSOR_RETURN_VALUE('MY_DB.MY_SCHEMA.DATA_PREP_TASK')

-- WORKS:
SYSTEM$GET_PREDECESSOR_RETURN_VALUE('DATA_PREP_TASK')
```

### 6. Editing a notebook doesn't update the NPO

After changing code in the workspace, you **must click "Deploy Changes"** (calendar icon > Deploy Changes). Otherwise the task keeps running the old version.

---

## Quick Reference

| Situation | Pattern | Parameter Method |
|-----------|---------|-----------------|
| Sequential notebooks, same workspace | `%run` | Shared Python variables |
| Independent notebooks, production pipeline | Task DAG | `SYSTEM$SET_RETURN_VALUE` + ARGUMENTS |
| Fan-in from multiple sources | Multiple predecessors | Multiple `GET_PREDECESSOR_RETURN_VALUE` calls |
| Generic reusable notebook | Same NPO, different DAGs | ARGUMENTS from each task |

## Monitoring

| What | Where |
|------|-------|
| Task run status | Snowsight: **Monitoring > Task History** |
| Notebook run output | **Catalog > NPO > Run History** (click a run to see cell output) |
| Deploy versions | `SHOW VERSIONS IN NOTEBOOK PROJECT db.schema.npo_name` |
| Return values | Task History > RETURN_VALUE column |

---

> Full working code for all scenarios: [GitHub repo](https://github.com/YOUR_REPO/snowflake-notebook-parameter-passing)
