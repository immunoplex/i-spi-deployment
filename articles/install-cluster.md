# On your own cluster (K3s or Kubernetes)

This guide installs a lasting instance on a server you control: a
virtual machine or a physical Linux host with single-node K3s, or an
existing Kubernetes cluster. It was tested on Rocky Linux 8 and 9 and
Ubuntu 24.04.

Read the
[Overview](https://immunoplex.github.io/i-spi-deployment/articles/overview.md)
first for what each component does. For a host without internet access,
combine this guide with [Without internet
access](https://immunoplex.github.io/i-spi-deployment/articles/install-airgapped.md).
For a cloud provider, see [In the
cloud](https://immunoplex.github.io/i-spi-deployment/articles/install-cloud.md).

## 1. Requirements

- A Linux host you can `sudo` on, or an existing cluster and `kubectl`
  access to it.
- For a host that will fit real studies: 8 CPUs or more, 16 to 32 GB of
  memory, and 100 GB of disk. The database (20 GB) and Dex (1 GB)
  volumes live on the node’s disk, next to the images. A smaller host (4
  CPUs, 16 GB) is enough to bring the system up.
- A hostname. It goes into every redirect URI, so choose it before you
  start (step 2).

On a new host, update the system and note its IP address:

``` shell
sudo dnf -y update                                # Rocky
sudo apt-get update && sudo apt-get -y upgrade    # Ubuntu
ip -4 addr show | grep inet
```

## 2. Choose the hostname

The hostname must resolve to the node in three places: on the node, in
the browsers that will use I-SPI, and inside the cluster.

- **With DNS:** point an `A` record at the node. Without a domain, a
  wildcard DNS service such as `sslip.io` turns an IP into a name:
  `1-2-3-4.sslip.io` resolves to `1.2.3.4`.
- **Without DNS** (a closed network): add the name to `/etc/hosts` on
  the node and to the hosts file of each client
  (`C:\Windows\System32\drivers\etc\hosts` on Windows).

On K3s, pods resolve the name through `coredns.yml` (step 5), which the
`sed` step fills in. Keep both values in shell variables:

``` shell
export ISPI_HOST="ispi.example.org"   # the name users type in the browser
export ISPI_IP="1.2.3.4"              # the node's IP address
```

## 3. Install K3s (skip on an existing cluster)

``` shell
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.33.5+k3s1 sh -s - --disable=traefik
sudo ln -s /usr/local/bin/kubectl /bin/kubectl
sudo kubectl get node -o wide
```

`--disable=traefik` is required: this deployment brings its own Traefik.
K3s keeps its built-in load balancer, which exposes Traefik on the
node’s IP, and its local-path storage, which backs the volumes. The K3s
[requirements](https://docs.k3s.io/installation/requirements) list what
the host needs.

## 4. Namespace, cert-manager and a certificate authority

``` shell
sudo kubectl create ns immunoplex

sudo kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.1/cert-manager.yaml
sudo kubectl wait -n cert-manager --for=condition=ready pod -l app=webhook --timeout=5m
```

Every Ingress asks cert-manager for its certificate through the
ClusterIssuer `intermediate-ca1-issuer`. The commands below create a
private certificate authority with that issuer: a self-signed root, and
an intermediate it signs. To use certificates browsers already trust
instead, see [In the
cloud](https://immunoplex.github.io/i-spi-deployment/articles/install-cloud.html#tls).

``` shell
cat <<EOF | sudo kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: root-ca-issuer-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: root-ca
  secretName: root-ca-secret
  duration: 87600h # 10y
  renewBefore: 78840h # 9y
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    name: root-ca-issuer-selfsigned
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: root-ca-issuer
spec:
  ca:
    secretName: root-ca-secret
EOF
sudo kubectl describe ClusterIssuer -n cert-manager     # root-ca-issuer should be Ready

cat <<EOF | sudo kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: intermediate-ca1
  namespace: cert-manager
spec:
  isCA: true
  commonName: intermediate-ca1
  secretName: intermediate-ca1-secret
  duration: 43800h # 5y
  renewBefore: 35040h # 4y
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    name: root-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: intermediate-ca1-issuer
spec:
  ca:
    secretName: intermediate-ca1-secret
EOF

# Copy the root certificate into the namespace, and export it for the browsers
sudo kubectl get secret root-ca-secret --namespace=cert-manager -o yaml \
  | sed 's/namespace: cert-manager/namespace: immunoplex/' \
  | sudo kubectl create -f -
sudo kubectl -n cert-manager get secret root-ca-secret -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > immunoplex-root-ca.crt
```

Import `immunoplex-root-ca.crt` into the browser or operating-system
trust store of every client. Without it, browsers warn that the site is
not trusted.

## 5. Get and configure the manifests

``` shell
git clone https://github.com/immunoplex/i-spi-deployment.git
cd i-spi-deployment/k8s-manifests
```

The manifests contain placeholders (`IMMUNOPLEX_*`). One `sed` pass
replaces each everywhere it appears, so values shared between files
always match. [Configuration and
secrets](https://immunoplex.github.io/i-spi-deployment/articles/configuration.md)
lists what each placeholder is used for.

``` shell
sed -i "s/IMMUNOPLEX_HOSTNAME/$ISPI_HOST/g"                        *.yml
sed -i "s/IMMUNOPLEX_IP_ADDRESS/$ISPI_IP/g"                        coredns.yml
sed -i "s/IMMUNOPLEX_POSTGRES_PASSWORD/$(openssl rand -hex 16)/g"  *.yml
sed -i "s/IMMUNOPLEX_OAUTH_CLIENT_ID/$(openssl rand -hex 32)/g"    *.yml
sed -i "s/IMMUNOPLEX_OAUTH_SECRET/$(openssl rand -hex 32)/g"       *.yml
sed -i "s/IMMUNOPLEX_REDIS_AUTH/$(openssl rand -hex 32)/g"         *.yml
sed -i "s/IMMUNOPLEX_API_KEY/$(openssl rand -hex 32)/g"            *.yml
# only for the optional whoami test page:
sed -i "s/IMMUNOPLEX_OAUTH_COOKIE_SECRET/$(openssl rand -hex 16)/g" *.yml
```

Each `sed` line generates its value once and writes it into every file
that uses it. The configured files now hold real secrets: keep them out
of version control.

## 6. Deploy

Apply in order, and wait for each step before the next.

``` shell
# Name resolution (K3s only) and the ingress
sudo kubectl apply -f coredns.yml
sudo kubectl -n kube-system rollout restart deploy coredns
sudo kubectl -n immunoplex apply -f traefik.yml

# Sign-in
sudo kubectl -n immunoplex apply -f dex.yml

# Optional: test sign-in before going further (step 7)
sudo kubectl -n immunoplex apply -f whoami.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=whoami --timeout=5m

# Database and schema (see Database schema)
sudo kubectl -n immunoplex apply -f postgresql.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=postgresql --timeout=5m
sudo kubectl -n immunoplex exec -it deploy/postgresql -- psql -U postgres -c "CREATE DATABASE immunoplex;"
cat ../db/[0-9][0-9]_*.sql | sudo kubectl -n immunoplex exec -i deploy/postgresql -- \
  psql -v ON_ERROR_STOP=1 -U postgres immunoplex

# i-spi-compute, before I-SPI
sudo kubectl -n immunoplex apply -f i-spi-compute.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi-compute-redis  --timeout=5m
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi-compute-api    --timeout=5m
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi-compute-worker --timeout=5m

# I-SPI (a large image; the first start can take several minutes)
sudo kubectl -n immunoplex apply -f i-spi.yml
sudo kubectl -n immunoplex wait --for=condition=ready pod -l app=i-spi --timeout=10m
```

On a cluster that is not K3s, skip `coredns.yml` and make the hostname
resolve through DNS instead.

## 7. Check that it works

1.  **Sign-in** (if you deployed whoami): open `https://<host>/whoami`,
    sign up, sign in, and check that the page shows your email address.
    Then remove the test page:
    `sudo kubectl -n immunoplex delete -f whoami.yml`.

2.  **Database:**
    `sudo kubectl -n immunoplex exec -it deploy/postgresql -- psql -U postgres -c "select version();"`

3.  **Compute:**

    ``` shell
    sudo kubectl -n immunoplex exec -it deploy/i-spi-compute-api -- \
      python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/health').read().decode())"
    # {"status":"ok","redis":"connected"}
    ```

4.  **I-SPI:** open `https://<host>/i-spi/`, sign in, create a project
    and a study, import plates and run a fit. When the results appear,
    the whole path works: I-SPI, the compute API, Redis, the worker, the
    database, and back.

## If something does not work

- **Sign-in does not complete.** Almost always a hostname mismatch. The
  hostname must be the same in the browser, the hosts files or DNS,
  `coredns.yml` and the manifests, and I-SPI’s `APP_REDIRECT_URI`
  (`https://<host>/i-spi/`) must be one of the client’s `redirectURIs`
  in `dex.yml`. Set `SHINY_LOG_LEVEL` to `DEBUG` in `i-spi.yml` and read
  `kubectl -n immunoplex logs deploy/i-spi`.
- **A fit is submitted but never finishes.** Read the worker’s log:
  `kubectl -n immunoplex logs deploy/i-spi-compute-worker`. A stuck job
  is almost always on the compute side.
- **I-SPI cannot submit a job.** From the I-SPI pod,
  `curl http://i-spi-compute-api:8000/health` should answer as in
  step 7. I-SPI and the API read the same key from the `i-spi-compute`
  Secret, so a 401 or 403 means the Secret changed after I-SPI started:
  restart I-SPI.
- **Fits are slow, or the worker is killed for lack of memory.** Raise
  the worker’s CPU and memory limits in `i-spi-compute.yml`, keeping
  `WORKER_CORES` equal to the CPU limit, or add worker replicas.
- **The worker cannot reach the database.** Its `DB_SSLMODE` must be
  `require`: PostgreSQL rejects connections without TLS.
- **A pod stays in `ImagePullBackOff`** on a host without internet
  access: see [Without internet
  access](https://immunoplex.github.io/i-spi-deployment/articles/install-airgapped.html#check).

## Remove it

``` shell
sudo kubectl delete ns immunoplex      # the application and its data
/usr/local/bin/k3s-uninstall.sh        # or K3s and everything on it
```

Everything, including the database and the Dex accounts, is on the node.
To keep results, `pg_dump` the `immunoplex` database first.
