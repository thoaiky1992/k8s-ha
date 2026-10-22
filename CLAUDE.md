# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a highly available stack on AWS EKS: Terraform for AWS and cluster add-ons, plain Kubernetes manifests (some via operators) for Elasticsearch, Redis Sentinel, Kibana and RedisInsight, and one small Node.js app that consumes both data stores over TLS. There is no build, lint, or test system. Validation is `terraform plan`, `kubectl` dry-runs, and the `check.sh` preflight scripts.

The runbooks (`*/README.md`, `ELASTICSEARCH.md`, `KIBANA.md`) are written in Vietnamese and are the source of truth for install order and verification commands. Keep new docs consistent with that language.

## Commands

Terraform runs per layer, always with a layer-specific var file. Init uses the backend config from the `.example` file copied to `backend.tfvars`:

```bash
terraform -chdir=terraform/00-networking init -backend-config=backend.tfvars
terraform -chdir=terraform/00-networking plan -var-file=terraform.tfvars
terraform -chdir=terraform/00-networking apply -var-file=terraform.tfvars
```

Repeat for `terraform/01.kubernetes` and `terraform/02.dns-records`. Apply in that order: `01.kubernetes` reads the networking layer's state from S3 through `terraform_remote_state`.

Kubernetes manifests are applied with an explicit context. Set it first so writes never go to the wrong cluster:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
kubectl --context "$KUBE_CONTEXT" apply -f <file>
```

Preflight checks, run before installing a stack:

```bash
KUBE_CONTEXT=<context> bash elasticsearch/check.sh
KUBE_CONTEXT=<context> bash redis-sentinel/check.sh
```

Both need `kubectl` and `jq`; the Redis check also needs `helm`.

Application (run from `app/`):

```bash
npm install
npm start          # node server.js; requires the env vars listed in server.js
docker build -t <registry>/node-api:<tag> app
```

Single-test runs do not apply here because there is no test suite.

## Secrets and files that must stay out of git

Each `*.example` file is a template. Copy it to the real name, fill it in, and never commit the copy. Ignore rules exist for `*.tfvars` (root `.gitignore`), `redis-sentinel/secret.yaml`, `elasticsearch/secret.yaml`, and `app/credentials.env`, `*.crt`, `*.key` (`app/.gitignore`). `redisinsight/secret.yaml` is tracked in git and is not ignored, so check its contents and `git status` before committing anything under `redisinsight/`. Do not put real credentials, state bucket names, or account IDs into tracked files. Do not disable TLS verification (`rejectUnauthorized: false`, `--insecure`, skipping the CA) to make a connection work; fix the CA or the hostname instead.

## Architecture: how the pieces connect

**Terraform layers (state in S3):**
- `00-networking`: VPC, subnets, NAT, route tables. Publishes subnet IDs as outputs.
- `01.kubernetes`: EKS cluster (API auth mode, public endpoint only), node groups, and add-ons: metrics-server, cluster-autoscaler, AWS Load Balancer Controller, EBS CSI driver, cert-manager, EKS Pod Identity. It also provisions the S3 buckets and IAM roles for Elasticsearch snapshots (`13.elasticsearch-backup.tf`) and Redis backups (`14.redis-sentinel-backup.tf`), with Pod Identity associations to their ServiceAccounts.
- `02.dns-records`: Route 53 records (e.g. Kibana).

**Data plane (Kubernetes, all on EBS gp3 PVCs, one replica per AZ):**
- Elasticsearch is managed by the ECK operator, which the ELASTICSEARCH.md runbook installs with Helm. The `search` cluster has 3 nodes. ECK issues and rotates the TLS certificates, including transport TLS, and creates the `search-es-http-certs-public` Secret that holds the CA.
- Redis is managed by the OT Redis Operator 0.27.0 (Helm, watching only the `redis-sentinel` namespace). It runs one `RedisReplication` (`redis-sentinel`, 3 pods) and one `RedisSentinel` (also named `redis-sentinel`, so its Service is `redis-sentinel-sentinel`, port 26379). Redis, replication, and Sentinel all use TLS.
- cert-manager provides the Redis CA. `certificate.yaml` creates a self-signed root, then the `redis-sentinel-ca` CA and the `redis-sentinel-tls` server certificate. The DNS SANs must match the Service and headless Service names. If the cluster uses a DNS suffix other than `cluster.local`, update `dnsNames`.
- Namespaces: `elasticsearch`/`elastic-system` (ECK), `redis-sentinel`/`redis-sentinel-system` (Redis and its operator), `app` (the Node service), and `kibana`.

**Cross-namespace trust is manual.** Kubernetes Pods cannot mount Secrets from other namespaces. The `app` namespace therefore receives copies of the public CA certificates only (`ca.crt` from ECK, `tls.crt` from `redis-sentinel-ca`), stored in a ConfigMap `backend-ca`. Never copy `tls.key`. Changing a CA or password means updating the Secret or ConfigMap and restarting the Deployment, because the app reads them only at startup.

**Application (`app/server.js`):** a single-file Node 22 HTTP server that uses `@elastic/elasticsearch` v9 and `redis` v5 `createSentinel`. It refuses to start unless every variable in its `required` list is set, and it requires `https://` for Elasticsearch. It reaches the Redis primary by asking Sentinel (`REDIS_SENTINEL_HOST`/`PORT`, master name `REDIS_MASTER_NAME`). It does not connect to Redis directly by a fixed address, so failover is handled by Sentinel.

**Backups:** a daily CronJob in `redis-sentinel` runs the image built from `redis-sentinel/backup/Dockerfile`, which is based on `redis:7.0.15-bookworm` and adds AWS CLI v2. The script in `backup-configmap.yaml` asks Sentinel for the current primary, pulls an RDB with `redis-cli --rdb`, validates it with `redis-check-rdb`, writes `metadata.json` and `SHA256SUMS`, and uploads to `s3://<bucket>/redis-sentinel/<UTC-timestamp>/`. `_SUCCESS` is uploaded last. Restores must skip any prefix that lacks `_SUCCESS`. AOF on the PVCs is not a backup.

**RedisInsight** connects through the same path as the app. It asks Sentinel for the primary and then talks to Redis directly over TLS. Its `RI_ENCRYPTION_KEY` encrypts the saved connection passwords in its SQLite database on a PVC, so the key must be kept with that PVC.

## Gotchas

- Sentinel must return hostnames that match the certificate SANs, not IPs. The `resolveHostnames` and `announceHostnames` settings are what make this work. Do not treat pod ordinal 0 as the primary; it changes after failover.
- Helm does not upgrade CRDs on `helm upgrade`. Check for an existing operator or CRDs before reinstalling, as the Redis runbook warns.
- The Redis PVCs and the Redis CR use `whenDeleted: Retain`. Deleting the cluster does not delete data; clean PVCs up explicitly.
- Images are pinned on purpose (Redis `v7.0.15` from `quay.io/opstree`, ECK 3.5 with Elasticsearch 9.5.5, OT operator 0.27.0). Upgrade them as a deliberate change with a compatibility check, not as a side effect.
- Changing the Redis namespace or resource names creates a new cluster and does not migrate data. Back up first, restore into the new cluster, then switch client endpoints.
