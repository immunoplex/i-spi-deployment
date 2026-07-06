# Standalone I-SPI — Install Guide

This is the minimal, corrected path to stand up **I-SPI** as a focused analysis instance —
without Data Portal, the ingest API/Worker, the main Redis, or MinIO. It pairs with the
corrected manifests in this folder and the architecture rationale in `ARCHITECTURE.md`.

**I-SPI does its own fitting.** The I-SPI source performs all standard-curve fitting and the
concentration / se_concentration / pcov calculations *inside the I-SPI pod* (the `stanassay`
package + JAGS, parallelized with the R `future` package), coordinating through the shared
`immunoplex` database. So a complete instance is just I-SPI plus its edge/auth/data layers — no
separate compute service is required, and I-SPI itself needs to be sized generously (see the
resources block in `i-spi.yml`).

The repo's external **Batch Calculator** (`batch-calculator.yml`) is included here as an
**optional** add-on for offloading fitting, but the provided I-SPI build does not call it. Deploy
it only if your I-SPI build is known to hand jobs to it; otherwise skip it.

## What's in this folder vs. what you reuse from the repo

| Manifest | Source | Why |
|---|---|---|
| `i-spi.yml` | **Use this folder's copy** | All corrections; in-process fitting; sized for it |
| `dex.yml` | **Use this folder's copy** | Redirect URIs trimmed to I-SPI (+ whoami test) |
| `traefik.yml` | **Use this folder's copy** | Unused Data Portal middleware removed |
| `coredns.yml` | Repo, unchanged | Internal hostname resolution (K3s) |
| `postgresql.yml` | Repo, unchanged | Database |
| `whoami.yml` | Repo, unchanged *(optional)* | Verifies the auth chain before I-SPI |
| `batch-calculator.yml` | This folder *(optional)* | `DB_SSLMODE` corrected; deploy only if used |

Not used for this install: `data-portal.yml`, `worker.yml`, `api.yml`, `minio.yml`, `redis.yml`.

## Corrections

**`i-spi.yml`**
1. `DEX_CLIENT_SECRET` reads from I-SPI's own `i-spi` Secret instead of the `data-portal`
   Secret — the change that makes a standalone install possible.
2. `REDIRECT_URL: ???` replaced with `DEX_LOGOUT_ENDPOINT`. The I-SPI app's own `.env.sample`
   and `app.R` use `DEX_LOGOUT_ENDPOINT`, not `REDIRECT_URL`, so the original placeholder was for
   a variable the app does not read.
3. `resources` raised and uncommented (requests 2 CPU / 4Gi, limits 8 CPU / 12Gi). Because
   fitting runs in-process, I-SPI is the CPU/memory-heavy component — the original manifest's
   commented values requested 6 CPU / limited 10. Tune to your node.
4. `SHINY_LOG_LEVEL` set to `INFO` (was `DEBUG`).
5. Env reconciled with the app's `.env.sample` and source: added the uppercase **"python
   engine"** DB credential set (`DB`, `DB_HOST`, `DB_PORT`, `DB_USERID_X`, `DB_PWD_X`) and
   `upload_template_path`, both documented by the app but missing from the original manifest.

No batch-submission wiring is set in `i-spi.yml`: the source confirms I-SPI fits in-process and
reads no endpoint/key for the external Batch Calculator.

**`batch-calculator.yml`** *(optional — only if your build offloads fitting to it)*
- `DB_SSLMODE` changed from `disable` to `require`. PostgreSQL's `init.sh` rewrites
  `pg_hba.conf` to reject all non-SSL TCP connections, so a worker with SSL disabled is refused.

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

# ── Only needed if you deploy the OPTIONAL batch-calculator.yml ──
# Strong password for the Batch Calculator's bundled Redis
sed -i "s/IMMUNOPLEX_REDIS_AUTH/PUT_YOUR_REDIS_PASSWORD_HERE/g" *.yml
# API key for the Batch Calculator API
IMMUNOPLEX_API_KEY=$(openssl rand -hex 32)
sed -i "s/IMMUNOPLEX_API_KEY/$IMMUNOPLEX_API_KEY/g" *.yml
```

For a core I-SPI install (no Batch Calculator) you only need the hostname, IP, Postgres
password, and the two OAuth values. The `IMMUNOPLEX_REDIS_AUTH` and `IMMUNOPLEX_API_KEY` lines
matter only if you deploy `batch-calculator.yml`.

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

# 5. I-SPI  — after this, you have a fully working analysis instance
sudo kubectl -n immunoplex apply -f i-spi.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi --timeout=5m

# 6. OPTIONAL: external Batch Calculator (needs PostgreSQL; brings its own Redis).
#    Deploy ONLY if your I-SPI build offloads fitting to it — the provided build
#    does its fitting in-process and will not drive this service.
sudo kubectl -n immunoplex apply -f batch-calculator.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=batch-calculator-redis --timeout=5m
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=batch-calculator-api --timeout=5m
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=batch-calculator-worker --timeout=5m
```

If you deployed the optional Batch Calculator, confirm its API is healthy:

```shell
sudo kubectl -n immunoplex exec -it deploy/batch-calculator-api -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/health').read().decode())"
# Expected: {"status":"ok","redis":"connected"}
```

Then browse to `https://<host>/i-spi/`, log in via Dex, and run a fit — concentration /
se_concentration / pcov results appearing confirms the in-process fitting path works.

## If something doesn't work

- **Login doesn't complete** — almost always an OAuth redirect mismatch. Check the hostname is
  identical everywhere and that `APP_REDIRECT_URI` (`https://<host>/i-spi/`) matches a URI
  registered in `dex.yml`, and that `IMMUNOPLEX_OAUTH_SECRET` is identical in `dex.yml` and the
  `i-spi` Secret. Set `SHINY_LOG_LEVEL` back to `DEBUG` to watch the flow in the pod logs.
- **Fitting is slow or the pod is OOM-killed** — fitting runs in-process, so this is an I-SPI
  sizing issue: raise the CPU/memory limits in `i-spi.yml` and/or move to a larger node. Watch
  pod memory during a fit; Stan/JAGS runs are memory-hungry.
- **(Optional Batch Calculator) worker can't reach the database** — confirm `DB_SSLMODE` is
  `require` (not `disable`); the hardened PostgreSQL rejects non-SSL connections. Note this
  service is idle unless your I-SPI build is wired to submit jobs to it.
