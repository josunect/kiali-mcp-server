#!/usr/bin/env bash
#
# Installs the full EAP environment for MCP/Kiali scenarios on OpenShift:
#   - Operators from Software Catalog (redhat-operators by default):
#       Service Mesh (Sail/OSSM), Kiali, Tempo (tracing)
#   - OSSM/Istio control plane with tracing to Tempo
#   - Prometheus y Grafana (addons)
#   - Kiali with tracing enabled (Tempo provider)
#   - Bookinfo con traffic generator
#   - EAP preconditions (equivalent to setup-bookinfo-preconditions.sh)
#
# Requirements: oc logged in as cluster-admin, jq, curl, envsubst (gettext).
# Does not invoke other repository scripts.
#
# Usage:
#   ./install-openshift-eap-env.sh
#   CATALOG_SOURCE=redhat BOOKINFO_NS=bookinfo ./install-openshift-eap-env.sh
#   ./install-openshift-eap-env.sh --delete
#
set -euo pipefail

# --- Configuration (override with environment variables) ---------------------

OC="${OC:-oc}"
CATALOG_SOURCE="${CATALOG_SOURCE:-redhat}"          # redhat | community
CONTROL_PLANE_NAMESPACE="${CONTROL_PLANE_NAMESPACE:-istio-system}"
TEMPO_NAMESPACE="${TEMPO_NAMESPACE:-tempo}"
TEMPO_OPERATOR_NAMESPACE="${TEMPO_OPERATOR_NAMESPACE:-openshift-tempo-operator}"
OLM_OPERATORS_NAMESPACE="${OLM_OPERATORS_NAMESPACE:-openshift-operators}"
BOOKINFO_NS="${BOOKINFO_NS:-bookinfo}"
ISTIO_VERSION="${ISTIO_VERSION:-latest}"
KIALI_VERSION="${KIALI_VERSION:-default}"
ADDONS="${ADDONS:-prometheus}"
GENERATE_TRAFFIC="${GENERATE_TRAFFIC:-1}"           # Short EAP job (setup-bookinfo-preconditions)
ENABLE_TRAFFIC_GENERATOR="${ENABLE_TRAFFIC_GENERATOR:-1}"  # Continuous Kiali traffic generator
TRAFFIC_RATE="${TRAFFIC_RATE:-1}"
ISTIO_BOOKINFO_BRANCH="${ISTIO_BOOKINFO_BRANCH:-master}"
MODE="${MODE:-install}"  # install | delete

LABEL_KEY="eap.kiali.io/test"
LABEL_VAL="eap-preconditions"
LABEL="${LABEL_KEY}=${LABEL_VAL}"

MINIO_ACCESS_KEY_ID="minio"
MINIO_ACCESS_KEY_SECRET="minio123"
MINIO_ENDPOINT="http://minio:9000"
MINIO_SECRET_NAME="tempostack-dev-minio"
MINIO_BUCKET_NAME="tempo-data"

# --- Utilidades --------------------------------------------------------------

infomsg() { echo "==> $*"; }
errormsg()  { echo "ERROR: $*" >&2; }

usage() {
  cat <<EOF
Usage:
  $0 [--delete]

Modes:
  (no flags)   Install full EAP environment
  --delete     Delete resources created by this script
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete)
        MODE="delete"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        errormsg "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    errormsg "Required command not found: $1"
    exit 1
  fi
}

wait_for_crd() {
  local crd="$1"
  infomsg "Waiting for CRD ${crd}"
  echo -n "  "
  until "${OC}" get crd "${crd}" >/dev/null 2>&1; do echo -n "."; sleep 2; done
  echo
  "${OC}" wait --for=condition=established --timeout=300s "crd/${crd}"
}

wait_for_deployment_ready() {
  local ns="$1" name="$2" timeout="${3:-300s}"
  infomsg "Waiting for deployment/${name} in ${ns}"
  "${OC}" wait --for=condition=Available --timeout="${timeout}" -n "${ns}" "deployment/${name}"
}

wait_for_pods_ready() {
  local ns="$1" timeout="${2:-300s}"
  infomsg "Waiting for Ready pods in ${ns}"
  "${OC}" wait --for=condition=Ready pod --all -n "${ns}" --timeout="${timeout}" 2>/dev/null || true
}

detect_istio_revision() {
  local rev=""
  # With Sail, namespace label istio.io/rev expects the revision tag name
  # (for example "default"), not the target version (for example "v1.30.3").
  rev="$("${OC}" get istiorevisiontag default -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
  if [[ -z "${rev}" ]]; then
    rev="$("${OC}" get istiorevisiontag -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  if [[ -z "${rev}" ]]; then
    rev="default"
  fi
  echo "${rev}"
}

download_to() {
  local url="$1" dest="$2"
  while ! curl --silent --fail --location --output "${dest}" "${url}"; do
    errormsg "Reintentando descarga: ${url}"
    sleep 5
  done
}

# --- Preflight checks --------------------------------------------------------

preflight() {
  require_cmd "${OC}"
  require_cmd jq
  require_cmd curl
  require_cmd envsubst

  if ! "${OC}" whoami >/dev/null 2>&1; then
    errormsg "You are not logged into OpenShift. Run: ${OC} login ..."
    exit 1
  fi

  if [[ "${CATALOG_SOURCE}" != "redhat" && "${CATALOG_SOURCE}" != "community" ]]; then
    errormsg "CATALOG_SOURCE must be 'redhat' or 'community' (current: ${CATALOG_SOURCE})"
    exit 1
  fi

  infomsg "Cluster: $("${OC}" whoami --show-server 2>/dev/null || echo unknown)"
  infomsg "Usuario: $("${OC}" whoami 2>/dev/null || echo unknown)"
}

# --- Delete / cleanup ---------------------------------------------------------

delete_eap_preconditions() {
  infomsg "Deleting EAP preconditions in ${BOOKINFO_NS}"
  "${OC}" -n "${BOOKINFO_NS}" delete job eap-bookinfo-traffic --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" -n "${BOOKINFO_NS}" delete virtualservice reviews details --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" -n "${BOOKINFO_NS}" delete destinationrule reviews details --ignore-not-found >/dev/null 2>&1 || true
}

delete_bookinfo() {
  infomsg "Deleting traffic generator and Bookinfo in ${BOOKINFO_NS}"
  "${OC}" -n "${BOOKINFO_NS}" delete -f https://raw.githubusercontent.com/kiali/kiali-test-mesh/master/traffic-generator/openshift/traffic-generator.yaml --ignore-not-found --validate=false >/dev/null 2>&1 || true
  "${OC}" -n "${BOOKINFO_NS}" delete configmap traffic-generator-config --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" -n "${BOOKINFO_NS}" delete route productpage --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" -n "${CONTROL_PLANE_NAMESPACE}" delete route istio-ingressgateway --ignore-not-found >/dev/null 2>&1 || true

  if "${OC}" get namespace "${BOOKINFO_NS}" >/dev/null 2>&1; then
    "${OC}" delete namespace "${BOOKINFO_NS}" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

delete_kiali() {
  infomsg "Deleting Kiali CR"
  "${OC}" -n "${CONTROL_PLANE_NAMESPACE}" delete kiali kiali --ignore-not-found >/dev/null 2>&1 || true
}

delete_addons() {
  infomsg "Deleting addons and SCC"
  for addon in prometheus grafana jaeger loki; do
    "${OC}" -n "${CONTROL_PLANE_NAMESPACE}" delete svc "${addon}" --ignore-not-found >/dev/null 2>&1 || true
    "${OC}" -n "${CONTROL_PLANE_NAMESPACE}" delete deployment "${addon}" --ignore-not-found >/dev/null 2>&1 || true
    "${OC}" -n "${CONTROL_PLANE_NAMESPACE}" delete route "${addon}" --ignore-not-found >/dev/null 2>&1 || true
  done
  "${OC}" delete scc istio-addons-scc --ignore-not-found >/dev/null 2>&1 || true
}

delete_istio_control_plane() {
  infomsg "Deleting Istio/IstioCNI CRs and control plane namespaces"
  "${OC}" delete istio default --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" delete istiocni default --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" delete namespace "${CONTROL_PLANE_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" delete namespace istio-cni --ignore-not-found >/dev/null 2>&1 || true
}

delete_tempo_stack() {
  infomsg "Deleting TempoStack and tempo namespace"
  "${OC}" -n "${TEMPO_NAMESPACE}" delete tempostack tempo --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" -n "${TEMPO_NAMESPACE}" delete deployment minio --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" -n "${TEMPO_NAMESPACE}" delete pvc minio-pv-claim --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" -n "${TEMPO_NAMESPACE}" delete secret "${MINIO_SECRET_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" delete namespace "${TEMPO_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
}

delete_operator_subscriptions() {
  infomsg "Deleting operator Subscriptions"
  "${OC}" -n "${OLM_OPERATORS_NAMESPACE}" delete subscription my-kiali my-sailoperator --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" -n "${TEMPO_OPERATOR_NAMESPACE}" delete subscription my-tempo-operator --ignore-not-found >/dev/null 2>&1 || true
  "${OC}" -n "${TEMPO_OPERATOR_NAMESPACE}" delete operatorgroup "${TEMPO_OPERATOR_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
}

delete_operator_csvs_and_crds() {
  infomsg "Deleting related CSVs and CRDs (kiali/tempo/sail/istio)"
  while IFS=":" read -r ns csv; do
    [[ -z "${ns}" || -z "${csv}" ]] && continue
    "${OC}" -n "${ns}" delete csv "${csv}" --ignore-not-found >/dev/null 2>&1 || true
  done < <("${OC}" get csv --all-namespaces --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name 2>/dev/null | awk '/kiali|tempo|sail|servicemesh|istio/ {print $1 ":" $2}')

  while IFS= read -r crd; do
    [[ -z "${crd}" ]] && continue
    "${OC}" delete "${crd}" --ignore-not-found >/dev/null 2>&1 || true
  done < <("${OC}" get crds -o name 2>/dev/null | awk '/kiali\.io|tempo|sail|istio/')

  "${OC}" delete namespace "${TEMPO_OPERATOR_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
}

run_delete() {
  preflight
  infomsg "=== Delete mode: cleaning EAP environment ==="
  delete_eap_preconditions
  delete_bookinfo
  delete_kiali
  delete_addons
  delete_istio_control_plane
  delete_tempo_stack
  delete_operator_subscriptions
  delete_operator_csvs_and_crds
  infomsg "Cleanup completed."
}

# --- OLM operators (Software Catalog) ----------------------------------------

install_kiali_operator() {
  local source name
  case "${CATALOG_SOURCE}" in
    redhat)
      source="redhat-operators"
      name="kiali-ossm"
      ;;
    community)
      source="community-operators"
      name="kiali"
      ;;
  esac

  infomsg "Installing Kiali Operator from ${source}"
  "${OC}" apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: my-kiali
  namespace: ${OLM_OPERATORS_NAMESPACE}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: ${name}
  source: ${source}
  sourceNamespace: openshift-marketplace
  config:
    env:
    - name: ALLOW_ALL_ACCESSIBLE_NAMESPACES
      value: "true"
    - name: ACCESSIBLE_NAMESPACES_LABEL
      value: ""
EOF
}

install_tempo_operator() {
  local source name channel
  case "${CATALOG_SOURCE}" in
    redhat)
      source="redhat-operators"
      name="tempo-product"
      channel="stable"
      ;;
    community)
      source="community-operators"
      name="tempo-operator"
      channel="alpha"
      ;;
  esac

  infomsg "Installing Tempo Operator from ${source}"
  "${OC}" apply -f - <<EOF
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  labels:
    kubernetes.io/metadata.name: ${TEMPO_OPERATOR_NAMESPACE}
    openshift.io/cluster-monitoring: "true"
  name: ${TEMPO_OPERATOR_NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${TEMPO_OPERATOR_NAMESPACE}
  namespace: ${TEMPO_OPERATOR_NAMESPACE}
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: my-tempo-operator
  namespace: ${TEMPO_OPERATOR_NAMESPACE}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: ${name}
  source: ${source}
  sourceNamespace: openshift-marketplace
EOF
}

install_servicemesh_operator() {
  local source name channel
  case "${CATALOG_SOURCE}" in
    redhat)
      source="redhat-operators"
      name="servicemeshoperator3"
      channel="stable"
      ;;
    community)
      source="community-operators"
      name="sailoperator"
      channel="stable"
      ;;
  esac

  infomsg "Installing Service Mesh Operator (OSSM) from ${source}"
  "${OC}" apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: my-sailoperator
  namespace: ${OLM_OPERATORS_NAMESPACE}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: ${name}
  source: ${source}
  sourceNamespace: openshift-marketplace
EOF
}

wait_for_operators() {
  infomsg "Waiting for Kiali, Tempo, and Service Mesh operators"
  wait_for_crd "kialis.kiali.io"
  wait_for_crd "tempostacks.tempo.grafana.com"
  wait_for_crd "istios.sailoperator.io"

  local dep
  echo -n "  operadores: "
  until dep="$("${OC}" get deployment -n "${OLM_OPERATORS_NAMESPACE}" -o name 2>/dev/null | grep -E 'kiali|sail|servicemesh|istio' | head -1)" && [[ -n "${dep}" ]]; do
    echo -n "."
    sleep 3
  done
  echo

  for dep in $("${OC}" get deployment -n "${OLM_OPERATORS_NAMESPACE}" -o name | grep -E 'kiali|sail|servicemesh|istio'); do
    "${OC}" wait --for=condition=Available --timeout=600s -n "${OLM_OPERATORS_NAMESPACE}" "${dep}"
  done

  echo -n "  tempo operator: "
  until dep="$("${OC}" get deployment -n "${TEMPO_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep tempo | head -1)" && [[ -n "${dep}" ]]; do
    echo -n "."
    sleep 3
  done
  echo
  for dep in $("${OC}" get deployment -n "${TEMPO_OPERATOR_NAMESPACE}" -o name | grep tempo); do
    "${OC}" wait --for=condition=Available --timeout=600s -n "${TEMPO_OPERATOR_NAMESPACE}" "${dep}"
  done

  # Webhooks Tempo
  echo -n "  webhooks tempo: "
  until [[ -n "$("${OC}" get validatingwebhookconfigurations -o name 2>/dev/null | grep tempo | head -1)" ]]; do echo -n "."; sleep 3; done
  until [[ -n "$("${OC}" get mutatingwebhookconfigurations -o name 2>/dev/null | grep tempo | head -1)" ]]; do echo -n "."; sleep 3; done
  echo " ready"
}

# --- Tempo (tracing backend) --------------------------------------------------

install_minio() {
  infomsg "Installing Minio in ${TEMPO_NAMESPACE}"
  "${OC}" get namespace "${TEMPO_NAMESPACE}" >/dev/null 2>&1 || "${OC}" create namespace "${TEMPO_NAMESPACE}"

  "${OC}" apply -n "${TEMPO_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pv-claim
  labels:
    app: minio
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 256Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  labels:
    app: minio
spec:
  selector:
    matchLabels:
      app: minio
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: minio
    spec:
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: minio-pv-claim
      initContainers:
      - name: create-buckets
        image: quay.io/jitesoft/alpine:latest
        command: ["sh", "-c", "mkdir -p /storage/tempo-data"]
        volumeMounts:
        - name: storage
          mountPath: /storage
      containers:
      - name: minio
        image: quay.io/minio/minio:latest
        args: ["server", "/storage", "--console-address", ":9001"]
        env:
        - name: MINIO_ROOT_USER
          value: "${MINIO_ACCESS_KEY_ID}"
        - name: MINIO_ROOT_PASSWORD
          value: "${MINIO_ACCESS_KEY_SECRET}"
        ports:
        - containerPort: 9000
        - containerPort: 9001
        volumeMounts:
        - name: storage
          mountPath: /storage
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  labels:
    app: minio
spec:
  type: ClusterIP
  ports:
  - port: 9000
    targetPort: 9000
    protocol: TCP
    name: api
  - port: 9001
    targetPort: 9001
    protocol: TCP
    name: console
  selector:
    app: minio
EOF

  "${OC}" delete secret -n "${TEMPO_NAMESPACE}" "${MINIO_SECRET_NAME}" --ignore-not-found
  "${OC}" create secret generic -n "${TEMPO_NAMESPACE}" "${MINIO_SECRET_NAME}" \
    --from-literal=bucket="${MINIO_BUCKET_NAME}" \
    --from-literal=endpoint="${MINIO_ENDPOINT}" \
    --from-literal=access_key_id="${MINIO_ACCESS_KEY_ID}" \
    --from-literal=access_key_secret="${MINIO_ACCESS_KEY_SECRET}"

  wait_for_deployment_ready "${TEMPO_NAMESPACE}" minio 300s
}

install_tempo_stack() {
  install_minio

  infomsg "Installing TempoStack in ${TEMPO_NAMESPACE}"
  "${OC}" apply -n "${TEMPO_NAMESPACE}" -f - <<EOF
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: tempo
spec:
  storageSize: 1Gi
  storage:
    secret:
      type: s3
      name: ${MINIO_SECRET_NAME}
  template:
    distributor:
      tls:
        enabled: false
    queryFrontend:
      jaegerQuery:
        enabled: true
        ingress:
          route:
            termination: edge
          type: route
EOF

  sleep 5
  wait_for_pods_ready "${TEMPO_NAMESPACE}" 600s
}

# --- Istio / OSSM control plane ----------------------------------------------

install_istio_cni() {
  local version="$1"
  if "${OC}" get istiocni default >/dev/null 2>&1; then
    infomsg "IstioCNI already exists; skipping"
    return
  fi
  "${OC}" get namespace istio-cni >/dev/null 2>&1 || "${OC}" create namespace istio-cni
  infomsg "Installing IstioCNI (version ${version})"
  "${OC}" apply -f - <<EOF
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  version: ${version}
  namespace: istio-cni
EOF
}

resolve_istio_version() {
  local version="${ISTIO_VERSION}"
  if [[ "${version}" == "latest" ]]; then
    version="$("${OC}" get crd istios.sailoperator.io -o json | jq -r '.spec.versions | sort_by(.name) | .[-1].schema.openAPIV3Schema.properties.spec.properties.version.default')"
    if [[ -z "${version}" || "${version}" == "null" ]]; then
      errormsg "Could not determine Istio version. Set ISTIO_VERSION=vX.Y.Z"
      exit 1
    fi
    infomsg "Detected Istio version: ${version}" >&2
  fi
  echo "${version}"
}

install_istio_control_plane() {
  local version
  version="$(resolve_istio_version)"

  # Additional mesh CRDs
  for crd in \
    authorizationpolicies.security.istio.io \
    destinationrules.networking.istio.io \
    gateways.networking.istio.io \
    istiocnis.sailoperator.io \
    peerauthentications.security.istio.io \
    virtualservices.networking.istio.io; do
    wait_for_crd "${crd}"
  done

  "${OC}" get namespace "${CONTROL_PLANE_NAMESPACE}" >/dev/null 2>&1 || "${OC}" create namespace "${CONTROL_PLANE_NAMESPACE}"

  install_istio_cni "${version}"

  infomsg "Installing Istio CR (OSSM) with tracing to Tempo"
  "${OC}" apply -f - <<EOF
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  version: ${version}
  namespace: ${CONTROL_PLANE_NAMESPACE}
  updateStrategy:
    type: RevisionBased
  profile: demo
  values:
    meshConfig:
      defaultConfig:
        tracing:
          zipkin:
            address: tempo-tempo-distributor.${TEMPO_NAMESPACE}:9411
EOF

  infomsg "Waiting for Istio control plane"
  local i=0
  until "${OC}" get pods -n "${CONTROL_PLANE_NAMESPACE}" -l app=istiod --no-headers 2>/dev/null | grep -q Running || [[ ${i} -ge 120 ]]; do
    echo -n "."
    sleep 5
    ((i++)) || true
  done
  echo
  wait_for_pods_ready "${CONTROL_PLANE_NAMESPACE}" 600s
}

# --- Addons (Prometheus, Grafana) ---------------------------------------------

create_addons_scc() {
  infomsg "Creating SCC for Istio addons"
  "${OC}" apply -f - <<EOF
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: istio-addons-scc
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: RunAsAny
supplementalGroups:
  type: RunAsAny
fsGroup:
  type: RunAsAny
seccompProfiles:
- '*'
priority: 9
users:
- system:serviceaccount:${CONTROL_PLANE_NAMESPACE}:default
- system:serviceaccount:${CONTROL_PLANE_NAMESPACE}:prometheus
- system:serviceaccount:${CONTROL_PLANE_NAMESPACE}:grafana
EOF
}

install_addon() {
  local addon="$1"
  local url="https://raw.githubusercontent.com/istio/istio/master/samples/addons/${addon}.yaml"
  local tmp
  tmp="$(mktemp)"
  download_to "${url}" "${tmp}"
  infomsg "Applying addon ${addon}"
  sed "s/istio-system/${CONTROL_PLANE_NAMESPACE}/g" "${tmp}" | "${OC}" apply -n "${CONTROL_PLANE_NAMESPACE}" -f -
  rm -f "${tmp}"
  "${OC}" expose service "${addon}" -n "${CONTROL_PLANE_NAMESPACE}" 2>/dev/null || true

  # Wait only for the addon deployment instead of all namespace pods.
  local i=0
  local dep=""
  until [[ ${i} -ge 60 ]]; do
    dep="$("${OC}" -n "${CONTROL_PLANE_NAMESPACE}" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk -v a="${addon}" '$0 ~ a {print; exit}')"
    if [[ -n "${dep}" ]]; then
      break
    fi
    sleep 2
    ((i++)) || true
  done
  if [[ -n "${dep}" ]]; then
    "${OC}" -n "${CONTROL_PLANE_NAMESPACE}" rollout status "deployment/${dep}" --timeout=600s || true
  fi
}

install_addons() {
  create_addons_scc
  if [[ -z "${ADDONS// }" ]]; then
    infomsg "No addons requested. Skipping addon installation."
    return
  fi
  for addon in ${ADDONS}; do
    install_addon "${addon}"
  done
}

# --- Kiali CR (tracing enabled) -----------------------------------------------

install_kiali_cr() {
  wait_for_crd "kialis.kiali.io"

  local tracing_url grafana_url grafana_enabled
  tracing_url="$("${OC}" get route -n "${TEMPO_NAMESPACE}" -l app.kubernetes.io/name=tempo,app.kubernetes.io/component=query-frontend -o jsonpath='https://{..spec.host}' 2>/dev/null || true)"
  grafana_url="$("${OC}" get route -n "${CONTROL_PLANE_NAMESPACE}" grafana -o jsonpath='http://{..spec.host}' 2>/dev/null || true)"
  if [[ " ${ADDONS} " == *" grafana "* ]]; then
    grafana_enabled="true"
  else
    grafana_enabled="false"
    grafana_url=""
  fi

  infomsg "Installing Kiali CR (Tempo tracing enabled)"
  "${OC}" apply -f - <<EOF
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
  namespace: ${CONTROL_PLANE_NAMESPACE}
spec:
  version: ${KIALI_VERSION}
  auth:
    strategy: openshift
  external_services:
    grafana:
      enabled: ${grafana_enabled}
      internal_url: http://grafana.${CONTROL_PLANE_NAMESPACE}:3000
      external_url: ${grafana_url}
      in_cluster_url: http://grafana.${CONTROL_PLANE_NAMESPACE}:3000
      url: ${grafana_url}
    tracing:
      enabled: true
      provider: tempo
      internal_url: http://tempo-tempo-query-frontend.${TEMPO_NAMESPACE}:3200
      external_url: ${tracing_url}
      in_cluster_url: http://tempo-tempo-query-frontend.${TEMPO_NAMESPACE}:3200
      url: ${tracing_url}
      use_grpc: false
EOF

  infomsg "Waiting for Kiali deployment/pod"
  local kiali_deployment=""
  local i=0
  until [[ ${i} -ge 120 ]]; do
    kiali_deployment="$("${OC}" -n "${CONTROL_PLANE_NAMESPACE}" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/^kiali$/ {print; exit}')"
    if [[ -n "${kiali_deployment}" ]]; then
      break
    fi
    sleep 5
    ((i++)) || true
  done

  if [[ -z "${kiali_deployment}" ]]; then
    errormsg "Kiali deployment was not created in namespace ${CONTROL_PLANE_NAMESPACE}"
    "${OC}" -n "${CONTROL_PLANE_NAMESPACE}" get kiali kiali -o yaml || true
    return 1
  fi

  "${OC}" -n "${CONTROL_PLANE_NAMESPACE}" rollout status "deployment/${kiali_deployment}" --timeout=600s
  wait_for_pods_ready "${CONTROL_PLANE_NAMESPACE}" 600s
}

# --- Bookinfo + traffic generator ---------------------------------------------

install_istio_ingress_gateway() {
  infomsg "Installing istio-ingressgateway in ${CONTROL_PLANE_NAMESPACE}"
  "${OC}" apply -n "${CONTROL_PLANE_NAMESPACE}" -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-ingressgateway
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: istio-ingressgateway-secret-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: secret-reader
subjects:
- kind: ServiceAccount
  name: istio-ingressgateway
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-ingressgateway
  labels:
    app: istio-ingressgateway
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  template:
    metadata:
      annotations:
        inject.istio.io/templates: gateway
      labels:
        app: istio-ingressgateway
        istio: ingressgateway
        sidecar.istio.io/inject: "true"
    spec:
      containers:
      - name: istio-proxy
        image: auto
      serviceAccountName: istio-ingressgateway
---
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
  labels:
    app: istio-ingressgateway
spec:
  type: LoadBalancer
  selector:
    istio: ingressgateway
  ports:
  - name: status-port
    port: 15021
    protocol: TCP
    targetPort: 15021
  - name: http
    port: 80
    protocol: TCP
    targetPort: 8080
  - name: https
    port: 443
    protocol: TCP
    targetPort: 443
EOF
}

install_bookinfo() {
  local rev tmp_bookinfo tmp_gateway
  rev="$(detect_istio_revision)"
  infomsg "Sidecar injection label: istio.io/rev=${rev}"

  if "${OC}" get namespace "${BOOKINFO_NS}" >/dev/null 2>&1; then
    infomsg "Namespace ${BOOKINFO_NS} already exists"
  else
    "${OC}" new-project "${BOOKINFO_NS}"
  fi

  "${OC}" apply -n "${BOOKINFO_NS}" -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: istio-cni
EOF

  tmp_bookinfo="$(mktemp)"
  tmp_gateway="$(mktemp)"
  download_to "https://raw.githubusercontent.com/istio/istio/${ISTIO_BOOKINFO_BRANCH}/samples/bookinfo/platform/kube/bookinfo.yaml" "${tmp_bookinfo}"
  download_to "https://raw.githubusercontent.com/istio/istio/${ISTIO_BOOKINFO_BRANCH}/samples/bookinfo/networking/bookinfo-gateway.yaml" "${tmp_gateway}"

  "${OC}" label namespace "${BOOKINFO_NS}" "istio.io/rev=${rev}" --overwrite
  install_istio_ingress_gateway
  "${OC}" apply -n "${BOOKINFO_NS}" -f "${tmp_bookinfo}"
  "${OC}" apply -n "${BOOKINFO_NS}" -f "${tmp_gateway}"
  rm -f "${tmp_bookinfo}" "${tmp_gateway}"

  # Ensure sidecars are injected when the namespace already existed.
  "${OC}" -n "${BOOKINFO_NS}" rollout restart deployment --all >/dev/null 2>&1 || true
  "${OC}" -n "${BOOKINFO_NS}" rollout status deployment --all --timeout=600s || true

  "${OC}" expose svc/productpage -n "${BOOKINFO_NS}" 2>/dev/null || true
  "${OC}" expose svc/istio-ingressgateway --port http -n "${CONTROL_PLANE_NAMESPACE}" --name=istio-ingressgateway 2>/dev/null || true

  infomsg "Waiting for Bookinfo pods"
  wait_for_pods_ready "${BOOKINFO_NS}" 600s
}

install_traffic_generator() {
  local ingress_route=""
  infomsg "Installing Kiali Traffic Generator"

  "${OC}" wait --for=jsonpath='{.status.ingress[].host}' --timeout=60s route istio-ingressgateway -n "${CONTROL_PLANE_NAMESPACE}" 2>/dev/null || true
  ingress_route="$("${OC}" get route istio-ingressgateway -o jsonpath='{.spec.host}{"\n"}' -n "${CONTROL_PLANE_NAMESPACE}" 2>/dev/null || true)"

  if [[ -z "${ingress_route}" ]]; then
    "${OC}" wait --for=jsonpath='{.status.ingress[].host}' --timeout=60s route productpage -n "${BOOKINFO_NS}" 2>/dev/null || true
    ingress_route="$("${OC}" get route productpage -o jsonpath='{.spec.host}{"\n"}' -n "${BOOKINFO_NS}" 2>/dev/null || true)"
  fi

  if [[ -z "${ingress_route}" ]]; then
    errormsg "No route found for traffic generator; using internal productpage endpoint"
    ingress_route="productpage.${BOOKINFO_NS}.svc.cluster.local:9080"
  else
    infomsg "Traffic generator will use: http://${ingress_route}/productpage"
  fi

  "${OC}" adm policy add-scc-to-user anyuid -z default -n "${BOOKINFO_NS}" 2>/dev/null || true

  export DURATION='0s'
  export ROUTE="http://${ingress_route}/productpage"
  export RATE="${TRAFFIC_RATE}"

  curl --silent --fail --location \
    https://raw.githubusercontent.com/kiali/kiali-test-mesh/master/traffic-generator/openshift/traffic-generator-configmap.yaml \
    | envsubst | "${OC}" apply -n "${BOOKINFO_NS}" -f -

  curl --silent --fail --location \
    https://raw.githubusercontent.com/kiali/kiali-test-mesh/master/traffic-generator/openshift/traffic-generator.yaml \
    | "${OC}" apply --validate=false -n "${BOOKINFO_NS}" -f -
}

# --- EAP preconditions (setup-bookinfo-preconditions.sh) ---------------------

apply_eap_preconditions() {
  infomsg "Applying EAP preconditions in ${BOOKINFO_NS}"

  "${OC}" -n "${BOOKINFO_NS}" delete virtualservice ratings destinationrule ratings -l "${LABEL}" --ignore-not-found >/dev/null 2>&1 || true

  "${OC}" apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: ${BOOKINFO_NS}
  labels:
    ${LABEL_KEY}: ${LABEL_VAL}
spec:
  host: reviews.${BOOKINFO_NS}.svc.cluster.local
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
  namespace: ${BOOKINFO_NS}
  labels:
    ${LABEL_KEY}: ${LABEL_VAL}
spec:
  host: details.${BOOKINFO_NS}.svc.cluster.local
  subsets:
  - name: v1
    labels:
      version: v1
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: ${BOOKINFO_NS}
  labels:
    ${LABEL_KEY}: ${LABEL_VAL}
spec:
  hosts:
  - reviews.${BOOKINFO_NS}.svc.cluster.local
  http:
  - route:
    - destination:
        host: reviews.${BOOKINFO_NS}.svc.cluster.local
        subset: v1
      weight: 100
    - destination:
        host: reviews.${BOOKINFO_NS}.svc.cluster.local
        subset: v2
      weight: 0
    - destination:
        host: reviews.${BOOKINFO_NS}.svc.cluster.local
        subset: v3
      weight: 0
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: details
  namespace: ${BOOKINFO_NS}
  labels:
    ${LABEL_KEY}: ${LABEL_VAL}
spec:
  hosts:
  - details.${BOOKINFO_NS}.svc.cluster.local
  http:
  - route:
    - destination:
        host: details.${BOOKINFO_NS}.svc.cluster.local
        subset: v1
      weight: 100
    fault:
      abort:
        percentage:
          value: 100
        httpStatus: 503
EOF

  if [[ "${GENERATE_TRAFFIC}" == "1" ]]; then
    local job="eap-bookinfo-traffic"
    "${OC}" -n "${BOOKINFO_NS}" delete job "${job}" --ignore-not-found >/dev/null 2>&1 || true
    "${OC}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${BOOKINFO_NS}
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
              http://productpage.${BOOKINFO_NS}.svc.cluster.local:9080/productpage || true
            sleep 1
          done
EOF
  else
    infomsg "Skipping EAP traffic Job (GENERATE_TRAFFIC=${GENERATE_TRAFFIC})"
  fi
}

# --- Final summary -------------------------------------------------------------

print_summary() {
  local kiali_url tempo_url grafana_url console_url
  kiali_url="$("${OC}" get route -n "${CONTROL_PLANE_NAMESPACE}" -l app.kubernetes.io/name=kiali -o jsonpath='https://{..spec.host}{"\n"}' 2>/dev/null || true)"
  tempo_url="$("${OC}" get route -n "${TEMPO_NAMESPACE}" -l app.kubernetes.io/name=tempo,app.kubernetes.io/component=query-frontend -o jsonpath='https://{..spec.host}{"\n"}' 2>/dev/null || true)"
  grafana_url="$("${OC}" get route -n "${CONTROL_PLANE_NAMESPACE}" grafana -o jsonpath='http://{..spec.host}{"\n"}' 2>/dev/null || true)"
  console_url="$("${OC}" get console cluster -o jsonpath='{.status.consoleURL}' 2>/dev/null || true)"

  cat <<EOF

================================================================================
EAP installation completed.

Operators (Software Catalog: ${CATALOG_SOURCE}):
  - Service Mesh (OSSM/Sail)
  - Kiali
  - Tempo

Mesh:
  - Control plane: ${CONTROL_PLANE_NAMESPACE}
  - Tracing: Tempo (${TEMPO_NAMESPACE})
  - Addons: ${ADDONS}

Kiali (tracing enabled):
  ${kiali_url:-  (route not available yet)}

Tempo / Jaeger UI:
  ${tempo_url:-  (route not available yet)}

Grafana:
  ${grafana_url:-  (route not available yet)}

Bookinfo:
  - Namespace: ${BOOKINFO_NS}
  - Traffic generator: $([[ "${ENABLE_TRAFFIC_GENERATOR}" == "1" ]] && echo enabled || echo disabled)

EAP preconditions (MCP scenarios):
  [4]  VirtualService/reviews — v3 weight = 0
  [5]  VirtualService/details — fault.abort HTTP 503 @ 100%
  [10-11] EAP traffic Job: $([[ "${GENERATE_TRAFFIC}" == "1" ]] && echo enabled || echo skipped)

EAP preconditions cleanup (without uninstalling Bookinfo):
  $(dirname "$0")/cleanup-bookinfo-preconditions.sh
================================================================================
EOF
}

# --- Main ----------------------------------------------------------------------

run_install() {
  preflight

  infomsg "=== Phase 1/6: OLM operators (Software Catalog) ==="
  install_kiali_operator
  install_tempo_operator
  install_servicemesh_operator
  wait_for_operators

  infomsg "=== Phase 2/6: Tempo (tracing backend) ==="
  install_tempo_stack

  infomsg "=== Phase 3/6: OSSM / Istio control plane ==="
  install_istio_control_plane

  infomsg "=== Phase 4/6: Addons ==="
  install_addons

  infomsg "=== Phase 5/6: Kiali ==="
  install_kiali_cr

  infomsg "=== Phase 6/6: Bookinfo + EAP preconditions ==="
  install_bookinfo
  if [[ "${ENABLE_TRAFFIC_GENERATOR}" == "1" ]]; then
    install_traffic_generator
  fi
  apply_eap_preconditions

  print_summary
}

main() {
  parse_args "$@"
  if [[ "${MODE}" == "delete" ]]; then
    run_delete
  else
    run_install
  fi
}

main "$@"
