# Use of generative AI in this repository

*Last reviewed: 2026-11-20. Maintainer: Michael S. Zens.*

This repository holds the deployment material for I-SPI and
i-spi-compute. A generative AI assistant (Anthropic’s Claude, used
through the Claude Code command-line tool) has been used to help write
it. The project’s full statement, covering the curveR packages and the
I-SPI application, is [`AI_USE.md` in
immunoplex/i-spi](https://github.com/immunoplex/i-spi/blob/main/AI_USE.md).

## What the assistant did here

- **Database schema (`db/`).** It traced which tables, views and
  functions I-SPI and i-spi-compute actually use, and wrote the
  extraction, comparison and load-test scripts. It generated the schema
  files from a schema-only dump of the production database. No row data
  was used except the settings catalog and the system-wide default
  settings.
- **Documentation site (`vignettes/articles/`, `_pkgdown.yml`).** It
  consolidated the earlier guides into the articles of the pkgdown site
  and wrote the cloud and reference pages, checking statements against
  the manifests and the application source.
- **Tests (`tests/`, `.github/workflows/`).** It wrote the manifest
  checker, the end-to-end fit test and the workflows that run them.
- **Documentation and manifests.** It drafted text and configuration
  from the maintainer’s instructions.

## What people did

- Decided what a deployment must contain and what is left out, which
  install paths the guides cover, and that the cloud guide names no
  provider.
- Reviewed every change, and merged it through a pull request.

## Checks

- `db/tests/load_test.sh` loads the schema into an empty PostgreSQL and
  checks that it works.
- `db/tools/compare_schema.py` compares each created object with
  production; every remaining difference is listed in `db/MANIFEST.md`.
- `tests/check_manifests.py` and `tests/e2e/run_e2e.sh` check the
  manifests and run a real fit on every pull request; the site is built
  on every pull request.

The maintainer is responsible for everything merged. The AI is not an
author.
