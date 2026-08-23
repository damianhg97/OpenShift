#!/usr/bin/env bash
# =============================================================================
# Deploy script – Camunda 8 Self-Managed trên OpenShift Developer Sandbox
# Project: Kevin Bank - Banking Platform
# Namespace: khoadghg97-dev
# =============================================================================
# Prerequisites:
#   - oc login đã thực hiện
#   - Helm 3 đã cài
#   - PostgreSQL (postgres), Keycloak (keycloak) đã chạy trong namespace
#   - Secret postgres-secret và keycloak-secret đã tồn tại
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-khoadghg97-dev}"
HELM_RELEASE="${HELM_RELEASE:-camunda}"
# Chart version tương ứng Camunda 8.6.x (kiểm tra helm search repo camunda/camunda-platform)
CHART_VERSION="${CHART_VERSION:-11.3.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo " Camunda 8 Deploy – Kevin Bank"
echo " Namespace : ${NAMESPACE}"
echo " Release   : ${HELM_RELEASE}"
echo " Chart ver : ${CHART_VERSION}"
echo "=============================================="

# -----------------------------------------------------------------------------
# 0. Kiểm tra context
# -----------------------------------------------------------------------------
echo ""
echo "==> [0/8] Checking OpenShift context..."
oc project "${NAMESPACE}" >/dev/null
echo "    Current project: $(oc project -q)"

# -----------------------------------------------------------------------------
# 1. Deploy Elasticsearch
# -----------------------------------------------------------------------------
echo ""
echo "==> [1/8] Deploying Elasticsearch + Dashboards..."
oc apply -f "${SCRIPT_DIR}/elasticsearch-kibana.yaml"
echo "    Waiting for Elasticsearch pod ready (timeout 5m)..."
oc wait --for=condition=available deployment/elasticsearch \
  -n "${NAMESPACE}" --timeout=300s || {
  echo "WARNING: Elasticsearch chưa ready. Kiểm tra logs:"
  echo "  oc logs -l app.kubernetes.io/name=opensearch -n ${NAMESPACE}"
}

# -----------------------------------------------------------------------------
# 2. Tạo PostgreSQL schema / database
# -----------------------------------------------------------------------------
echo ""
echo "==> [2/8] Creating PostgreSQL schema & identity database..."
# Xóa job cũ nếu có để chạy lại
oc delete job camunda-postgres-schema -n "${NAMESPACE}" --ignore-not-found=true
oc apply -f "${SCRIPT_DIR}/camunda-postgres-schema.yaml"
echo "    Waiting for schema job to complete..."
oc wait --for=condition=complete job/camunda-postgres-schema \
  -n "${NAMESPACE}" --timeout=180s || {
  echo "ERROR: Schema job failed. Logs:"
  oc logs job/camunda-postgres-schema -n "${NAMESPACE}" || true
  exit 1
}

# -----------------------------------------------------------------------------
# 3. Tạo Keycloak client
# -----------------------------------------------------------------------------
echo ""
echo "==> [3/8] Creating Keycloak client 'camunda' in realm 'banking'..."
oc delete job camunda-keycloak-client -n "${NAMESPACE}" --ignore-not-found=true
oc apply -f "${SCRIPT_DIR}/camunda-keycloak-client.yaml"
echo "    Waiting for Keycloak client job..."
oc wait --for=condition=complete job/camunda-keycloak-client \
  -n "${NAMESPACE}" --timeout=300s || {
  echo "WARNING: Keycloak client job failed hoặc timeout."
  echo "  Kiểm tra secret keycloak-secret và logs:"
  echo "  oc logs job/camunda-keycloak-client -n ${NAMESPACE}"
  echo "  Bạn có thể tạo client thủ công trên Keycloak Admin Console."
}

# -----------------------------------------------------------------------------
# 4. Tạo Secret cho Identity client secrets
# -----------------------------------------------------------------------------
echo ""
echo "==> [4/8] Applying Camunda Identity secrets..."
oc apply -f "${SCRIPT_DIR}/camunda-identity-secret.yaml"

# -----------------------------------------------------------------------------
# 5. Deploy Camunda Helm chart
# -----------------------------------------------------------------------------
echo ""
echo "==> [5/8] Installing / upgrading Camunda Helm chart..."
helm repo add camunda https://helm.camunda.io 2>/dev/null || true
helm repo update

# Kiểm tra values file
if [ ! -f "${SCRIPT_DIR}/camunda-values.yaml" ]; then
  echo "ERROR: camunda-values.yaml not found"
  exit 1
fi

# Lưu ý: Cập nhật publicIssuerUrl / redirectUrl trong values trước khi chạy
# nếu domain Keycloak / Operate đã biết.

helm upgrade --install "${HELM_RELEASE}" camunda/camunda-platform \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  -f "${SCRIPT_DIR}/camunda-values.yaml" \
  --timeout 15m \
  --wait=false

echo "    Helm release applied. Waiting for pods (có thể mất 5–10 phút)..."

# -----------------------------------------------------------------------------
# 6. Đợi pods ready (best-effort)
# -----------------------------------------------------------------------------
echo ""
echo "==> [6/8] Waiting for Camunda pods..."
# Zeebe thường lâu nhất
for deploy in zeebe operate tasklist identity connectors zeebe-gateway; do
  FULL_NAME="${HELM_RELEASE}-${deploy}"
  if oc get deployment "${FULL_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "    Waiting for ${FULL_NAME}..."
    oc rollout status deployment/"${FULL_NAME}" -n "${NAMESPACE}" --timeout=300s || \
      echo "    WARNING: ${FULL_NAME} chưa ready"
  fi
done

# -----------------------------------------------------------------------------
# 7. Tạo OpenShift Routes
# -----------------------------------------------------------------------------
echo ""
echo "==> [7/8] Creating OpenShift Routes..."
oc apply -f "${SCRIPT_DIR}/camunda-routes.yaml"

# -----------------------------------------------------------------------------
# 8. Kiểm tra kết quả
# -----------------------------------------------------------------------------
echo ""
echo "==> [8/8] Summary"
echo "----------------------------------------------"
echo "Pods:"
oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/part-of=banking-platform 2>/dev/null || \
  oc get pods -n "${NAMESPACE}" | grep -E 'camunda|opensearch|zeebe|operate|tasklist|identity' || true

echo ""
echo "Services:"
oc get svc -n "${NAMESPACE}" | grep -E 'camunda|opensearch' || true

echo ""
echo "Routes:"
oc get route -n "${NAMESPACE}" | grep -E 'camunda|opensearch' || true

echo ""
echo "=============================================="
echo " Deploy finished."
echo ""
echo " Next steps:"
echo "  1. Cập nhật publicIssuerUrl + redirectUrl trong camunda-values.yaml"
echo "     cho khớp với Route Keycloak / Operate thực tế."
echo "  2. helm upgrade ${HELM_RELEASE} camunda/camunda-platform -n ${NAMESPACE} -f camunda-values.yaml"
echo "  3. Truy cập Operate / Tasklist qua Route."
echo "  4. Kiểm tra logs nếu pod CrashLoop:"
echo "       oc logs -f deploy/${HELM_RELEASE}-zeebe -n ${NAMESPACE}"
echo "=============================================="
