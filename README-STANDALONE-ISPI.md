# Standalone I-SPI — Install Guide

This is the minimal path to stand up **I-SPI** as a focused analysis instance —
without Data Portal, the platform's ingest API/Worker, the platform's main Redis, or MinIO. It
uses the manifests in `k8s-manifests/` and the architecture rationale in
`ARCHITECTURE.md`.

**Fitting runs in i-spi-compute, not in I-SPI.** I-SPI **enqueues** fitting jobs to the
i-spi-compute API; the API queues them in Redis; the **curveR** worker runs the frequentist and
Bayesian (Stan) fits and writes the concentration / se_concentration / pcov results to the
`calib_*` tables in the shared `immunoplex` database; and I-SPI **reads those results back**. So
a complete instance is I-SPI **plus** the required i-spi-compute tier (`i-spi-compute.yml` —
API + Redis + worker) plus its edge/auth/data layers. The worker — not I-SPI — is the component
to size generously (see `ARCHITECTURE.md` §2.5).

The former external Batch Calculator has been removed; i-spi-compute replaces it.

## The manifests

| Manifest | What it runs | Needed |
|---|---|---|
| `coredns.yml` | internal name resolution for the hostname (K3s) | yes |
| `traefik.yml` | ingress and TLS; defines the path middlewares | yes |
| `dex.yml` | sign-in (Dex) and self-service signup | yes |
| `postgresql.yml` | the `immunoplex` database (TLS only); schema from `../db/` | yes |
| `i-spi-compute.yml` | the fitting tier: API, Redis queue, curveR worker; the `i-spi-compute` Secret | **yes** |
| `i-spi.yml` | I-SPI 1.1.0 | yes |
| `whoami.yml` | a test page that shows the signed-in user | optional |
| `i-spi-compute-sim.yml` | a second, independent fitting tier | optional |

Images are pinned: I-SPI `1.1.0`, i-spi-compute `1.1.0` (curveRcore 0.7.0,
curveRfreq 0.5.2, curveRbayes 0.5.2, curveRweights 0.3.0, CmdStan 2.40.0). To
upgrade, change the tags and re-apply; to roll back, apply the previous tags.

**How the pieces connect.**
- I-SPI connects to PostgreSQL as `db_*` with TLS, and to Dex for sign-in:
  `DEX_INTERNAL_URL` inside the cluster for discovery and tokens, and the public
  `DEX_ISSUER` for the browser.
- I-SPI posts fit jobs to `http://i-spi-compute-api:8000`, the in-cluster
  Service, with the API key from the `i-spi-compute` Secret. No TLS or Ingress
  is involved, so the compute Ingress in `i-spi-compute.yml` is optional.
- The worker reads jobs from Redis, reads the points to fit from the database's
  `*_for_fit` views, and writes the `calib_*` tables, which I-SPI reads back.
- With `i-spi-compute-sim.yml` and the two `ISPI_COMPUTE_*__SIM` variables in
  `i-spi.yml` uncommented, the `compute_cluster` setting sends chosen projects
  or studies to the second tier.

`i-spi.yml` sets only the variables I-SPI 1.1.0 reads; its header lists them.

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
cat ../db/[0-9][0-9]_*.sql | sudo kubectl -n immunoplex exec -i deploy/postgresql -- psql -v ON_ERROR_STOP=1 -U postgres immunoplex   # schema: see db/README.md

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
  `WORKER_CORES` equal) and/or run more worker replicas. Stan runs are memory-hungry.
- **Fits never start / I-SPI reports it can't submit a job** — check the API from the I-SPI
  pod: `curl http://i-spi-compute-api:8000/health` should return
  `{"status":"ok","redis":"connected"}`. I-SPI and the API read the same key from the
  `i-spi-compute` Secret, so a 401/403 means that Secret changed after the I-SPI pod started:
  restart I-SPI.
- **Worker can't reach the database** — confirm the worker's `DB_SSLMODE` is `require` (not
  `disable`); the hardened PostgreSQL rejects non-SSL connections.
