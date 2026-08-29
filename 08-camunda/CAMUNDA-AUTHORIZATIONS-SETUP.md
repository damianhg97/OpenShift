# Camunda 8.9 – Authorizations cho client `customer-service`

**Project:** Kevin Bank / Corporate Banking Platform – Phase 1  
**Component:** `customer-service` ↔ Camunda Orchestration Cluster  
**Ngày:** 2026-08-29

---

## 1. Bối cảnh

Từ Camunda 8.8+, Orchestration Cluster (Zeebe / Operate / Tasklist / API) dùng hệ thống **Authorization riêng**, tách biệt hoàn toàn khỏi Management Identity.

Mặc định Helm chart 14.8.5 bật:

```yaml
camunda.security.authorizations.enabled: true
```

Client OIDC mới (ví dụ `customer-service`) **không có quyền nào** cho đến khi được cấp thủ công (hoặc qua API).

---

## 2. Các Authorization đã tạo thủ công (Admin UI)

URL:  
`https://camunda-orchestration-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com/admin/authorizations`

### 2.1. RESOURCE – Deploy BPMN

| Field            | Value              |
|------------------|--------------------|
| Owner type       | `Client`           |
| Owner ID         | `customer-service` |
| Resource type    | `RESOURCE`         |
| Resource ID      | `*`                |
| Permissions      | `CREATE`           |

**Mục đích:** Cho phép gọi `POST /v2/deployments`.

> ⚠ Camunda cảnh báo: quyền CREATE trên RESOURCE tương đương remote code execution. Chỉ cấp cho client tin cậy.

### 2.2. PROCESS_DEFINITION – Start process instance

| Field            | Value                     |
|------------------|---------------------------|
| Owner type       | `Client`                  |
| Owner ID         | `customer-service`        |
| Resource type    | `PROCESS_DEFINITION`      |
| Resource ID      | `*` (hoặc `customer-onboarding`) |
| Permissions      | `CREATE_PROCESS_INSTANCE` |

**Mục đích:** Cho phép `newCreateInstanceCommand()`.

### 2.3. PROCESS_DEFINITION – Activate & complete job

| Field            | Value                     |
|------------------|---------------------------|
| Owner type       | `Client`                  |
| Owner ID         | `customer-service`        |
| Resource type    | `PROCESS_DEFINITION`      |
| Resource ID      | `*` (hoặc `customer-onboarding`) |
| Permissions      | `UPDATE_PROCESS_INSTANCE` |

**Mục đích:** Job Worker có thể activate job (`customer-create`) và complete job.

> Đây là quyền quan trọng nhất bị thiếu lúc đầu → process instance stuck ở Service Task.

---

## 3. Cách tạo thủ công trên Admin UI (chi tiết)

1. Login Admin (user `demo` / `demo` hoặc admin Keycloak).
2. Vào tab **Authorizations**.
3. Chọn Resource type bên trái (RESOURCE hoặc PROCESS_DEFINITION).
4. Nhấn **Create authorization**.
5. Điền:
   - Owner type = `Client`
   - Owner ID = `customer-service` (phải khớp `client_id` trong token JWT)
   - Resource ID = `*` hoặc process id cụ thể
   - Tick permission cần thiết
6. Save.

Lặp lại cho từng dòng ở mục 2.

---

## 4. Có thể tạo Authorization bằng code / API không?

**Có.** Camunda 8.9 cung cấp REST API:

```
POST /v2/authorizations
```

### 4.1. Ví dụ curl

```bash
# 1. Lấy token (dùng client có quyền tạo authorization, thường là admin)
TOKEN=$(curl -s -X POST \
  "https://camunda-keycloak-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com/auth/realms/camunda-platform/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=<admin-or-privileged-client>" \
  -d "client_secret=<SECRET>" \
  -d "audience=orchestration-api" | jq -r .access_token)

# 2. Tạo authorization
curl -X POST \
  "https://camunda-orchestration-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com/v2/authorizations" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{
    "ownerId": "customer-service",
    "ownerType": "CLIENT",
    "resourceId": "*",
    "resourceType": "PROCESS_DEFINITION",
    "permissionTypes": ["CREATE_PROCESS_INSTANCE", "UPDATE_PROCESS_INSTANCE"]
  }'
```

Tương tự cho `RESOURCE` + `CREATE`.

### 4.2. Tự động hóa trong code (gợi ý)

Có thể làm một trong các cách sau:

| Cách | Mô tả | Phù hợp khi |
|------|--------|-------------|
| **Script init (bash/curl)** | Chạy 1 lần sau khi deploy Camunda | Sandbox / CI đơn giản |
| **Job Kubernetes / Helm hook** | Post-install hook tạo authorization | Production GitOps |
| **ApplicationRunner trong customer-service** | Lúc startup, dùng CamundaClient (hoặc RestTemplate) gọi `/v2/authorizations` nếu chưa tồn tại | Muốn self-contained |
| **Terraform / Ansible / custom operator** | Declarative infra | Môi trường lớn |

**Lưu ý quan trọng khi tự động hóa:**

- Client gọi API tạo authorization **phải có quyền** `CREATE` trên resource type `AUTHORIZATION` (thường chỉ admin/role đặc biệt mới có).
- Client `customer-service` bình thường **không** nên tự cấp quyền cho chính nó (security risk).
- Nên dùng một client/admin riêng hoặc script chạy bởi pipeline có credential privileged.

### 4.3. Ví dụ skeleton Java (ApplicationRunner – chỉ minh họa)

```java
@Component
@ConditionalOnProperty(name = "app.camunda.bootstrap-authorizations", havingValue = "true")
public class CamundaAuthorizationBootstrap implements ApplicationRunner {

    private final RestClient restClient; // hoặc WebClient / Camunda low-level HTTP
    // ... inject token provider ...

    @Override
    public void run(ApplicationArguments args) {
        createIfMissing("RESOURCE", "*", List.of("CREATE"));
        createIfMissing("PROCESS_DEFINITION", "*", 
            List.of("CREATE_PROCESS_INSTANCE", "UPDATE_PROCESS_INSTANCE"));
    }

    private void createIfMissing(String resourceType, String resourceId, List<String> permissions) {
        // 1. Search existing authorizations (GET /v2/authorizations/search)
        // 2. Nếu chưa có → POST /v2/authorizations
    }
}
```

> Khuyến nghị production: **không** để application tự bootstrap quyền cho chính nó. Nên để infrastructure / platform team quản lý.

---

## 5. Bảng quyền tối thiểu cho Phase 1

| Resource type      | Resource ID              | Permissions                                      | Dùng cho |
|--------------------|--------------------------|--------------------------------------------------|----------|
| RESOURCE           | `*`                      | CREATE                                           | Deploy BPMN |
| PROCESS_DEFINITION | `*` hoặc `customer-onboarding` | CREATE_PROCESS_INSTANCE, UPDATE_PROCESS_INSTANCE | Start instance + Job Worker |

Sau này nếu cần thêm:

- `READ_PROCESS_INSTANCE` – đọc trạng thái instance
- `CANCEL_PROCESS_INSTANCE` – hủy instance
- `MODIFY_PROCESS_INSTANCE` – sửa biến / migrate

---

## 6. Checklist khi thêm client mới

1. Tạo client trong Keycloak realm `camunda-platform` (client credentials).
2. Thêm Audience mapper → `orchestration-api` (và/hoặc `orchestration`).
3. Cấp Authorization trong Admin (hoặc qua API) theo bảng trên.
4. Cấu hình `camunda.client.auth.*` trong service.
5. Test: deploy → start instance → job worker complete.

---

## 7. Liên quan đến các file khác

- `CAMUNDA-BPMN-UPDATE-NOTES.md` – quá trình sửa schema BPMN DI.
- Audience mismatch (`zeebe-api` → `orchestration-api`) đã xử lý trước khi tới bước Authorization.

---

*Tài liệu này ghi lại việc cấp Authorization thủ công ngày 2026-08-29 và khả năng tự động hóa qua REST API `/v2/authorizations`.*
