# ClusterLoader2 dataplane assertion POC

Status: archived standalone POC. The production CNI path now owns its CL2
profile in the Hydra delivery branch; this directory remains only for
experimentation and requirement traceability.

This POC verifies that current ClusterLoader2 can be the only scale-test
assertion engine for CNI and NPA.

It proves:

1. Prometheus discovers IPAMD, NPA, kubelet WSS, and host-only evidence on
   every expected Linux node.
2. `GenericPrometheusQuery` produces per-node threshold verdicts.
3. Missing targets, metric families, baseline samples, or adapter data fail
   closed.
4. PromQL compares recovery WSS and exact NPA BPF identity sets with a
   pre-test baseline.

See `assertion-coverage.md` for the full requirement map and the recommended
production phase sequence.

## Historical prerequisite

At the time of this POC, the packaged internal ClusterLoader2 binary was from
October 2022 and lacked `--prometheus-additional-monitors-path` and current
fail-closed query support. The delivery implementation uses the refreshed,
pinned package instead of this standalone wrapper.

## Compile without a cluster

```bash
CL2_POC_DRY_RUN=true \
DATAPLANE_COMPONENT=npa \
EXPECTED_LINUX_NODES=7 \
CL2_BIN=/path/to/current/clusterloader2 \
scripts/run-dataplane-metrics-cl2-poc.sh
```

## Run against an EKS cluster

CNI:

```bash
DATAPLANE_COMPONENT=ipamd \
EXPECTED_LINUX_NODES=7 \
CL2_BIN=/path/to/current/clusterloader2 \
KUBECONFIG=/path/to/kubeconfig \
scripts/run-dataplane-metrics-cl2-poc.sh
```

NPA:

```bash
DATAPLANE_COMPONENT=npa \
EXPECTED_LINUX_NODES=7 \
CL2_BIN=/path/to/current/clusterloader2 \
KUBECONFIG=/path/to/kubeconfig \
scripts/run-dataplane-metrics-cl2-poc.sh
```

Set `CL2_POC_KEEP_PROMETHEUS=true` to retain Prometheus and Grafana for manual
queries. The default removes the namespaced monitoring stack after the run.

Current upstream ClusterLoader2 leaves its cluster-scoped Prometheus CRDs,
RBAC, discovery services, service account, and fixed-name `ssd` StorageClass
behind. Hydra deletes the whole test cluster, so this does not affect the
pipeline design. Use a disposable cluster for manual POC runs until the
ClusterLoader2 package adds symmetric cleanup; do not run this wrapper on a
shared cluster that already has an `ssd` StorageClass.

For a deliberate fail-closed test, set `EXPECTED_LINUX_NODES` one higher than
the actual Linux node count. ClusterLoader2 must return a failed verdict.

The CNI profile also requires the node-local containerd metrics endpoint. A
cluster without that setup must fail the containerd adapter and metric-family
cardinality checks.

## Test PromQL without a cluster

```bash
docker run --rm \
  --entrypoint=promtool \
  --volume "$PWD/scripts/scale/cl2-metrics-poc:/poc:ro" \
  prom/prometheus:v2.40.0 \
  test rules /poc/promql.test.yaml
```

The suite covers:

- exact and missing node cardinality;
- per-node restart and WSS recovery checks;
- a deliberate WSS leak;
- a stale node-evidence adapter;
- lazy error counters whose first observed value is non-zero; and
- exact BPF set comparison, including an equal-cardinality identity swap.

## POC-only node evidence adapter

`monitors/node-evidence-adapter.yaml` republishes two host-only sources:

- selected containerd CRI metrics from `127.0.0.1:1338/v1/metrics`; and
- hashed NPA program and map identities from the read-only bpffs mount.

It also publishes a refresh timestamp. The ClusterLoader2 profile fails if an
expected node is absent or its adapter data is more than 45 seconds old.

For production, merge this endpoint into the existing CommonGo
`dp-prom-scraper` DaemonSet instead of installing a second DaemonSet.
