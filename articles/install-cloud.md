# In the cloud (incl. EU data residency)

The deployment needs nothing provider-specific: a Linux virtual machine,
or a Kubernetes cluster, from any provider will do. This guide says what
to ask a provider for, how the installation differs from the [cluster
guide](https://immunoplex.github.io/i-spi-deployment/articles/install-cluster.md),
and what to check when the data must stay in the EU. It names no
provider. The single-VM path was tested on a Civo instance in London
with Ubuntu 24.04.

## Two ways to run it

**A. One virtual machine with K3s.** The simplest. Everything, including
the database, runs on one VM; the [cluster
guide](https://immunoplex.github.io/i-spi-deployment/articles/install-cluster.md)
applies step by step. You need:

- a VM with 8 or more vCPUs, 16 to 32 GB of memory and 100 GB of disk,
  running Ubuntu 24.04 or Rocky Linux 9;
- a public IP address, or a private one reached through your network;
- a firewall that allows SSH (22) from your own address only, and
  HTTP (80) and HTTPS (443) from the users’ networks;
- a hostname for the IP (an `A` record, or a name such as
  `1-2-3-4.sslip.io` for a test).

**B. A managed Kubernetes cluster.** The provider runs the control plane
and supplies storage and load balancers. Use the [cluster
guide](https://immunoplex.github.io/i-spi-deployment/articles/install-cluster.md)
from step 4, with these differences:

- Skip the K3s install and `coredns.yml`. The hostname resolves through
  DNS.
- The cluster needs a default StorageClass that provides `ReadWriteOnce`
  volumes. PostgreSQL asks for 20 GB and Dex for 1 GB.
- `traefik.yml` exposes Traefik as a `LoadBalancer` Service. The
  provider creates a load balancer with an external IP; point the
  hostname’s `A` record at it (`kubectl -n immunoplex get svc` shows the
  IP).
- The i-spi-compute worker image is built for amd64: the worker needs
  amd64 nodes, and its `nodeSelector` asks for them.
- Give the node pool enough room for the worker’s limits (2 CPUs and 4
  GB in the manifest; raise them for real studies, see
  [Overview](https://immunoplex.github.io/i-spi-deployment/articles/overview.md)).

A managed PostgreSQL service can replace the bundled one: point I-SPI’s
`db_*` and the worker’s `DB_*` variables at it, keep TLS required, and
load the schema from `db/` into it. This is not tested here.

## TLS

Each Ingress has the annotation
`cert-manager.io/cluster-issuer: intermediate-ca1-issuer`. On a cloud
host you can choose:

- **The private certificate authority** from the cluster guide. Browsers
  trust the site only after importing its root certificate. Acceptable
  for a closed group of users.

- **An ACME issuer, such as Let’s Encrypt.** Browsers trust it without
  any import. The hostname must be public and reachable on port 80 for
  the HTTP-01 challenge. Create a ClusterIssuer for it, then point the
  Ingresses at it:

  ``` shell
  sed -i "s/cluster-issuer: intermediate-ca1-issuer/cluster-issuer: <your-issuer>/" *.yml
  ```

  Traefik here watches only the `immunoplex` namespace, which is also
  where cert-manager places the challenge solver for these certificates.
  This combination has not been tested; check that the first certificate
  is issued (`kubectl -n immunoplex get certificate`).

- **Your organisation’s certificates.** Create a cert-manager issuer for
  your CA, or store the certificate as the Secret `cert-secret` that the
  Ingresses use.

## Keeping the data in the EU

These points concern where the data and its copies are stored and
processed. They are technical checks, not legal advice; your data
protection officer decides what the data requires.

- **Region.** Create the VM or cluster, its disks and its load balancer
  in an EU region. With managed Kubernetes, also check where the control
  plane runs.
- **What holds personal or study data.** The PostgreSQL volume (all
  assay data and results) and Dex’s volume (user accounts and email
  addresses). The Redis queue holds job descriptions only while they
  run. I-SPI, the API and the worker keep no data of their own.
- **Backups and snapshots.** Database dumps, volume snapshots and VM
  images are copies of the data: keep them in the same region, or
  another EU region. Check the provider’s default for snapshot and
  backup location.
- **Logs.** Pod logs contain user email addresses and study names. If
  the provider ships logs to a central service, check where it stores
  them.
- **Images.** The images contain software, not data, and can come from
  any registry. To avoid depending on registries outside the EU at run
  time, copy the images into a registry in the same region and change
  the `image:` fields; the image list is in [Without internet
  access](https://immunoplex.github.io/i-spi-deployment/articles/install-airgapped.html#images).
- **Sign-in.** Dex stores accounts in the cluster itself; no external
  identity service is involved unless you configure one.
- **Access.** Restrict SSH and the Kubernetes API to your own addresses,
  and keep the configured manifests, which hold the secrets, out of
  version control.

## Cost and time

- One VM in the 8 vCPU, 16 to 32 GB range costs a few units of currency
  per day at most providers. Stop or delete it when a test is over:
  deleting the VM deletes the data with it, so `pg_dump` first if you
  want to keep results.
- Allow 30 to 60 minutes from a new VM to a working sign-in: a few
  minutes to create the VM, about 10 for K3s and cert-manager, and the
  rest for pulling images and starting pods.
