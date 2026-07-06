# Test Deployment Plan — Standalone I-SPI on a Local Host

A step-by-step runbook for standing up a **throwaway test instance** of I-SPI on a machine you
control — a VM on your laptop/workstation, or a spare bare-metal Linux box — using the corrected
manifests in this folder and the repo's install docs (`K3S.md`, `README.md`).

It is the local-host counterpart to `TEST-DEPLOYMENT-CIVO.md`. The key difference is
**connectivity**: a local box is often on a restricted or fully offline network, so this plan is
built around **`OFFLINE-IMAGES.md`** — you stage the container images yourself and side-load them,
rather than pulling from public registries. If your local host *does* have internet egress, you
can skip the offline staging (Phase 3) and let images pull normally, exactly as the Civo plan
does.

> This is a **test** instance: self-signed TLS (a private CA you import into your browser), a
> single node, and passwords you choose. Don't put production data on it, and tear it down
> (Phase 9) when finished.

---

## Phase 0 — Before you start

You will need:

- A Linux host you can `sudo` on. Tested distros: **Rocky 8/9, Ubuntu 24.04**. A VM (VirtualBox,
  UTM, KVM, Hyper-V, cloud-agnostic) or bare metal both work.
- **Sizing.** I-SPI does its curve fitting **in-process** (stanassay/Stan + JAGS via `future`), so
  it is the CPU/memory-heavy component. The repo floor is 4 vCPU / 16 GB, but for a test that
  actually exercises fitting, target **≥ 8 vCPU, ≥ 16 GB RAM (32 GB preferred), ≥ 100 GB disk**.
  The disk matters: K3s's local-path provisioner backs the PostgreSQL (20 GB) and Dex (1 GB) PVCs
  on the node's own disk, alongside container images and the database dump. See `ARCHITECTURE.md`
  §2.5.
- The deployment repo, the **`i-spi-db.sql`** dump, and the corrected standalone manifests from
  this folder — present on the node (Phase 5).
- A decision on **hostname** (Phase 2) — the single most important choice, because it is baked
  into every OAuth redirect URL.
- A decision on **connectivity**:
  - **Connected** local host → images pull from registries; skip Phase 3.
  - **Offline / air-gapped** local host → follow Phase 3 to stage images per `OFFLINE-IMAGES.md`.

If you are unsure, treat it as offline — the offline path also works on a connected host, just
with extra steps.

---

## Phase 1 — Prepare the host

On the node:

```shell
sudo dnf -y update      # Rocky
# or
sudo apt-get update && sudo apt-get -y upgrade   # Ubuntu

# Note the node's IP — you'll reuse it for the hostname mapping and CoreDNS
ip -4 addr show | grep inet
```

Follow the K3s system-requirements checklist before installing:
<https://docs.k3s.io/installation/requirements>.

---

## Phase 2 — Choose a hostname (local resolution)

Every OAuth redirect URL is built from one hostname, so it must resolve consistently and stay
stable — **from the node, from inside the cluster, and from the browser you'll test with.**

On a local/offline network there's no public DNS to lean on, so pick a name and map it in three
places to the node's IP (call it `<NODE_IP>`):

1. **The node's `/etc/hosts`** (so the node itself resolves it):
   ```shell
   echo "<NODE_IP>  ispi.test" | sudo tee -a /etc/hosts
   ```
2. **The client machine's hosts file** (the laptop whose browser you'll use):
   - Linux/macOS: add `"<NODE_IP>  ispi.test"` to `/etc/hosts`
   - Windows: add it to `C:\Windows\System32\drivers\etc\hosts`
3. **Inside the cluster**, via `coredns.yml` (Phase 5's `sed` fills this in), so pods resolve the
   same name to `<NODE_IP>`.

Set two shell variables you'll reuse on the node:

```shell
export ISPI_HOST="ispi.test"     # your chosen hostname
export ISPI_IP="<NODE_IP>"       # the node's IP address
```

> If the host *does* have a routable IP and DNS, you can instead use a wildcard-DNS-as-IP name
> like `<ip-with-dashes>.sslip.io` and skip the hosts-file edits — but that requires DNS
> resolution, so it is not an option on a fully offline network.

---

## Phase 3 — Stage container images (OFFLINE hosts only)

**Skip this phase if your host has internet egress.** Otherwise, this is where
`OFFLINE-IMAGES.md` does the work. In short:

1. **On a connected machine**, follow `OFFLINE-IMAGES.md` to `docker pull` and `docker save` the
   images this standalone install needs. The core set is Traefik, Dex, `busybox`, the signup UI,
   PostgreSQL, and I-SPI; add the whoami harness and/or Batch Calculator images only if you plan
   to deploy those. That doc lists the exact tags, matched to these manifests.

2. **Also stage the cluster prerequisites** (`OFFLINE-IMAGES.md` §2):
   - The **K3s** binary and the `k3s-airgap-images-<arch>.tar.zst` bundle for `v1.33.5+k3s1`.
   - The **cert-manager** `v1.19.1` images (derive the exact list from the release manifest).

3. **Transfer** all tarballs to the node (USB, internal share, `scp` over the local LAN).

4. **Side-load on the node.** Create the K3s images directory and drop everything in — including
   the K3s airgap bundle, which K3s imports on first start:
   ```shell
   sudo mkdir -p /var/lib/rancher/k3s/agent/images/
   sudo cp *.tar *.tar.zst /var/lib/rancher/k3s/agent/images/
   ```

5. **Plan for `imagePullPolicy`.** Several manifests use `imagePullPolicy: Always`, which fails
   offline even when the image is already imported. You'll flip those to `IfNotPresent` in
   Phase 6 (`OFFLINE-IMAGES.md` §4 explains this).

Leave the tarballs staged; K3s (installed next) picks them up automatically.

---

## Phase 4 — Install K3s (repo: `K3S.md`)

**Connected host:**

```shell
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.33.5+k3s1 sh -s - --disable=traefik
sudo ln -s /usr/local/bin/kubectl /bin/kubectl
sudo kubectl get node -o wide
```

**Offline host** (using the staged binary + airgap bundle from Phase 3):

```shell
# Place the downloaded k3s binary and make it executable
sudo cp k3s /usr/local/bin/k3s && sudo chmod +x /usr/local/bin/k3s
# Run the install script WITHOUT downloading (script obtained on a connected machine)
INSTALL_K3S_VERSION=v1.33.5+k3s1 INSTALL_K3S_SKIP_DOWNLOAD=true \
  ./install.sh --disable=traefik
sudo ln -s /usr/local/bin/kubectl /bin/kubectl
sudo kubectl get node -o wide
```

`--disable=traefik` is required either way: this project ships its **own** namespace-scoped
Traefik (Phase 7), so the bundled one is turned off to avoid a conflict. K3s keeps its
service-load-balancer (klipper) and local-path storage, which is what exposes Traefik on the
node's IP and backs the PVCs — no managed load balancer or volumes needed.

---

## Phase 5 — Cluster prerequisites (repo: `K3S.md`)

Follow `K3S.md` for the full commands; the sequence is:

1. **Namespace** — `sudo kubectl create ns immunoplex` (create it first; later steps assume it).
2. **CoreDNS custom mapping** — apply `coredns.yml` (after the Phase-6 `sed` fills in host/IP)
   and restart CoreDNS, so pods resolve `$ISPI_HOST` to the node internally.
3. **cert-manager** — apply the cert-manager `v1.19.1` release, then `kubectl wait` for its
   webhook. *(Offline: its images must already be staged — Phase 3.)*
4. **Private CA** — create the self-signed `root-ca`, the `intermediate-ca1`, and the
   `intermediate-ca1-issuer` ClusterIssuer (the `cat <<EOF | kubectl apply` blocks in `K3S.md`),
   then copy `root-ca-secret` into the `immunoplex` namespace.
5. **Export the root certificate** — `K3S.md`'s last command writes `immunoplex-root-ca.crt`;
   copy it to your client machine (Phase 8) to trust the site in your browser.

---

## Phase 6 — Get the manifests and configure them

Put the repo and the corrected standalone manifests on the node, then run the **standalone
subset** of the `sed` configuration (full detail in `README-STANDALONE-ISPI.md`):

```shell
cd k8s-manifests
sed -i "s/IMMUNOPLEX_HOSTNAME/$ISPI_HOST/g"            *.yml
sed -i "s/IMMUNOPLEX_IP_ADDRESS/$ISPI_IP/g"            coredns.yml
sed -i "s/IMMUNOPLEX_POSTGRES_PASSWORD/$(openssl rand -hex 16)/g" *.yml
OAUTH_ID=$(openssl rand -hex 32);     sed -i "s/IMMUNOPLEX_OAUTH_CLIENT_ID/$OAUTH_ID/g" *.yml
OAUTH_SECRET=$(openssl rand -hex 32); sed -i "s/IMMUNOPLEX_OAUTH_SECRET/$OAUTH_SECRET/g" *.yml
# whoami test harness (optional) needs a cookie secret:
sed -i "s/IMMUNOPLEX_OAUTH_COOKIE_SECRET/$(openssl rand -hex 16)/g" *.yml
```

Only add the `IMMUNOPLEX_REDIS_AUTH` and `IMMUNOPLEX_API_KEY` substitutions if you also intend to
deploy the optional `batch-calculator.yml` (this I-SPI build fits in-process and does not call
that service — see `ARCHITECTURE.md` §3.5).

**Offline hosts, two extra edits:**

```shell
# 1. Flip Always -> IfNotPresent so pods start from the side-loaded images
sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g' *.yml

# 2. Pre-seed the Dex web theme so its init container skips the GitHub download.
#    Unpack the web/ directory (from OFFLINE-IMAGES.md / the repo templates) into the
#    dex PVC at /var/dex/web BEFORE starting Dex. See dex.yml's air-gap note.
```

> The substituted files now contain real secrets — don't commit them.

---

## Phase 7 — Deploy I-SPI (repo: `README.md` order)

Apply into the `immunoplex` namespace, waiting for readiness at each step:

```shell
# DNS + ingress
sudo kubectl -n immunoplex apply -f coredns.yml
sudo kubectl -n kube-system rollout restart deploy coredns
sudo kubectl -n immunoplex apply -f traefik.yml

# Auth
sudo kubectl -n immunoplex apply -f dex.yml

# (Optional) prove the auth chain works before I-SPI
sudo kubectl -n immunoplex apply -f whoami.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=whoami --timeout=5m

# Database, then create + load the I-SPI database
sudo kubectl -n immunoplex apply -f postgresql.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=postgresql --timeout=5m
sudo kubectl -n immunoplex exec -it deploy/postgresql -- psql -U postgres -c "CREATE DATABASE immunoplex;"
sudo kubectl -n immunoplex exec -i deploy/postgresql -- psql -U postgres immunoplex < ../db-dumps/i-spi-db.sql

# I-SPI
sudo kubectl -n immunoplex apply -f i-spi.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi --timeout=10m
```

The Batch Calculator (`batch-calculator.yml`) is an **optional** last step and only meaningful if
your I-SPI build offloads to it; for this build, skip it.

---

## Phase 8 — Access and verify

1. **Trust the CA.** Copy `immunoplex-root-ca.crt` (Phase 5) to your client machine and import it
   into your browser/OS trust store. Without this you'll get TLS warnings (expected for a test).
2. **Confirm the hostname resolves from the client** (the `/etc/hosts` entry from Phase 2):
   `ping ispi.test` should hit `<NODE_IP>`.
3. **Auth check (if you deployed whoami):** browse to `https://$ISPI_HOST/whoami`, click Signup,
   create a user, log in, and confirm the page shows your `X-Forwarded-Email`.
4. **Database check:**
   `sudo kubectl -n immunoplex exec -it deploy/postgresql -- psql -U postgres -c "select version();"`
5. **I-SPI:** browse to `https://$ISPI_HOST/i-spi/`, log in via Dex, and run a standard-curve fit.
   When concentration / se_concentration / pcov results appear, the in-process fitting path is
   working end to end.

If login bounces or errors, it's almost always a hostname/redirect mismatch: confirm `$ISPI_HOST`
is identical everywhere (node hosts file, client hosts file, `coredns.yml`, and the manifests) and
that `APP_REDIRECT_URI` matches a URI registered in `dex.yml`. Flip `SHINY_LOG_LEVEL` to `DEBUG`
in `i-spi.yml` to watch the OAuth flow (`kubectl -n immunoplex logs deploy/i-spi`).

If a pod is stuck in `ImagePullBackOff` on an offline host, it's the `imagePullPolicy`/tag issue
from Phase 6 — see `OFFLINE-IMAGES.md` §5.

---

## Phase 9 — Tear down

Everything (database, Dex users, certs) lives on the single node, so removing K3s removes all
test data:

```shell
# Remove just the app, keeping the cluster:
sudo kubectl delete ns immunoplex

# Or remove K3s entirely:
/usr/local/bin/k3s-uninstall.sh
```

If the host is a disposable VM, simply deleting the VM removes everything. If you want to keep a
result set, `pg_dump` the `immunoplex` database off the node first.

---

## Cost and time expectations

- No cloud spend — this runs on hardware you already have.
- End-to-end, expect roughly **30–60 minutes** on a connected host. An offline host takes longer
  the first time, dominated by pulling/saving images on the connected machine and transferring
  them; the on-node install itself is quick once images are staged.
- The I-SPI image is large, hence the 10-minute readiness wait; on an offline host it is already
  local, so readiness is limited mainly by the app's own startup.
