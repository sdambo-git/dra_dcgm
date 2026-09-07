# NVIDIA GPUCluster DRA + DCGM on OpenShift (OLM only)

From-scratch install of **Dynamic Resource Allocation (DRA)** GPUs on OpenShift, with DCGM Exporter scraped by cluster Prometheus and OpenShift console dashboards.

This is **not** the classic `ClusterPolicy` / device-plugin path (`nvidia.com/gpu: 1`). Workloads get a GPU with a `ResourceClaim` against DeviceClass `gpu.nvidia.com`.

Do **not** use Helm. Use OperatorHub / OLM only.

## What you get

| Piece | What it does |
|---|---|
| Node Feature Discovery | Labels NVIDIA PCI (`feature.node.kubernetes.io/pci-10de.present=true`) |
| GPU Operator **26.7** | Owns `GPUCluster` / `NVIDIADriver` CRDs |
| `NVIDIADriver` | Builds and loads the NVIDIA kernel module via OpenShift Driver Toolkit |
| `GPUCluster` named `gpu-cluster` | DRA kubelet plugin, DeviceClasses, ResourceSlices, DCGM Exporter |
| DCGM Exporter + ServiceMonitor | `DCGM_FI_*` metrics with `dra_claim_name` labels |
| Console dashboards | Administrator → Observe → Dashboards |

## Requirements

- OpenShift **4.21 or 4.22** (Kubernetes **1.34.2+**). DRA is GA; you do **not** need `TechPreviewNoUpgrade`.
- At least one worker with an NVIDIA GPU (this lab: `g4dn.xlarge` Tesla T4, PCI `10de:1eb8`).
- Cluster-admin (`oc` with a kubeconfig).
- Outbound pull from `nvcr.io` and OpenShift Driver Toolkit (`openshift/driver-toolkit` ImageStream).
- GPU Operator channel **v26.7**. 26.3 does **not** have `GPUCluster`.

### Hard rule: never create `ClusterPolicy`

A cluster can have **either** `ClusterPolicy` **or** `GPUCluster`, not both. The OpenShift console “Create ClusterPolicy” button after Operator install will lock you into the old device plugin. Skip it.

The GPUCluster object **must** be named `gpu-cluster`. The operator looks for that name (or a ClusterPolicy). If neither exists it logs `No ClusterPolicy or GPUCluster CR exists` and never labels nodes / never starts DaemonSets.

## Lab values (this cluster)

These manifests were proven on:

- OpenShift **4.22.10**, Kubernetes **v1.35.6**, CRI-O 1.35.6
- GPU Operator **26.7.0**, DRA driver **v0.5.0**
- Driver **595.91.07** (Driver Toolkit on RHCOS)
- Namespace `nvidia-gpu-operator`

Adjust the driver version if NVIDIA publishes a newer certified one for your OCP release.

---

## File map

Apply from this directory (`~/nvidia_gpu_update`).

| File | Purpose |
|---|---|
| `nfd-namespace.yaml` | NFD namespace |
| `nfd-operatorgroup.yaml` | NFD OperatorGroup |
| `nfd-subscription.yaml` | NFD Operator from `redhat-operators` |
| `nfd-instance.yaml` | `NodeFeatureDiscovery` with PCI vendor labels |
| `nvidia-gpu-operator.yaml` | GPU Operator namespace + monitoring / DRA admin labels |
| `nvidia-gpu-operatorgroup.yaml` | Namespaced OperatorGroup |
| `nvidia-gpu-sub.yaml` | Certified GPU Operator **v26.7**, Manual InstallPlan |
| `nvidiadriver.yaml` | NVIDIA kernel driver CR |
| `gpu-cluster.yaml` | DRA + DCGM Exporter + ServiceMonitor |
| `prometheus-k8s-rbac.yaml` | Lets cluster Prometheus scrape the GPU namespace |
| `dcgm-exporter-dashboard.json` | Official NVIDIA DCGM Grafana JSON |
| `nvidia-dra-gpu-dashboard.json` | OpenShift schema-14 dashboard with a **DRA claim** dropdown |
| `install-dashboards.sh` | Loads both dashboards into `openshift-config-managed` |
| `gpu-dra-demo.yaml` | Continuous nbody CUDA workload via ResourceClaim |

---

## 0. kubeconfig

```bash
export KUBECONFIG=/home/sdambo/aws_install/test-cluster/auth/kubeconfig
cd ~/nvidia_gpu_update

oc get clusterversion
oc version
oc api-resources | grep -E 'deviceclass|resourceclaim|resourceslice'
```

You should already see `deviceclasses`, `resourceclaims`, `resourceslices` on 4.21+.

---

## 1. Node Feature Discovery

NFD must label NVIDIA PCI **before** GPUCluster will select the node.

```bash
oc apply -f nfd-namespace.yaml
oc apply -f nfd-operatorgroup.yaml
oc apply -f nfd-subscription.yaml
oc -n openshift-nfd wait csv --for=jsonpath='{.status.phase}'=Succeeded -l operators.coreos.com/nfd.openshift-nfd --timeout=300s
oc apply -f nfd-instance.yaml
```

Wait until GPU workers have the NVIDIA vendor label (`10de` is NVIDIA):

```bash
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
```

If that is empty, NFD is not seeing the GPU. Check `nfd-worker` logs on that node.

---

## 2. GPU Operator namespace and OLM

```bash
oc apply -f nvidia-gpu-operator.yaml
oc apply -f nvidia-gpu-operatorgroup.yaml
oc apply -f nvidia-gpu-sub.yaml
```

Manual InstallPlan (do **not** skip this):

```bash
oc get installplan -n nvidia-gpu-operator
oc -n nvidia-gpu-operator patch installplan "$(oc get installplan -n nvidia-gpu-operator -o jsonpath='{.items[-1:].metadata.name}')" \
  --type merge -p '{"spec":{"approved":true}}'
oc -n nvidia-gpu-operator wait csv/gpu-operator-certified.v26.7.0 --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

Confirm CRDs exist and that there is still **no** ClusterPolicy:

```bash
oc get crd gpuclusters.nvidia.com nvidiadrivers.nvidia.com clusterpolicies.nvidia.com
oc get clusterpolicy
# should print: No resources found
```

Namespace labels that matter:

- `openshift.io/cluster-monitoring=true` — CMO looks for ServiceMonitors here
- `resource.kubernetes.io/admin-access=true` — DCGM exporter and validator use DRA `adminAccess`

If you already had GPU Operator **26.3** installed with no ClusterPolicy, switch the Subscription channel to `v26.7` and approve the new InstallPlan. Do not install ClusterPolicy on the way.

---

## 3. NVIDIADriver

Create the driver **before or with** GPUCluster. Driver Toolkit compile on RHCOS often takes **10–20 minutes**.

```bash
oc apply -f nvidiadriver.yaml
oc get nvidiadriver gpu-driver -o wide
```

Until GPUCluster exists, the operator may log `No nodes matching the given node selector`. That is expected. GPUCluster is what sets `nvidia.com/gpu.present=true`.

---

## 4. GPUCluster (DRA + DCGM)

```bash
oc apply -f gpu-cluster.yaml
```

This CR:

- Starts `nvidia-dra-driver-kubelet-plugin`
- Creates DeviceClasses `gpu.nvidia.com`, `mig.nvidia.com`, `vfio.gpu.nvidia.com`
- Starts `nvidia-dcgm-exporter-dra` (embedded DCGM hostengine)
- Creates ServiceMonitor `nvidia-dcgm-exporter-dra` (15s scrape)

`spec.dcgm.enabled: false` is intentional. That flag only runs a **separate** `nvidia-dcgm` hostengine DaemonSet. The exporter’s embedded engine is what NVIDIA uses by default and is enough for Prometheus.

`computeDomains.enabled: false` because this lab is a single T4, not MIG / compute-domain sharing.

Watch the wait chain:

```bash
oc get gpucluster gpu-cluster
oc get nvidiadriver gpu-driver
oc get pods -n nvidia-gpu-operator -o wide
```

Typical order:

1. Operator labels the GPU node `nvidia.com/gpu.present=true`
2. Driver DaemonSet `nvidia-gpu-driver-rhel9-*` compiles, then `modprobe nvidia`. Startup probe fails with `NVIDIA kernel module not loaded` until that finishes.
3. DRA plugin Init waits on `/run/nvidia/validations/.driver-ctr-ready`
4. Validator and DCGM Exporter stay Pending with `cannot allocate all claims` until ResourceSlices exist
5. `GPUCluster` `status.state: ready`

```bash
oc get deviceclass
oc get resourceslice
oc get nodes -l nvidia.com/gpu.present=true
```

You want one ResourceSlice for `gpu.nvidia.com` listing `gpu-0` (or your device name).

---

## 5. Prometheus scrape RBAC

`openshift.io/cluster-monitoring=true` is **not** enough on its own. Cluster Monitoring Operator does not always create `Role/prometheus-k8s` in this namespace, so `prometheus-k8s` cannot list services/endpoints/pods and the target stays down.

```bash
oc apply -f prometheus-k8s-rbac.yaml
```

Check:

```bash
oc auth can-i list endpoints -n nvidia-gpu-operator \
  --as=system:serviceaccount:openshift-monitoring:prometheus-k8s
# yes

oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(DCGM_FI_DEV_GPU_UTIL)'
```

OpenShift console: **Administrator → Observe → Targets**, job  
`serviceMonitor/nvidia-gpu-operator/nvidia-dcgm-exporter-dra/0` should be **Up**.

Useful labels on DCGM series:

- `dra_claim_name` — ResourceClaim that currently holds the GPU
- `dra_device_name` — e.g. `gpu-0`
- `exported_pod` — workload pod (Prometheus `honorLabels=false` overwrites `pod` to the **exporter** pod)

---

## 6. Console dashboards

```bash
chmod +x install-dashboards.sh
./install-dashboards.sh
```

Then **Administrator → Observe → Dashboards** (not Developer project view):

- **NVIDIA DCGM Exporter Dashboard** — official NVIDIA JSON
- **NVIDIA DRA GPU Dashboard** — claim dropdown (`$claim` → `dra_claim_name=~"$claim"`)

The DRA dashboard is Grafana **schema 14 with `rows`**. OpenShift’s bundled Grafana ignores modern Grafana 9+ `panels`-only JSON, so `$claim` never rendered and graphs showed “No datapoints”. Do not replace `nvidia-dra-gpu-dashboard.json` with an unmodified Grafana.com export.

---

## 7. Continuous DRA workload (optional)

DCGM scrape is 15s. A one-shot `vectorAdd` finishes too fast, so `DCGM_FI_DEV_GPU_UTIL` stays 0. Use nbody in a loop.

On this lab the T4 is already claimed by DCGM (`allocationMode: All` + `adminAccess`) and the validator. A **normal** claim cannot get the card. The demo uses `adminAccess: true` in `nvidia-gpu-operator` (the namespace has `resource.kubernetes.io/admin-access=true`).

```bash
oc apply -f gpu-dra-demo.yaml
oc adm policy add-scc-to-user privileged -z gpu-dra-demo -n nvidia-gpu-operator
oc get pod,resourceclaim -n nvidia-gpu-operator | grep gpu-dra
```

Image: `nvcr.io/nvidia/k8s/cuda-sample:nbody-cuda11.7.1`  
(`nbody-cuda12.5.0` does not exist; `vectoradd-cuda12.5.0` exists but is too short for graphs.)

On the DRA dashboard pick claim `gpu-dra-demo-gpu-*`. GPU util / power should move.

Delete when done:

```bash
oc delete pod gpu-dra-demo -n nvidia-gpu-operator
```

The ResourceClaim from the template goes away with the pod.

---

## Verification cheat sheet

```bash
# Operator
oc get csv -n nvidia-gpu-operator
oc get clusterpolicy          # must be empty
oc get gpucluster,nvidiadriver

# Node
oc get node -L feature.node.kubernetes.io/pci-10de.present,nvidia.com/gpu.present

# DRA
oc get deviceclass
oc get resourceslice -o yaml | grep -E 'name: gpu-|modelName|driver:'
oc get resourceclaim -A

# DCGM
oc get ds,svc,servicemonitor -n nvidia-gpu-operator | grep dcgm
oc exec -n nvidia-gpu-operator deploy/nvidia-dcgm-exporter-dra -- \
  wget -qO- http://127.0.0.1:9400/metrics | grep '^DCGM_FI_DEV_GPU_UTIL'

# Driver
oc logs -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver --tail=50
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No DaemonSets, only operator pod | No `GPUCluster` named `gpu-cluster` | Apply `gpu-cluster.yaml`. Do not create ClusterPolicy. |
| NVIDIADriver: no matching nodes | GPUCluster has not labeled `nvidia.com/gpu.present` | Create `gpu-cluster`; confirm NFD PCI label first |
| Driver 1/2, probe `NVIDIA kernel module not loaded` | Driver Toolkit still compiling | Wait; RHCOS compile is slow |
| DRA plugin Init:0/1 | Waiting for `/run/nvidia/validations/.driver-ctr-ready` | Wait for driver 2/2 |
| Validator / DCGM Pending `cannot allocate all claims` | No ResourceSlice yet | Wait for DRA plugin Ready |
| ServiceMonitor exists, Prometheus target down | No Role for `prometheus-k8s` | Apply `prometheus-k8s-rbac.yaml` |
| Metrics have `pod=nvidia-dcgm-exporter-dra-*` | `honorLabels=false` | Use `exported_pod` and `dra_claim_name` |
| Dashboard “No datapoints”, no claim dropdown | Grafana schema too new, or not in Administrator view | Use `nvidia-dra-gpu-dashboard.json` schema 14 + rows; Administrator → Observe → Dashboards |
| GPU util always 0 with a demo pod | Workload too short vs 15s scrape | Use `gpu-dra-demo.yaml` nbody loop |
| Normal app claim stuck Pending | T4 already held by exporter + validator admin claims | Demo in this namespace with `adminAccess: true`, or disable validator/exporter for a clean user claim |
| `ImagePullBackOff` nbody-cuda12.5.0 | Tag does not exist | Use `nbody-cuda11.7.1` or `vectoradd-cuda12.5.0` |

---

## Architecture (why this order)

```
NFD (PCI 10de)
  → GPU Operator 26.7 (no ClusterPolicy)
    → NVIDIADriver (Driver Toolkit → nvidia.ko)
    → GPUCluster gpu-cluster
         → node label nvidia.com/gpu.present
         → nvidia-dra-driver-kubelet-plugin
         → DeviceClass + ResourceSlice
         → nvidia-dcgm-exporter-dra  (admin ResourceClaim, All devices)
         → ServiceMonitor 15s
              → prometheus-k8s Role  (this repo)
              → OpenShift dashboards
```

User pods:

```yaml
resourceClaims:
- name: gpu
  resourceClaimTemplateName: <template>   # deviceClassName: gpu.nvidia.com
containers:
- resources:
    claims:
    - name: gpu
```

Do not set `limits: nvidia.com/gpu: 1` on this path. That is the ClusterPolicy device plugin.

---

## References

- NVIDIA GPU Operator DRA: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/dra-intro-install.html
- NVIDIA OpenShift GPU Operator: https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html
- Kubernetes DRA: DeviceClass / ResourceClaim / ResourceSlice (`resource.k8s.io`)
