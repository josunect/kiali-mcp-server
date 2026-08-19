#!/usr/bin/env bash
# Removes EAP mesh preconditions created by setup-bookinfo-preconditions.sh.
# Does NOT uninstall Bookinfo itself.
#
# Usage:
#   ./cleanup-bookinfo-preconditions.sh
#   NS=bookinfo ./cleanup-bookinfo-preconditions.sh
#
set -euo pipefail

NS="${NS:-bookinfo}"
LABEL_KEY="eap.kiali.io/test"
LABEL_VAL="eap-preconditions"
LABEL="${LABEL_KEY}=${LABEL_VAL}"
LIMITED_SA="${LIMITED_SA:-eap-mesh-reader}"
OC_OR_KUBECTL="${OC_OR_KUBECTL:-}"

if [[ -z "${OC_OR_KUBECTL}" ]]; then
  if command -v oc >/dev/null 2>&1; then
    OC_OR_KUBECTL=oc
  else
    OC_OR_KUBECTL=kubectl
  fi
fi
K="${OC_OR_KUBECTL}"

echo "==> Using ${K}; namespace=${NS}; label=${LABEL}"

if ! "${K}" get ns "${NS}" >/dev/null 2>&1; then
  echo "Namespace '${NS}' not found — nothing to clean."
  exit 0
fi

echo "==> Deleting labeled mesh / batch / RBAC resources"
for kind in \
  httproute \
  gateway.networking.k8s.io \
  virtualservice \
  destinationrule \
  gateway.networking.istio.io \
  job \
  rolebinding \
  role \
  serviceaccount
do
  "${K}" delete "${kind}" -n "${NS}" -l "${LABEL}" --ignore-not-found --wait=false 2>/dev/null || true
done

# Disposable objects testers may leave from Scenarios 11–12 (created without our label)
echo "==> Deleting common disposable create-test names (Scenarios 11–12)"
"${K}" -n "${NS}" delete gateway.networking.istio.io eap-test-gateway --ignore-not-found --wait=false 2>/dev/null || true
"${K}" -n "${NS}" delete gateway.networking.k8s.io eap-test-gateway --ignore-not-found --wait=false 2>/dev/null || true
"${K}" -n "${NS}" delete httproute eap-test-httproute --ignore-not-found --wait=false 2>/dev/null || true
"${K}" -n istio-system delete gateway.networking.istio.io eap-test-gateway --ignore-not-found --wait=false 2>/dev/null || true

# Named RBAC fallback if labels were lost
"${K}" -n "${NS}" delete rolebinding,role,serviceaccount "${LIMITED_SA}" --ignore-not-found --wait=false 2>/dev/null || true

cat <<EOF

Cleanup complete for namespace '${NS}'.
Bookinfo app (Deployments/Services) was left intact.

If WRITE tests changed unlabeled objects, re-check:
  ${K} -n ${NS} get virtualservice,destinationrule,gateway.networking.istio.io
EOF
