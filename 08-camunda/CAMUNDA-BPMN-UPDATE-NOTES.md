# Camunda Integration – Ghi chú cập nhật `customer-onboarding.bpmn`

**Project:** Kevin Bank / Corporate Banking Platform – Phase 1  
**Component:** `customer-service` ↔ Camunda 8.9 (Orchestration Cluster)  
**Ngày:** 2026-08-29

---

## 1. Bối cảnh

- Process BPMN: `customer-onboarding`
- Flow Phase 1:  
  `StartEvent` → `ServiceTask (type=customer-create)` → `EndEvent`
- File gốc nằm tại:  
  `src/main/resources/bpmn/customer-onboarding.bpmn`
- Cơ chế deploy ban đầu:  
  `camunda-spring-boot-starter` auto-deploy khi Spring context khởi động (`camunda.client.deployment.enabled=true`).

---

## 2. Lỗi gặp phải

Khi `customer-service` start, bean `camundaLifecycleEventProducer` fail với lỗi:

```text
Command 'CREATE' rejected with code 'INVALID_ARGUMENT':
'customer-onboarding.bpmn': Error: URI=null Line=45:
cvc-complex-type.2.4.a: Invalid content was found starting with element
'{"http://www.omg.org/spec/DD/20100524/DC":Bounds}'.
One of '{"http://www.omg.org/spec/DD/20100524/DI":extension,
"http://www.omg.org/spec/DD/20100524/DI":waypoint}' is expected.
```

### Nguyên nhân

Trong phần Diagram Interchange (`BPMNEdge`), file gốc dùng sai element:

```xml
<!-- SAI – Bounds chỉ dành cho BPMNShape -->
<bpmndi:BPMNEdge id="Flow_1_di" bpmnElement="Flow_1">
  <omgdc:Bounds x="186" y="118" width="64" height="1" />
</bpmndi:BPMNEdge>
```

Camunda 8 (và schema BPMN DI) yêu cầu `BPMNEdge` phải dùng `waypoint`:

```xml
<!-- ĐÚNG -->
<bpmndi:BPMNEdge id="Flow_1_di" bpmnElement="Flow_1">
  <di:waypoint x="186" y="118" />
  <di:waypoint x="250" y="118" />
</bpmndi:BPMNEdge>
```

---

## 3. Cách xử lý đã thực hiện

### 3.1. Sửa file BPMN

Thay toàn bộ nội dung `customer-onboarding.bpmn` bằng bản hợp lệ (đã thêm namespace `di`, đổi `omgdc` → `dc`, thay `Bounds` trong Edge bằng `waypoint`).

Bản đã sửa:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                  xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
                  xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
                  xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
                  xmlns:zeebe="http://camunda.org/schema/zeebe/1.0"
                  id="Definitions_customer_onboarding"
                  targetNamespace="http://bpmn.io/schema/bpmn"
                  exporter="Kevin Bank customer-service" exporterVersion="phase-1">

  <bpmn:process id="customer-onboarding" name="Customer Onboarding (Phase 1)" isExecutable="true">

    <bpmn:startEvent id="StartEvent_1" name="Customer Created">
      <bpmn:outgoing>Flow_1</bpmn:outgoing>
    </bpmn:startEvent>

    <bpmn:serviceTask id="Task_CustomerCreate" name="Create Customer">
      <bpmn:extensionElements>
        <zeebe:taskDefinition type="customer-create" />
      </bpmn:extensionElements>
      <bpmn:incoming>Flow_1</bpmn:incoming>
      <bpmn:outgoing>Flow_2</bpmn:outgoing>
    </bpmn:serviceTask>

    <bpmn:endEvent id="EndEvent_1" name="Onboarding Started">
      <bpmn:incoming>Flow_2</bpmn:incoming>
    </bpmn:endEvent>

    <bpmn:sequenceFlow id="Flow_1" sourceRef="StartEvent_1" targetRef="Task_CustomerCreate" />
    <bpmn:sequenceFlow id="Flow_2" sourceRef="Task_CustomerCreate" targetRef="EndEvent_1" />

  </bpmn:process>

  <bpmndi:BPMNDiagram id="BPMNDiagram_1">
    <bpmndi:BPMNPlane id="BPMNPlane_1" bpmnElement="customer-onboarding">
      <bpmndi:BPMNShape id="StartEvent_1_di" bpmnElement="StartEvent_1">
        <dc:Bounds x="150" y="100" width="36" height="36" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="Task_CustomerCreate_di" bpmnElement="Task_CustomerCreate">
        <dc:Bounds x="250" y="78" width="100" height="80" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNShape id="EndEvent_1_di" bpmnElement="EndEvent_1">
        <dc:Bounds x="420" y="100" width="36" height="36" />
      </bpmndi:BPMNShape>
      <bpmndi:BPMNEdge id="Flow_1_di" bpmnElement="Flow_1">
        <di:waypoint x="186" y="118" />
        <di:waypoint x="250" y="118" />
      </bpmndi:BPMNEdge>
      <bpmndi:BPMNEdge id="Flow_2_di" bpmnElement="Flow_2">
        <di:waypoint x="350" y="118" />
        <di:waypoint x="420" y="118" />
      </bpmndi:BPMNEdge>
    </bpmndi:BPMNPlane>
  </bpmndi:BPMNDiagram>
</bpmn:definitions>
```

### 3.2. Workaround tạm thời (để service start được)

Vì image lúc đó vẫn chứa dụng BPMN cũ → auto-deploy fail → service không lên được:

```bash
oc set env deployment/customer-service \
  CAMUNDA_CLIENT_DEPLOYMENT_ENABLED=false \
  -n khoadghg97-dev

oc rollout restart deployment/customer-service -n khoadghg97-dev
```

### 3.3. Deploy thủ công (sau khi service đã lên)

Lấy token OIDC từ Keycloak của Camunda, rồi gọi REST API:

```bash
# 1. Lấy token
TOKEN=$(curl -s -X POST \
  "https://camunda-keycloak-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com/auth/realms/camunda-platform/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=customer-service" \
  -d "client_secret=<SECRET>" \
  -d "audience=orchestration-api" | jq -r .access_token)

# 2. Deploy BPMN đã sửa
curl -X POST \
  "https://camunda-orchestration-khoadghg97-dev.apps.rm3.7wse.p1.openshiftapps.com/v2/deployments" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json" \
  -F "resources=@customer-onboarding.bpmn;type=application/octet-stream"
```

Kết quả thành công:

```json
{
  "deploymentKey": "2251799813686263",
  "deployments": [{
    "processDefinition": {
      "processDefinitionId": "customer-onboarding",
      "processDefinitionVersion": 1,
      "processDefinitionKey": "2251799813686264"
    }
  }]
}
```

---

## 4. Kết quả E2E sau khi sửa

Sau khi có process definition hợp lệ + đủ Authorization:

1. `POST /api/v1/customers` → ghi PostgreSQL thành công  
2. `@TransactionalEventListener(AFTER_COMMIT)` fire  
3. `CustomerOnboardingProcessTrigger` start process instance  
4. Job Worker `customer-create` nhận job → complete  
5. Process instance chuyển sang trạng thái **Completed**

Log tiêu biểu:

```text
[TRACE-CAMUNDA] AFTER_COMMIT fired for CUSTOMER_CREATED customer=CUS-...
[TRACE-CAMUNDA] SUCCESS — started 'customer-onboarding' process instance ...
```

---

## 5. Khuyến nghị tiếp theo (không xóa file BPMN)

| Hành động | Lý do |
|-----------|--------|
| **Giữ** file `src/main/resources/bpmn/customer-onboarding.bpmn` (bản đã sửa) | Đây là source of truth |
| Rebuild image với BPMN đã sửa | Đảm bảo image chứa dụng file đúng schema |
| Bật lại auto-deploy | `CAMUNDA_CLIENT_DEPLOYMENT_ENABLED=true` (hoặc xóa env override) |
| (Tùy chọn) Siết Authorization | Đổi Resource ID từ `*` → `customer-onboarding` |

**Không nên** xóa file BPMN khỏi source rồi chỉ deploy thủ công mãi.  
Deploy thủ công chỉ phù hợp cho hotfix / môi trường sandbox tạm thời.

---

## 6. Checklist khi sửa BPMN sau này

1. Mở file bằng **Camunda Modeler** (khuyến nghị) → Save để Modeler tự sinh DI đúng schema.
2. Hoặc sửa tay: Edge chỉ được chứa `di:waypoint` (hoặc `extension`), không được chứa `dc:Bounds`.
3. Build lại image → deploy.
4. Nếu muốn test nhanh: deploy thủ công qua REST API như mục 3.3.
5. Kiểm tra Operate + log `[TRACE-CAMUNDA]` + Job Worker.

---

## 7. Liên quan Authorization đã cấp cho client `customer-service`

| Resource type       | Resource ID | Permissions                | Mục đích                          |
|---------------------|-------------|----------------------------|-----------------------------------|
| RESOURCE            | *           | CREATE                     | Deploy BPMN                       |
| PROCESS_DEFINITION  | *           | CREATE_PROCESS_INSTANCE    | Start process instance            |
| PROCESS_DEFINITION  | *           | UPDATE_PROCESS_INSTANCE    | Activate + complete job           |

---

*Tài liệu này ghi lại quá trình xử lý lỗi BPMN DI ngày 2026-08-29 trong buổi tích hợp Camunda 8.9 với customer-service.*
