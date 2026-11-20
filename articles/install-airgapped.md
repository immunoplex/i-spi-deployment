# Without internet access

On a host that cannot reach public registries, the images are brought in
by hand: pull and save them on a connected machine, carry the files
over, and load them on the host. Then follow the [cluster
guide](https://immunoplex.github.io/i-spi-deployment/articles/install-cluster.md)
with the differences below.

## 1. The images

These are the images the manifests in `k8s-manifests/` use. The
[automated
checks](https://immunoplex.github.io/i-spi-deployment/articles/checks.md)
fail if a manifest uses an image that is not listed here.

| Image | Used by |
|----|----|
| `traefik:v3.5.4` | `traefik.yml` |
| `dexidp/dex:v2.44.0-alpine` | `dex.yml` |
| `busybox` | `dex.yml` (init container that installs the Dex web theme) |
| `ghcr.io/immunoplex/signup:main@sha256:cd7c59b4e5fb2b5090b6995b96265afcfba6b564a86894c1a2ebbae3a2067a79` | `dex.yml` (signup page; pinned by digest, the image has no release tags) |
| `postgres:17.2` | `postgresql.yml` |
| `ghcr.io/immunoplex/i-spi:1.1.1` | `i-spi.yml` |
| `ghcr.io/immunoplex/i-spi-compute-api:1.1.0` | `i-spi-compute.yml`, `i-spi-compute-sim.yml` |
| `ghcr.io/immunoplex/i-spi-compute-worker:1.1.0` | `i-spi-compute.yml`, `i-spi-compute-sim.yml` |
| `redis:7.4` | `i-spi-compute.yml`, `i-spi-compute-sim.yml` |
| `traefik/whoami` | `whoami.yml` (optional test page) |
| `quay.io/oauth2-proxy/oauth2-proxy:v7.8.1` | `whoami.yml` (optional test page) |

On a connected machine with Docker:

``` shell
for img in \
  traefik:v3.5.4 \
  dexidp/dex:v2.44.0-alpine \
  busybox \
  ghcr.io/immunoplex/signup:main@sha256:cd7c59b4e5fb2b5090b6995b96265afcfba6b564a86894c1a2ebbae3a2067a79 \
  postgres:17.2 \
  ghcr.io/immunoplex/i-spi:1.1.1 \
  ghcr.io/immunoplex/i-spi-compute-api:1.1.0 \
  ghcr.io/immunoplex/i-spi-compute-worker:1.1.0 \
  redis:7.4 \
  traefik/whoami \
  quay.io/oauth2-proxy/oauth2-proxy:v7.8.1
do
  docker pull "$img"
  docker save -o "$(echo "$img" | tr '/:@' '___').tar" "$img"
done
```

The worker image is about 5 GB; the others together about 3 GB.

## 2. The cluster’s own images

If the host already runs Kubernetes with cert-manager, skip this step.
To build single-node K3s offline, also bring:

- **K3s:** the `k3s` binary, the install script, and the
  `k3s-airgap-images-<arch>.tar.zst` bundle for `v1.33.5+k3s1`. The K3s
  [air-gap documentation](https://docs.k3s.io/installation/airgap)
  describes them.
- **cert-manager `v1.19.1`:** its release manifest (`cert-manager.yaml`)
  and the images it names (controller, webhook, cainjector,
  startupapicheck). Read the exact tags from that manifest, then pull
  and save them as above.

## 3. Load the images on the host

Copy every `.tar` and the `.tar.zst` bundle to the host, then:

``` shell
sudo mkdir -p /var/lib/rancher/k3s/agent/images/
sudo cp *.tar *.tar.zst /var/lib/rancher/k3s/agent/images/
```

K3s imports everything in that folder when it starts, and within a
minute or two when files are added while it runs.

Install K3s without downloading:

``` shell
sudo cp k3s /usr/local/bin/k3s && sudo chmod +x /usr/local/bin/k3s
INSTALL_K3S_VERSION=v1.33.5+k3s1 INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh --disable=traefik
sudo ln -s /usr/local/bin/kubectl /bin/kubectl
```

Then continue with step 4 of the [cluster
guide](https://immunoplex.github.io/i-spi-deployment/articles/install-cluster.md),
applying cert-manager from the copied `cert-manager.yaml`.

## 4. Two changes to the manifests

After the `sed` step of the cluster guide:

1.  **Pull policy.** `dex.yml` and `postgresql.yml` use
    `imagePullPolicy: Always`, which tries the registry even when the
    image is already loaded, and fails offline. Change it:

    ``` shell
    sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g' *.yml
    ```

2.  **The Dex web theme.** Dex’s init container downloads its web theme
    (`web.zip`) from GitHub on first start. Offline, put the unpacked
    `web/` folder (from `templates/web.zip` in this repository) on the
    `dex` volume at `/var/dex/web` before starting Dex; the init
    container then skips the download.

## 5. Check

``` shell
sudo k3s ctr images ls | grep -E 'i-spi|dex|traefik|postgres|signup|redis'
```

Every image from step 1 should be listed. A pod in `ImagePullBackOff`
almost always means `imagePullPolicy: Always` on a loaded image, or a
tag that differs from the one saved.
