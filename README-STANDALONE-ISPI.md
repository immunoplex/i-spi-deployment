# Standalone I-SPI — Install Guide

This is the minimal, corrected path to stand up **I-SPI** as a focused analysis instance —
without Data Portal, the platform's ingest API/Worker, the platform's main Redis, or MinIO. It
pairs with the corrected manifests in this folder and the architecture rationale in
`ARCHITECTURE.md`.

**Fitting runs in i-spi-compute, not in I-SPI.** I-SPI **enqueues** fitting jobs to the
i-spi-compute API; the API queues them in Redis; the **curveR** worker runs the frequentist and
Bayesian (Stan/JAGS) fits and writes the concentration / se_concentration / pcov results to the
`calib_*` tables in the shared `immunoplex` database; and I-SPI **reads those results back**. So
a complete instance is I-SPI **plus** the required i-spi-compute tier (`i-spi-compute.yml` —
API + Redis + worker) plus its edge/auth/data layers. The worker — not I-SPI — is the component
to size generously (see `ARCHITECTURE.md` §2.5).

The former external **Batch Calculator** (`batch-calculator.yml`) is **retired** and replaced by
i-spi-compute; do not deploy it.

## What's in this folder vs. what you reuse from the repo

| Manifest | Source | Why |
|---|---|---|
| `i-spi.yml` | **Use this folder's copy** | All corrections; wires `ISPI_COMPUTE_*` to the fitting tier |
| `i-spi-compute.yml` | **Use this folder's copy** | **Required** fitting tier: API + Redis + curveR worker |
| `dex.yml` | **Use this folder's copy** | Redirect URIs trimmed to I-SPI (+ whoami test) |
| `traefik.yml` | **Use this folder's copy** | Unused Data Portal middleware removed |
| `coredns.yml` | Repo, unchanged | Internal hostname resolution (K3s) |
| `postgresql.yml` | Repo, unchanged | Database |
| `whoami.yml` | Repo, unchanged *(optional)* | Verifies the auth chain before I-SPI |

Not used for this install: `data-portal.yml`, `worker.yml`, `api.yml`, `minio.yml`, `redis.yml`,
and the retired `batch-calculator.yml`.

## Corrections

**`i-spi.yml`**
1. `DEX_CLIENT_SECRET` reads from I-SPI's own `i-spi` Secret instead of the `data-portal`
   Secret — the change that makes a standalone install possible.
2. `REDIRECT_URL: ???` replaced with `DEX_LOGOUT_ENDPOINT`. The I-SPI app's own `.env.sample`
   and `app.R` use `DEX_LOGOUT_ENDPOINT`, not `REDIRECT_URL`, so the original placeholder was for
   a variable the app does not read.
3. `resources` set to sane starting values. I-SPI no longer fits curves, so it is **not** the
   heavy component — the worker in `i-spi-compute.yml` is. Size I-SPI for concurrent users; size
   the worker for fitting (see `ARCHITECTURE.md` §2.5).
4. `SHINY_LOG_LEVEL` set to `INFO` (was `DEBUG`).
5. Env reconciled with the app's `.env.sample` and source: added the uppercase **"python
   engine"** DB credential set (`DB`, `DB_HOST`, `DB_PORT`, `DB_USERID_X`, `DB_PWD_X`) and
   `upload_template_path`, both documented by the app but missing from the original manifest.

6. Compute wiring: `i-spi.yml` sets `ISPI_COMPUTE_URL` (`https://HOST/i-spi-compute`) and
   `ISPI_COMPUTE_API_KEY` (filled by `sed` to the same `IMMUNOPLEX_API_KEY` the compute API
   enforces). The app's `compute_api_client.R` reads these to submit fit jobs. The retired
   `BATCH_API_URL`/`BATCH_API_KEY` variables are gone.

**`i-spi-compute.yml`** *(required)*
- The fitting tier: `i-spi-compute-api` (FastAPI job broker, `X-API-Key` auth),
  `i-spi-compute-redis` (`redis:7`, `--requirepass` `IMMUNOPLEX_REDIS_AUTH`), and
  `i-spi-compute-worker` (curveR engine). The worker connects to PostgreSQL with
  `DB_SSLMODE=require` — the hardened PostgreSQL rejects non-SSL connections.

## Configure (the `sed` step)

From the folder holding these manifests:

```shell
# Hostname users type in the browser
sed -i "s/IMMUNOPLEX_HOSTNAME/PUT_YOUR_HOSTNAME_HERE/g" *.yml coredns.yml postgresql.yml

# This host's IP (CoreDNS internal resolution on K3s)
sed -i "s/IMMUNOPLEX_IP_ADDRESS/PUT_YOUR_IP_ADDRESS_HERE/g" coredns.yml

# Strong PostgreSQL password
sed -i "s/IMMUNOPLEX_POSTGRES_PASSWORD/PUT_YOUR_POSTGRES_PASSWORD_HERE/g" *.yml postgresql.yml

# OAuth client id + secret (must match across dex.yml and i-spi.yml)
IMMUNOPLEX_OAUTH_CLIENT_ID=$(openssl rand -hex 32)
sed -i "s/IMMUNOPLEX_OAUTH_CLIENT_ID/$IMMUNOPLEX_OAUTH_CLIENT_ID/g" *.yml
IMMUNOPLEX_OAUTH_SECRET=$(openssl rand -hex 32)
sed -i "s/IMMUNOPLEX_OAUTH_SECRET/$IMMUNOPLEX_OAUTH_SECRET/g" *.yml

# ── Required: i-spi-compute fitting tier ──
# Strong password for the i-spi-compute Redis (shared by Redis, the API, and the worker)
sed -i "s/IMMUNOPLEX_REDIS_AUTH/PUT_YOUR_REDIS_PASSWORD_HERE/g" *.yml
# API key shared by the i-spi-compute API and I-SPI (ISPI_COMPUTE_API_KEY)
IMMUNOPLEX_API_KEY=$(openssl rand -hex 32)
sed -i "s/IMMUNOPLEX_API_KEY/$IMMUNOPLEX_API_KEY/g" *.yml
```

You need all of these: hostname, IP, Postgres password, the two OAuth values, **and**
`IMMUNOPLEX_REDIS_AUTH` + `IMMUNOPLEX_API_KEY`, because i-spi-compute is required. The single
`sed` pass fills each placeholder everywhere it appears, so the shared values match across
`i-spi-compute.yml` and `i-spi.yml` (`IMMUNOPLEX_API_KEY`) and across the API/worker/Redis
(`IMMUNOPLEX_REDIS_AUTH`).

If you also deploy the optional `whoami.yml` test harness, generate its cookie secret too:
`IMMUNOPLEX_OAUTH_COOKIE_SECRET=$(openssl rand -hex 16)` and `sed` it into `whoami.yml`. You do
**not** need the MinIO placeholder for this install.

> Keep the substituted copies out of version control — they now contain real secrets.

## Deploy (bottom-up, in order)

Assumes the `immunoplex` namespace exists and cert-manager + the root/intermediate CA are
installed per `K3S.md`. Apply everything into the `immunoplex` namespace.

```shell
# 1. DNS (K3s) and ingress controller
sudo kubectl -n immunoplex apply -f coredns.yml
sudo kubectl -n kube-system rollout restart deploy coredns
sudo kubectl -n immunoplex apply -f traefik.yml

# 2. Authentication
sudo kubectl -n immunoplex apply -f dex.yml

# 3. (Optional) verify the auth chain before going further
sudo kubectl -n immunoplex apply -f whoami.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=whoami --timeout=5m
#    Browse to https://<host>/whoami, sign up, log in, confirm X-Forwarded-Email appears.

# 4. Database — then create and load the I-SPI database
sudo kubectl -n immunoplex apply -f postgresql.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=postgresql --timeout=5m
sudo kubectl -n immunoplex exec -it deploy/postgresql -- psql -U postgres -c "CREATE DATABASE immunoplex;"
sudo kubectl -n immunoplex exec -it deploy/postgresql -- psql -U postgres immunoplex < db-dumps/i-spi-db.sql

# 5. i-spi-compute — the REQUIRED fitting tier (Redis + API + worker).
#    Bring it up BEFORE I-SPI so the enqueue path has somewhere to go.
sudo kubectl -n immunoplex apply -f i-spi-compute.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi-compute-redis  --timeout=5m
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi-compute-api    --timeout=5m
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi-compute-worker --timeout=5m

# 6. I-SPI — after this, you have a fully working analysis instance
sudo kubectl -n immunoplex apply -f i-spi.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi --timeout=5m
```

Confirm the fitting tier is healthy (the API reports Redis connectivity):

```shell
sudo kubectl -n immunoplex exec -it deploy/i-spi-compute-api -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/health').read().decode())"
# Expected: {"status":"ok","redis":"connected"}
```

Then browse to `https://<host>/i-spi/`, log in via Dex, and run a fit. I-SPI submits the job to
i-spi-compute, the worker fits the curves and writes `calib_*`, and the results (concentration /
se_concentration / pcov) appearing in I-SPI confirm the whole
enqueue → worker → `calib_*` → read chain works.

## If something doesn't work

- **Login doesn't complete** — almost always an OAuth redirect mismatch. Check the hostname is
  identical everywhere and that `APP_REDIRECT_URI` (`https://<host>/i-spi/`) matches a URI
  registered in `dex.yml`, and that `IMMUNOPLEX_OAUTH_SECRET` is identical in `dex.yml` and the
  `i-spi` Secret. Set `SHINY_LOG_LEVEL` back to `DEBUG` to watch the flow in the pod logs.
- **Fitting is slow or a pod is OOM-killed during a fit** — this is a **worker** sizing issue,
  not I-SPI: raise the CPU/memory limits on `i-spi-compute-worker` (keep its CPU limit and
  `WORKER_CORES` equal) and/or run more worker replicas. Stan/JAGS runs are memory-hungry.
- **Fits never start / I-SPI reports it can't submit a job** — check I-SPI can reach the API:
  `curl https://<host>/i-spi-compute/health` from the I-SPI pod should return
  `{"status":"ok","redis":"connected"}`. If `/health` is fine but submitting 401/403s, the
  `IMMUNOPLEX_API_KEY` in `i-spi.yml` and `i-spi-compute.yml` don't match (re-run the single
  `sed` pass so both get the same value).
- **Worker can't reach the database** — confirm the worker's `DB_SSLMODE` is `require` (not
  `disable`); the hardened PostgreSQL rejects non-SSL connections.
