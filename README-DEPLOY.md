# Banking Platform – Hướng dẫn deploy thủ công theo thứ tự

Bộ manifest được tổ chức để **deploy từng thành phần một**, dùng **ConfigMap + Secret** nên đổi cấu hình (URL, CORS, Keycloak issuer…) **không cần rebuild container**.

```
manifests/
├── 00-namespace.yaml
├── 01-postgresql/          # Bước 1
├── 02-keycloak/            # Bước 2
├── 03-customer-service/    # Bước 3
├── 04-ui/                  # Bước 4
└── README-DEPLOY.md
```

Namespace mặc định: `khoadghg97-dev`.

---

## Chuẩn bị trước khi deploy

1. Đổi mật khẩu trong các file Secret:
   - `01-postgresql/postgres-secret.yaml`
   - `02-keycloak/keycloak-secret.yaml`
   - `03-customer-service/customer-service-secret.yaml`

2. Kiểm tra `storageClassName` trong `postgres-pvc.yaml` (hiện là `gp3`).

3. (Sau khi có Route thật) cập nhật ConfigMap:
   - `02-keycloak/keycloak-configmap.yaml` (nếu cần `KC_HOSTNAME`)
   - `03-customer-service/customer-service-configmap.yaml` → `APP_OIDC_ISSUER_URI`, `APP_CORS_ALLOWED_ORIGIN`
   - `04-ui/ui-configmap.yaml` → `KEYCLOAK_URL`, `API_UPSTREAM` (thường giữ internal service)

---

## Thứ tự deploy thủ công

### Bước 0 – Namespace

```bash
oc apply -f 00-namespace.yaml
# hoặc: kubectl apply -f 00-namespace.yaml
```

### Bước 1 – PostgreSQL

```bash
oc apply -f 01-postgresql/postgres-secret.yaml
oc apply -f 01-postgresql/postgres-pvc.yaml
oc apply -f 01-postgresql/postgres-service.yaml
oc apply -f 01-postgresql/postgres-deployment.yaml
```

Chờ Postgres ready:

```bash
oc -n khoadghg97-dev rollout status deployment/postgres --timeout=120s
oc -n khoadghg97-dev get pods -l app=postgres
```

### Bước 2 – Keycloak

```bash
# Secret + ConfigMap
oc apply -f 02-keycloak/keycloak-secret.yaml
oc apply -f 02-keycloak/keycloak-configmap.yaml

# Tạo schema keycloak trong DB banking
oc apply -f 02-keycloak/keycloak-db-init-job.yaml
oc -n khoadghg97-dev wait --for=condition=complete job/keycloak-db-init --timeout=120s

# Service + Deployment + Route
oc apply -f 02-keycloak/keycloak-service.yaml
oc apply -f 02-keycloak/keycloak-route.yaml
oc apply -f 02-keycloak/keycloak-deployment.yaml
```

Chờ Keycloak ready:

```bash
oc -n khoadghg97-dev rollout status deployment/keycloak --timeout=300s
oc -n khoadghg97-dev get route keycloak -o jsonpath='{.spec.host}{"\n"}'
```

Sau khi có host thật, **cập nhật** ConfigMap customer-service & UI (issuer URI, KEYCLOAK_URL) rồi apply lại.

### Bước 3 – Customer Service

```bash
oc apply -f 03-customer-service/customer-service-secret.yaml
oc apply -f 03-customer-service/customer-service-configmap.yaml
oc apply -f 03-customer-service/customer-service-service.yaml
oc apply -f 03-customer-service/customer-service-route.yaml
oc apply -f 03-customer-service/customer-service-deployment.yaml

```

Chờ:

```bash
oc -n khoadghg97-dev rollout status deployment/customer-service --timeout=180s
oc -n khoadghg97-dev get route customer-service -o jsonpath='{.spec.host}{"\n"}'
```

### Bước 4 – Corporate Banking UI

```bash
# Cập nhật KEYCLOAK_URL / API_UPSTREAM trong ConfigMap trước nếu cần
oc apply -f 04-ui/ui-configmap.yaml
oc apply -f 04-ui/ui-service.yaml
oc apply -f 04-ui/ui-route.yaml
oc apply -f 04-ui/ui-deployment.yaml

```

Chờ:

```bash
oc -n khoadghg97-dev rollout status deployment/corporate-banking-ui --timeout=60s
oc -n khoadghg97-dev get route corporate-banking-ui -o jsonpath='{.spec.host}{"\n"}'
```

Sau khi có UI route, **cập nhật** `APP_CORS_ALLOWED_ORIGIN` trong customer-service ConfigMap và apply lại Deployment (hoặc `oc set env` / restart).

---

## Đổi cấu hình không rebuild image

| Thành phần        | File ConfigMap                          | Biến quan trọng                                      |
|-------------------|-----------------------------------------|------------------------------------------------------|
| Keycloak          | `02-keycloak/keycloak-configmap.yaml`   | KC_DB_URL, KC_HOSTNAME_STRICT, KC_PROXY_HEADERS      |
| Customer Service  | `03-customer-service/...-configmap.yaml`| APP_OIDC_ISSUER_URI, APP_CORS_ALLOWED_ORIGIN, DB URL |
| UI                | `04-ui/ui-configmap.yaml`               | KEYCLOAK_URL, KEYCLOAK_REALM, KEYCLOAK_CLIENT_ID, API_UPSTREAM |

Sau khi sửa ConfigMap:

```bash
oc apply -f <path-to-configmap.yaml>
# Restart pod để nhận config mới (ConfigMap không auto-reload vào env)
oc -n khoadghg97-dev rollout restart deployment/<name>
```

UI dùng entrypoint `40-runtime-config.sh` → mỗi lần start pod sẽ generate lại `config.json` và nginx.conf từ env.

---

## Kiểm tra nhanh

```bash
oc -n khoadghg97-dev get all,route,pvc,secret,configmap
oc -n khoadghg97-dev logs -l app=customer-service --tail=50
oc -n khoadghg97-dev logs -l app=keycloak --tail=50
```

---

## Ghi chú

- Keycloak dùng **schema `keycloak`** trong database `banking` (không tạo DB riêng).
- Job `keycloak-db-init` chỉ cần chạy 1 lần (hoặc mỗi khi xóa PVC).
- Image UI placeholder: `docker.io/kevinhg97/banking-platform-ui:latest` – thay bằng image thật sau khi build & push.
- Tất cả Secret dùng `stringData` để dễ đọc; production nên dùng External Secrets / Sealed Secrets.
