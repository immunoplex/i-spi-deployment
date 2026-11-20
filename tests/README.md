# Checks

Three checks run on every pull request and every push to `main`
(`.github/workflows/checks.yml`). Each is a script you can run locally from the
repo root.

| Check | What it proves | Run locally |
|---|---|---|
| **db** | `db/` loads into an empty PostgreSQL in one session. Smoke checks: a new project gets an access key, a new curve gets its multiplate group, every view and settings function the app and worker use runs, the settings cascade returns the system defaults, `schema_version` is 0.7.0 | `db/tests/load_test.sh /usr/lib/postgresql/16/bin` (the folder holding `initdb`, `pg_ctl`, `psql`) |
| **manifests** | Every manifest and the Compose file parse. Every `secretKeyRef` names a Secret the manifests define. Every `IMMUNOPLEX_*` placeholder is filled by the guide's `sed` step. Every `ghcr.io/immunoplex` image is pinned (release tag or digest). The Compose file uses the same I-SPI and i-spi-compute versions as the manifests | `python3 tests/check_manifests.py` (needs PyYAML) |
| **e2e** | The local stack (`local/docker-compose.yml`) does a real fit. Steps below | `tests/e2e/run_e2e.sh` |

The e2e steps:
1. Start the stack on an empty database.
2. Seed a small synthetic study (`tests/e2e/seed.sql`): 2 plates; 8 standard dilutions in duplicate; blanks, controls and samples.
3. Submit a frequentist fit to the compute API, as I-SPI does.
4. Wait for the job to finish.
5. Check what the worker wrote (`tests/e2e/check.sql`):
   - the run with its release manifest;
   - the best model per curve, parameters, grid and diagnostics;
   - all 8 samples;
   - all 32 standards with their stored estimates;
   - the blanks;
   - all 8 controls.

Before running the e2e test locally:
- **It deletes the local stack's data:** it runs `docker compose down -v` before and after.
- `KEEP_STACK=1` leaves the stack running afterwards, for inspection.
- On Windows, set `PYTHON=python`.
- The first run downloads the images, about 8 GB.
- The fit itself takes seconds.
