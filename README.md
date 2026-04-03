# Immunoodle Deployment

TODO: Add short blurb on what Immunoodle is.

This repo provides instructions and manifests for deploying Immunoodle in your choice of Kubernetes clusters.

If you don't have a Kubernetes cluster, you can use [k3s](https://rancher.com/docs/k3s/latest/en/). K3s installation instructions are provided below.

Deploy the applications and services in the order listed in the document.

## Hardware Requirements

To run all the components of immunoodle, you'll need at least 2 CPU cores and 16GB of RAM.  These instructions have been tested on Rocky8, Rocky9, and Ubuntu 24.04.3.

## Configuration for your environment

On the system where you'll be installing immunoodle, clone this git repository and make the changes below to configure immunoodle for your environment.

```shell
git clone https://github.com/immunoodle/deployment.git
cd deployment

# Replace PUT_YOUR_HOSTNAME_HERE with the hostname that users will use to access the immunoodle service, then run the `sed` command
sed -i "s/IMMUNOODLE_HOSTNAME/PUT_YOUR_HOSTNAME_HERE/g" k8s-manifests/*

# Replace PUT_YOUR_IP_ADDRESS_HERE with the IP address used to access this host, then run the command
sed -i "s/IMMUNOODLE_IP_ADDRESS/PUT_YOUR_IP_ADDRESS_HERE/g" k8s-manifests/*

# Replace PUT_YOUR_POSTGRES_PASSWORD_HERE with a strong password for the `postgres` user in PostgreSQL, then run the `sed` command
sed -i "s/IMMUNOODLE_POSTGRES_PASSWORD/PUT_YOUR_POSTGRES_PASSWORD_HERE/g" k8s-manifests/*

# Replace PUT_YOUR_REDIS_PASSWORD_HERE with a strong password used for accessing REDIS, then run the command
sed -i "s/IMMUNOODLE_REDIS_AUTH/PUT_YOUR_REDIS_PASSWORD_HERE/g" k8s-manifests/*

# Replace PUT_YOUR_MINIO_ROOT_PASSWORD_HERE with a strong password used for accessing Minio (local S3 Object Storage), then run the `sed` command
sed -i "s/IMMUNOODLE_MINIO_ROOT_PASSWORD/PUT_YOUR_MINIO_ROOT_PASSWORD_HERE/g" k8s-manifests/*

# Run the following two commands to generate a random string which will be used as part of the authentication service
IMMUNOODLE_OAUTH_CLIENT_ID=$(openssl rand -hex 32)
sed -i "s/IMMUNOODLE_OAUTH_CLIENT_ID/$IMMUNOODLE_OAUTH_CLIENT_ID/g" k8s-manifests/*

# Run the following two commands to generate a random string which will be used as part of the authentication service
IMMUNOODLE_OAUTH_SECRET=$(openssl rand -hex 32)
sed -i "s/IMMUNOODLE_OAUTH_SECRET/$IMMUNOODLE_OAUTH_SECRET/g" k8s-manifests/*

# Run the following two commands to generate a random string which will be used as part of the authentication service
IMMUNOODLE_OAUTH_COOKIE_SECRET=$(openssl rand -hex 16)
sed -i "s/IMMUNOODLE_OAUTH_COOKIE_SECRET/$IMMUNOODLE_OAUTH_COOKIE_SECRET/g" k8s-manifests/*

# Run the following two commands to generate a random string which will be used for internal API server access
IMMUNOODLE_API_KEY=$(openssl rand -hex 32)
sed -i "s/IMMUNOODLE_API_KEY/$IMMUNOODLE_API_KEY/g" k8s-manifests/*
```

## Install k3s (Only requireed if you don't already have a Kubernetes cluster)

If you don't have Kubernetes already installed, you can follow these instructions for deploying K3s (a lightweight Kubernetes environment).

[K3s Install](K3S.md)

## Create immunoodle namespace

These instructions expect all components of immunoodle to be installed in the immunoodle namespace. If you haven't already created the `immunoodle` namespace, please do it now.

```shell
sudo kubectl create ns immunoodle
```

## Traefik

Traefik is a Ingress Controller that provides access to the various Immunoodle Components. Run the following command to install Traefik.

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/traefik.yml
```

## Dex

Dex is an Identity Provider that's used for authentication to the Immunoodle components.  Run the following command to install Dev.

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/dex.yml 
```

## Whoami

Whoami lets us test the components installed thus far.  Run the following command to install `whoami`.

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/whoami.yml
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=whoami --timeout=5m
```

To test Dex and Traefik, follow these steps:

1. In your browser, navigate to: https://PUT_IMMUNOODLE_HOSTNAME_HERE/whoami
2. You will be redirected to Dex. Click `Signup` to create a user account
3. Provide your name, email address and create a password, then click `SIGNUP`
4. Provide your email address and password on the login screen
5. After sucessful login, you'll be redirected back to `whoami`.

`whoami` displays a variety of information about the HTTP request.  Find the `X-Forwarded-Email` attribute to see that your email address is specified as the authenticated user.

## PostgreSQL

PostgreSQL is used as the relational database for many of the Immunoodle components.  Run the following commands to install PostgreSQL.

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/postgresql.yml
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=postgresql --timeout=5m
```

To confirm PostgreSQL is available, run the following command.  If successfull, it will display the version of PostgreSQL.

```shell
sudo kubectl -n immunoodle exec -it deploy/postgresql -- psql -U postgres -c "select version();"
```

```shell
#
# Example output:
#
#                                                         version
#   ---------------------------------------------------------------------------------------------------------------------
#   PostgreSQL 17.2 (Debian 17.2-1.pgdg120+1) on x86_64-pc-linux-gnu, compiled by gcc (Debian 12.2.0-14) 12.2.0, 64-bit
#   (1 row)
# 
```

## Redis

Redis is the key-value database. Run the following commands to install Redis.

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/redis.yml
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=redis --timeout=5m
```

To confirm Redis is available, run the following command. When prompted, provide the password you select above.

```shell
sudo kubectl -n immunoodle exec -it deploy/redis -- redis-cli --askpass INFO SERVER
```

```shell
#  
# Example output:
# 
#   # Server
#   redis_version:8.2.3
#   redis_git_sha1:00000000
#   redis_git_dirty:1
#   redis_build_id:c978de5219ded02d
#   redis_mode:standalone
#   os:Linux 4.18.0-553.81.1.el8_10.x86_64 x86_64
#   ...
# 
```

## Minio

Minio provides S3-compatible object storage. 

Note that Minio is AGPL licensed and the source code is [here](https://github.com/minio/minio/tree/RELEASE.2025-07-23T15-54-02Z) for the version deployed.

Run the following commands to install Minio and create the `data-portal` bucket.

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/minio.yml
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=minio --timeout=5m
sudo kubectl -n immunoodle exec -it deploy/minio -- sh -c 'mc alias set minio http://localhost:9000 root $MINIO_ROOT_PASSWORD'
sudo kubectl -n immunoodle exec -it deploy/minio -- mc mb minio/data-portal
```

To confirm Minio is available, run the following command. If available, you'll get a `HTTP/1.1 200 OK` response.

```shell
sudo kubectl -n immunoodle exec -it deploy/minio -- curl localhost:9000/minio/health/ready -I | head -1
```

## Applications

### Worker

Worker handles task management for data processing. Run the following commands to install the Worker component.

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/worker.yml
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=worker --timeout=5m
```

### API

API provides API endpoints for data processing. Run the following commands to install the API component.

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/api.yml
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=api --timeout=5m
```

### Data Portal

Data Portal Database

```shell
gunzip -c db-dumps/dataportal.sql.gz | sudo kubectl -n immunoodle exec -it deploy/postgresql -- psql -U postgres postgres
```

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/data-portal.yml
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=data-portal --timeout=5m
```

### I-SPI

I-SPI is an interactive R Shiny application for processing, analyzing, and visualizing Luminex bead-based immunoassay data. It provides a unified platform for managing serology experiments with robust features for data import, quality control, curve fitting, and results visualization. I-SPI depends on the rest of the Infrastructure and Application stacks being deployed first

Set-up the database for the application first. Find the name of the postgresql pod in the immunoodle namespace:

```shell
sudo kubectl -n immunoodle exec -it deploy/postgresql -- psql -U postgres -c "CREATE DATABASE immunoodle;"
sudo kubectl -n immunoodle exec -it deploy/postgresql -- psql -U postgres immunoodle < db-dumps/i-spi-db.sql
```

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/i-spi.yml
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=i-spi --timeout=5m
```

### Batch Calculator

Batch Calculator provides background Bayesian standard curve fitting for i-spi. It includes its own dedicated Redis instance, a FastAPI job submission API, and an R worker that uses the [stanassay](https://github.com/immunoplex/stanassay) package for hierarchical 4PL/5PL/Gompertz ensemble fitting via Stan MCMC.

The batch calculator depends on PostgreSQL being available (it writes results to the `madi_results` schema in the same database as i-spi).

Run the following commands to install the Batch Calculator:

```shell
sudo kubectl -n immunoodle apply -f k8s-manifests/batch-calculator.yml
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=batch-calculator-redis --timeout=5m
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=batch-calculator-api --timeout=5m
sudo kubectl -n immunoodle wait --for=condition=ready pod -l app=batch-calculator-worker --timeout=5m
```

To confirm the Batch Calculator API is available:

```shell
sudo kubectl -n immunoodle exec -it deploy/batch-calculator-api -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/health').read().decode())"
```

```shell
#
# Example output:
#
#   {"status":"ok","redis":"connected"}
#

```

For more information, see the [Batch Calculator repository](https://github.com/immunoplex/immunoplex-batch-calculator).
