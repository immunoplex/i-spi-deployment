# ImmunoPlex Deployment (Standalone I-SPI)

ImmunoPlex enables researchers to assess, analyze, and share data. ImmunoPlex improves QA and QC practices to make them accessible and standardized. We offer tools that enable discovery by increasing statistical power. ImmunoPlex promotes data interoperability, making research more transparent and data more reusable for the community.

This repo provides instructions and manifests for deploying a **standalone I-SPI** analysis instance — I-SPI plus the edge (Traefik), authentication (Dex), and data (PostgreSQL) layers it needs — on your choice of Kubernetes cluster. Data Portal, the ingest API/Worker, the main Redis, and MinIO belong to the larger data-sharing platform and are **not** part of this deployment.

If you don't have a Kubernetes cluster, you can use [k3s](https://rancher.com/docs/k3s/latest/en/). K3s installation instructions are provided below.

Deploy the applications and services in the order listed in this document.

## Documentation map

| Document | What it's for |
|---|---|
| **README.md** (this file) | The quick, ordered install for a standalone I-SPI instance |
| `README-STANDALONE-ISPI.md` | The detailed runbook, the corrected-manifest notes, and troubleshooting |
| `ARCHITECTURE.md` | Why the pieces fit together, sizing, and the design choices behind them |
| `K3S.md` | Installing single-node K3s + cert-manager + the private CA (if you have no cluster) |
| `OFFLINE-IMAGES.md` | Obtaining and side-loading container images for offline / air-gapped installs |
| `TEST-DEPLOYMENT-CIVO.md` / `TEST-DEPLOYMENT-LOCAL.md` | End-to-end throwaway-test runbooks (cloud VM / local host) |

## Hardware Requirements

The documented floor is **4 CPU cores and 16 GB of RAM**, which is adequate for bring-up and light use. Note that I-SPI performs its standard-curve fitting **in-process** (stanassay/Stan + JAGS, parallelized with the R `future` package), so I-SPI itself is the CPU- and memory-heavy component — for real fitting workloads, size well above the floor (≥ 8 vCPU, ≥ 16 GB, more RAM preferred) and see `ARCHITECTURE.md` §2.5. These instructions have been tested on Rocky8, Rocky9, and Ubuntu 24.04.

## Configuration for your environment

On the system where you'll be installing I-SPI, clone this git repository and make the changes below to configure it for your environment.

```shell
git clone https://github.com/immunoplex/deployment.git
cd deployment

# Replace PUT_YOUR_HOSTNAME_HERE with the hostname that users will use to access the service, then run the `sed` command
sed -i "s/IMMUNOPLEX_HOSTNAME/PUT_YOUR_HOSTNAME_HERE/g" k8s-manifests/*

# Replace PUT_YOUR_IP_ADDRESS_HERE with the IP address used to access this host, then run the command
sed -i "s/IMMUNOPLEX_IP_ADDRESS/PUT_YOUR_IP_ADDRESS_HERE/g" k8s-manifests/*

# Replace PUT_YOUR_POSTGRES_PASSWORD_HERE with a strong password for the `postgres` user in PostgreSQL, then run the `sed` command
sed -i "s/IMMUNOPLEX_POSTGRES_PASSWORD/PUT_YOUR_POSTGRES_PASSWORD_HERE/g" k8s-manifests/*

# Run the following two commands to generate a random string which will be used as part of the authentication service
IMMUNOPLEX_OAUTH_CLIENT_ID=$(openssl rand -hex 32)
sed -i "s/IMMUNOPLEX_OAUTH_CLIENT_ID/$IMMUNOPLEX_OAUTH_CLIENT_ID/g" k8s-manifests/*

# Run the following two commands to generate a random string which will be used as part of the authentication service
IMMUNOPLEX_OAUTH_SECRET=$(openssl rand -hex 32)
sed -i "s/IMMUNOPLEX_OAUTH_SECRET/$IMMUNOPLEX_OAUTH_SECRET/g" k8s-manifests/*
```

The four values above (hostname, IP, Postgres password, and the two OAuth values) are all a core standalone I-SPI install needs. The following two are only needed if you deploy the **optional** components:

```shell
# ONLY if you deploy the optional whoami test harness (whoami.yml)
IMMUNOPLEX_OAUTH_COOKIE_SECRET=$(openssl rand -hex 16)
sed -i "s/IMMUNOPLEX_OAUTH_COOKIE_SECRET/$IMMUNOPLEX_OAUTH_COOKIE_SECRET/g" k8s-manifests/*

# ONLY if you deploy the optional external Batch Calculator (batch-calculator.yml)
sed -i "s/IMMUNOPLEX_REDIS_AUTH/PUT_YOUR_REDIS_PASSWORD_HERE/g" k8s-manifests/*
IMMUNOPLEX_API_KEY=$(openssl rand -hex 32)
sed -i "s/IMMUNOPLEX_API_KEY/$IMMUNOPLEX_API_KEY/g" k8s-manifests/*
```

> Keep the substituted copies out of version control — they now contain real secrets.

## Install k3s (Only required if you don't already have a Kubernetes cluster)

If you don't have Kubernetes already installed, you can follow these instructions for deploying K3s (a lightweight Kubernetes environment). This also covers cert-manager and the private CA the Ingresses use.

[K3s Install](K3S.md)

## Create immunoplex namespace

These instructions expect all components to be installed in the `immunoplex` namespace. If you haven't already created the `immunoplex` namespace (K3S.md creates it), please do it now.

```shell
sudo kubectl create ns immunoplex
```

## Traefik

Traefik is an Ingress Controller that provides access to the various ImmunoPlex components. Run the following command to install Traefik.

```shell
sudo kubectl -n immunoplex apply -f k8s-manifests/traefik.yml
```

## Dex

Dex is an Identity Provider that's used for authentication to the ImmunoPlex components. Run the following command to install Dex.

```shell
sudo kubectl -n immunoplex apply -f k8s-manifests/dex.yml
```

## Whoami (optional test harness)

Whoami lets us verify the Traefik + Dex authentication chain before deploying I-SPI. It is optional — deploy it during bring-up, confirm login works, then delete it. Run the following command to install `whoami`.

```shell
sudo kubectl -n immunoplex apply -f k8s-manifests/whoami.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=whoami --timeout=5m
```

To test Dex and Traefik, follow these steps:

1. In your browser, navigate to: `https://<your-hostname>/whoami`
2. You will be redirected to Dex. Click `Signup` to create a user account
3. Provide your name, email address and create a password, then click `SIGNUP`
4. Provide your email address and password on the login screen
5. After successful login, you'll be redirected back to `whoami`.

`whoami` displays a variety of information about the HTTP request. Find the `X-Forwarded-Email` attribute to see that your email address is specified as the authenticated user.

## PostgreSQL

PostgreSQL is the relational database used by I-SPI. Run the following commands to install PostgreSQL.

```shell
sudo kubectl -n immunoplex apply -f k8s-manifests/postgresql.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=postgresql --timeout=5m
```

To confirm PostgreSQL is available, run the following command. If successful, it will display the version of PostgreSQL.

```shell
sudo kubectl -n immunoplex exec -it deploy/postgresql -- psql -U postgres -c "select version();"
```

```shell
#
# Example output:
#
#                                                         version
#   ---------------------------------------------------------------------------------------------------------------------
#   PostgreSQL 17.2 (Debian 17.2-1.pgdg120+1) on x86_64-pc-linux-gnu, compiled by gcc (Debian 12.2.0-14) 12.2.0, 64-bit
#   (1 row)
#
```

## I-SPI

I-SPI is an interactive R Shiny application for processing, analyzing, and visualizing Luminex bead-based immunoassay data. It provides a unified platform for managing serology experiments with robust features for data import, quality control, curve fitting, and results visualization. In this standalone deployment, I-SPI depends on **PostgreSQL, Dex, and Traefik** being deployed first, and it performs all curve fitting and the concentration / se_concentration / pcov computation in-process (see `ARCHITECTURE.md` §3.4).

Set up the database for the application first — create the `immunoplex` database and load the I-SPI dump:

```shell
sudo kubectl -n immunoplex exec -it deploy/postgresql -- psql -U postgres -c "CREATE DATABASE immunoplex;"
sudo kubectl -n immunoplex exec -i deploy/postgresql -- psql -U postgres immunoplex < db-dumps/i-spi-db.sql
```

Then deploy I-SPI:

```shell
sudo kubectl -n immunoplex apply -f k8s-manifests/i-spi.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi --timeout=10m
```

After this, you have a fully working analysis instance. Browse to `https://<your-hostname>/i-spi/`, log in via Dex, and run a standard-curve fit; when concentration / se_concentration / pcov results appear, the in-process fitting path is working.

## Batch Calculator (optional)

Batch Calculator provides background Bayesian standard-curve fitting as an external service. It includes its own dedicated Redis instance, a FastAPI job submission API, and an R worker that uses the [stanassay](https://github.com/immunoplex/stanassay) package for hierarchical 4PL/5PL/Gompertz ensemble fitting via Stan MCMC.

> **The provided I-SPI build does its fitting in-process and does not call this service** (see `ARCHITECTURE.md` §3.5). Deploy it **only** if your I-SPI build is known to offload fitting jobs to it; otherwise it will sit idle. It depends on PostgreSQL (it writes results to the `madi_results` schema in the same `immunoplex` database as I-SPI) and brings its own Redis.

Run the following commands to install the Batch Calculator:

```shell
sudo kubectl -n immunoplex apply -f k8s-manifests/batch-calculator.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=batch-calculator-redis --timeout=5m
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=batch-calculator-api --timeout=5m
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=batch-calculator-worker --timeout=5m
```

To confirm the Batch Calculator API is available:

```shell
sudo kubectl -n immunoplex exec -it deploy/batch-calculator-api -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/health').read().decode())"
```

```shell
#
# Example output:
#
#   {"status":"ok","redis":"connected"}
#
```

For more information, see the [Batch Calculator repository](https://github.com/immunoplex/immunoplex-batch-calculator).
