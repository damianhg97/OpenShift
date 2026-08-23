# Camunda 8 Self-Managed – Deploy trên OpenShift (Kevin Bank)

Bộ file deploy Camunda 8 Self-Managed (Helm) trên **OpenShift Developer Sandbox**, dùng chung namespace `khoadghg97-dev` với các dependency external đã có sẵn.

## Kiến trúc đã chốt

| Component | Cách triển khai | Ghi chú |
|-----------|-----------------|---------|
| Zeebe / Operate / Tasklist / Identity / Connectors | Helm chart `camunda/camunda-platform` | Version 8.6.x (chart ~11.x) |
| PostgreSQL | External (`postgres:5432`) | Schema `camunda` + DB `identity` |
| Keycloak | External (`keycloak:8080`) | Realm `banking`, client `camunda` |
| OpenSearch | Deploy riêng (file YAML) | Secondary storage, security plugin tắt |
| Routes | OpenShift Route (edge + Redirect) | Operate, Tasklist, Identity |

**Không** deploy PostgreSQL / Keycloak / Elasticsearch nội bộ của Helm chart.

## Danh sách file

```
camunda-deploy/
├── opensearch-deployment.yaml      # Phase 1 – OpenSearch + Dashboards
├── camunda-postgres-schema.yaml    # Phase 2 – Job tạo schema/DB
├── camunda-keycloak-client.yaml    # Phase 3 – Job tạo client Keycloak
├── camunda-identity-secret.yaml    # Secret client secrets cho Identity
├── camunda-values.yaml             # Phase 4 – Helm values
├── camunda-routes.yaml             # Phase 5 – OpenShift Routes
├── deploy-camunda.sh               # Phase 6 – Script deploy tuần tự
└── README.md
```

## Prerequisites

1. Đã `oc login` vào cluster và project `khoadghg97-dev`.
2. Các service sau đã chạy:
   - `postgres:5432` (DB `banking`, user `banking`)
   - `keycloak:8080` (realm `banking`)
3. Secrets đã tồn tại:
   - `postgres-secret` (key `password`)
   - `keycloak-secret` (key `KEYCLOAK_ADMIN` + `KEYCLOAK_ADMIN_PASSWORD`, hoặc `admin-password`)
4. Helm 3 đã cài.

Nếu tên secret/key khác, sửa `secretKeyRef` trong:
- `camunda-postgres-schema.yaml`
- `camunda-keycloak-client.yaml`
- `camunda-values.yaml`

## Cách deploy (khuyến nghị)

```bash
cd camunda-deploy
./deploy-camunda.sh
```

Script thực hiện đúng thứ tự dependency:

1. Deploy OpenSearch → đợi ready  
2. Job tạo schema PostgreSQL  
3. Job tạo Keycloak client `camunda`  
4. Apply Identity secret  
5. `helm upgrade --install` Camunda  
6. Đợi pods (best-effort)  
7. Tạo Routes  
8. In summary  

### Deploy thủ công từng bước

```bash
# 1. OpenSearch
oc apply -f opensearch-deployment.yaml
oc wait --for=condition=available deployment/opensearch --timeout=300s

# 2. Schema
oc delete job camunda-postgres-schema --ignore-not-found
oc apply -f camunda-postgres-schema.yaml
oc wait --for=condition=complete job/camunda-postgres-schema --timeout=180s

# 3. Keycloak client
oc delete job camunda-keycloak-client --ignore-not-found
oc apply -f camunda-keycloak-client.yaml
oc wait --for=condition=complete job/camunda-keycloak-client --timeout=300s

# 4. Secrets
oc apply -f camunda-identity-secret.yaml

# 5. Helm
helm repo add camunda https://helm.camunda.io
helm repo update
helm upgrade --install camunda camunda/camunda-platform \
  --namespace khoadghg97-dev \
  --version 11.3.0 \
  -f camunda-values.yaml

# 6. Routes
oc apply -f camunda-routes.yaml
```

## Cấu hình quan trọng cần chỉnh sau deploy

### 1. publicIssuerUrl & redirectUrl

Trong `camunda-values.yaml`, thay domain placeholder bằng hostname thực tế từ Route:

```bash
oc get route -n khoadghg97-dev
```

Ví dụ:

```yaml
global:
  identity:
    auth:
      publicIssuerUrl: "https://keycloak-khoadghg97-dev.apps.xxxx.openshiftapps.com/realms/banking"
      operate:
        redirectUrl: "https://camunda-operate-khoadghg97-dev.apps.xxxx.openshiftapps.com/operate"
      tasklist:
        redirectUrl: "https://camunda-tasklist-khoadghg97-dev.apps.xxxx.openshiftapps.com/tasklist"
```

Sau đó:

```bash
helm upgrade camunda camunda/camunda-platform -n khoadghg97-dev -f camunda-values.yaml
```

### 2. Keycloak client redirect URIs

Trên Keycloak Admin Console (realm `banking` → client `camunda`):

- Valid redirect URIs: `https://camunda-*-khoadghg97-dev.apps.../*`
- Web origins: `+` hoặc domain cụ thể

### 3. Secret Keycloak admin

Nếu Job Keycloak client fail vì secret key khác, sửa:

```yaml
# camunda-keycloak-client.yaml
secretKeyRef:
  name: keycloak-secret   # tên secret thực tế
  key: KEYCLOAK_ADMIN_PASSWORD  # hoặc admin-password / password
```

## Resource footprint (Sandbox)

| Component | CPU request | Memory request |
|-----------|-------------|----------------|
| OpenSearch | 500m | 1Gi |
| OpenSearch Dashboards | 200m | 512Mi |
| Zeebe | 200m | 800Mi |
| Operate / Tasklist | 200m mỗi cái | 512Mi |
| Identity / Connectors / Gateway | 100–200m | 256–512Mi |

Tổng khoảng **~2–3 CPU / 5–6 Gi** – vừa với quota Sandbox nếu các service khác không quá nặng.

## Troubleshooting nhanh

| Triệu chứng | Hành động |
|-------------|-----------|
| OpenSearch CrashLoop | `oc logs deploy/opensearch` – thường do OOM hoặc permission. Giảm `OPENSEARCH_JAVA_OPTS` xuống `-Xms256m -Xmx256m` |
| Schema job fail | Kiểm tra `postgres-secret` key `password` và network tới `postgres:5432` |
| Keycloak client job fail | Kiểm tra admin password + realm `banking` đã tồn tại |
| Operate/Tasklist không login | Cập nhật `publicIssuerUrl` + redirect URI trên Keycloak |
| Zeebe không export | Kiểm tra `http://opensearch:9200/_cluster/health` từ pod Zeebe |

## Lưu ý

- OpenSearch dùng **emptyDir** → data mất khi pod restart (phù hợp Sandbox).
- Security plugin OpenSearch **tắt** → chỉ dùng nội bộ cluster, không expose public.
- Phase tích hợp Job Worker (sửa code customer-service) làm sau – bộ file này chỉ infrastructure + Camunda.
- Version chart: kiểm tra `helm search repo camunda/camunda-platform --versions` để chọn bản mới nhất 8.6.x.
