# ClusterLoader2 assertion coverage

## Decision

Use ClusterLoader2 as the single assertion engine for CNI and NPA scale tests.
The custom Go metric catalog, snapshot model, reducers, and verdict engine are
not required.

Keep only:

- the existing OSS workload and cleanup scripts;
- ClusterLoader2 profiles containing PromQL and thresholds;
- one small node-evidence endpoint for host-only containerd and bpffs data; and
- the existing Hydra diagnostics and artifact-upload hook.

The node-evidence endpoint is collection glue, not an assertion framework. Its
production form can be merged into the existing CommonGo `dp-prom-scraper`
DaemonSet, which already has host networking and a read-only bpffs mount.

The internal `EKSDataPlaneClusterloader2` runtime must be refreshed first. Its
current binary was built from upstream revision
`1f525a2c858e609af587320dbf357d851c5fcf2d` in October 2022 and does not expose
the additional-monitor flag or the current fail-closed query behavior used by
this POC.

## Test phase contract

ClusterLoader2 can represent baseline, full-load, and recovery checks without
an application snapshot API:

1. Start Prometheus and wait for a stable baseline window.
2. Start two `GenericPrometheusQuery` measurements with different identifiers:
   one for full-load evidence and one for end-to-end recovery evidence.
3. Run the existing workload script with the ClusterLoader2 `Exec`
   measurement. The scale script leaves its final load active.
4. Gather the full-load measurement.
5. Run the existing cleanup script with `Exec`.
6. Sleep for the configured recovery period, currently five minutes.
7. Gather the recovery measurement.

Each measurement substitutes its own elapsed duration into `%v`. PromQL
`offset %v` therefore addresses the pre-test baseline while the current range
addresses full load or recovery. ClusterLoader2 stores independent measurement
state by method and identifier, so the two windows can overlap. Start both
measurements before the workload `Exec`; the offset baseline window then ends
at measurement start and cannot include workload activity.

## Fail-closed rules

- Require exactly one expected node set for every required metric family.
- Set `requireSamples: true` on every blocking query.
- Preserve the `node` label and return per-node violation values.
- Require a recent node-evidence refresh timestamp so a stale exporter file
  cannot satisfy containerd or bpffs assertions.
- Assert that `process_start_time_seconds` does not change during a window.
- Normalize an empty vector to zero only when zero has defined semantics:
  required-family cardinality starts at zero, and no residual pins or errors
  also means zero.
- Use snapshot deltas for lazy counters:

  ```promql
  clamp_min(
    (sum(max_over_time(metric[30s])) or vector(0))
      -
    (sum(max_over_time(metric[30s] offset %v)) or vector(0)),
    0
  )
  ```

  Plain `increase()` can miss a lazily-created error series whose first
  observed value is already one.

## Required assertion map

| Requirement | ClusterLoader2 mechanism | Evidence | Status |
| --- | --- | --- | --- |
| Every expected Linux node is observed | Exact cardinality plus `requireSamples` | `up`, process metric, and component metric cardinality by `node` | Covered and validated live |
| One unhealthy node fails the run | PromQL returns one score per `node`; `dimensions: [node]` | Stable node relabeling in PodMonitor and ServiceMonitor | Covered and validated live |
| Node adapter remains fresh | Per-node `time() - refresh_timestamp` threshold | Node-evidence endpoint | Covered; stale synthetic series fails |
| Missing metric family fails | Exact family cardinality | Required family | Covered and validated with a deliberately wrong node count |
| Component restart during test | `changes(process_start_time_seconds[%v])` | IPAMD or NPA endpoint | Covered and validated live |
| Runtime image is the expected image | `Exec` verifies `kubectl get pod` image IDs and records them in metadata | Kubernetes API | Covered outside PromQL; no custom evaluator needed |
| CNI EC2 request activity | Positive snapshot delta | `awscni_ec2api_req_count` | Covered |
| CNI EC2 request volume within ±10% | Compare the snapshot delta with the scenario-supplied expected count and return only the excess outside the tolerance band | `awscni_ec2api_req_count` | Covered; expected count belongs in the CL2 scenario profile |
| CNI IPAMD and EC2 API errors | Zero snapshot delta, gated by positive request activity | `awscni_ipamd_error_count`, `awscni_ec2api_error_count` | Covered |
| CNI throttling | Zero filtered snapshot delta | `awscni_aws_api_error_count{error=~"(?i)(.*throttl.*|requestlimitexceeded)"}` | Covered |
| Configured EC2 error-rate budget | `errors / clamp_min(requests, 1)` compared with the profile budget | IPAMD counters | Covered |
| CNI ADD and DEL operation counts | Minimum snapshot delta by `operation_type` | Containerd CRI metrics | Covered when endpoint is enabled |
| CNI ADD and DEL failures | Zero snapshot delta | Containerd error counter | Covered when endpoint is enabled |
| CNI ADD and DEL latency | Histogram quantile or `_sum / _count` | Containerd duration histogram | Covered when endpoint is enabled |
| CNI functional completion | `Exec` propagates non-zero exit from ready-pod, unique-IP, and connectivity checks | Existing CNI workload script | Covered |
| NPA policy setup and teardown counts | Minimum snapshot delta | NPA setup and teardown summary counts | Covered |
| NPA eBPF SDK hard errors | Zero filtered snapshot delta; explicitly allowed labels remain report-only | NPA SDK error counter | Covered |
| NPA policy-programming latency | Histogram quantile or summary average | NPA policy and SDK latency metrics | Covered |
| NPA pinned-object activity at full load | Full-load set difference, or positive `LoadBpfFile` delta | Node-evidence bpffs series and NPA SDK counter | Covered |
| NPA residual program or map identity | Recovery set minus baseline set with `unless on(node,kind,pin_hash)` | Node-evidence bpffs series | Covered and validated live |
| NPA functional enforcement | `Exec` propagates non-zero exit from allow, deny, mode, and policy-removal probes | Existing NPA workload and cleanup scripts | Covered |
| CPU utilization or growth | `rate(process_cpu_seconds_total[window])`, peak, or slope by node | Component endpoint | Covered |
| Process RSS | Baseline/recovery comparison or slope | `process_resident_memory_bytes` | Covered |
| Container WSS leak check | Recovery average must be no more than baseline plus `max(10%, 32 MiB)` per node | Kubelet `/metrics/resource` | Covered and validated live |
| Cleanup followed by recovery | `Exec` cleanup, `Sleep`, then recovery gather | Existing cleanup script | Covered |
| Workload cardinality and rounds | Existing script validates its requested/completed counts and exits non-zero on mismatch | Workload state/report | Covered through `Exec` |

## Evidence adapters

### Containerd

Containerd listens on node loopback at `127.0.0.1:1338/v1/metrics`. A
host-network endpoint republishes the selected counters and histogram to
ClusterLoader2 Prometheus. It also exports
`dataplane_containerd_scrape_success`; exact node cardinality makes a disabled
or unreachable endpoint fail closed.

### NPA bpffs

The same endpoint reads the existing read-only `/sys/fs/bpf` mount and exports:

- `dataplane_npa_bpf_snapshot_success`; and
- `dataplane_npa_bpf_pin_present{kind,pin_hash}`.

Only a hash of each pin identity is exported. PromQL compares identity sets, so
equal counts with one identity replaced still fail.

## Outside ClusterLoader2's native metric engine

| Concern | Handling |
| --- | --- |
| Historical comparison with a previous run | Supply a baseline parameter or query a retained external Prometheus. Ephemeral ClusterLoader2 Prometheus has no previous-run data. |
| Node bundle collection and S3 upload | Keep the existing Hydra failure hook. This is diagnostics, not assertion policy. |
| Functional semantics that are not metrics | Run the existing scripts through ClusterLoader2 `Exec`; their exit code is the verdict. |
| Host-only evidence | Expose it through the small node-evidence endpoint described above. |

None of these require a second generic metric assertion interface.

## ClusterLoader2 lifecycle boundary

Current upstream teardown removes the `monitoring` namespace but not all
cluster-scoped objects installed with the Prometheus stack. Hydra deletes its
ephemeral test cluster after diagnostics are captured, so pipeline runs remain
bounded. Developer runs should use a disposable cluster until the refreshed
internal ClusterLoader2 package adds symmetric cleanup.

## POC evidence

- Current upstream ClusterLoader2 revision:
  `2a436dfdad1b8c73b79aca52169b61362b54bd50`.
- Live three-node EKS run discovered three IPAMD targets, three NPA targets,
  and three WSS series for each component.
- CNI and NPA per-node coverage verdicts passed.
- A run configured for four expected nodes failed on target, process, and WSS
  cardinality.
- NPA WSS baseline/recovery comparison passed for all three nodes.
- A final live run reported fresh node-evidence data on all three nodes with
  zero per-node staleness violations.
- The node adapter exported 14 map and four program identities per node in the
  observed cluster; exact recovery-minus-baseline identity count was zero.
- The same adapter reported containerd scrape success as zero on all three
  nodes of a cluster created without the containerd metrics setting, and
  ClusterLoader2 failed both required containerd queries.
- Prometheus 2.40 unit tests cover healthy and leaking WSS, lazy error
  counters, missing nodes, a stale node adapter, and an equal-cardinality BPF
  identity swap.
