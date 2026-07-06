# ImmunoPlex Container Images for Offline / Air-Gapped Installs

This guide covers how to obtain the container images a **standalone I-SPI** install needs and
make them available on a machine with no (or restricted) access to public registries. It pairs
with `README-STANDALONE-ISPI.md` (the runbook), `K3S.md` (cluster prerequisites), and
`ARCHITECTURE.md` §2.2 (the connected-vs-air-gapped decision).

The image list below is derived from the `image:` fields of the standalone manifests, so it
matches what those manifests actually pull. **Keep this list in sync with the manifests** — if
you bump a version in a `.yml`, bump it here too.

> The workflow is: on an internet-connected machine, `pull` then `save` each image to a tarball;
> transfer the tarballs (USB, etc.); then side-load them on the target. Versions below are the
> ones pinned in the current manifests — update them if you change the manifests.

## 1. Application images

### Core (always needed for a standalone I-SPI install)

| Image | Pulled by |
|---|---|
| `traefik:v3.5.4` | `traefik.yml` |
| `dexidp/dex:v2.44.0-alpine` | `dex.yml` |
| `busybox` | `dex.yml` (init container that seeds the Dex web theme) |
| `ghcr.io/immunoplex/signup:main` | `dex.yml` (dex-account signup UI) |
| `postgres:17.2` | `postgresql.yml` |
| `ghcr.io/immunoplex/i-spi:main` | `i-spi.yml` |

```shell
docker pull traefik:v3.5.4
docker pull dexidp/dex:v2.44.0-alpine
docker pull busybox
docker pull ghcr.io/immunoplex/signup:main
docker pull postgres:17.2
docker pull ghcr.io/immunoplex/i-spi:main
```

### Optional — whoami auth-chain test harness (`whoami.yml`)

Only if you deploy the optional whoami check before I-SPI.

```shell
docker pull traefik/whoami
docker pull quay.io/oauth2-proxy/oauth2-proxy:v7.8.1
```

### Optional — external Batch Calculator (`batch-calculator.yml`)

Only if your I-SPI build offloads fitting to the external Batch Calculator. The provided I-SPI
build fits **in-process** and does not need these (see `ARCHITECTURE.md` §3.5).

```shell
docker pull redis:7
docker pull ghcr.io/immunoplex/immunoplex-batch-cal-api:main
docker pull ghcr.io/immunoplex/immunoplex-batch-cal-worker:main
```

> Images the standalone install does **not** use (and that earlier versions of this list wrongly
> included): `redis:8` (the main Redis is not part of a standalone install), and
> `quay.io/minio/minio:*` (MinIO / object storage is out of scope). Don't ship them.

## 2. Cluster-prerequisite images (only if you are also building the cluster offline)

If the target already has a working Kubernetes cluster with cert-manager, skip this section. If
you are building single-node K3s per `K3S.md` on an offline host, you also need the images those
steps pull:

- **K3s system images.** K3s normally pulls its own system images (pause, CoreDNS,
  local-path-provisioner, metrics-server, klipper service-lb) at first start. For an offline
  install, download the matching `k3s` binary and the `k3s-airgap-images-<arch>.tar.zst` bundle
  for the pinned version (`v1.33.5+k3s1`), place the bundle in
  `/var/lib/rancher/k3s/agent/images/`, and run the installer with
  `INSTALL_K3S_SKIP_DOWNLOAD=true`. See the K3s air-gap documentation for the exact procedure.
- **cert-manager images.** `K3S.md` applies the cert-manager `v1.19.1` release, which pulls the
  jetstack cert-manager images (`controller`, `webhook`, `cainjector`, `startupapicheck`). Get
  the exact image list for the version you install from that release's manifest
  (`cert-manager.yaml`) rather than hand-typing tags, then pull/save them the same way as the
  application images below. These must be present before the CA/`ClusterIssuer` steps will
  succeed.

## 3. Save the images as tarballs

Once pulled, save each image to a tarball (repeat for every image you pulled above):

```shell
docker save -o traefik.tar          traefik:v3.5.4
docker save -o dex.tar              dexidp/dex:v2.44.0-alpine
docker save -o busybox.tar          busybox
docker save -o signup.tar           ghcr.io/immunoplex/signup:main
docker save -o postgres.tar         postgres:17.2
docker save -o i-spi.tar            ghcr.io/immunoplex/i-spi:main
# optional whoami harness:
docker save -o whoami.tar           traefik/whoami
docker save -o oauth2-proxy.tar     quay.io/oauth2-proxy/oauth2-proxy:v7.8.1
# optional batch calculator:
docker save -o redis.tar            redis:7
docker save -o batch-cal-api.tar    ghcr.io/immunoplex/immunoplex-batch-cal-api:main
docker save -o batch-cal-worker.tar ghcr.io/immunoplex/immunoplex-batch-cal-worker:main
```

Transfer the tarballs to the target host (USB drive, internal artifact store, etc.).

## 4. Make the images available

### K3s

On the K3s node, create the images directory and copy in every tarball:

```shell
sudo mkdir -p /var/lib/rancher/k3s/agent/images/
sudo cp *.tar /var/lib/rancher/k3s/agent/images/
```

Within a minute or two K3s imports them and they are available to pods. (K3s also auto-imports
`.tar.zst` bundles here, which is how the `k3s-airgap-images` bundle from §2 is loaded.)

> **Set `imagePullPolicy` appropriately.** Several manifests use `imagePullPolicy: Always`
> (e.g. `i-spi.yml`, `dex.yml`'s signup, `postgresql.yml`). With no registry reachable, `Always`
> makes the kubelet try (and fail) to re-pull even when the image is already side-loaded. For an
> offline install, change those to `IfNotPresent` (or pin to a digest that is present) so pods
> start from the imported images.

### The Dex web theme (air-gap trap)

The Dex pod's init container downloads its web theme (`web.zip`) from GitHub on first start —
which fails offline. Pre-seed the `dex` PVC with the unpacked `web/` directory at
`/var/dex/web` before starting Dex; the init container detects it and skips the download. (This
is noted in `dex.yml` as well.)

## 5. Verify

After the pods come up, a quick sanity check that images resolved from the local store rather
than a registry:

```shell
sudo k3s ctr images ls | grep -E 'i-spi|dex|traefik|postgres|signup'
```

You should see the tags you side-loaded. If a pod is stuck in `ImagePullBackOff`, it is almost
always an `imagePullPolicy: Always` on an image that exists locally, or a version tag that
doesn't match what you saved.
