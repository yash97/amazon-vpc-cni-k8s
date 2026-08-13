#!/usr/bin/env bash

# Runs repeated pod scale and Kubernetes NetworkPolicy enforcement checks against
# an existing cluster. The CNI image must already be installed by the caller.

set -euo pipefail

NAMESPACE="cni-scale-test"
TEST_IMAGE_REGISTRY=${TEST_IMAGE_REGISTRY:-"617930562442.dkr.ecr.us-west-2.amazonaws.com"}
NGINX_IMAGE=${NGINX_IMAGE:-"${TEST_IMAGE_REGISTRY}/networking-e2e-test-images/nginx:1.25.2"}
BUSYBOX_IMAGE=${BUSYBOX_IMAGE:-"${TEST_IMAGE_REGISTRY}/networking-e2e-test-images/busybox:latest"}
SCALE_TEST_PODS=${SCALE_TEST_PODS:-20}
SCALE_TEST_POLICIES=${SCALE_TEST_POLICIES:-20}
SCALE_TEST_CYCLES=3
SCALE_TEST_ALLOWED_PROBES=${SCALE_TEST_ALLOWED_PROBES:-3}
SCALE_TEST_DENIED_PROBES=${SCALE_TEST_DENIED_PROBES:-10}
SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS=${SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS:-600}
SCALE_TEST_POLICY_TIMEOUT_SECONDS=${SCALE_TEST_POLICY_TIMEOUT_SECONDS:-120}
SCALE_TEST_PROBE_TIMEOUT_SECONDS=${SCALE_TEST_PROBE_TIMEOUT_SECONDS:-5}
DENIED_PROBE_COUNT_FILE=${DENIED_PROBE_COUNT_FILE:-"/tmp/cni-scale-denied-probe-count"}
NG_LABEL_KEY=${NG_LABEL_KEY:-"kubernetes.io/os"}
NG_LABEL_VAL=${NG_LABEL_VAL:-"linux"}
CLUSTER_NAME=${CLUSTER_NAME:-"not-set"}
IMAGE_TAG=${IMAGE_TAG:-"not-set"}
K8S_VERSION=${K8S_VERSION:-"not-set"}
REGION=${REGION:-${AWS_REGION:-"us-west-2"}}
AWS_REGION=${AWS_REGION:-$REGION}

if [[ -n "${KUBE_CONFIG_PATH:-}" && -z "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG=$KUBE_CONFIG_PATH
fi
KUBECONFIG=${KUBECONFIG:-"${HOME:?HOME must be set}/.kube/config"}
export KUBECONFIG REGION AWS_REGION

KUBECTL=(kubectl --kubeconfig "$KUBECONFIG")
DENIED_PROBE_COUNT=0

validate_positive_integer() {
  local name
  local value
  name=$1
  value=$2
  if [[ ! $value =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer; got '$value'" >&2
    exit 2
  fi
}

write_denied_probe_count() {
  printf '%s\n' "$DENIED_PROBE_COUNT" >"$DENIED_PROBE_COUNT_FILE"
  echo "CNI_SCALE_DENIED_PROBE_COUNT=$DENIED_PROBE_COUNT"
  echo "CNI_SCALE_DENIED_PROBE_COUNT_FILE=$DENIED_PROBE_COUNT_FILE"
}

record_denied_probe() {
  DENIED_PROBE_COUNT=$((DENIED_PROBE_COUNT + 1))
  write_denied_probe_count
}

run_probe() {
  local access
  access=$1
  "${KUBECTL[@]}" exec \
    --namespace "$NAMESPACE" \
    "deployment/scale-${access}-probe" \
    -- wget -q -T "$SCALE_TEST_PROBE_TIMEOUT_SECONDS" -O /dev/null http://scale-target:80/
}

allowed_probe() {
  if ! run_probe allowed; then
    echo "Allowed connectivity probe failed" >&2
    return 1
  fi
}

denied_probe() {
  record_denied_probe
  if run_probe denied; then
    echo "Denied connectivity probe unexpectedly succeeded" >&2
    return 1
  fi
  echo "Denied connectivity probe was blocked as expected"
}

verify_probe_pods_ready() {
  "${KUBECTL[@]}" wait pod \
    --namespace "$NAMESPACE" \
    --selector cni-test-role=probe \
    --for condition=Ready \
    --timeout "${SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS}s"
}

wait_for_policy_enforcement() {
  local deadline
  local attempt=0
  deadline=$((SECONDS + SCALE_TEST_POLICY_TIMEOUT_SECONDS))
  verify_probe_pods_ready

  while (( SECONDS < deadline )); do
    attempt=$((attempt + 1))
    if allowed_probe && denied_probe; then
      echo "NetworkPolicy enforcement converged on attempt $attempt"
      return 0
    fi
    sleep 5
  done

  echo "NetworkPolicy enforcement did not converge within ${SCALE_TEST_POLICY_TIMEOUT_SECONDS}s" >&2
  return 1
}

wait_for_zero_target_pods() {
  local deadline
  local pods
  deadline=$((SECONDS + SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    pods=$("${KUBECTL[@]}" get pods --namespace "$NAMESPACE" \
      --selector app=cni-scale-target --output name)
    if [[ -z $pods ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Target pods did not scale to zero within ${SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS}s" >&2
  return 1
}

verify_target_ready() {
  local ready
  "${KUBECTL[@]}" rollout status deployment/scale-target \
    --namespace "$NAMESPACE" \
    --timeout "${SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS}s"
  "${KUBECTL[@]}" wait pod \
    --namespace "$NAMESPACE" \
    --selector app=cni-scale-target \
    --for condition=Ready \
    --timeout "${SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS}s"
  ready=$("${KUBECTL[@]}" get deployment scale-target \
    --namespace "$NAMESPACE" \
    --output jsonpath='{.status.readyReplicas}')
  if [[ $ready != "$SCALE_TEST_PODS" ]]; then
    echo "Expected $SCALE_TEST_PODS Ready target pods, found ${ready:-0}" >&2
    return 1
  fi
}

apply_policies() {
  local index
  for ((index = 1; index <= SCALE_TEST_POLICIES; index++)); do
    "${KUBECTL[@]}" apply --filename - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: scale-allow-${index}
  namespace: ${NAMESPACE}
  labels:
    cni-test-suite: scale
spec:
  podSelector:
    matchLabels:
      app: cni-scale-target
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              cni-test-access: allowed
      ports:
        - protocol: TCP
          port: 80
EOF
  done
}

print_failure_diagnostics() {
  local status
  status=$1
  if (( status == 0 )); then
    return
  fi
  echo "Scale test failed; preserving namespace $NAMESPACE for diagnostics" >&2
  "${KUBECTL[@]}" get all,networkpolicy --namespace "$NAMESPACE" --output wide || true
  "${KUBECTL[@]}" get events --namespace "$NAMESPACE" --sort-by=.lastTimestamp || true
  write_denied_probe_count
}

for value_name in \
  SCALE_TEST_PODS \
  SCALE_TEST_POLICIES \
  SCALE_TEST_CYCLES \
  SCALE_TEST_ALLOWED_PROBES \
  SCALE_TEST_DENIED_PROBES \
  SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS \
  SCALE_TEST_POLICY_TIMEOUT_SECONDS \
  SCALE_TEST_PROBE_TIMEOUT_SECONDS; do
  validate_positive_integer "$value_name" "${!value_name}"
done

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required" >&2
  exit 127
}

printf 'Running CNI scale tests: cluster=%s region=%s k8s=%s image-tag=%s\n' \
  "$CLUSTER_NAME" "$REGION" "$K8S_VERSION" "$IMAGE_TAG"
echo "Using kubeconfig: $KUBECONFIG"
echo "Workload images: $NGINX_IMAGE and $BUSYBOX_IMAGE"
echo "Denied-probe count file: $DENIED_PROBE_COUNT_FILE"
write_denied_probe_count

"${KUBECTL[@]}" version --client
"${KUBECTL[@]}" cluster-info

if "${KUBECTL[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Removing leftover namespace $NAMESPACE"
  "${KUBECTL[@]}" delete namespace "$NAMESPACE" \
    --wait=true \
    --timeout "${SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS}s"
fi
"${KUBECTL[@]}" create namespace "$NAMESPACE"
trap 'print_failure_diagnostics "$?"' EXIT

TARGET_NODE=${SCALE_TEST_NODE:-$("${KUBECTL[@]}" get nodes \
  --field-selector spec.unschedulable!=true \
  --selector "${NG_LABEL_KEY}=${NG_LABEL_VAL}" \
  --output jsonpath='{.items[0].metadata.name}')}
if [[ -z $TARGET_NODE ]]; then
  echo "No node matched ${NG_LABEL_KEY}=${NG_LABEL_VAL}" >&2
  exit 1
fi
"${KUBECTL[@]}" wait "node/$TARGET_NODE" \
  --for condition=Ready \
  --timeout "${SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS}s"
echo "Pinning $SCALE_TEST_PODS target pods to node $TARGET_NODE to exercise secondary ENIs"

"${KUBECTL[@]}" apply --filename - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scale-target
  namespace: ${NAMESPACE}
spec:
  replicas: 0
  selector:
    matchLabels:
      app: cni-scale-target
  template:
    metadata:
      labels:
        app: cni-scale-target
    spec:
      nodeName: ${TARGET_NODE}
      containers:
        - name: nginx
          image: ${NGINX_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 2
            timeoutSeconds: 2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scale-allowed-probe
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cni-scale-allowed-probe
  template:
    metadata:
      labels:
        app: cni-scale-allowed-probe
        cni-test-access: allowed
        cni-test-role: probe
    spec:
      containers:
        - name: busybox
          image: ${BUSYBOX_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["sleep", "604800"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scale-denied-probe
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cni-scale-denied-probe
  template:
    metadata:
      labels:
        app: cni-scale-denied-probe
        cni-test-access: denied
        cni-test-role: probe
    spec:
      containers:
        - name: busybox
          image: ${BUSYBOX_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["sleep", "604800"]
---
apiVersion: v1
kind: Service
metadata:
  name: scale-target
  namespace: ${NAMESPACE}
spec:
  selector:
    app: cni-scale-target
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

verify_probe_pods_ready

for ((cycle = 1; cycle <= SCALE_TEST_CYCLES; cycle++)); do
  echo "=== Scale cycle $cycle/$SCALE_TEST_CYCLES: 0 -> $SCALE_TEST_PODS -> 0 ==="
  "${KUBECTL[@]}" scale deployment/scale-target \
    --namespace "$NAMESPACE" \
    --replicas "$SCALE_TEST_PODS"
  verify_target_ready

  apply_policies
  wait_for_policy_enforcement

  for ((probe = 1; probe <= SCALE_TEST_ALLOWED_PROBES; probe++)); do
    allowed_probe
  done
  for ((probe = 1; probe <= SCALE_TEST_DENIED_PROBES; probe++)); do
    denied_probe
  done

  "${KUBECTL[@]}" delete networkpolicy \
    --namespace "$NAMESPACE" \
    --selector cni-test-suite=scale \
    --wait=true
  "${KUBECTL[@]}" scale deployment/scale-target \
    --namespace "$NAMESPACE" \
    --replicas 0
  wait_for_zero_target_pods
done

write_denied_probe_count
echo "CNI scale tests completed successfully in $SECONDS seconds"
"${KUBECTL[@]}" delete namespace "$NAMESPACE" \
  --wait=true \
  --timeout "${SCALE_TEST_CONVERGENCE_TIMEOUT_SECONDS}s"
trap - EXIT
