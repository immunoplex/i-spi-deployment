# Database schema

Everything a new, empty PostgreSQL database needs to run I-SPI 1.1 and
i-spi-compute 1.1: the tables, views, functions and triggers, and the default
settings. No project or assay data.

| File | Contents | Source |
|---|---|---|
| `00_schemas.sql` | the schemas `madi_lumi_users` and `madi_results` | written here |
| `10_ispi_core.sql` | projects and access keys, raw assay tables (`xmap_*`), annotations, the curve registry (`curve_lookup`), source aliases, the settings-cascade functions, the `*_for_fit` views the worker fits from | generated from the production schema by `tools/extract_core_ddl.py` |
| `15_fresh_install.sql` | adjustments a new database needs on top of `10_` | written here |
| `20_calib_schema.sql` | the `calib_*` results tables, `control_reference`, `schema_version` (calib schema 0.7.0) | verbatim copy of curveRcore `R/calib_schema.sql` at tag `v0.7.0` |
| `30_seed_settings.sql` | the settings catalog (`calib_settings_meta`) and the system-wide defaults | generated from production (catalog and system tier only) |

[`MANIFEST.md`](MANIFEST.md) lists every object, who uses it, and what was left
out on purpose.

## Loading

The files run in name order into an empty database:

```sh
createdb immunoplex
cat db/[0-9][0-9]_*.sql | psql -v ON_ERROR_STOP=1 immunoplex
```

On Kubernetes, pipe the same files into the PostgreSQL pod:

```sh
cat db/[0-9][0-9]_*.sql | kubectl -n immunoplex exec -i deploy/postgresql -- \
  psql -v ON_ERROR_STOP=1 -U postgres immunoplex
```

The official `postgres` image also runs `*.sql` files from
`/docker-entrypoint-initdb.d/` in name order when it creates a new data
directory, so mounting this folder there works too.

`30_seed_settings.sql` can be re-run; it leaves existing rows alone.

## Testing

`tests/load_test.sh` creates a throwaway PostgreSQL cluster, loads the files and
runs `tests/smoke.sql`:
- a new project gets an access key;
- a new curve gets its multiplate group;
- every view the app and worker read can be queried;
- the settings cascade returns the system defaults;
- `schema_version` reads calib schema 0.7.0.

```sh
db/tests/load_test.sh /usr/lib/postgresql/16/bin    # directory holding initdb, pg_ctl, psql
```

With `DUMP_TO=<file>` it also writes the loaded schema as a `pg_dump`, which
`tools/compare_schema.py` compares object by object with a dump of an existing
database. See MANIFEST.md, "Differences from production".

## Updating

- **curveRcore releases a new calib schema:** copy its `R/calib_schema.sql`
  from the new tag into `20_calib_schema.sql`. Keep the header and update the
  tag and commit in it. Existing databases are upgraded by the i-spi-compute
  migration of the same version, not by this folder.
- **The core schema changes:** take a schema-only dump of production
  (`pg_dump --schema-only --no-owner --no-privileges`), keep it out of git, and
  rerun `python -I tools/extract_core_ddl.py <dump> 10_ispi_core.sql`. A new
  object the app or worker needs must be added to `KEEP` in that script and to
  MANIFEST.md.
