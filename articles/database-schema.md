# Database schema

The folder
[`db/`](https://github.com/immunoplex/i-spi-deployment/tree/main/db)
creates the complete schema in an empty database: tables, views,
functions, triggers, and the default settings. An existing database is
upgraded with i-spi-compute’s migrations instead; see
[Upgrading](https://immunoplex.github.io/i-spi-deployment/articles/upgrading.md).

Everything a new, empty PostgreSQL database needs to run I-SPI 1.1 and
i-spi-compute 1.1: the tables, views, functions and triggers, and the
default settings. No project or assay data.

| File | Contents | Source |
|----|----|----|
| `00_schemas.sql` | the schemas `madi_lumi_users` and `madi_results` | written here |
| `10_ispi_core.sql` | projects and access keys, raw assay tables (`xmap_*`), annotations, the curve registry (`curve_lookup`), source aliases, the settings-cascade functions, the `*_for_fit` views the worker fits from | generated from the production schema by `tools/extract_core_ddl.py` |
| `15_fresh_install.sql` | adjustments a new database needs on top of `10_` | written here |
| `20_calib_schema.sql` | the `calib_*` results tables, `control_reference`, `schema_version` (calib schema 0.7.0) | verbatim copy of curveRcore `R/calib_schema.sql` at tag `v0.7.0` |
| `30_seed_settings.sql` | the settings catalog (`calib_settings_meta`) and the system-wide defaults | generated from production (catalog and system tier only) |
| `40_ispi_export.sql` | the `ispi_export` schema: read-only views other systems use to read I-SPI results (`model_qc`, `standard_curve`, `sample_qc`, the raw tables) and `check_access_key()` | written here |

[`MANIFEST.md`](https://github.com/immunoplex/i-spi-deployment/blob/main/db/MANIFEST.md)
lists every object, who uses it, and what was left out on purpose.

## Loading

The files run in name order into an empty database:

``` sh
createdb immunoplex
cat db/[0-9][0-9]_*.sql | psql -v ON_ERROR_STOP=1 immunoplex
```

On Kubernetes, pipe the same files into the PostgreSQL pod:

``` sh
cat db/[0-9][0-9]_*.sql | kubectl -n immunoplex exec -i deploy/postgresql -- \
  psql -v ON_ERROR_STOP=1 -U postgres immunoplex
```

The official `postgres` image also runs `*.sql` files from
`/docker-entrypoint-initdb.d/` in name order when it creates a new data
directory, so mounting this folder there works too.

`30_seed_settings.sql` can be re-run; it leaves existing rows alone.
`40_ispi_export.sql` can be re-run, and can be loaded on its own into an
existing database: it only creates the `ispi_export` schema, its views
and functions, and grants them to the role `ispi_export_reader` when
that exists.

## Testing

`tests/load_test.sh` creates a throwaway PostgreSQL cluster, loads the
files and runs `tests/smoke.sql`: - a new project gets an access key; -
a new curve gets its multiplate group; - every view the app and worker
read can be queried; - the settings cascade returns the system
defaults; - `schema_version` reads calib schema 0.7.0.

``` sh
db/tests/load_test.sh /usr/lib/postgresql/16/bin    # directory holding initdb, pg_ctl, psql
```

With `DUMP_TO=<file>` it also writes the loaded schema as a `pg_dump`,
which `tools/compare_schema.py` compares object by object with a dump of
an existing database. See MANIFEST.md, “Differences from production”.

## Updating

- **curveRcore releases a new calib schema:** copy its
  `R/calib_schema.sql` from the new tag into `20_calib_schema.sql`. Keep
  the header and update the tag and commit in it. Existing databases are
  upgraded by the i-spi-compute migration of the same version, not by
  this folder.
- **The core schema changes:** take a schema-only dump of production
  (`pg_dump --schema-only --no-owner --no-privileges`), keep it out of
  git, and rerun
  `python -I tools/extract_core_ddl.py <dump> 10_ispi_core.sql`. A new
  object the app or worker needs must be added to `KEEP` in that script
  and to MANIFEST.md.

## Manifest

What the files in `db/` create, who uses each object, and what was left
out. Checked against I-SPI 1.1.0 and i-spi-compute 1.1.0 (2026-11-19);
I-SPI 1.1.1 and i-spi-compute 1.1.1 change no database objects.
`40_ispi_export.sql` added 2026-11-23 (I-SPI 1.3.0).

- **A** is the I-SPI app (`immunoplex/i-spi`, `src/`).
- **W** is the i-spi-compute worker. The compute API itself does not
  touch the database.
- An object counts as used only if code the app or worker actually runs
  reaches it. A function that mentions a table but is never called does
  not count.

### Created

#### `madi_lumi_users` (10_ispi_core.sql)

| Object | Kind | Used by |
|----|----|----|
| `projects` | table | A: user management, project picker |
| `project_users` | table | A: project membership |
| `project_access_keys` | table | A: joins projects to their access key |
| `public.add_project_access_key()` + trigger `after_project_insert` | function, trigger | creates the access key when a project is inserted |

#### `madi_results`: raw data and registry (10_ispi_core.sql)

| Object | Kind | Used by |
|----|----|----|
| `xmap_header`, `xmap_standard`, `xmap_control`, `xmap_buffer`, `xmap_sample` | tables | A: import, Data tab, plate views; W via the `*_for_fit` views |
| `xmap_antigen_family` | table | A: import, study clone/delete |
| `xmap_planned_visit` | table | A: import (planned visits are written inside the import transaction) |
| `xmap_users` | table | A: workspace per user |
| `annotation_analyte`, `annotation_level`, `annotation_order` | tables | A: annotations, bundles |
| `curve_lookup` | table | A and W: the curve registry every result row joins to |
| `madi_multiplate_group_id()`, `trg_set_multiplate_group_id()` + trigger | functions, trigger | set `curve_lookup.multiplate_group_id` on insert; W groups fits by it |
| `curve_lookup_unmasked` | view | A: curve reads, source-alias review |
| `source_alias` | table | A: source-name editor, curve comparison |
| `calib_recalc_flag` | table | A: deferred recompute after unmasking. A creates it itself if missing; it is created here so the app does not need CREATE rights on the schema |
| `sample_for_fit`, `standard_for_fit`, `blank_for_fit` | views | W: the points each fit uses |
| `control_for_fit` | view | W: the control wells estimated after each fit; A: Replicate Linearity |
| `calib_settings_candidates()`, `resolve_settings()`, `resolve_settings_batch()` | functions | A: settings cascade; W: settings for each curve |

#### `madi_results`: results and settings (20_calib_schema.sql, curveRcore 0.7.0)

`calib_run`, `calib_fit`, `calib_param`, `calib_gate`, `calib_grid`,
`calib_samples`, `calib_standards`, `calib_controls`, `calib_blanks`,
`calib_diagnostics`, `calib_loo`, `calib_fit_diag`, `calib_hyperparam`,
`calib_draws`, `calib_weights`, `calib_weights_fit`,
`control_reference`, the view `calib_controls_qc`, `calib_settings`,
`calib_settings_meta`, `calib_settings_migration_log`,
`calib_settings_studycfg_log`, `schema_version`.

W writes the results and A reads them. The two `calib_settings_*_log`
tables are not used at run time; they come with the curveRcore contract.

#### Data (30_seed_settings.sql)

- **`calib_settings_meta`:** 33 settings with group, label, type,
  control and description.
- **`calib_settings` with `project_id = -1`:** the 30 system-wide
  defaults.

No project, study or user data.

#### `ispi_export` (40_ispi_export.sql)

The read-only interface for systems outside I-SPI (first: the MADI Data
Portal’s I-SPI migration). Consumers get access to this schema only.

| Object | Kind | Used by |
|----|----|----|
| `model_qc` | view | best fit per curve and method (frequentist and Bayesian): parameters, LOQ/LOD/MDC/RDL, inflection, fit statistics. Columns 1-39 keep the names of the retired `get_model_qc_data()` |
| `standard_curve` | view | standard-curve parameters per curve and method; replaces reads of the retired `best_glance_all` |
| `sample_qc` | view | sample estimates per well, curve and method, with the raw well data; columns 1-20 keep the names of the retired `get_sample_qc_data()`. Gate classes from `censor_class`, else the curve limits, else `pcov_gate_class` (`gate_class_basis` says which) |
| `xmap_header`, `xmap_sample`, `xmap_control`, `xmap_buffer`, `xmap_standard`, `xmap_planned_visit` (+ `xmap_subjects`, `xmap_sample_timing` where those legacy tables exist) | views | the raw tables, unchanged |
| `check_access_key(project_id, key)` | function (owner’s rights) | validates a project access key without exposing `project_access_keys` |
| `model_y()`, `model_dydx()`, `safe_exp()`, `safe_pow()` | functions | the curve models used by `model_qc`; match curveRcore to 1e-14 |

### Left out

These exist in the production database but nothing in I-SPI 1.1 or
i-spi-compute 1.1 uses them.

| Objects | Why |
|----|----|
| `best_glance_all`, `best_plate_all`, `best_pred_all`, `best_sample_se_all`, `best_standard_all`, `best_tidy_all` | results of the retired batch calculator; replaced by `calib_*` |
| `bayes_cdan_grid`, `bayes_curve_grid`, `bayes_curves`, `bayes_ensemble`, `bayes_pareto_k`, `bayes_samples`, `bayes_job_audit` | the earlier Bayesian pipeline; replaced by `calib_*` |
| `freq_*` | an earlier frequentist pipeline |
| `xmap_standard_fits`, `xmap_standard_fit_tab`, `xmap_standard_preds`, `xmap_standard_stor`, `xmap_profile`, `xmap_subjects`, `xmap_sample_timing`, `xmap_arm_reference` | no code reads them |
| `xmap_study_config`, `xmap_dilution_analysis`, `xmap_dilution_parameters` | optional: study clone/delete include them when present and skip them otherwise. Study settings live in the settings cascade |
| `antigen_feature_settings` (view), `antigen_feature_settings_static_backup` | superseded by the settings cascade |
| `header_unmasked`, `standard_unmasked`, `control_unmasked`, `sample_unmasked`, `blank_unmasked`, `curve_lookup_canon` | unused views |
| `madi_lumi_users.users` | unused |
| schema `madi_lumi_reader_outliers` | the outlier module was retired from the app |
| schema `madi_vendor_export` | written by a process outside I-SPI and i-spi-compute |
| `db_*`, `mbaa_samples`, `tmp_*`, `dev_curves`, `public._dev_curves` | scratch tables |
| procedures `database_control_samples`, `database_std_curves`, `db_control_results`, `mbaa_for_database`; functions `get_job_status*`, `get_freq_status`, `get_model_qc_data`, `get_sample_qc_data`, `*antigen_slash*`, `public.clean_plate_id`, `public.count_study_accession_rows`, `public.delete_study_accession_rows` | not called |
| ImmPort reference data (`madi_dat`, `lk_*`; the old `dataportal.sql.gz`) | I-SPI does not read it |

### Differences from production

`tests/load_test.sh` with `DUMP_TO` followed by
`tools/compare_schema.py` compares every created object with production.
150 of 157 objects match exactly (2026-11-19). The rest differ only as
listed here:

| Object | Difference |
|----|----|
| `curve_lookup` | **Intended.** The check reads `project_id > 0` instead of production’s `project_id >= 16`. A new database numbers its projects from 1; see `15_fresh_install.sql`. |
| `calib_samples`, `calib_draws` | Unnamed CHECK constraints in curveRcore’s file get PostgreSQL’s generated names (`*_check`), while production has `*_chk`. |
| `calib_samples` | `agroup` is `varchar(40)` as in the contract and in `xmap_sample.agroup`, from which it is copied; production’s column was widened to 128 by hand. |
| `calib_samples`, `calib_diagnostics` | Column order: production added some columns at the end, through migrations. |
| `calib_settings`, `calib_settings_meta`, `curve_lookup_unmasked` | Printed differently by PostgreSQL 16 than by production’s 14; the definitions are the same. |
