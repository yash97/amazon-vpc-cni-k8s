#!/usr/bin/env bash

# Runs pod, IP-allocation, and Kubernetes NetworkPolicy churn against an
# existing cluster. The CNI image must already be installed by the caller.

set -euo pipefail

NAMESPACE="cni-soak-test"
TEST_IMAGE_REGISTRY=${TEST_IMAGE_REGISTRY:-"617930562442.dkr.ecr.us-west-2.amazonaws.com"}
NGINX_IMAGE=${NGINX_IMAGE:-"${TEST_IMAGE_REGISTRY}/networking-e2e-test-images/nginx:1.25.2"}
BUSYBOX_IMAGE=${BUSYBOX_IMAGE:-"${TEST_IMAGE_REGISTRY}/networking-e2e-test-images/busybox:latest"}
SOAK_DURATION_MINUTES=${SOAK_DURATION_MINUTES:-120}
SOAK_BASE_PODS=${SOAK_BASE_PODS:-6}
SOAK_CHURN_PODS=${SOAK_CHURN_PODS:-1}
SOAK_CHURN_INTERVAL_SECONDS=${SOAK_CHURN_INTERVAL_SECONDS:-300}
SOAK_HEALTH_INTERVAL_SECONDS=${SOAK_HEALTH_INTERVAL_SECONDS:-60}
SOAK_CONVERGENCE_TIMEOUT_SECONDS=${SOAK_CONVERGENCE_TIMEOUT_SECONDS:-600}
SOAK_POLICY_TIMEOUT_SECONDS=${SOAK_POLICY_TIMEOUT_SECONDS:-120}
SOAK_PROBE_TIMEOUT_SECONDS=${SOAK_PROBE_TIMEOUT_SECONDS:-5}
SOAK_DENIED_PROBES=${SOAK_DENIED_PROBES:-5}
SOAK_IP_PRESSURE_PODS=${SOAK_IP_PRESSURE_PODS:-30}
SOAK_IP_PRESSURE_EVERY_CYCLES=${SOAK_IP_PRESSURE_EVERY_CYCLES:-2}
METRIC_ASSERT_INPUTS_FILE=${METRIC_ASSERT_INPUTS_FILE:-metric-assert-inputs.json}
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
POLICY_ENABLED=false
IP_PRESSURE_ENABLED=false
NAMESPACE_CREATED=false
RUN_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RUN_END=$RUN_START
CURRENT_PHASE=""
CURRENT_PHASE_START=""
DENIED_PROBE_COUNT=0
PRESSURE_SCALE_UPS=0
ALLOWED_WINDOW_STARTS=()
ALLOWED_WINDOW_ENDS=()
DENY_WINDOW_STARTS=()
DENY_WINDOW_ENDS=()

validate_positive_integer() {
  local name=$1
  local value=$2
  if [[ ! $value =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer; got '$value'" >&2
    exit 2
  fi
}

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

render_windows() {
  local phase=$1
  local index
  local count
  local start
  local end
  local separator=""
  printf '['
  if [[ $phase == allowed ]]; then
    count=${#ALLOWED_WINDOW_STARTS[@]}
    for ((index = 0; index < count; index++)); do
      start=${ALLOWED_WINDOW_STARTS[$index]}
      end=${ALLOWED_WINDOW_ENDS[$index]}
      printf '%s{"start":"%s","end":"%s"}' "$separator" "$start" "$end"
      separator=','
    done
  else
    count=${#DENY_WINDOW_STARTS[@]}
    for ((index = 0; index < count; index++)); do
      start=${DENY_WINDOW_STARTS[$index]}
      end=${DENY_WINDOW_ENDS[$index]}
      printf '%s{"start":"%s","end":"%s"}' "$separator" "$start" "$end"
      separator=','
    done
  fi
  printf ']'
}

write_metric_inputs() {
  local directory
  local temporary
  local allowed_windows
  local deny_windows
  RUN_END=$(timestamp)
  directory=$(dirname "$METRIC_ASSERT_INPUTS_FILE")
  mkdir -p "$directory"
  temporary="${METRIC_ASSERT_INPUTS_FILE}.tmp.$$"
  allowed_windows=$(render_windows allowed)
  deny_windows=$(render_windows deny)
  cat >"$temporary" <<EOF
{
  "kind": "soak",
  "clusterName": "$(json_escape "$CLUSTER_NAME")",
  "run": {"start": "$RUN_START", "end": "$RUN_END"},
  "allowedOnlyWindows": $allowed_windows,
  "denyWindows": $deny_windows,
  "deniedProbeCount": $DENIED_PROBE_COUNT,
  "churnAmplitude": $SOAK_CHURN_PODS,
  "basePodCount": $SOAK_BASE_PODS,
  "ipPressurePodCount": $SOAK_IP_PRESSURE_PODS
}
EOF
  mv "$temporary" "$METRIC_ASSERT_INPUTS_FILE"
}

close_current_phase() {
  local end
  if [[ -z $CURRENT_PHASE || -z $CURRENT_PHASE_START ]]; then
    return
  fi
  end=$(timestamp)
  if [[ $end == "$CURRENT_PHASE_START" ]]; then
    sleep 1
    end=$(timestamp)
  fi
  if [[ $CURRENT_PHASE == allowed ]]; then
    ALLOWED_WINDOW_STARTS+=("$CURRENT_PHASE_START")
    ALLOWED_WINDOW_ENDS+=("$end")
  else
    DENY_WINDOW_STARTS+=("$CURRENT_PHASE_START")
    DENY_WINDOW_ENDS+=("$end")
  fi
  CURRENT_PHASE=""
  CURRENT_PHASE_START=""
}

start_phase() {
  CURRENT_PHASE=$1
  CURRENT_PHASE_START=$(timestamp)
}

print_failure_diagnostics() {
  local status=$1
  if (( status == 0 )) || [[ $NAMESPACE_CREATED != true ]]; then
    return
  fi
  echo "Soak test failed; preserving namespace $NAMESPACE for diagnostics" >&2
  "${KUBECTL[@]}" get all,networkpolicy --namespace "$NAMESPACE" --output wide || true
  "${KUBECTL[@]}" get events --namespace "$NAMESPACE" --sort-by=.lastTimestamp || true
}

finish() {
  local status=$1
  trap - EXIT
  close_current_phase || true
  RUN_END=$(timestamp)
  if [[ $RUN_END == "$RUN_START" ]]; then
    sleep 1
  fi
  write_metric_inputs || echo "Failed to write $METRIC_ASSERT_INPUTS_FILE" >&2
  print_failure_diagnostics "$status"
  exit "$status"
}
trap 'finish "$?"' EXIT

run_probe() {
  local access=$1
  "${KUBECTL[@]}" exec \
    --namespace "$NAMESPACE" \
    "deployment/soak-${access}-probe" \
    -- wget -q -T "$SOAK_PROBE_TIMEOUT_SECONDS" -O /dev/null http://soak-target:80/
}

verify_probe_pods_ready() {
  "${KUBECTL[@]}" wait pod \
    --namespace "$NAMESPACE" \
    --selector cni-test-role=probe \
    --for condition=Ready \
    --timeout "${SOAK_CONVERGENCE_TIMEOUT_SECONDS}s"
}

verify_ready() {
  local ready
  "${KUBECTL[@]}" rollout status deployment/soak-target \
    --namespace "$NAMESPACE" \
    --timeout "${SOAK_CONVERGENCE_TIMEOUT_SECONDS}s"
  "${KUBECTL[@]}" wait pod \
    --namespace "$NAMESPACE" \
    --selector app=cni-soak-target \
    --for condition=Ready \
    --timeout "${SOAK_CONVERGENCE_TIMEOUT_SECONDS}s"
  ready=$("${KUBECTL[@]}" get deployment soak-target \
    --namespace "$NAMESPACE" \
    --output jsonpath='{.status.readyReplicas}')
  if [[ ${ready:-0} != "$SOAK_BASE_PODS" ]]; then
    echo "Expected $SOAK_BASE_PODS Ready base pods, found ${ready:-0}" >&2
    return 1
  fi
}

verify_ip_pressure() {
  local ready
  "${KUBECTL[@]}" rollout status deployment/soak-ip-pressure \
    --namespace "$NAMESPACE" \
    --timeout "${SOAK_CONVERGENCE_TIMEOUT_SECONDS}s"
  ready=$("${KUBECTL[@]}" get deployment soak-ip-pressure \
    --namespace "$NAMESPACE" \
    --output jsonpath='{.status.readyReplicas}')
  if [[ $IP_PRESSURE_ENABLED == true && ${ready:-0} != "$SOAK_IP_PRESSURE_PODS" ]]; then
    echo "Expected $SOAK_IP_PRESSURE_PODS Ready IP-pressure pods, found ${ready:-0}" >&2
    return 1
  fi
  if [[ $IP_PRESSURE_ENABLED == false && ${ready:-0} != 0 ]]; then
    echo "Expected no Ready IP-pressure pods, found ${ready:-0}" >&2
    return 1
  fi
}

connectivity_matches_policy() {
  verify_probe_pods_ready
  if ! run_probe allowed; then
    echo "Allowed connectivity probe failed" >&2
    return 1
  fi
  if [[ $POLICY_ENABLED == true ]]; then
    if run_probe denied; then
      echo "Denied connectivity probe unexpectedly succeeded" >&2
      return 1
    fi
    echo "Denied connectivity probe was blocked as expected"
  elif ! run_probe denied; then
    echo "Connectivity did not recover after NetworkPolicy removal" >&2
    return 1
  fi
}

health_check() {
  echo "Running soak health check at ${SECONDS}s (policy-enabled=$POLICY_ENABLED, ip-pressure=$IP_PRESSURE_ENABLED)"
  verify_ready
  verify_ip_pressure
  connectivity_matches_policy
}

wait_for_policy_state() {
  local deadline=$((SECONDS + SOAK_POLICY_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if connectivity_matches_policy; then
      echo "NetworkPolicy state converged (enabled=$POLICY_ENABLED)"
      return 0
    fi
    sleep 5
  done
  echo "NetworkPolicy state did not converge within ${SOAK_POLICY_TIMEOUT_SECONDS}s" >&2
  return 1
}

apply_policy() {
  "${KUBECTL[@]}" apply --filename - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: soak-allow
  namespace: ${NAMESPACE}
  labels:
    cni-test-suite: soak
spec:
  podSelector:
    matchLabels:
      app: cni-soak-target
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
  POLICY_ENABLED=true
  wait_for_policy_state
}

remove_policy() {
  "${KUBECTL[@]}" delete networkpolicy soak-allow \
    --namespace "$NAMESPACE" \
    --ignore-not-found \
    --wait=true
  POLICY_ENABLED=false
  wait_for_policy_state
}

run_denied_probes() {
  local attempt
  for ((attempt = 1; attempt <= SOAK_DENIED_PROBES; attempt++)); do
    DENIED_PROBE_COUNT=$((DENIED_PROBE_COUNT + 1))
    if run_probe denied; then
      echo "Denied probe attempt $attempt unexpectedly succeeded" >&2
      return 1
    fi
  done
  echo "$SOAK_DENIED_PROBES denied probe attempts were blocked"
  write_metric_inputs
}

restart_base_pods() {
  local pod
  local pods=()
  while IFS= read -r pod; do
    [[ -n $pod ]] && pods+=("$pod")
  done < <("${KUBECTL[@]}" get pods \
    --namespace "$NAMESPACE" \
    --selector app=cni-soak-target \
    --output jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -n "$SOAK_CHURN_PODS")
  if (( ${#pods[@]} != SOAK_CHURN_PODS )); then
    echo "Expected $SOAK_CHURN_PODS base pods to restart, found ${#pods[@]}" >&2
    return 1
  fi
  echo "Restarting ${#pods[@]} base pods: ${pods[*]}"
  "${KUBECTL[@]}" delete pod "${pods[@]}" --namespace "$NAMESPACE" --wait=false
  for pod in "${pods[@]}"; do
    "${KUBECTL[@]}" wait "pod/$pod" \
      --namespace "$NAMESPACE" \
      --for delete \
      --timeout "${SOAK_CONVERGENCE_TIMEOUT_SECONDS}s"
  done
  verify_ready
}

cycle_ip_pressure() {
  local replicas
  if [[ $IP_PRESSURE_ENABLED == true ]]; then
    replicas=0
    IP_PRESSURE_ENABLED=false
  else
    replicas=$SOAK_IP_PRESSURE_PODS
    IP_PRESSURE_ENABLED=true
    PRESSURE_SCALE_UPS=$((PRESSURE_SCALE_UPS + 1))
  fi
  echo "Scaling IP-pressure deployment to $replicas replicas"
  "${KUBECTL[@]}" scale deployment/soak-ip-pressure \
    --namespace "$NAMESPACE" \
    --replicas "$replicas"
  verify_ip_pressure
}

for value_name in \
  SOAK_DURATION_MINUTES \
  SOAK_BASE_PODS \
  SOAK_CHURN_PODS \
  SOAK_CHURN_INTERVAL_SECONDS \
  SOAK_HEALTH_INTERVAL_SECONDS \
  SOAK_CONVERGENCE_TIMEOUT_SECONDS \
  SOAK_POLICY_TIMEOUT_SECONDS \
  SOAK_PROBE_TIMEOUT_SECONDS \
  SOAK_DENIED_PROBES \
  SOAK_IP_PRESSURE_PODS \
  SOAK_IP_PRESSURE_EVERY_CYCLES; do
  validate_positive_integer "$value_name" "${!value_name}"
done
if (( SOAK_CHURN_PODS > SOAK_BASE_PODS )); then
  echo "SOAK_CHURN_PODS must not exceed SOAK_BASE_PODS" >&2
  exit 2
fi

# Emit the contract before touching the cluster so failure paths leave an
# artifact containing the run boundary and any phases completed so far.
write_metric_inputs

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required" >&2
  exit 127
}

printf 'Running CNI soak test: cluster=%s region=%s k8s=%s image-tag=%s duration=%sm\n' \
  "$CLUSTER_NAME" "$REGION" "$K8S_VERSION" "$IMAGE_TAG" "$SOAK_DURATION_MINUTES"
echo "Using kubeconfig: $KUBECONFIG"
echo "Workload images: $NGINX_IMAGE and $BUSYBOX_IMAGE"
echo "Metric assertion inputs: $METRIC_ASSERT_INPUTS_FILE"

"${KUBECTL[@]}" version --client
"${KUBECTL[@]}" cluster-info

# ReuseCluster leaves the cluster alive. Remove only this script's namespace so
# retries are idempotent and unrelated workloads remain untouched.
if "${KUBECTL[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Removing leftover namespace $NAMESPACE"
  "${KUBECTL[@]}" delete namespace "$NAMESPACE" \
    --wait=true \
    --timeout "${SOAK_CONVERGENCE_TIMEOUT_SECONDS}s"
fi
"${KUBECTL[@]}" create namespace "$NAMESPACE"
NAMESPACE_CREATED=true

"${KUBECTL[@]}" apply --filename - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: soak-target
  namespace: ${NAMESPACE}
spec:
  replicas: ${SOAK_BASE_PODS}
  selector:
    matchLabels:
      app: cni-soak-target
  template:
    metadata:
      labels:
        app: cni-soak-target
    spec:
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
  name: soak-allowed-probe
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cni-soak-allowed-probe
  template:
    metadata:
      labels:
        app: cni-soak-allowed-probe
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
  name: soak-denied-probe
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cni-soak-denied-probe
  template:
    metadata:
      labels:
        app: cni-soak-denied-probe
        cni-test-access: denied
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
  name: soak-ip-pressure
  namespace: ${NAMESPACE}
spec:
  replicas: 0
  selector:
    matchLabels:
      app: cni-soak-ip-pressure
  template:
    metadata:
      labels:
        app: cni-soak-ip-pressure
    spec:
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: cni-soak-allowed-probe
              namespaces:
                - ${NAMESPACE}
              topologyKey: kubernetes.io/hostname
      containers:
        - name: busybox
          image: ${BUSYBOX_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["sleep", "604800"]
---
apiVersion: v1
kind: Service
metadata:
  name: soak-target
  namespace: ${NAMESPACE}
spec:
  selector:
    app: cni-soak-target
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

verify_ready
verify_ip_pressure
connectivity_matches_policy
start_phase allowed
write_metric_inputs

DURATION_SECONDS=$((SOAK_DURATION_MINUTES * 60))
DEADLINE=$((SECONDS + DURATION_SECONDS))
NEXT_HEALTH=$((SECONDS + SOAK_HEALTH_INTERVAL_SECONDS))
NEXT_CHURN=$((SECONDS + SOAK_CHURN_INTERVAL_SECONDS))
CHURN_CYCLE=0

while (( SECONDS < DEADLINE )); do
  if (( SECONDS >= NEXT_CHURN )); then
    CHURN_CYCLE=$((CHURN_CYCLE + 1))
    echo "=== Soak churn cycle $CHURN_CYCLE at ${SECONDS}s ==="
    close_current_phase
    restart_base_pods
    if (( CHURN_CYCLE % SOAK_IP_PRESSURE_EVERY_CYCLES == 0 )); then
      cycle_ip_pressure
    fi
    if [[ $POLICY_ENABLED == true ]]; then
      remove_policy
      start_phase allowed
    else
      apply_policy
      start_phase deny
      run_denied_probes
    fi
    write_metric_inputs
    NEXT_CHURN=$((SECONDS + SOAK_CHURN_INTERVAL_SECONDS))
  fi

  if (( SECONDS >= NEXT_HEALTH )); then
    health_check
    NEXT_HEALTH=$((SECONDS + SOAK_HEALTH_INTERVAL_SECONDS))
  fi

  NEXT_EVENT=$NEXT_HEALTH
  if (( NEXT_CHURN < NEXT_EVENT )); then
    NEXT_EVENT=$NEXT_CHURN
  fi
  if (( DEADLINE < NEXT_EVENT )); then
    NEXT_EVENT=$DEADLINE
  fi
  SLEEP_SECONDS=$((NEXT_EVENT - SECONDS))
  if (( SLEEP_SECONDS > 0 )); then
    sleep "$SLEEP_SECONDS"
  fi
done

health_check
close_current_phase
write_metric_inputs
if (( ${#ALLOWED_WINDOW_STARTS[@]} == 0 || ${#DENY_WINDOW_STARTS[@]} == 0 )); then
  echo "Soak run did not complete both allowed-only and deny phases" >&2
  exit 1
fi
if (( PRESSURE_SCALE_UPS == 0 )); then
  echo "Soak run did not execute an IP-pressure scale-up" >&2
  exit 1
fi
if [[ $IP_PRESSURE_ENABLED == true ]]; then
  cycle_ip_pressure
fi
echo "CNI soak test completed successfully after $SOAK_DURATION_MINUTES minutes and $CHURN_CYCLE churn cycles"
"${KUBECTL[@]}" delete namespace "$NAMESPACE" \
  --wait=true \
  --timeout "${SOAK_CONVERGENCE_TIMEOUT_SECONDS}s"
NAMESPACE_CREATED=false
