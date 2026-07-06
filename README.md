# ImmunoPlex Deployment (Standalone I-SPI)

ImmunoPlex enables researchers to assess, analyze, and share data. ImmunoPlex improves QA and QC practices to make them accessible and standardized. We offer tools that enable discovery by increasing statistical power. ImmunoPlex promotes data interoperability, making research more transparent and data more reusable for the community.

This repo provides instructions and manifests for deploying a **standalone I-SPI** analysis instance — I-SPI plus the edge (Traefik), authentication (Dex), and data (PostgreSQL) layers it needs — on your choice of Kubernetes cluster. Data Portal, the ingest API/Worker, the main Redis, and MinIO belong to the larger data-sharing platform and are **not** part of this deployment.

## Start here — which document do I need?

This repo has several documents, each for a different job. Find the row that matches what you're trying to do:

| If you want to… | Read | Which gives you |
|---|---|---|
| Understand *what* gets deployed and *why* — the components, how they fit, sizing, and the TLS/hostname choices | **[`ARCHITECTURE.md`](ARCHITECTURE.md)** | The concepts and design decisions behind every step (read this first) |
| Deploy a real, lasting instance | **[`README-STANDALONE-ISPI.md`](README-STANDALONE-ISPI.md)** — the runbook (the [Deploying](#deploying) summary below shows the order) | The exact `sed`/`kubectl` steps, in order, with correction notes and troubleshooting |
| Build a cluster first (you have no Kubernetes) | **[`K3S.md`](K3S.md)** | Single-node K3s + cert-manager + the private CA |
| Install without internet access (air-gapped) | **[`OFFLINE-IMAGES.md`](OFFLINE-IMAGES.md)** | Which images to stage, and how to side-load them |
| Just try it on a throwaway instance before committing | **[`TEST-DEPLOYMENT-CIVO.md`](TEST-DEPLOYMENT-CIVO.md)** (cloud VM) or **[`TEST-DEPLOYMENT-LOCAL.md`](TEST-DEPLOYMENT-LOCAL.md)** (your machine / offline) | A complete, self-contained run from bare VM to a working login |

The intended reading order is **concept → implementation → verification**:

1. **Concept —** skim `ARCHITECTURE.md` once so the steps make sense (what you're building, and why I-SPI is the CPU/memory-heavy component).
2. **Implementation —** `README-STANDALONE-ISPI.md` is the runbook; the [Deploying](#deploying) summary below shows the order and hands off to it. No cluster? Do `K3S.md` first. Offline? Add `OFFLINE-IMAGES.md`.
3. **Verification —** or, if you'd rather rehearse on a disposable instance first, run one of the `TEST-DEPLOYMENT-*.md` runbooks end to end.

> **This README vs. `README-STANDALONE-ISPI.md`** — this file is a landing / routing page: it sends you to the right document and summarizes the deploy order. `README-STANDALONE-ISPI.md` is the authoritative runbook, with the exact commands, the manifest-correction notes, the "what's in this folder vs. the repo" table, and troubleshooting.

If you don't have a Kubernetes cluster, you can use [k3s](https://rancher.com/docs/k3s/latest/en/); see `K3S.md`.

## Hardware Requirements

The documented floor is **4 CPU cores and 16 GB of RAM**, which is adequate for bring-up and light use. Note that I-SPI performs its standard-curve fitting **in-process** (stanassay/Stan + JAGS, parallelized with the R `future` package), so I-SPI itself is the CPU- and memory-heavy component — for real fitting workloads, size well above the floor (≥ 8 vCPU, ≥ 16 GB, more RAM preferred) and see `ARCHITECTURE.md` §2.5. These instructions have been tested on Rocky8, Rocky9, and Ubuntu 24.04.

## Deploying

Deployment is three moves — **clone, configure, then apply the manifests in dependency order.** This is only the summary: the **full commands, per-step readiness checks, the manifest-correction notes, and troubleshooting live in [`README-STANDALONE-ISPI.md`](README-STANDALONE-ISPI.md)**, which is the authoritative runbook.

1. **Clone** this repository onto the host where you'll install:
   ```shell
   git clone https://github.com/immunoplex/i-spi-deployment.git
   cd i-spi-deployment
   ```
2. **Configure** it for your environment with the `sed` step — it fills in your hostname, the host IP, a PostgreSQL password, and the two shared OAuth values (plus a cookie secret / Redis password / API key only if you add the optional whoami harness or Batch Calculator). Exact commands are in [`README-STANDALONE-ISPI.md`](README-STANDALONE-ISPI.md).
3. **Deploy** in this order — each component waits on the one before it:
   1. **CoreDNS + Traefik** — DNS and the ingress / TLS edge
   2. **Dex** (+ signup) — authentication
   3. **whoami** *(optional)* — verify the auth chain before going further
   4. **PostgreSQL** — then create the `immunoplex` database and load `i-spi-db.sql`
   5. **I-SPI** — after this you have a working analysis instance (fitting runs in-process)
   6. **Batch Calculator** *(optional)* — only if your I-SPI build offloads fitting to it (see `ARCHITECTURE.md` §3.5)

**Prerequisites**

- No Kubernetes cluster yet? Build single-node K3s + cert-manager + the private CA with **[`K3S.md`](K3S.md)** first.
- Installing without internet access? Stage and side-load the images per **[`OFFLINE-IMAGES.md`](OFFLINE-IMAGES.md)**.

For *why* this order and what each piece does, see **[`ARCHITECTURE.md`](ARCHITECTURE.md)** (§6 covers the deployment order).
