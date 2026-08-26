# Camunda 8.9 trên OpenShift Developer Sandbox

Hướng dẫn cài đặt và sử dụng **Camunda 8.9** (Helm chart 14.x) trên OpenShift Developer Sandbox.

**Namespace:** `khoadghg97-dev`

---

## Mục lục

1. [Yêu cầu](#1-yêu-cầu)
2. [Cấu trúc thư mục](#2-cấu-trúc-thư-mục)
3. [Dọn dẹp (nếu cài lại)](#3-dọn-dẹp-nếu-cài-lại)
4. [Cài đặt](#4-cài-đặt)
5. [Truy cập ứng dụng](#5-truy-cập-ứng-dụng)
6. [Giải thích từng ứng dụng](#6-giải-thích-từng-ứng-dụng)
7. [Tài khoản mặc định](#7-tài-khoản-mặc-định)
8. [Kiểm tra & Debug](#8-kiểm-tra--debug)
9. [Lưu ý quan trọng](#9-lưu-ý-quan-trọng)

---

## 1. Yêu cầu

- OpenShift CLI (`oc`) đã login vào Developer Sandbox
- Helm 3.x trở lên
- Namespace: `khoadghg97-dev`

```bash
oc project khoadghg97-dev
helm version
```

---

## 2. Cấu trúc thư mục

```
08-camunda/
├── camunda-credentials.yaml   # Secret chứa password & token
├── camunda-routes.yaml        # Route OpenShift
├── values-sandbox.yaml        # Helm values cho Sandbox
└── README.md
```

---

## 3. Dọn dẹp (nếu cài lại)

```bash
oc project khoadghg97-dev

# Xóa Helm release
helm uninstall camunda -n khoadghg97-dev || true

# Xóa PVC
oc delete pvc --all -n khoadghg97-dev || true

# Xóa Secret & Route
oc delete secret camunda-credentials -n khoadghg97-dev || true
oc delete route camunda-orchestration camunda-identity camunda-keycloak -n khoadghg97-dev || true
```

---

## 4. Cài đặt

### Bước 1: Tạo Secret

```bash
oc apply -f camunda-credentials.yaml
```

### Bước 2: Cài Camunda bằng Helm

```bash
helm repo add camunda https://helm.camunda.io
helm repo update

helm upgrade --install camunda camunda/camunda-platform \
  --version 14.8.5 \
  --namespace khoadghg97-dev \
  -f values-sandbox.yaml \
  --timeout 20m
```

### Bước 3: Đợi Pod sẵn sàng

```bash
oc get pods -w
```

Các pod cần ở trạng thái `Running` và `Ready`:

- `camunda-elasticsearch-master-0`
- `camunda-zeebe-0`
- `camunda-identity-...`
- `camunda-keycloak-0`
- `camunda-identity-postgresql-0`
- `camunda-postgresql-0` (nếu có)

### Bước 4: Tạo Route

```bash
oc apply -f camunda-routes.yaml
```

Kiểm tra:

```bash
oc get route | grep camunda
```

---

## 5. Truy cập ứng dụng

| Ứng dụng   | URL                                                                                      | Tài khoản      |
|------------|------------------------------------------------------------------------------------------|----------------|
| **Operate**    | https://camunda-orchestration-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com/operate  | demo / demo    |
| **Tasklist**   | https://camunda-orchestration-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com/tasklist | demo / demo    |
| **Admin**      | https://camunda-orchestration-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com/admin    | demo / demo    |
| **Identity**   | https://camunda-identity-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com               | demo / demo    |
| **Keycloak**   | https://camunda-keycloak-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com               | admin / admin123 |

> **Lưu ý:** Từ Camunda 8.8+, Operate + Tasklist + Admin được gộp chung trong **Orchestration Cluster** (pod `camunda-zeebe`). Không còn pod riêng `operate` / `tasklist`.

---

## 6. Giải thích từng ứng dụng

| Ứng dụng     | Mục đích chính                                      | Khi nào dùng                                      |
|--------------|-----------------------------------------------------|---------------------------------------------------|
| **Operate**  | Theo dõi process instance, xử lý incident           | Xem process chạy đến đâu, sửa lỗi runtime         |
| **Tasklist** | Làm User Task (công việc của con người)             | Duyệt đơn, nhập liệu, hoàn thành task             |
| **Admin**    | Quản trị Orchestration Cluster (user/role nội bộ)   | Quản lý quyền truy cập Operate/Tasklist/API       |
| **Identity** | Quản lý User – Role – Permission toàn hệ thống      | Tạo user mới, phân quyền, multi-tenant            |
| **Keycloak** | Identity Provider (OIDC) – nơi xác thực thực sự     | Cấu hình SSO, client, password policy, realm      |

### Luồng sử dụng thường gặp

1. Vào **Identity** → tạo user / gán role  
2. User đăng nhập **Operate** để theo dõi process  
3. User đăng nhập **Tasklist** để làm task  
4. Khi có lỗi → vào **Operate** xem và xử lý incident  
5. Chỉ vào **Keycloak** khi cần cấu hình xác thực sâu (SSO, LDAP…)

---

## 7. Tài khoản mặc định

| Thành phần              | Username | Password   | Ghi chú                          |
|-------------------------|----------|------------|----------------------------------|
| Operate / Tasklist / Admin / Identity | `demo`   | `demo`     | User Camunda (từ secret)         |
| Keycloak Admin Console  | `admin`  | `admin123` | Admin của Keycloak               |

Mật khẩu được lưu trong Secret `camunda-credentials`.

Lấy lại password demo:

```bash
oc get secret camunda-credentials -n khoadghg97-dev \
  -o jsonpath='{.data.identity-firstuser-password}' | base64 -d
echo
```

---

## 8. Kiểm tra & Debug

### Xem trạng thái

```bash
oc get pods
oc get svc
oc get route | grep camunda
oc get pvc
```

### Xem log

```bash
oc logs -f camunda-zeebe-0
oc logs -f deploy/camunda-identity
oc logs -f camunda-keycloak-0
```

### Port-forward (nếu Route lỗi)

```bash
# Orchestration (Operate / Tasklist / Admin)
oc port-forward svc/camunda-zeebe-gateway 8080:8080 -n khoadghg97-dev

# Identity
oc port-forward svc/camunda-identity 8084:80 -n khoadghg97-dev

# Keycloak
oc port-forward svc/camunda-keycloak 18080:80 -n khoadghg97-dev
```

Sau đó truy cập:
- http://localhost:8080/operate
- http://localhost:8080/tasklist
- http://localhost:8080/admin
- http://localhost:8084
- http://localhost:18080

### Kiểm tra API

```bash
curl -u demo:demo http://localhost:8080/v2/topology
```

---

## 9. Lưu ý quan trọng

1. **Developer Sandbox** có giới hạn resource rất thấp → chỉ chạy 1 broker Zeebe, tắt Optimize / Web Modeler / Console / Connectors.
2. Từ **Camunda 8.9**, Helm **không tự tạo secret** nữa → bắt buộc tạo `camunda-credentials` trước khi cài.
3. `clusterSize`, `partitionCount`, `replicationFactor` **phải là string** (`"1"`), không phải number.
4. Phải bật `global.compatibility.openshift.adaptSecurityContext: force` vì Sandbox dùng SCC restricted.
5. Elasticsearch cần `sysctlImage.enabled: false` trên OpenShift.
6. Có **2 PostgreSQL** là bình thường khi bật Identity + Keycloak (mỗi cái một database riêng).
7. File `values-sandbox.yaml` đã cấu hình sẵn `publicIssuerUrl` và `redirectUrl` trỏ đúng domain Route của Sandbox.

---

## Tài liệu tham khảo

- [Camunda 8.9 Docs](https://docs.camunda.io/)
- [Helm Chart Version Matrix](https://helm.camunda.io/camunda-platform/version-matrix/)
- [OpenShift Deployment Guide](https://docs.camunda.io/docs/self-managed/deployment/helm/cloud-providers/openshift/redhat-openshift/)
```

Tôi cũng tạo luôn 3 file cấu hình còn lại để bạn tải đủ bộ.