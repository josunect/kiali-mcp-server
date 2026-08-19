#!/usr/bin/env bash
# EAP preconditions for docs/mcp-kiali.txt scenarios (bookinfo already installed).
# Seeds DestinationRules / VirtualServices required by WRITE / READ cases.
# Does NOT install Bookinfo.
#
# Covers (mcp-kiali.txt §6 minimal extras):
#   Scenario 4  — reviews VS with subset v3 weight 0 (no red stars)
#   Scenario 5  — details VS with fault.abort HTTP 503 (READ troubleshooting)
#   Scenarios 10–11 — optional traffic Job so metrics/traces have signal
#
# Not seeded here (tester / MCP config):
#   Scenario 8  — toggle MCP read_only=true and reconnect the client
#   Scenarios 11–12 — create / delete disposable Gateway (e.g. eap-test-gateway)
#
# Usage:
#   ./setup-bookinfo-preconditions.sh
#   NS=bookinfo GENERATE_TRAFFIC=0 ./setup-bookinfo-preconditions.sh
#
set -euo pipefail

NS="${NS:-bookinfo}"
LABEL_KEY="eap.kiali.io/test"
LABEL_VAL="eap-preconditions"
LABEL="${LABEL_KEY}=${LABEL_VAL}"
GENERATE_TRAFFIC="${GENERATE_TRAFFIC:-1}"
OC_OR_KUBECTL="${OC_OR_KUBECTL:-}"

if [[ -z "${OC_OR_KUBECTL}" ]]; then
  if command -v oc >/dev/null 2>&1; then
    OC_OR_KUBECTL=oc
  else
    OC_OR_KUBECTL=kubectl
  fi
fi
K="${OC_OR_KUBECTL}"

echo "==> Using ${K}; namespace=${NS}"

if ! "${K}" get ns "${NS}" >/dev/null 2>&1; then
  echo "ERROR: namespace '${NS}' not found. Install Bookinfo first, then re-run." >&2
  exit 1
fi

if ! "${K}" -n "${NS}" get svc productpage >/dev/null 2>&1; then
  echo "ERROR: Bookinfo productpage Service missing in '${NS}'. Install Bookinfo first." >&2
  exit 1
fi

echo "==> Applying DestinationRules + WRITE-precondition VirtualServices"
# Remove superseded fault target (ratings) when re-seeding from an older script version.
"${K}" -n "${NS}" delete virtualservice ratings destinationrule ratings -l "${LABEL}" --ignore-not-found >/dev/null 2>&1 || true
"${K}" apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: ${NS}
  labels:
    ${LABEL_KEY}: ${LABEL_VAL}
spec:
  host: reviews.${NS}.svc.cluster.local
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
  - name: v3
    labels:
      version: v3
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: details
  namespace: ${NS}
  labels:
    ${LABEL_KEY}: ${LABEL_VAL}
spec:
  host: details.${NS}.svc.cluster.local
  subsets:
  - name: v1
    labels:
      version: v1
---
# Scenario 4: productpage never shows red stars (reviews-v3 weight = 0)
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: ${NS}
  labels:
    ${LABEL_KEY}: ${LABEL_VAL}
spec:
  hosts:
  - reviews.${NS}.svc.cluster.local
  http:
  - route:
    - destination:
        host: reviews.${NS}.svc.cluster.local
        subset: v1
      weight: 100
    - destination:
        host: reviews.${NS}.svc.cluster.local
        subset: v2
      weight: 0
    - destination:
        host: reviews.${NS}.svc.cluster.local
        subset: v3
      weight: 0
---
# Scenario 5 (READ): fault on details — productpage calls details every load
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: details
  namespace: ${NS}
  labels:
    ${LABEL_KEY}: ${LABEL_VAL}
spec:
  hosts:
  - details.${NS}.svc.cluster.local
  http:
  - route:
    - destination:
        host: details.${NS}.svc.cluster.local
        subset: v1
      weight: 100
    fault:
      abort:
        percentage:
          value: 100
        httpStatus: 503
EOF

if [[ "${GENERATE_TRAFFIC}" == "1" ]]; then
  echo "==> Starting short traffic Job for metrics/traces (Scenarios 10–11)"
  JOB="eap-bookinfo-traffic"
  "${K}" -n "${NS}" delete job "${JOB}" --ignore-not-found >/dev/null 2>&1 || true
  "${K}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
  labels:
    ${LABEL_KEY}: ${LABEL_VAL}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 900
  template:
    metadata:
      labels:
        ${LABEL_KEY}: ${LABEL_VAL}
    spec:
      restartPolicy: Never
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command:
        - sh
        - -c
        - |
          set +e
          for i in \$(seq 1 60); do
            curl -sS -o /dev/null --connect-timeout 2 \
              http://productpage.${NS}.svc.cluster.local:9080/productpage || true
            sleep 1
          done
EOF
else
  echo "==> Skipping traffic Job (GENERATE_TRAFFIC=${GENERATE_TRAFFIC})"
fi

cat <<EOF

Setup complete for namespace '${NS}'.

WRITE / observability preconditions ready:
  [4]  VirtualService/reviews — v3 weight = 0
  [5]  VirtualService/details — fault.abort HTTP 503 @ 100% (visible on productpage)
  [10–11] traffic Job (unless GENERATE_TRAFFIC=0)

NOT covered by this script (run during the test / MCP config):
  [8]  Toggle MCP read_only=true and reconnect the AI client
  [11] Create disposable Gateway (e.g. eap-test-gateway)
  [12] Delete Gateway from scenario 11

Cleanup:
  $(dirname "$0")/cleanup-bookinfo-preconditions.sh
EOF
