# Snowflake Notebook Recipes: Passing Parameters Between Notebooks

Working examples for the Medium article **"Passing Parameters Between Snowflake Notebooks: A Complete Guide"**.

They show four ways to chain Snowflake Workspace notebooks and pass values between them. The approaches run from the simple `%run` magic to production Task DAGs built on Notebook Project Objects (NPOs).

---

> ## ⚠️ Disclaimer
>
> **This repository is provided for reference only. It shows an *approach*, not a production-ready solution.**
>
> - The code is sample/demo code. It is **not** an official Snowflake product and comes with **no warranty or support**.
> - **Adapt** the logic to your organization's **security, governance, and development best practices**. That includes least-privilege roles (not `ACCOUNTADMIN`), secrets management, naming standards, and code review.
> - **Review, test, and validate** everything in a non-production environment before you use it.
> - **Scale and harden** the solution for your workload: error handling, retries, monitoring/alerting, cost controls, and data volumes.
> - Some behavior described here (for example, the internal `_active_sessions` fallback and how `sys.argv` is handled in headless runs) was observed on a specific runtime version (`V2.4-CPU-PY3.12`). It **may change** in future Snowflake releases.
> - The database, schema, warehouse, compute pool, and NPO names are placeholders. Replace them with your own.
>
> You are responsible for anything you deploy from this repo.

---

## Scenarios at a Glance

| # | Scenario | How parameters flow | Best for |
|---|----------|---------------------|----------|
| 1 | `%run` | Shared Python namespace (variables) | Notebooks in the same project, simple orchestration |
| 2 | Task DAG | `SYSTEM$SET_RETURN_VALUE` → `SYSTEM$GET_PREDECESSOR_RETURN_VALUE` → `ARGUMENTS` → `sys.argv` | Separate NPOs, production scheduling |
| 3 | Multiple predecessors | Child task reads return values from several parents | Fan-in pipelines |
| 4 | Reusable NPO | Same NPO, different arguments per DAG (or Task `CONFIG`) | One notebook shared by many pipelines |

## Repo Structure

```
.
├── README.md
├── passing-parameters-between-snowflake-notebooks.md   Medium article
├── challenge-box.png                                    Article image
│
├── scenario-1-run/
│   ├── main_orchestrator.ipynb     Calls both notebooks with %run
│   ├── data_prep.ipynb             Creates raw data + summary table
│   └── report.ipynb                Reads summary, generates report
│
├── scenario-2-task-dag/
│   ├── data_prep.ipynb             Standalone NPO, sets return value
│   ├── report.ipynb                Standalone NPO, parses sys.argv
│   └── task_dag_setup.sql          Root + child task wiring
│
├── scenario-3-multi-predecessor/
│   ├── data_prep.ipynb
│   ├── enrichment.ipynb
│   ├── validation.ipynb
│   ├── report.ipynb                Receives values from all 3 parents
│   └── multi_predecessor_dag.sql
│
└── scenario-4-reusable-npo/
    ├── report.ipynb                Generic report driven by arguments
    └── reusable_npo_dag.sql        Sales DAG + Marketing DAG + CONFIG variant
```

## Prerequisites

- A Snowflake account with **Workspaces** and **Notebooks on Container Runtime** enabled
- A **compute pool**, for example `SYSTEM_COMPUTE_POOL_CPU`
- A **warehouse**, for example `COMPUTE_WH`
- A target **database and schema**. The samples use `AGENTHIVE_LINEAGE.NPO_DEMO`; replace it with yours.
- A role with the privileges below. Use a dedicated least-privilege role, not `ACCOUNTADMIN`:

```sql
-- Example only: adapt to your RBAC model
CREATE ROLE IF NOT EXISTS NOTEBOOK_PIPELINE_ROLE;
GRANT USAGE ON DATABASE <your_db> TO ROLE NOTEBOOK_PIPELINE_ROLE;
GRANT USAGE, CREATE TABLE, CREATE TASK, CREATE NOTEBOOK PROJECT
  ON SCHEMA <your_db>.<your_schema> TO ROLE NOTEBOOK_PIPELINE_ROLE;
GRANT USAGE ON WAREHOUSE <your_wh> TO ROLE NOTEBOOK_PIPELINE_ROLE;
GRANT USAGE ON COMPUTE POOL <your_pool> TO ROLE NOTEBOOK_PIPELINE_ROLE;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE NOTEBOOK_PIPELINE_ROLE;
```

## Step 0: Configure the Placeholders

Before you run anything, search and replace these values in the notebooks and `.sql` files:

| Placeholder in code | Replace with |
|---------------------|--------------|
| `AGENTHIVE_LINEAGE` | Your database |
| `NPO_DEMO` | Your schema |
| `COMPUTE_WH` | Your warehouse |
| `SYSTEM_COMPUTE_POOL_CPU` | Your compute pool |
| `CODE_BUNDLE_xxxxxxxx` | The NPO name Snowflake generates when you deploy (see Step 3 below) |
| `npo_demo/<notebook>.ipynb` | The notebook's path relative to your workspace root (the `ENTRYPOINT`) |

## Getting the Files into Snowflake

**Option A: Upload (Private/Shared workspace)**
1. In Snowsight, go to **Projects → Workspaces** and open your workspace.
2. Create a folder, for example `npo_demo`, then use **+ → Upload Files** to upload the scenario notebooks.

**Option B: Git-integrated workspace**
1. Go to **Projects → Workspaces → From Git repository** and connect this repo (or your fork).
2. The scenario folders show up directly. Pull to get updates.

> Paths matter. The `ENTRYPOINT` in the SQL must match where the notebook sits inside the workspace.

---

## Scenario 1: `%run` (Shared Namespace)

1. Upload all three notebooks from `scenario-1-run/` into the **same folder**.
2. Open `main_orchestrator.ipynb` and click **Run All**.
3. Variables defined in `data_prep.ipynb` (such as `OUTPUT_TABLE` and `RUN_DATE`) are now available in `report.ipynb`.
4. To schedule it: deploy `main_orchestrator.ipynb` as an NPO (**Calendar icon → Create schedule / Deploy**).

## Scenario 2: Task DAG with Separate NPOs

1. Upload `data_prep.ipynb` and `report.ipynb` from `scenario-2-task-dag/`.
2. **Run each one interactively** to confirm it works. The code detects interactive mode and skips `SYSTEM$SET_RETURN_VALUE`.
3. **Deploy each notebook as its own NPO**: open the notebook → **Calendar icon → Deploy**. Write down the generated NPO name (`CODE_BUNDLE_xxxxxxxx`):
   ```sql
   SHOW NOTEBOOK PROJECTS IN SCHEMA <your_db>.<your_schema>;
   ```
4. Update `task_dag_setup.sql` with your NPO names, entrypoints, warehouse, and pool, then run it in a SQL worksheet.
5. Test the DAG:
   ```sql
   EXECUTE TASK <your_db>.<your_schema>.DATA_PREP_NPO;
   ```
6. Check the result in **Monitoring → Task History**, or with the monitoring queries below. `DATA_PREP_NPO` should show a `RETURN_VALUE` like `DB.SCHEMA.ORDER_SUMMARY|5|2026-09-30|SUCCESS`.

## Scenario 3: Multiple Predecessors (Fan-in)

1. Upload all four notebooks from `scenario-3-multi-predecessor/`.
2. Deploy **each** one as a separate NPO.
3. Update the NPO names in `multi_predecessor_dag.sql` and run it.
4. Trigger the root task(s) as shown in the SQL file and confirm the report task gets all three values.

## Scenario 4: Reusable NPO Across DAGs

1. Deploy `scenario-4-reusable-npo/report.ipynb` once as an NPO (you can also reuse the Scenario 2 report NPO).
2. Run `reusable_npo_dag.sql`. It creates a Sales DAG, a Marketing DAG, and a Task `CONFIG` variant that all call the **same** NPO with different arguments.
3. Trigger each DAG on its own and compare the outputs.

---

## Important: Redeploy After Every Edit

Editing a notebook in the workspace **does not** update the deployed NPO. After every change:
**Open the notebook → Calendar icon → Deploy Changes**, then re-run the task.

## Key Gotchas

| Issue | Fix |
|-------|-----|
| `sys.argv` contains kernel launcher args when run interactively | Filter them: `[a for a in sys.argv[1:] if not a.startswith('-') and not a.startswith('/')]` |
| `get_active_session()` fails in headless runs ("more than one active session") | Fall back to `next(iter(snowpark_session._active_sessions))`. This is an internal API; review it per release. |
| `SYSTEM$SET_RETURN_VALUE` fails interactively | Wrap it in try/except and skip it outside a task |
| JSON is mangled when passed through `ARGUMENTS` (quotes get stripped) | Use a pipe-delimited payload such as `table\|count\|date\|status` |
| `SYSTEM$GET_PREDECESSOR_RETURN_VALUE` says "not a valid predecessor" | Pass the **short** task name, not the fully qualified name |
| Task runs the old notebook code | Deploy Changes after every edit |

## Monitoring

```sql
-- Task run history (last 24h)
SELECT name, state, scheduled_time, return_value, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
  SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())
))
WHERE schema_name = '<YOUR_SCHEMA>'
ORDER BY scheduled_time DESC;

-- Deployed NPOs and their versions
SHOW NOTEBOOK PROJECTS IN SCHEMA <your_db>.<your_schema>;
SHOW VERSIONS IN NOTEBOOK PROJECT <your_db>.<your_schema>.<your_npo>;

-- Trigger manually
EXECUTE TASK <your_db>.<your_schema>.<root_task>;
```

## Cleanup

```sql
ALTER TASK <your_db>.<your_schema>.DATA_PREP_NPO SUSPEND;
DROP TASK IF EXISTS <your_db>.<your_schema>.REPORT_NPO;
DROP TASK IF EXISTS <your_db>.<your_schema>.DATA_PREP_NPO;
-- Drop the demo tables and NPOs if you no longer need them
DROP SCHEMA IF EXISTS <your_db>.<your_schema>;   -- only if the schema was created just for this demo
```

## Before You Go to Production

- [ ] Replace `ACCOUNTADMIN` with a least-privilege service role
- [ ] Move hardcoded names into Task `CONFIG` or environment-specific settings
- [ ] Add input validation for every value parsed from `sys.argv`
- [ ] Add error handling, retries, and failure notifications (for example, a finalizer task or alerts)
- [ ] Test with production-like data volumes and right-size the compute pool and warehouse
- [ ] Use Git integration plus code review for all notebook changes
- [ ] Re-validate the gotchas above whenever you upgrade the runtime version

## License & Support

Shared as-is for educational purposes, without support or warranty. See the disclaimer above.
