# Local stack (Docker Compose)

The whole system on one machine, for trying I-SPI, testing a release, or
developing against real services. It runs the same images as the Kubernetes
manifests:

| Service | Image | Reached at |
|---|---|---|
| `i-spi` | `ghcr.io/immunoplex/i-spi:1.1.0` | http://localhost:3838/ |
| `dex` | `dexidp/dex:v2.44.0` | http://localhost:5556/dex (sign-in) |
| `i-spi-compute-api` | `ghcr.io/immunoplex/i-spi-compute-api:1.1.0` | http://localhost:8000/docs (optional) |
| `i-spi-compute-worker` | `ghcr.io/immunoplex/i-spi-compute-worker:1.1.0` | no port |
| `i-spi-compute-redis` | `redis:7.4` | no port |
| `postgres` | `postgres:16`, schema from `../db` | `localhost:5433` (optional) |

All ports are bound to `127.0.0.1`: nothing is reachable from other machines.

## Requirements

- Docker with Compose v2 (Docker Desktop on Windows or macOS, Docker Engine on Linux).
- About 8 GB of disk for the images; the worker image alone is about 5 GB.
- 4 CPUs and 8 GB of memory for the worker by default. See "Worker size" below.
- The worker image is built for amd64. On Apple silicon, Docker runs it under
  emulation, which is much slower.

## Start

```sh
cd local
cp .env.example .env      # then replace every change-me, e.g. with: openssl rand -hex 24
docker compose up -d
```

The first start downloads the images and loads the schema into the new
database. Then open http://localhost:3838/ and sign in with:

- **Email:** `ispi-user@example.org`
- **Password:** `ispi-local`

`dex.yaml` holds this account; how to change the password is described there.

## What to expect on first use

The database starts empty: no projects, studies or data. In I-SPI:
1. Create a project.
2. Create a study.
3. Import plates.
4. Run a fit.

The fit goes to the local worker. Its progress shows in I-SPI, and the
results appear in the study's views and in Data > Results.

## Day to day

```sh
docker compose ps                              # what is running
docker compose logs -f i-spi                   # I-SPI log (sign-in, errors)
docker compose logs -f i-spi-compute-worker    # fitting
docker compose stop                            # stop, keep the data
docker compose up -d                           # start again
docker compose down -v                         # remove everything, including the database
```

To look at the database: `psql "host=localhost port=5433 dbname=immunoplex user=postgres sslmode=require"`,
with the password from `.env`.

## Worker size

`WORKER_CORES`, `WORKER_CPUS` and `WORKER_MEMORY` in `.env` size the worker:
- `WORKER_CORES` caps how many curves it fits in parallel and its Stan chains.
  It must not exceed `WORKER_CPUS`.
- The worker plans its parallel fits against `WORKER_MEMORY`.

Bayesian fits of large studies want more of both; production runs with 16
CPUs and 16 GB.

## Upgrading

Change the image tags in `docker-compose.yml` and run `docker compose up -d`.
The database keeps its data. If a new i-spi-compute release brings a new calib
schema version, apply that release's migration from i-spi-compute
`worker/migrations/` to the existing database before starting the new worker.
`../db` is only loaded into an empty database.

## How it differs from the Kubernetes install

- **No Traefik, TLS or hostname:** everything is plain HTTP on localhost.
- **Dex** keeps no database: it has one fixed account, and no signup page.
- **PostgreSQL** uses the image's self-signed certificate. I-SPI and the worker
  always connect with TLS, as in production.
