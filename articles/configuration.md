# Configuration and secrets

There is no secret manager in this deployment. The manifests hold
placeholders, and one `sed` pass at install time replaces them ([cluster
guide, step
5](https://immunoplex.github.io/i-spi-deployment/articles/install-cluster.html#configure)).
Secrets then sit in plain Kubernetes Secrets inside the cluster. Keep
the configured manifests out of version control.

## Placeholders

| Placeholder | Value | Where it ends up |
|----|----|----|
| `IMMUNOPLEX_HOSTNAME` | the name users type in the browser | Ingresses, the sign-in issuer, every redirect URI |
| `IMMUNOPLEX_IP_ADDRESS` | the node’s IP | `coredns.yml` (K3s only), so pods resolve the hostname |
| `IMMUNOPLEX_POSTGRES_PASSWORD` | `openssl rand -hex 16` | Secret `postgresql`; read by PostgreSQL, I-SPI and the worker |
| `IMMUNOPLEX_OAUTH_CLIENT_ID` | `openssl rand -hex 32` | Dex’s client (`dex.yml`) and I-SPI |
| `IMMUNOPLEX_OAUTH_SECRET` | `openssl rand -hex 32` | Dex’s client and Secret `i-spi` |
| `IMMUNOPLEX_REDIS_AUTH` | `openssl rand -hex 32` | Secret `i-spi-compute`; Redis password, read by Redis, the API and the worker |
| `IMMUNOPLEX_API_KEY` | `openssl rand -hex 32` | Secret `i-spi-compute`; the compute API’s key, read by the API and I-SPI |
| `IMMUNOPLEX_OAUTH_COOKIE_SECRET` | `openssl rand -hex 16` | `whoami.yml` only (optional test page) |

## Secrets

| Secret | Defined in | Keys | Read by |
|----|----|----|----|
| `postgresql` | `postgresql.yml` | `POSTGRES_PASSWORD` | PostgreSQL, I-SPI, the worker |
| `i-spi` | `i-spi.yml` | `DEX_CLIENT_SECRET` | I-SPI |
| `i-spi-compute` | `i-spi-compute.yml` | `API_KEY`, `REDIS_AUTH` | API, worker, Redis, I-SPI; also the optional sim tier |
| `dex` | `dex.yml` | Dex’s configuration | Dex |
| `whoami` | `whoami.yml` | cookie secret | oauth2-proxy (optional) |

A pod reads a Secret when it starts. After changing a Secret, restart
every pod that reads it.

## Environment of each image

The manifests set exactly the variables the images read.

**I-SPI 1.1.1** (`i-spi.yml`)

| Variable | Meaning |
|----|----|
| `db`, `db_host`, `db_port`, `db_userid_x`, `db_pwd_x` | the database. I-SPI always connects with TLS |
| `DEX_ISSUER` | the public sign-in address, `https://<host>/dex` |
| `DEX_INTERNAL_URL` | Dex inside the cluster, `http://dex:5556/dex`, for discovery and token exchange |
| `DEX_CLIENT_ID`, `DEX_CLIENT_SECRET` | I-SPI’s client in Dex |
| `APP_REDIRECT_URI` | `https://<host>/i-spi/`; must be one of the client’s `redirectURIs` in `dex.yml` |
| `ISPI_COMPUTE_URL`, `ISPI_COMPUTE_API_KEY` | the default compute tier (`http://i-spi-compute-api:8000`) and its key |
| `ISPI_COMPUTE_URL__<NAME>`, `ISPI_COMPUTE_API_KEY__<NAME>` | optional further tiers; see [Compute tiers](https://immunoplex.github.io/i-spi-deployment/articles/compute-tiers.md) |
| `SHINY_LOG_LEVEL`, `SHINY_LOG_STDERR` | Shiny Server logging. `INFO` normally, `DEBUG` to follow a sign-in |

For development, I-SPI also reads `LOCAL_DEV` and `LOCAL_DEV_EMAIL`:
with `LOCAL_DEV=1` it skips sign-in and acts as `LOCAL_DEV_EMAIL`. Never
set `LOCAL_DEV` in a deployment.

**i-spi-compute 1.1.0 API** (`i-spi-compute.yml`)

| Variable | Meaning |
|----|----|
| `REDIS_HOST`, `REDIS_PORT`, `REDIS_DB`, `REDIS_AUTH` | the job queue |
| `API_KEY` | every request except `/health` must send it as the `X-API-Key` header |
| `ROOT_PATH` | the public path prefix, used in the API’s own documentation links |

**i-spi-compute 1.1.0 worker** (`i-spi-compute.yml`)

| Variable | Meaning |
|----|----|
| `REDIS_HOST`, `REDIS_PORT`, `REDIS_DB`, `REDIS_AUTH` | the job queue |
| `DB_NAME`, `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD` | the database |
| `DB_SSLMODE` | must be `require`: PostgreSQL rejects connections without TLS |
| `PROGRESS_DIR` | where job progress files go (`/tmp`) |
| `WORKER_CORES` | how many fits run in parallel, and the cap on Stan chains. Must equal the container’s CPU limit |

The worker reads its memory budget from the container’s memory limit.
