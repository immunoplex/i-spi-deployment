# ImmunoPlex Deployment (Standalone I-SPI)

ImmunoPlex enables researchers to assess, analyze, and share data. ImmunoPlex improves QA and QC practices to make them accessible and standardized. We offer tools that enable discovery by increasing statistical power. ImmunoPlex promotes data interoperability, making research more transparent and data more reusable for the community.

This repo provides instructions and manifests for deploying a **standalone I-SPI** analysis instance — I-SPI, its required **i-spi-compute** fitting tier (a job **API**, a **Redis** queue, and a **curveR** worker), and the edge (Traefik), authentication (Dex), and data (PostgreSQL) layers they need — on your choice of Kubernetes cluster. Data Portal, the platform's data-ingest API/Worker, the platform's main Redis, and MinIO belong to the larger data-sharing platform and are **not** part of this deployment.

> **How fitting works now.** I-SPI does **not** fit curves in-process. It **enqueues** fitting jobs to the i-spi-compute API over HTTP; the API places them on a Redis queue; the curveR **worker** runs the frequentist and Bayesian (Stan) fits and writes the results to the `calib_*` tables in PostgreSQL; and I-SPI **reads those results back** from the database. In short:
>
> **I-SPI enqueues → API → Redis → worker (curveR) → `calib_*` → I-SPI reads.**
>
> The practical consequence is that i-spi-compute is a **required** tier (not an optional add-on), and the **worker** — not I-SPI — is the CPU/memory-heavy component. The former Batch Calculator has been removed; i-spi-compute replaces it.

## Start here — which document do I need?

This repo has several documents, each for a different job. Find the row that matches what you're trying to do:

| If you want to… | Read | Which gives you |
|---|---|---|
| Understand *what* gets deployed and *why* — the components (including i-spi-compute), how they fit, the enqueue→worker→`calib_*`→read chain, sizing, and the TLS/hostname choices | **[`ARCHITECTURE.md`](ARCHITECTURE.md)** | The concepts and design decisions behind every step (read this first) |
| Deploy a real, lasting instance | **[`README-STANDALONE-ISPI.md`](README-STANDALONE-ISPI.md)** — the runbook (the [Deploying](#deploying) summary below shows the order) | The exact `sed`/`kubectl` steps, in order, with troubleshooting |
| Build a cluster first (you have no Kubernetes) | **[`K3S.md`](K3S.md)** | Single-node K3s + cert-manager + the private CA |
| Install without internet access (air-gapped) | **[`OFFLINE-IMAGES.md`](OFFLINE-IMAGES.md)** | Which images to stage (including the i-spi-compute API/worker and Redis), and how to side-load them |
| Run everything on one machine with Docker, no Kubernetes (trying it out, testing a release, development) | **[`local/README.md`](local/README.md)** | `docker compose up` with I-SPI, i-spi-compute, Dex and PostgreSQL on localhost |
| Just try it on a throwaway instance before committing | **[`TEST-DEPLOYMENT-CIVO.md`](TEST-DEPLOYMENT-CIVO.md)** (cloud VM) or **[`TEST-DEPLOYMENT-LOCAL.md`](TEST-DEPLOYMENT-LOCAL.md)** (your machine / offline) | A complete, self-contained run from bare VM to a working login |

The intended reading order is **concept → implementation → verification**:

1. **Concept —** skim `ARCHITECTURE.md` once so the steps make sense (what you're building, the I-SPI → i-spi-compute → `calib_*` chain, and why the i-spi-compute worker — not I-SPI — is the CPU/memory-heavy component).
2. **Implementation —** `README-STANDALONE-ISPI.md` is the runbook; the [Deploying](#deploying) summary below shows the order and hands off to it. No cluster? Do `K3S.md` first. Offline? Add `OFFLINE-IMAGES.md`.
3. **Verification —** or, if you'd rather rehearse on a disposable instance first, run one of the `TEST-DEPLOYMENT-*.md` runbooks end to end.

> **This README vs. `README-STANDALONE-ISPI.md`** — this file is a landing / routing page: it sends you to the right document and summarizes the deploy order. `README-STANDALONE-ISPI.md` is the authoritative runbook, with the exact commands, the table of manifests, and troubleshooting.

If you don't have a Kubernetes cluster, you can use [k3s](https://rancher.com/docs/k3s/latest/en/); see `K3S.md`.

## Hardware Requirements

The documented floor is **4 CPU cores and 16 GB of RAM**, which is adequate for bring-up and light use. Standard-curve fitting (frequentist robust curves plus the Bayesian Stan ensemble) runs in the **i-spi-compute worker** — the curveR R packages — **not** inside I-SPI, so the **worker** is the CPU- and memory-heavy component. For real fitting workloads, size the worker well above the floor (give it several cores and generous RAM; set its CPU limit and `WORKER_CORES` together, since Stan runs are memory-hungry) and see `ARCHITECTURE.md` §2.5. I-SPI itself is comparatively light (an interactive front end that submits jobs and reads results from the database), and the API and Redis are small. These instructions have been tested on Rocky8, Rocky9, and Ubuntu 24.04.

## Deploying

Deployment is three moves — **clone, configure, then apply the manifests in dependency order.** This is only the summary: the **full commands, per-step readiness checks, and troubleshooting live in [`README-STANDALONE-ISPI.md`](README-STANDALONE-ISPI.md)**, which is the authoritative runbook.

1. **Clone** this repository onto the host where you'll install:
   ```shell
   git clone https://github.com/immunoplex/i-spi-deployment.git
   cd i-spi-deployment
   ```
2. **Configure** it for your environment with the `sed` step — it fills in your hostname, the host IP, a PostgreSQL password, the two shared OAuth values, and the **i-spi-compute API key and Redis password**. The API key and Redis password are now **required** (I-SPI authenticates to the compute API with the API key, and the API and worker authenticate to Redis with the Redis password) — they are no longer optional. A cookie secret is only needed if you add the optional whoami harness. Exact commands are in [`README-STANDALONE-ISPI.md`](README-STANDALONE-ISPI.md).
3. **Deploy** in this order — each component waits on the one before it:
   1. **CoreDNS + Traefik** — DNS and the ingress / TLS edge
   2. **Dex** (+ signup) — authentication
   3. **whoami** *(optional)* — verify the auth chain before going further
   4. **PostgreSQL** — then create the `immunoplex` database, and load the schema from [`db/`](db/README.md) (I-SPI's tables plus the `calib_*` calibration tables, which the worker **writes** and I-SPI **reads**)
   5. **i-spi-compute** (Redis + API + worker) — the **required** fitting tier (curveR); bring it up **before** I-SPI so the enqueue path has somewhere to go
   6. **I-SPI** — the analysis front end; it enqueues fits to i-spi-compute and reads results back from `calib_*`. After this you have a working analysis instance.

**Prerequisites**

- No Kubernetes cluster yet? Build single-node K3s + cert-manager + the private CA with **[`K3S.md`](K3S.md)** first.
- Installing without internet access? Stage and side-load the images per **[`OFFLINE-IMAGES.md`](OFFLINE-IMAGES.md)** — including the i-spi-compute API and worker images and `redis:7.4`.

For *why* this order and what each piece does, see **[`ARCHITECTURE.md`](ARCHITECTURE.md)** (§6 covers the deployment order).
