#!/usr/bin/env bash
# Install OpenShift console dashboards for DCGM / DRA GPU metrics.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

oc create configmap nvidia-dcgm-exporter-dashboard \
  -n openshift-config-managed \
  --from-file=dcgm-exporter-dashboard.json="${DIR}/dcgm-exporter-dashboard.json" \
  --dry-run=client -o yaml | oc apply -f -
oc label configmap nvidia-dcgm-exporter-dashboard -n openshift-config-managed \
  console.openshift.io/dashboard=true \
  console.openshift.io/odc-dashboard=true --overwrite

oc create configmap nvidia-dra-gpu-dashboard \
  -n openshift-config-managed \
  --from-file=nvidia-dra-gpu-dashboard.json="${DIR}/nvidia-dra-gpu-dashboard.json" \
  --dry-run=client -o yaml | oc apply -f -
oc label configmap nvidia-dra-gpu-dashboard -n openshift-config-managed \
  console.openshift.io/dashboard=true \
  console.openshift.io/odc-dashboard=true --overwrite

echo "Dashboards installed. Open Administrator → Observe → Dashboards"
echo "  - NVIDIA DCGM Exporter Dashboard"
echo "  - NVIDIA DRA GPU Dashboard"
