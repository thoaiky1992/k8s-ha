# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a highly available stack on AWS EKS: Terraform for AWS and cluster add-ons, Kubernetes manifests (some via operators) for Elasticsearch, Redis Cluster, Kibana and RedisInsight, and one small Node.js app that consumes Elasticsearch and Redis Cluster over TLS. There is no build, lint, or test system. Validation is `terraform plan`, `kubectl` dry-runs, and the `redis-cluster/check-cluster.sh` preflight script.

The runbooks (`*/README.md`, `elasticsearch/ELASTICSEARCH.md`, `kibana/KIBANA.md`) are written in Vietnamese and are the source of truth for install order and verification commands. Keep new docs in Vietnamese to match.

## Commands

Terraform runs per layer, always with a layer-specific var file. Init uses the backend config copied from `backend.tfvars.example`:

```bash
terraform -chdir=terraform/00-networking init -backend-config=backend.tfvars
terraform -chdir=terraform/00-networking plan -var-file=terraform.tfvars
terraform -chdir=terraform/00-networking apply -var-file=terraform.tfvars
```

Repeat for `terraform/01.kubernetes` and `terraform/02.dns-records`. Apply in that order: `01.kubernetes` reads the networking layer's state from S3 through `terraform_remote_state`.

Kubernetes manifests are applied with an explicit context so writes never land on the wrong cluster:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
kubectl --context "$KUBE_CONTEXT" apply -f <file>
```

Preflight check for the Redis Cluster (needs `kubectl` and `jq`):

```bash
KUBE_CONTEXT=<context> bash redis-cluster/check-cluster.sh
```

`redis-cluster/cleanup-ebs-restore.sh` is destructive. It only prints a plan unless `--execute` is passed, and it needs `--snapshot-map`, `--replacement-map`, `--context`, `--region`, `--account-id`, and at least one of `--old-volumes` or `--snapshots`. Run it only after a restore has been verified.

Application (run from `app/`). There is no test script in `package.json`, so there is no single-test command:

```bash
npm install
npm start          # node server.js; requires the env vars listed in server.js
docker build -t <registry>/node-api:<tag> app
```

## Secrets and files that must stay out of git

Each `*.example` file is a template. Copy it to the real name, fill it in, and never commit the copy. Ignored locally: `*.tfvars` (root `.gitignore`), `secret.yaml` in `redis-cluster/` and `redisinsight/`, `app/credentials.env`, `*.crt`, `*.key`. Check `git status` before committing anything under `redisinsight/` or `redis-cluster/`.

Do not disable TLS verification (`rejectUnauthorized: false`, `--insecure`, skipping the CA) to make a connection work. Fix the CA or the hostname instead.

## Architecture: how the pieces connect

**Terraform layers (state in S3):**
- `00-networking`: VPC, subnets, NAT, route tables. Publishes subnet IDs as outputs.
- `01.kubernetes`: EKS cluster (API auth mode, public endpoint only), node groups, and add-ons: metrics-server, cluster-autoscaler, AWS Load Balancer Controller, EBS CSI driver, cert-manager, EKS Pod Identity. It also provisions the S3 buckets and IAM roles for Elasticsearch snapshots (`13.elasticsearch-backup.tf`) and Redis Cluster backups (`14.redis-cluster-backup.tf`), with Pod Identity associations to their ServiceAccounts.
- `02.dns-records`: Route 53 records (Kibana, RedisInsight).

**Data plane (Kubernetes, EBS gp3 PVCs, spread across AZs):**
- Elasticsearch is managed by the ECK operator, installed with Helm per `elasticsearch/ELASTICSEARCH.md`. The `search` cluster has 6 nodes, 2 per AZ, with 6 master-eligible nodes. ECK issues and rotates the HTTP and transport TLS certificates and creates the `search-es-http-certs-public` Secret that holds the CA.
- Redis Cluster is managed by the OT Redis Operator 0.27.0, installed with Helm as release `redis-cluster-operator` in namespace `redis-cluster-system`. It watches only `redis-cluster`. Helm installs the CRDs, so do not pass `--skip-crds`. The cluster runs 3 leaders and 3 followers, and each leader has one follower in a different AZ. Client, replication, and cluster bus traffic all use TLS. Nodes run `thoaiky1992/redis-cluster:7.0.15-fqdn.1`, built from `redis-cluster/images/redis-cluster/` on top of `quay.io/opstree/redis:v7.0.15`. The only change is an entrypoint that announces the node's FQDN instead of the short Pod name.
- cert-manager provides the Redis Cluster CA. `certificate.yaml` creates a self-signed root, then the `redis-cluster-ca` CA and the `redis-cluster-tls` server certificate (`ca.crt`, `tls.crt`, `tls.key`). The DNS SANs must match the leader/follower Service and headless Service names. If the cluster uses a DNS suffix other than `cluster.local`, update `dnsNames`.
- Namespaces: `elasticsearch` / `elastic-system` (ECK), `redis-cluster` / `redis-cluster-system` (Redis Cluster and its operator), `redisinsight`, `app` (the Node service), `kibana`.

**Cross-namespace trust is manual.** Pods cannot mount Secrets from other namespaces. The `app` namespace therefore receives copies of the public CA certificates only (`ca.crt` from ECK and from `redis-cluster-tls`), stored in ConfigMap `backend-ca`. RedisInsight receives a copy of `ca.crt` from `redis-cluster-tls` in ConfigMap `redis-cluster-ca`. Never copy `tls.key`. Changing a CA or password means updating the Secret or ConfigMap and restarting the Deployment, because the app reads them only at startup.

**Application (`app/server.js`):** a single-file Node HTTP server using `@elastic/elasticsearch` v9 and the `Cluster` client from `ioredis`. Each backend is enabled by a flag variable and must have its `required` variables set, or the process refuses to start. `ELASTICSEARCH_URL` must use `https://`. Redis Cluster is reached through the root node (`REDIS_CLUSTER_HOST`/`PORT`), and the client reads the topology and routes by slot (MOVED/ASK). Logs are one JSON object per line with a `trace_id`.

**Backups:** a daily CronJob in `redis-cluster` (`backup-cronjob.yaml`) runs image `thoaiky1992/redis-cluster-backup:1.0.0`, built from `redis-cluster/images/redis-cluster-backup/`. The script in `backup-configmap.yaml` reads the current topology, pulls an RDB from each master with `redis-cli --rdb`, validates it with `redis-check-rdb`, writes `metadata.json`, `cluster-nodes.txt` and `SHA256SUMS`, and uploads to `s3://<bucket>/redis-cluster/<UTC-timestamp>/`. `_SUCCESS` is uploaded last, so restores must skip any prefix without it. AOF on the PVCs is not a backup. The restore procedure in `redis-cluster/README.md` replays the RDBs into the target cluster with `RESTORE ... REPLACE` through `dump_to_resp.py` in the restore image.

**RedisInsight** (namespace `redisinsight`) connects to Redis Cluster over TLS through the seed `redis-cluster-leader.redis-cluster.svc.cluster.local:6379` and follows the topology. Its `RI_ENCRYPTION_KEY` encrypts the saved connection passwords in the SQLite database on its PVC, so the key must be kept with that PVC.

## Gotchas

- Redis Cluster nodes must be reached by FQDN, not IP or short Pod name. The upstream entrypoint hardcodes `cluster-announce-hostname` to the short Pod name and appends it after the ConfigMap config, so the custom image is required. `cluster-preferred-endpoint-type hostname` makes `MOVED` and `CLUSTER SLOTS` return FQDNs, which match the certificate SANs via the headless-Service wildcard. Do not treat pod ordinal 0 as a leader; roles change after failover.
- Helm does not upgrade CRDs on `helm upgrade`. Check for an existing operator or CRDs before reinstalling, as the Redis runbook warns.
- Redis data survives cluster deletion: the `redis-cluster-gp3` StorageClass uses `reclaimPolicy: Retain` and the CR sets `keepAfterDelete: true`. Clean up PVCs and EBS volumes explicitly.
- Images are pinned on purpose (Redis base `v7.0.15`, ECK 3.5 with Elasticsearch 9.5.5, OT operator 0.27.0). Rebuild and push the node image whenever its base changes, and keep the tag in `redis-cluster.yaml` in sync with what was pushed. Upgrade versions as a deliberate change with a compatibility check.
- Changing the Redis Cluster namespace or resource names creates a new cluster and does not migrate data. Back up first, restore into the new cluster, then switch client endpoints.
- A Redis EBS snapshot must cover all 12 PVCs (`/data` and `/node-conf` for each of the 6 Pods). The `/data` volumes alone do not preserve cluster membership. Snapshots taken across several EC2 nodes are not atomic, so the runbook pauses the operator and Pods first.
