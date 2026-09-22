#!/usr/bin/env bash

# Proves that ClusterLoader2 can scrape and fail closed on per-node CNI or NPA
# metrics before those assertions are added to the scale workload itself.

set -euo pipefail

CL2_BIN=${CL2_BIN:-clusterloader2}
DATAPLANE_COMPONENT=${DATAPLANE_COMPONENT:-ipamd}
EXPECTED_LINUX_NODES=${EXPECTED_LINUX_NODES:-1}
CL2_POC_BASELINE_SETTLE=${CL2_POC_BASELINE_SETTLE:-45s}
CL2_POC_SCRAPE_SETTLE=${CL2_POC_SCRAPE_SETTLE:-90s}
CL2_POC_KEEP_PROMETHEUS=${CL2_POC_KEEP_PROMETHEUS:-false}
CL2_POC_DRY_RUN=${CL2_POC_DRY_RUN:-false}
CL2_POC_PROMETHEUS_MEMORY_GIB=${CL2_POC_PROMETHEUS_MEMORY_GIB:-4}

if [[ ! $EXPECTED_LINUX_NODES =~ ^[1-9][0-9]*$ ]]; then
  printf 'EXPECTED_LINUX_NODES must be a positive integer; got %q\n' \
    "$EXPECTED_LINUX_NODES" >&2
  exit 2
fi
if [[ ! $CL2_POC_PROMETHEUS_MEMORY_GIB =~ ^[1-9][0-9]*$ ]]; then
  printf 'CL2_POC_PROMETHEUS_MEMORY_GIB must be a positive integer; got %q\n' \
    "$CL2_POC_PROMETHEUS_MEMORY_GIB" >&2
  exit 2
fi
case "$DATAPLANE_COMPONENT" in
  ipamd | npa) ;;
  *)
    printf 'DATAPLANE_COMPONENT must be ipamd or npa; got %q\n' \
      "$DATAPLANE_COMPONENT" >&2
    exit 2
    ;;
esac
for variable in CL2_POC_KEEP_PROMETHEUS CL2_POC_DRY_RUN; do
  value=${!variable}
  if [[ $value != true && $value != false ]]; then
    printf '%s must be true or false; got %q\n' "$variable" "$value" >&2
    exit 2
  fi
done
for command in "$CL2_BIN"; do
  command -v "$command" >/dev/null 2>&1 || {
    printf '%s is required\n' "$command" >&2
    exit 127
  }
done
cl2_help=$("$CL2_BIN" --help 2>&1 || true)
if ! grep -q -- '--prometheus-additional-monitors-path' <<<"$cl2_help"; then
  printf '%s is too old: the POC requires --prometheus-additional-monitors-path\n' \
    "$CL2_BIN" >&2
  printf 'Refresh EKSDataPlaneClusterloader2 before enabling this path in Hydra.\n' >&2
  exit 2
fi

if [[ $CL2_POC_DRY_RUN == false ]]; then
  command -v kubectl >/dev/null 2>&1 || {
    printf 'kubectl is required for a live run\n' >&2
    exit 127
  }
  if [[ -n ${KUBE_CONFIG_PATH:-} && -z ${KUBECONFIG:-} ]]; then
    export KUBECONFIG=$KUBE_CONFIG_PATH
  fi
  KUBECONFIG=${KUBECONFIG:-"${HOME:?HOME must be set}/.kube/config"}
  export KUBECONFIG
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
poc_dir="${script_dir}/scale/cl2-metrics-poc"
safe_cluster_name=${CLUSTER_NAME:-local}
safe_cluster_name=${safe_cluster_name//[^a-zA-Z0-9_.-]/-}
report_dir=${CL2_POC_REPORT_DIR:-"log/cl2-metrics-poc-${DATAPLANE_COMPONENT}-${safe_cluster_name}"}

mkdir -p "$report_dir"
export CL2_DATAPLANE_COMPONENT=$DATAPLANE_COMPONENT
export CL2_EXPECTED_LINUX_NODES=$EXPECTED_LINUX_NODES
export CL2_POC_BASELINE_SETTLE
export CL2_POC_SCRAPE_SETTLE
# Avoid requiring a cluster-specific StorageClass for this short smoke run.
export CL2_PROMETHEUS_PVC_ENABLED=false
# ClusterLoader2 still creates its fixed-name "ssd" class when PVCs are
# disabled. Keep that class valid for EKS; production Hydra deletes the whole
# test cluster after the run.
export PROMETHEUS_STORAGE_CLASS_PROVISIONER=ebs.csi.aws.com
export PROMETHEUS_STORAGE_CLASS_VOLUME_TYPE=gp3
# Current ClusterLoader2 requests 10 GiB whenever kubelet scraping is enabled.
# The POC filters kubelet resource metrics to two containers on a small cluster,
# so use a bounded request that also fits common developer-cluster nodes.
export CL2_PROMETHEUS_KUBELET_MEMORY_SCALE_FACTOR=$CL2_POC_PROMETHEUS_MEMORY_GIB

tear_down_prometheus=true
if [[ $CL2_POC_KEEP_PROMETHEUS == true ]]; then
  tear_down_prometheus=false
fi

cl2_args=(
  -v=2
  "--testconfig=${poc_dir}/config.yaml"
  --provider=eks
  "--nodes=${EXPECTED_LINUX_NODES}"
  --enable-exec-service=false
  --enable-prometheus-server=true
  "--tear-down-prometheus-server=${tear_down_prometheus}"
  --prometheus-scrape-kube-proxy=false
  --prometheus-scrape-kubelets=true
  "--prometheus-additional-monitors-path=${poc_dir}/monitors"
  "--report-dir=${report_dir}"
)
generated_config="${report_dir}/generatedConfig_dataplane-metric-assertions-poc.yaml"
if [[ $CL2_POC_DRY_RUN == true ]]; then
  cl2_args+=(--dry-run=true)
  cl2_args+=(--skip-cluster-verification=true)
  cl2_args+=("--kubeconfig=${poc_dir}/kubeconfig.dry-run.yaml")
else
  cl2_args+=("--kubeconfig=${KUBECONFIG}")
fi

if [[ $CL2_POC_DRY_RUN == true ]]; then
  rm -f -- "$generated_config"
  set +e
  "$CL2_BIN" "${cl2_args[@]}"
  cl2_status=$?
  set -e
  if [[ ! -s $generated_config ]]; then
    printf 'ClusterLoader2 dry run did not produce %s (status %s)\n' \
      "$generated_config" "$cl2_status" >&2
    exit 1
  fi
  grep -Fq "metricName: ${DATAPLANE_COMPONENT} per-node metric coverage" \
    "$generated_config"
  grep -Fq -- "- ${EXPECTED_LINUX_NODES})" "$generated_config"
  printf 'ClusterLoader2 compiled the %s profile for %s nodes: %s\n' \
    "$DATAPLANE_COMPONENT" "$EXPECTED_LINUX_NODES" "$generated_config"
  exit 0
fi

"$CL2_BIN" "${cl2_args[@]}"

printf 'ClusterLoader2 %s metric assertion POC passed; reports: %s\n' \
  "$DATAPLANE_COMPONENT" "$report_dir"
