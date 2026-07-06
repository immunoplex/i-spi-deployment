# Test Deployment Plan — Standalone I-SPI on Civo (UK)

A step-by-step runbook for standing up a **throwaway test instance** of I-SPI on a fresh cloud
VM, using the corrected manifests in this folder and the repo's own install scripts
(`K3S.md`, `README.md`). It is written for **Civo**, but every step after provisioning is just
"a plain Ubuntu VM," so it ports to any provider.

## Why Civo, and the ground rules

Civo is a **UK-headquartered** cloud provider (founded 2015) with a **London (`LON1`)
region**, which keeps the test data in the UK. Civo is a UK-headquartered cloud provider founded in 2015, focused on Kubernetes-native infrastructure, operating datacenters in London, Frankfurt, and New York. It is well known in the
cloud-native world, gives new users $250 in free credit to try any instance, with unlimited free data transfer and no egress fees, and holds UK-relevant
assurances (a UK Sovereign Cloud offering subject only to UK law, including UK GDPR and the Data Protection Act 2018; the site also lists ISO 27001, Cyber
Essentials Plus, SOC 2 and Crown Commercial Service / G-Cloud supplier status), which is useful
context if the test later handles real assay data.

**The deliberate constraint:** Civo *does* offer managed Databases and managed Kubernetes, but
this plan **does not use them**. We provision one bare Compute VM and install everything
ourselves — K3s, PostgreSQL, Dex, Traefik, I-SPI — from the manifests. That keeps the test
faithful to the repo's self-contained deployment model and avoids any provider lock-in.

> This is a **test** instance: it uses self-signed TLS (a private CA you import into your
> browser), a single node, and default passwords you choose. Do not put production data on it,
> and destroy it when finished (Phase 8) so it stops consuming credit.

---

## Phase 0 — Before you start

You will need:

- A Civo account (sign up at `dashboard.civo.com/signup`; the free credit covers this test).
- An SSH key pair on your laptop (`ssh-keygen -t ed25519` if you don't have one).
- `kubectl` on your laptop (optional — you can run everything over SSH on the node instead).
- The deployment repo and the **`i-spi-db.sql`** dump (you already have these), plus the
  corrected manifests from this `standalone-i-spi/` folder.
- A decision on **hostname** (see Phase 2) — the single most important choice, because it is
  baked into every OAuth redirect URL.

**Sizing.** I-SPI does its curve fitting **in-process** (stanassay/Stan + JAGS via `future`), so
the node must be comfortably above the repo's 4-core / 16 GB floor. For a test that actually
exercises fitting, target **≥ 8 vCPU, ≥ 16 GB RAM (32 GB preferred), ≥ 100 GB disk**. The disk
matters: K3s's built-in local-path provisioner backs the PostgreSQL (20 GB) and Dex (1 GB) PVCs
on the node's own disk, alongside container images and the database dump.

Civo names sizes `g3.*` (e.g. `g3.xsmall` is 1 vCPU / 1 GB / 25 GB). The larger
size names/specs change over time, so list the current options and pick the smallest that meets
the target rather than hard-coding one:

```shell
# After installing the Civo CLI (Phase 1), or via the dashboard's size dropdown:
civo sizes list
```

---

## Phase 1 — Provision the VM

You can use the dashboard or the CLI. CLI shown (install: `curl -sL https://civo.com/get | sh`,
then `civo apikey save <name> <key>` from Dashboard → Security → API keys).

```shell
# Point the CLI at the London region
civo region use LON1

# Upload your SSH public key
civo sshkey create ispi-test --key "$(cat ~/.ssh/id_ed25519.pub)"

# Create a firewall allowing SSH + HTTP + HTTPS only
civo firewall create ispi-test --create-rules=false
civo firewall rule create ispi-test --protocol tcp --startport 22  --endport 22  --cidr 0.0.0.0/0 --direction ingress
civo firewall rule create ispi-test --protocol tcp --startport 80  --endport 80  --cidr 0.0.0.0/0 --direction ingress
civo firewall rule create ispi-test --protocol tcp --startport 443 --endport 443 --cidr 0.0.0.0/0 --direction ingress

# Create the instance (replace g3.<size> with a current size meeting the target)
civo instance create ispi-test \
  --size g3.<size> \
  --diskimage ubuntu-24-04 \
  --sshkey ispi-test \
  --firewall ispi-test \
  --region LON1

civo instance show ispi-test     # note the public IP
```

For tighter security, restrict the SSH rule (port 22) to your own IP (`--cidr <your-ip>/32`).
Civo Compute instances come up with a public IP and Ubuntu 24.04; a benchmark on Civo used Ubuntu 24.04 and noted that each Civo vCPU is a dedicated physical core rather than a shared hyperthread, which helps the CPU-bound fitting.

---

## Phase 2 — Prepare the host and choose a hostname

SSH in and update:

```shell
ssh civo@<PUBLIC_IP>      # 'civo' is the default user; initial password is in the dashboard
sudo apt-get update && sudo apt-get -y upgrade
```

**Hostname.** Every OAuth redirect URL is built from one hostname, so it must resolve and stay
stable. For a test without buying a domain, use a wildcard-DNS-as-IP service so the public IP
becomes a real resolvable name — e.g. with IP `1.2.3.4`, use `1-2-3-4.sslip.io` (or
`<ip>.nip.io`). That gives you `https://1-2-3-4.sslip.io/i-spi/` with no DNS setup. If you have
a real domain, point an `A` record at the IP instead and use that.

Set two shell variables you'll reuse (on the node):

```shell
export ISPI_HOST="1-2-3-4.sslip.io"     # your chosen hostname
export ISPI_IP="1.2.3.4"                # the node's public IP
```

---

## Phase 3 — Install K3s (repo: `K3S.md`)

```shell
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.33.5+k3s1 sh -s - --disable=traefik
sudo ln -s /usr/local/bin/kubectl /bin/kubectl
sudo kubectl get node -o wide
```

`--disable=traefik` is required: we deploy our **own** Traefik (Phase 6). K3s keeps its
service-load-balancer (klipper) and local-path storage, which is what exposes Traefik on the
node's public IP and backs the PVCs — no managed load balancer or volumes needed.

---

## Phase 4 — Cluster prerequisites (repo: `K3S.md`)

Follow `K3S.md` for the full commands; the sequence is:

1. **CoreDNS custom mapping** — apply `coredns.yml` (after the `sed` in Phase 5 fills in the
   host/IP) and restart CoreDNS, so pods resolve your hostname to the node internally.
2. **Namespace** — `sudo kubectl create ns immunoplex`.
3. **cert-manager** — `kubectl apply` the cert-manager release, then `kubectl wait` for its
   webhook.
4. **Private CA** — create the self-signed `root-ca`, the `intermediate-ca1`, and the
   `intermediate-ca1-issuer` ClusterIssuer (the `cat <<EOF | kubectl apply` blocks in `K3S.md`),
   then copy `root-ca-secret` into the `immunoplex` namespace.
5. **Export the root certificate** — `K3S.md`'s last command writes `immunoplex-root-ca.crt`;
   copy it to your laptop (Phase 7) to trust the site in your browser.

> Order note: you create the namespace here, but the CoreDNS step and the CA's cross-namespace
> secret copy assume it exists — so create the namespace first if you deviate from `K3S.md`.

---

## Phase 5 — Get the manifests and configure them

Put the repo and the corrected standalone manifests on the node:

```shell
git clone https://github.com/immunoplex/deployment.git
cd deployment

# Overlay the corrected standalone manifests (from this folder) into k8s-manifests/,
# replacing the repo's i-spi.yml, dex.yml, traefik.yml and adding batch-calculator.yml.
# (scp them up, or git-add them to your fork.)
```

Run the **standalone subset** of the `sed` configuration (full detail in
`README-STANDALONE-ISPI.md`). Minimum for a core I-SPI test:

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

Only add the `IMMUNOPLEX_REDIS_AUTH` and `IMMUNOPLEX_API_KEY` substitutions if you also intend
to deploy the optional `batch-calculator.yml` (this I-SPI build does its fitting in-process and
does not call that service — see `ARCHITECTURE.md` §3.5).

> The substituted files now contain real secrets — don't commit them.

---

## Phase 6 — Deploy I-SPI (repo: `README.md` order)

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

The Batch Calculator (`batch-calculator.yml`) is an **optional** last step and only meaningful
if your I-SPI build offloads to it; for this build, skip it.

If the air gap matters later, see `OFFLINE-IMAGES.md` — but a test on Civo has internet egress, so
images pull normally.

---

## Phase 7 — Access and verify

1. **Trust the CA.** Copy `immunoplex-root-ca.crt` (from Phase 4) to your laptop and import it
   into your browser/OS trust store. Without this you'll get TLS warnings (expected for a test).
2. **Auth check (if you deployed whoami):** browse to `https://$ISPI_HOST/whoami`, click Signup,
   create a user, log in, and confirm the page shows your `X-Forwarded-Email`.
3. **Database check:**
   `sudo kubectl -n immunoplex exec -it deploy/postgresql -- psql -U postgres -c "select version();"`
4. **I-SPI:** browse to `https://$ISPI_HOST/i-spi/`, log in via Dex, and run a standard-curve
   fit. When concentration / se_concentration / pcov results appear, the in-process fitting path
   is working end to end.

If login bounces or errors, it's almost always a hostname/redirect mismatch: confirm `$ISPI_HOST`
is identical everywhere and that `APP_REDIRECT_URI` matches a URI registered in `dex.yml`. Flip
`SHINY_LOG_LEVEL` to `DEBUG` in `i-spi.yml` to watch the OAuth flow in the pod logs
(`kubectl -n immunoplex logs deploy/i-spi`).

---

## Phase 8 — Tear down (stop the spend)

A test instance keeps consuming credit until destroyed:

```shell
civo instance delete ispi-test --region LON1
civo firewall delete ispi-test --region LON1
# Optionally remove the SSH key:
civo sshkey remove ispi-test
```

Because everything (database, Dex users, certs) lives on that single node, deleting the instance
removes all test data. If you want to keep a result set, `pg_dump` the `immunoplex` database off
the node first.

---

## Cost and time expectations

- A single `g3` node in the 8 vCPU / 16–32 GB range is a few pounds per day; the new-account
  free credit comfortably covers a multi-day test, and there are no egress fees.
- End-to-end, expect roughly **30–60 minutes**: a few minutes to provision, ~10 for K3s +
  cert-manager, and the rest pulling images and waiting for pods (the I-SPI image is large, hence
  the 10-minute readiness wait).
- Always verify current size specs and prices in the dashboard or `civo sizes list` before
  launching — cloud specs and pricing change.
