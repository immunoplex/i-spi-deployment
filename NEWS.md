# ispideployment 2.0.0

First versioned release of this repository. It replaces the earlier layout
(database dumps, batch calculator, separate README guides) with:

* **Images pinned:** I-SPI `1.1.1`, i-spi-compute API and worker `1.1.1`
  (curveRcore 0.7.0, curveRfreq 0.5.2, curveRbayes 0.5.2, curveRweights 0.3.0,
  CmdStan 2.40.0), Redis `7.4`, PostgreSQL `17.2` in the cluster
  manifest and `16` in the local stack.
* **`db/`:** a curated schema for a new, empty database (calib schema 0.7.0)
  with seeded settings, instead of `pg_dump` files. `db/MANIFEST.md` lists every
  object and where it comes from.
* **`k8s-manifests/`:** public templates with placeholders and no secrets.
  I-SPI reaches i-spi-compute inside the cluster. An optional second compute
  tier is in `i-spi-compute-sim.yml`. The batch calculator is removed.
* **`local/`:** a Docker Compose stack (PostgreSQL, Dex, Redis, i-spi-compute,
  I-SPI) that runs on one machine.
* **`tests/` and CI:** the schema loads into an empty PostgreSQL, the
  manifests and Compose file are checked for pinned and consistent versions,
  and an end-to-end run fits a curve through the local stack.
* **Documentation site** built with pkgdown: overview, local, cluster,
  cloud (provider-neutral) and air-gapped installs, configuration, database
  schema, upgrading, and checks.

i-spi-compute 1.1.1 fixes a 1.1.0 worker bug: Bayesian fits saved without
posterior draws (the default) stored no back-calculated standard or control
estimates. See [Upgrading](https://immunoplex.github.io/i-spi-deployment/articles/upgrading.html)
for how to fill them in for fits made on 1.1.0.
