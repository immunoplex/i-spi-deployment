# I-SPI deployment

Manifests, schema and guides for running **I-SPI**, an R Shiny
application for bead-based immunoassay data, with its curve-fitting tier
**i-spi-compute**.

**Documentation: <https://immunoplex.github.io/i-spi-deployment/>**

| To | Guide |
|----|----|
| understand what gets deployed | [Overview](https://immunoplex.github.io/i-spi-deployment/articles/overview.html) |
| run everything on one machine with Docker | [On one machine](https://immunoplex.github.io/i-spi-deployment/articles/install-local.html) |
| install on a server you control (K3s or Kubernetes) | [On your own cluster](https://immunoplex.github.io/i-spi-deployment/articles/install-cluster.html) |
| install with a cloud provider, including in the EU | [In the cloud](https://immunoplex.github.io/i-spi-deployment/articles/install-cloud.html) |
| install without internet access | [Without internet access](https://immunoplex.github.io/i-spi-deployment/articles/install-airgapped.html) |
| move to a new release | [Upgrading and rolling back](https://immunoplex.github.io/i-spi-deployment/articles/upgrading.html) |

Current versions: I-SPI `1.1.1`, i-spi-compute `1.1.0`, calib schema
`0.7.0`.

## What is in this repository

| Folder | Contents |
|----|----|
| [`k8s-manifests/`](https://github.com/immunoplex/i-spi-deployment/tree/main/k8s-manifests) | the Kubernetes manifests, with `IMMUNOPLEX_*` placeholders |
| [`db/`](https://github.com/immunoplex/i-spi-deployment/tree/main/db) | the database schema for a new database, and its manifest |
| [`local/`](https://github.com/immunoplex/i-spi-deployment/tree/main/local) | a Docker Compose stack with every service on one machine |
| [`tests/`](https://github.com/immunoplex/i-spi-deployment/tree/main/tests) | the automated checks run on every pull request |
| [`vignettes/articles/`](https://github.com/immunoplex/i-spi-deployment/tree/main/vignettes/articles) | the source of the documentation site |
| [`templates/`](https://github.com/immunoplex/i-spi-deployment/tree/main/templates) | the web theme for the Dex sign-in pages |

## License and AI use

AGPL-3.0; see
[`LICENSE`](https://github.com/immunoplex/i-spi-deployment/blob/main/LICENSE).
How generative AI was used in writing this repository:
[`AI_USE.md`](https://immunoplex.github.io/i-spi-deployment/AI_USE.md).
