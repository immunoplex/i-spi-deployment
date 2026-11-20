"""Static checks of the Kubernetes manifests and the local Compose file.

Usage (from the repo root):  python3 tests/check_manifests.py      (needs PyYAML)

1. Every k8s-manifests/*.yml and local/docker-compose.yml parses as YAML.
2. Every secretKeyRef in the manifests names a Secret defined in k8s-manifests/.
3. Every IMMUNOPLEX_* placeholder in the manifests is filled by the `sed` step in
   the cluster install guide (vignettes/articles/install-cluster.Rmd).
4. Every ghcr.io/immunoplex image is pinned to a version tag or a digest (not
   :main or :latest alone, not untagged), in the manifests and the Compose file.
5. The I-SPI and i-spi-compute images are the same versions in the manifests and
   in the Compose file.
6. Every image the manifests use is listed in the air-gapped install guide
   (vignettes/articles/install-airgapped.Rmd), so its image list stays complete.
Exit status 1 with a list of problems, 0 if all checks pass.
"""
import glob
import os
import re
import sys

import yaml

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
problems = []


def walk(x):
    if isinstance(x, dict):
        yield x
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)


manifests = sorted(glob.glob("k8s-manifests/*.yml"))
secrets, refs, images = set(), [], {}
for f in manifests:
    try:
        docs = [d for d in yaml.safe_load_all(open(f, encoding="utf-8")) if d]
    except yaml.YAMLError as e:
        problems.append(f"{f}: YAML error: {e}")
        continue
    for d in docs:
        if d.get("kind") in ("Secret", "SealedSecret"):
            secrets.add(d["metadata"]["name"])
        for node in walk(d):
            ref = node.get("secretKeyRef")
            if isinstance(ref, dict):
                refs.append((f, ref.get("name")))
            img = node.get("image")
            if isinstance(img, str):
                images.setdefault(img, set()).add(f)

for f, name in refs:
    if name not in secrets:
        problems.append(f"{f}: secretKeyRef to '{name}', which no manifest defines")

placeholders = set()
for f in manifests:
    placeholders |= set(re.findall(r"IMMUNOPLEX_[A-Z_]+", open(f, encoding="utf-8").read()))
GUIDE = "vignettes/articles/install-cluster.Rmd"
guide = open(GUIDE, encoding="utf-8").read()
for p in sorted(placeholders):
    if f"s/{p}/" not in guide:
        problems.append(f"placeholder {p} is not filled by the sed step in {GUIDE}")

AIRGAP = "vignettes/articles/install-airgapped.Rmd"
airgap = open(AIRGAP, encoding="utf-8").read()
for img in sorted(images):
    if f"`{img}`" not in airgap:
        problems.append(f"image {img} ({', '.join(sorted(images[img]))}) is not listed in {AIRGAP}")

compose = yaml.safe_load(open("local/docker-compose.yml", encoding="utf-8"))
compose_images = {svc.get("image") for svc in compose["services"].values() if svc.get("image")}


def check_pinned(img, where):
    if not img.startswith("ghcr.io/immunoplex/"):
        return
    if "@sha256:" in img:           # pinned by digest
        return
    tag = img.rsplit(":", 1)[1] if ":" in img.split("/")[-1] else None
    if tag is None or tag in ("main", "latest") or not re.match(r"^\d+\.\d+\.\d+", tag):
        problems.append(f"{where}: image {img} is not pinned to a release tag")


for img, files in images.items():
    check_pinned(img, ", ".join(sorted(files)))
for img in compose_images:
    check_pinned(img, "local/docker-compose.yml")


def tags(imgs, repo):
    return {i.rsplit(":", 1)[1] for i in imgs if i.startswith(f"ghcr.io/immunoplex/{repo}:")}


for repo in ("i-spi", "i-spi-compute-api", "i-spi-compute-worker"):
    k, c = tags(images, repo), tags(compose_images, repo)
    if k != c:
        problems.append(f"{repo}: manifests use {sorted(k)}, local/docker-compose.yml uses {sorted(c)}")

print(f"manifests: {len(manifests)}; Secrets: {sorted(secrets)}; secretKeyRefs: {len(refs)}; "
      f"placeholders: {len(placeholders)}; images: {len(images)} (+{len(compose_images)} in Compose)")
for p in problems:
    print("PROBLEM:", p)
sys.exit(1 if problems else 0)
