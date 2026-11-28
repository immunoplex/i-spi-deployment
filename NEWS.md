# ispideployment (development)

* **`db/30_seed_settings.sql`:** the `noise_model` setting (system default
  `constant`; choices `constant`, `add_prop`) and its catalog row, the same rows
  as i-spi-compute migration 013. Used by i-spi-compute 1.3.0 (curveRfreq and
  curveRbayes 0.6.0) and offered in I-SPI from the release after 1.3.5. The
  image tags stay at I-SPI 1.3.3 / i-spi-compute 1.2.0 until those releases
  are pinned here; an existing database gets the rows from migration 013.

# ispideployment 2.1.0

* **Images:** I-SPI `1.3.3` (from `1.1.1`), i-spi-compute API and worker `1.2.0`
  (from `1.1.1`; curveRcore 0.7.1, curveRweights 0.3.1, curveRfreq and
  curveRbayes 0.5.2, CmdStan 2.40.0).
* **`db/`:** calib schema `0.7.1` (`20_calib_schema.sql` copied from curveRcore
  v0.7.1): `calib_weights_fit` gains `fit_options` and six fit diagnostics. An
  existing database needs i-spi-compute migration 012 before the 1.2.0 worker
  starts; see
  [Upgrading](https://immunoplex.github.io/i-spi-deployment/articles/upgrading.html).
* **I-SPI environment:** the database settings are `DB_NAME`, `DB_HOST`,
  `DB_PORT`, `DB_USER`, `DB_PASSWORD` (the names the worker uses) in
  `i-spi.yml` and the local stack. I-SPI 1.3.3 still reads the old `db`,
  `db_host`, `db_port`, `db_userid_x`, `db_pwd_x` when the new names are unset.
  New optional `ISPI_ENABLE_ADDITIVE_WEIGHTS`.
* **Checks:** the end-to-end test waits for calib schema `0.7.1`.

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
