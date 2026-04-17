# Lab 8. Azure Key Vault 연동 (Secrets Management)

> **난이도:** ⭐⭐⭐ 중급+ | **소요시간:** 60분 | **사전 조건:** [Lab 2](lab2-parameterized-pipeline.md) 이상 완료

## 목표

- DB2 패스워드, Storage Account Key, API Key 등 민감 정보를 **Key Vault**로 중앙화
- ADF Linked Service에서 패스워드 직접 입력 대신 **Key Vault 참조** 방식으로 전환
- ADF Managed Identity에 Key Vault 접근 권한 부여 (**Key Vault Secrets User** 역할)
- 기존 Lab에서 만든 Linked Service들을 Key Vault 참조 방식으로 리팩토링

## 왜 Key Vault를 써야 하나?

### 현재 문제점 (Lab 1~7의 구조)

```
LS_DB2_OnPrem (Linked Service)
└─ Password: "MyP@ssw0rd123!"    ← ADF에 직접 입력됨

LS_AzureSQLDB_Config
└─ Password: "AnotherP@ss!"       ← ADF에 직접 입력됨

LS_ADLS_Gen2
└─ AccountKey: "+AStorageAccountKey..."   ← ADF에 직접 입력됨
```

- 비밀번호가 ADF JSON 내부에 저장 (`properties.typeProperties.password.value`)
- **Git에 JSON을 올리면 암호가 노출될 수 있음** (ADF는 암호화 저장하지만 CI/CD에서 위험)
- 비밀번호 변경 시 **Linked Service마다 수정** 필요
- 보안 감사 시 **비밀번호 소스가 분산되어 있음** → 관리 포인트 증가

### Key Vault 도입 후

```
┌──────────────────────────────────────────────────────────┐
│  Azure Key Vault                                         │
│  ┌─────────────────────────────────────────────────────┐│
│  │ secret-db2-password:    "MyP@ssw0rd123!"            ││
│  │ secret-sql-password:    "AnotherP@ss!"              ││
│  │ secret-storage-key:     "+AStorageAccountKey..."    ││
│  │ secret-teams-webhook:   "https://..."               ││
│  └─────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────┘
              ▲
              │ Managed Identity 인증 + RBAC 권한
              │
              │ (Secret 값은 런타임에만 메모리로 조회)
              │
┌──────────────────────────────────────────────────────────┐
│  Azure Data Factory                                      │
│                                                          │
│  LS_DB2_OnPrem ───▶ Secret Reference: secret-db2-password│
│  LS_AzureSQLDB ───▶ Secret Reference: secret-sql-password│
│  LS_ADLS_Gen2  ───▶ Secret Reference: secret-storage-key │
└──────────────────────────────────────────────────────────┘
```

**장점:**

| 항목 | 효과 |
|------|------|
| 비밀번호 중앙 관리 | Key Vault 한 곳에서만 관리 |
| Git 안전성 | ADF JSON에 Secret 이름만 저장, 값은 Git에 안 올라감 |
| 비밀번호 변경 | Key Vault에서만 수정 → 모든 Linked Service 자동 반영 |
| 감사 추적 | Key Vault Access Log로 누가/언제 Secret 사용했는지 추적 |
| RBAC 권한 분리 | 개발자는 Secret 값 못 보고, ADF MI만 조회 가능 |
| Version 관리 | Secret 버전 이력, 롤백 가능 |

---

## Part 1. Azure Key Vault 준비

### 1.1 Key Vault 생성

Azure Portal에서:

```
홈 → Key vaults → + 만들기
```

| 설정 | 값 |
|------|-----|
| 구독 | (해당 구독) |
| 리소스 그룹 | ADF와 동일 RG 권장 |
| Key Vault 이름 | `kv-adf-lab-001` (전역 고유) |
| 지역 | ADF와 동일 지역 권장 (Korea Central) |
| 가격 책정 계층 | **Standard** |
| 일시 삭제 | ☑ 활성화 (기본값, 90일 보존) |
| 제거 보호 | ☑ 활성화 (실수 방지 위해 권장) |

**액세스 구성 탭 (중요):**

| 설정 | 값 |
|------|-----|
| 사용 권한 모델 | **Azure 역할 기반 액세스 제어(RBAC)** ← 선택 |

> ### ★ RBAC vs Vault Access Policy
>
> Key Vault는 두 가지 권한 모델을 지원합니다:
>
> | 모델 | 설명 | 권장 |
> |------|------|------|
> | **Azure RBAC** | 다른 Azure 리소스와 동일한 IAM 방식, 역할 기반 | **권장** (Microsoft 신규 방식) |
> | Vault Access Policy | Key Vault 자체 권한 관리 (레거시) | 비권장 |
>
> 이 Lab에서는 **Azure RBAC**을 사용합니다.

**네트워킹 탭:**

| 설정 | 값 |
|------|-----|
| 연결 방법 | **모든 네트워크** (실습용) 또는 **프라이빗 엔드포인트** (운영) |

> 운영 환경에서는 Private Endpoint + Trusted Azure Services 조합을 권장합니다. 실습에서는 "모든 네트워크"로 진행합니다.

### 1.2 본인(개발자)에게 Secret 관리 권한 부여

Key Vault에 Secret을 등록하려면 본인에게도 권한이 필요합니다.

```
Key Vault → Access control (IAM) → + Add → Add role assignment
```

| 설정 | 값 |
|------|-----|
| Role | **Key Vault Secrets Officer** ← Secret 생성/수정/삭제 권한 |
| Assign access to | User |
| Select | `<본인 계정>` |

> **중요:** 역할 할당 후 반영까지 **최대 5분** 소요. 권한 에러 나면 잠시 기다리세요.

### 1.3 Secret 등록

```
Key Vault → Secrets → + Generate/Import
```

#### Secret 1: DB2 패스워드

| 설정 | 값 |
|------|-----|
| Upload options | Manual |
| Name | `secret-db2-password` |
| Secret value | `<실제 DB2 패스워드>` |
| Content type | `password` (선택) |
| Activation date | (비워둠) |
| Expiration date | (비워둠 또는 1년 후) |
| Enabled | Yes |

#### Secret 2: Azure SQL Config DB 패스워드 (사용 시)

| 설정 | 값 |
|------|-----|
| Name | `secret-sql-config-password` |
| Secret value | `<Azure SQL DB 패스워드>` |

> Azure SQL을 Managed Identity로 인증한다면 이 Secret은 불필요합니다.

#### Secret 3: Storage Account Key (사용 시)

| 설정 | 값 |
|------|-----|
| Name | `secret-storage-account-key` |
| Secret value | `<Storage Account의 Access Key>` |

> ADLS Gen2를 Managed Identity로 인증한다면 이 Secret은 불필요합니다. **MI 인증이 권장됩니다.**

#### Secret 4: Teams Webhook URL (Lab 3/5 알림용)

| 설정 | 값 |
|------|-----|
| Name | `secret-teams-webhook-url` |
| Secret value | `https://<tenant>.webhook.office.com/webhookb2/...` |

### 1.4 등록된 Secret 확인

```
Key Vault → Secrets
```

| Name | Status | Expiration |
|------|--------|------------|
| secret-db2-password | Enabled | - |
| secret-sql-config-password | Enabled | - |
| secret-storage-account-key | Enabled | - |
| secret-teams-webhook-url | Enabled | - |

---

## Part 2. ADF Managed Identity에 Key Vault 접근 권한 부여

ADF가 Key Vault에서 Secret을 조회하려면 ADF의 Managed Identity에 **Key Vault Secrets User** 역할이 필요합니다.

### 2.1 ADF Managed Identity 확인

```
ADF 인스턴스 → Properties (또는 Settings → Identity)
```

| 항목 | 값 |
|------|-----|
| System assigned managed identity | **On** ← 이 값이 활성화돼 있어야 함 |
| Principal ID | `<자동 생성된 GUID>` (나중에 참조용) |

> ADF 생성 시 기본적으로 System-assigned MI가 활성화됩니다. 비활성화돼 있다면 켜주세요.

### 2.2 Key Vault Secrets User 역할 할당

```
Key Vault → Access control (IAM) → + Add → Add role assignment
```

| 설정 | 값 |
|------|-----|
| Role | **Key Vault Secrets User** ← Secret **조회(읽기)** 권한 |
| Assign access to | **Managed identity** |
| Managed identity type | **Data Factory (V2)** |
| Select | `<ADF 인스턴스 이름>` |

> ### ★ Key Vault 관련 주요 역할 비교
>
> | 역할 | 권한 | 사용 대상 |
> |------|------|---------|
> | **Key Vault Secrets User** | Secret 값 **읽기만** | ADF, App Service 등 리소스 |
> | **Key Vault Secrets Officer** | Secret CRUD (읽기/쓰기/삭제) | 개발자/운영자 |
> | Key Vault Administrator | 전체 관리 (정책 포함) | 최고 관리자만 |
> | Key Vault Reader | 메타데이터만 읽기 (값은 못 봄) | 감사자 |
>
> **원칙:** ADF에는 Secret 값을 읽기만 할 수 있는 **Secrets User**를 주고, 개발자에게는 **Secrets Officer**를 줍니다.

### 2.3 역할 할당 확인

```
Key Vault → Access control (IAM) → Role assignments 탭
```

아래와 같이 표시되어야 합니다:

| Role | Principal | Type |
|------|-----------|------|
| Key Vault Secrets Officer | `<본인>` | User |
| Key Vault Secrets User | `<ADF 이름>` | Managed Identity |

> 할당 반영까지 **최대 5분** 소요됩니다.

---

## Part 3. Key Vault Linked Service 생성

ADF에서 Key Vault를 "원본" 중 하나로 등록합니다. 이후 다른 Linked Service들이 이 Key Vault LS를 참조하게 됩니다.

### 3.1 Linked Service 생성

```
ADF Studio → [Manage] → [Linked services] → + New
→ Data store 탭 → "Azure Key Vault" 검색 → 선택 → Continue
```

| 설정 | 값 |
|------|-----|
| Name | `LS_KeyVault` |
| Description | ADF 공통 Key Vault 참조용 |
| Connect via integration runtime | **AutoResolveIntegrationRuntime** |
| Azure Key Vault selection method | **From Azure subscription** |
| Azure subscription | (해당 구독) |
| Azure Key Vault name | `kv-adf-lab-001` |
| Authentication method | **System Assigned Managed Identity** |

### 3.2 연결 테스트

하단 **[Test connection]** 클릭:

| 결과 | 의미 |
|------|------|
| ✅ Connection successful | ADF MI → Key Vault 접근 가능 |
| ❌ Access denied | Part 2 권한 할당 확인 (역할 반영 5분 대기) |
| ❌ Vault not found | Key Vault 이름 오타 또는 구독 확인 |

### 3.3 [Create] → Publish

```
Publish all → Publish
```

> Key Vault Linked Service 자체는 Secret 값을 가지지 않고 **Key Vault 위치와 인증 방법**만 저장합니다. 따라서 Git에 올려도 안전합니다.

---

## Part 4. 기존 Linked Service를 Key Vault 참조로 전환

이제 Lab 1~7에서 만든 Linked Service를 Key Vault 참조 방식으로 바꿉니다.

### 4.1 LS_DB2_OnPrem 전환

기존 설정 (Lab 1):

```
Type     : IBM DB2
Server   : <서버 IP>
Database : SAMPLEDB
Username : db2user
Password : "MyP@ssw0rd123!"   ← 직접 입력
```

변경 후:

```
ADF Studio → [Manage] → [Linked services] → LS_DB2_OnPrem 클릭
```

**Password 필드 변경:**

| 설정 | 값 |
|------|-----|
| Password 방식 | **Azure Key Vault** ← 드롭다운 변경 |
| AKV linked service | `LS_KeyVault` |
| Secret name | `secret-db2-password` |
| Secret version | (비워둠 = 항상 최신 버전 사용) |

**[Test connection]** → 성공 확인 → **[Save]** → **[Publish all]**

> **확인 포인트:** Linked Service를 편집해도 Secret 값은 **Key Vault에서만 읽히고 ADF JSON에는 저장되지 않습니다.**

### 4.2 LS_AzureSQLDB_Config 전환 (Lab 2 확장)

Azure SQL 인증 방식에 따라 다릅니다:

**방식 A — SQL 인증 (Secret 사용):**

| 설정 | 값 |
|------|-----|
| Authentication type | SQL authentication |
| User name | `<SQL 사용자>` |
| Password 방식 | **Azure Key Vault** |
| AKV linked service | `LS_KeyVault` |
| Secret name | `secret-sql-config-password` |

**방식 B — Managed Identity (Secret 불필요, 권장):**

| 설정 | 값 |
|------|-----|
| Authentication type | **System Assigned Managed Identity** |

> Azure SQL Database에서 ADF Managed Identity를 사용자로 등록해야 합니다:
> ```sql
> -- Azure SQL DB에서 실행
> CREATE USER [<adf-name>] FROM EXTERNAL PROVIDER;
> ALTER ROLE db_datareader ADD MEMBER [<adf-name>];
> ALTER ROLE db_datawriter ADD MEMBER [<adf-name>];
> -- Lookup이 실행할 권한
> GRANT SELECT ON SCHEMA::dbo TO [<adf-name>];
> ```

**권장:** 방식 B (MI) 사용. Secret 관리 부담 자체가 없어집니다.

### 4.3 LS_ADLS_Gen2 전환

현재 이미 **Managed Identity 인증**으로 구성돼 있다면 변경 불필요합니다.

Account Key 방식을 쓰고 있었다면:

| 설정 | 값 |
|------|-----|
| Authentication method | Account key |
| Account key 방식 | **Azure Key Vault** |
| AKV linked service | `LS_KeyVault` |
| Secret name | `secret-storage-account-key` |

> **권장:** ADLS Gen2는 Managed Identity로 전환하세요. Secret 자체를 없애는 것이 최선입니다.

---

## Part 5. Web Activity에서 Key Vault Secret 동적 조회 (Lab 3/5 알림용)

Lab 3의 Teams Webhook URL, 또는 외부 API 호출 시 Key Vault Secret을 **파이프라인 런타임에 직접 조회**하는 패턴입니다.

### 5.1 시나리오

Lab 3의 Error Handling에서 Teams Webhook URL을 하드코딩했지만, 운영 환경에서는 Webhook URL도 Secret으로 관리해야 합니다.

### 5.2 Web Activity로 Key Vault Secret 조회

**Activity 이름:** `Get_Teams_Webhook`

| 설정 | 값 |
|------|-----|
| Method | **GET** |
| Authentication | **Managed Identity** |
| Resource | `https://vault.azure.net` ← Key Vault용 (Blob과 다름!) |

**URL:**
```
https://kv-adf-lab-001.vault.azure.net/secrets/secret-teams-webhook-url?api-version=7.4
```

### 5.3 조회한 Secret을 다음 Activity에서 사용

Get_Teams_Webhook 다음에 Notify_Error_Teams Web Activity 연결:

**Notify_Error_Teams → URL:**
```
@activity('Get_Teams_Webhook').output.value
```

> Key Vault Secret API 응답 구조:
> ```json
> {
>   "value": "https://<tenant>.webhook.office.com/webhookb2/...",
>   "id": "https://kv-adf-lab-001.vault.azure.net/secrets/secret-teams-webhook-url/<version>",
>   "attributes": { ... }
> }
> ```
> `.output.value`에 실제 Secret 값이 들어있습니다.

### 5.4 주의: Secret 값이 로그에 노출될 수 있음

Web Activity output은 기본적으로 **Monitor 로그에 기록**됩니다. Secret 값 노출을 막으려면:

```
Web Activity → Secure output ☑ 체크
Web Activity → Secure input ☑ 체크
```

| 옵션 | 효과 |
|------|------|
| **Secure output** | Activity 출력을 Monitor에 기록하지 않음 |
| **Secure input** | Activity 입력(URL, Body)을 Monitor에 기록하지 않음 |

> **Key Vault Secret 조회 Activity는 반드시 Secure output을 활성화**하세요. 비활성화 시 Secret 값이 Monitor 로그에 평문으로 노출됩니다.

---

## Part 6. 검증 및 운영 가이드

### 6.1 검증 체크리스트

- [ ] Key Vault `kv-adf-lab-001` 생성, RBAC 권한 모델 선택
- [ ] 본인에게 **Key Vault Secrets Officer** 역할 할당
- [ ] 필요한 Secret 4개 등록
- [ ] ADF Managed Identity에 **Key Vault Secrets User** 역할 할당
- [ ] `LS_KeyVault` Linked Service 생성 + Test connection 성공
- [ ] `LS_DB2_OnPrem` 패스워드를 Key Vault 참조로 전환 + Test connection 성공
- [ ] Publish 완료
- [ ] Lab 6 마스터 파이프라인 Debug 실행 → 정상 동작 확인

### 6.2 운영 시 Secret 변경 절차

DB2 패스워드가 변경되었다고 가정:

1. Key Vault에서 `secret-db2-password` Secret 선택
2. **+ New Version** → 새 패스워드 입력
3. ADF 변경 **불필요** — 자동으로 새 버전 사용
4. 다음 파이프라인 실행부터 새 패스워드 적용

> Secret version을 명시적으로 지정했다면 (`secret-db2-password/abc123`), 버전도 업데이트 필요.
> 일반적으로는 version을 비워두어 "항상 최신"으로 관리합니다.

### 6.3 Secret 만료 관리

운영 팁:

| 항목 | 권장 |
|------|------|
| Secret 만료일 설정 | 1년 권장 (정책에 따라 조정) |
| 만료 전 알림 | Azure Monitor로 Key Vault 만료 임박 알림 설정 |
| 정기 순환 | 연 1회 이상 패스워드 변경 주기 수립 |

### 6.4 감사 추적 (누가 Secret을 읽었는가?)

```
Key Vault → Monitoring → Diagnostic settings → + Add diagnostic setting
  Category: AuditEvent
  Destination: Log Analytics workspace
```

**쿼리 예시 (Log Analytics):**
```
AzureDiagnostics
| where ResourceType == "VAULTS"
| where OperationName == "SecretGet"
| where TimeGenerated > ago(1d)
| project TimeGenerated, identity_claim_appid_g, CallerIPAddress, requestUri_s
| order by TimeGenerated desc
```

| 결과 | 의미 |
|------|------|
| `identity_claim_appid_g` | Secret을 읽은 주체 (ADF MI의 Object ID) |
| `requestUri_s` | 어떤 Secret을 읽었는지 |
| `CallerIPAddress` | 요청 IP (ADF의 Azure 내부 IP) |

---

## Part 7. 주의사항 및 모범 사례

### 7.1 Secret 이름 네이밍 컨벤션

| 권장 패턴 | 예시 |
|----------|------|
| `secret-<시스템>-<용도>` | `secret-db2-password`, `secret-sql-password` |
| `secret-<환경>-<시스템>-<용도>` (다환경 시) | `secret-prod-db2-password`, `secret-dev-db2-password` |

> 다환경 구성 시 **Key Vault를 환경별로 분리**하는 것이 더 안전합니다:
> - `kv-adf-dev`
> - `kv-adf-stg`
> - `kv-adf-prod`

### 7.2 절대 하지 말아야 할 것

- ❌ Secret 값을 Code, Git, 이메일에 평문으로 저장
- ❌ Secret을 파이프라인 **Parameter Default Value**에 입력 (JSON에 저장됨)
- ❌ Web Activity로 Secret 조회 시 **Secure output 미설정**
- ❌ ADF Managed Identity에 **Key Vault Administrator** 같은 과도한 권한 부여

### 7.3 권장 체계 (운영 환경)

```
┌─────────────────────────────────────────────────────────┐
│  Key Vault 계층 구조 (환경별 분리 + 공통 Vault)          │
│                                                         │
│  kv-adf-shared        ← 공통 Secret (Teams Webhook 등)  │
│  kv-adf-dev           ← Dev 환경 전용                   │
│  kv-adf-stg           ← Stg 환경 전용                   │
│  kv-adf-prod          ← Prod 환경 전용 (최소 권한)      │
│                                                         │
│  각 환경의 ADF는 해당 환경 Key Vault만 접근             │
└─────────────────────────────────────────────────────────┘
```

### 7.4 Key Vault 방화벽 (운영 환경)

운영 환경에서는 Public 접근을 차단합니다:

```
Key Vault → Networking → Firewalls and virtual networks
  Allow access from: Selected networks
  Exception: Allow trusted Microsoft services to bypass this firewall ☑
```

> **Allow trusted services** 활성화하면 같은 테넌트의 ADF MI는 방화벽을 우회하여 접근 가능합니다.
>
> ※ 확실하지 않음: ADF MI의 "Trusted Service" 동작은 Azure 지역/설정에 따라 예외가 있을 수 있으므로, 운영 적용 전 반드시 Test connection으로 검증하세요.

---

## Part 8. 전체 Linked Service 전환 결과

### 변경 전 (Lab 1~7)

| Linked Service | 인증 방식 | Secret 위치 |
|---------------|---------|-----------|
| `LS_DB2_OnPrem` | Basic | ADF JSON 내부 ❌ |
| `LS_AzureSQLDB_Config` | SQL Auth | ADF JSON 내부 ❌ |
| `LS_ADLS_Gen2` | Managed Identity | - (안전) |

### 변경 후 (Lab 8 완료)

| Linked Service | 인증 방식 | Secret 위치 |
|---------------|---------|-----------|
| `LS_KeyVault` | Managed Identity | - (Key Vault 자체가 대상) |
| `LS_DB2_OnPrem` | Basic (Username만, Password는 KV) | Key Vault ✅ |
| `LS_AzureSQLDB_Config` | **Managed Identity** (권장) 또는 Key Vault | Key Vault ✅ 또는 없음 |
| `LS_ADLS_Gen2` | Managed Identity | - (안전) |

### ADF JSON 변화 예시

**Before (Lab 1):**
```json
{
  "name": "LS_DB2_OnPrem",
  "properties": {
    "type": "Db2",
    "typeProperties": {
      "server": "db2-host",
      "database": "SAMPLEDB",
      "username": "db2user",
      "password": {
        "type": "SecureString",
        "value": "********"
      }
    }
  }
}
```

**After (Lab 8):**
```json
{
  "name": "LS_DB2_OnPrem",
  "properties": {
    "type": "Db2",
    "typeProperties": {
      "server": "db2-host",
      "database": "SAMPLEDB",
      "username": "db2user",
      "password": {
        "type": "AzureKeyVaultSecret",
        "store": {
          "referenceName": "LS_KeyVault",
          "type": "LinkedServiceReference"
        },
        "secretName": "secret-db2-password"
      }
    }
  }
}
```

> **중요:** `After` JSON에는 Secret **값이 없습니다**. Secret 이름만 참조합니다. → Git에 올려도 안전!

---

**이전 Lab:** [Lab 7 — ADF 트리거](lab7-triggers.md)  
**참고:** [부록 B — Linked Service 설정](appendix-b-linked-service.md) | [부록 C — 오류 해결](appendix-c-troubleshooting.md)
