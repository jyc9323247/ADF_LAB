# Lab 5. Copy Activity / Pipeline 실행 로깅 (Azure Blob Storage)

> **난이도:** ⭐⭐⭐ 중급+ | **소요시간:** 60분 | **사전 조건:** [Lab 3](lab3-delete-error-handling.md) 완료

## 목표

- Copy Activity 실행 결과(행 수, 데이터 크기, 소요시간 등)를 JSON 로그로 수집
- 파이프라인 성공/실패 모두 로그 기록
- **로그를 Azure Blob Storage에 JSON 파일로 저장** (Web Activity + Blob REST API)
- 3가지 방법 비교: Copy Activity (Append Blob) / Web Activity (REST API) / Script Activity

## 왜 Blob Storage에 로그를 저장하나?

| 방법 | 장점 | 단점 |
|------|------|------|
| ADF Monitor (기본) | 별도 설정 불필요 | 45일 보존 제한, 커스텀 분석 어려움 |
| Azure SQL 테이블 (Lab 3) | 구조화 쿼리 가능 | DB 비용 발생, 스키마 관리 필요 |
| **Blob Storage (이번 Lab)** | 저비용, 무제한 보존, Databricks/Synapse 분석 가능 | 실시간 쿼리 어려움 (배치 분석 적합) |

> **실무 권장:** Blob Storage 로그 + Azure SQL 요약 테이블 병행 구성

---

## 전체 아키텍처

```
┌──────────────────────────────────────────────────────────────────────────┐
│  PL_Copy_DB2_to_ADLS_Child (차일드 파이프라인)                          │
│                                                                         │
│  ┌──────────┐ comp. ┌──────────┐ success ┌──────────────────────────┐   │
│  │ Delete   │──────▶│ Copy     │────────▶│ Log_Success              │   │
│  │ Existing │       │ DB2→ADLS │         │ (Web Activity → Blob)    │   │
│  └──────────┘       └────┬─────┘         └──────────────────────────┘   │
│                          │ failure                                       │
│                          ▼                                               │
│                   ┌──────────────────────────┐                           │
│                   │ Log_Failure              │                           │
│                   │ (Web Activity → Blob)    │                           │
│                   └──────────────────────────┘                           │
└──────────────────────────────────────────────────────────────────────────┘

로그 저장 경로:
  datalake/pipeline-logs/YYYY/MM/DD/{pipeline}_{runid}_{table}_{status}.json
```

---

## Part 1. 사전 구성

### 5.1.1 Blob Storage 로그 컨테이너 준비

기존 ADLS Gen2 스토리지 계정에 로그 전용 컨테이너를 생성합니다.

```
스토리지 계정: <기존 ADLS Gen2 계정>
컨테이너 이름: pipeline-logs
```

Azure Portal에서:
```
Storage Account → Containers → + Container
  Name: pipeline-logs
  Public access level: Private
```

### 5.1.2 ADF Managed Identity에 Blob 쓰기 권한 부여

ADF의 Managed Identity에 로그 컨테이너 쓰기 권한을 부여합니다.

```
Storage Account → Access Control (IAM) → + Add role assignment
  Role: Storage Blob Data Contributor
  Assign access to: Managed identity
  Select: <ADF 인스턴스 이름>
```

> **참고:** Lab 1에서 이미 `Storage Blob Data Contributor`를 할당했다면 계정 수준 권한이므로 추가 작업 불필요합니다.

### 5.1.3 로그용 Linked Service 확인

기존 `LS_ADLS_Gen2` (Managed Identity 인증)를 그대로 사용합니다.
Web Activity에서 Blob REST API 호출 시에도 ADF Managed Identity 인증을 사용합니다.

---

## Part 2. Copy Activity 출력 속성 이해

로그에 기록할 데이터를 이해하기 위해 Copy Activity의 output 속성을 먼저 확인합니다.

### 5.2.1 Copy Activity output 주요 속성

| 속성 | 타입 | 설명 | 표현식 |
|------|------|------|--------|
| `rowsRead` | long | 소스에서 읽은 행 수 | `@activity('Copy_DB2_to_ADLS').output.rowsRead` |
| `rowsCopied` | long | Sink에 쓴 행 수 | `@activity('Copy_DB2_to_ADLS').output.rowsCopied` |
| `dataRead` | long | 읽은 데이터 바이트 | `@activity('Copy_DB2_to_ADLS').output.dataRead` |
| `dataWritten` | long | 쓴 데이터 바이트 | `@activity('Copy_DB2_to_ADLS').output.dataWritten` |
| `copyDuration` | int | 복사 소요 시간 (초) | `@activity('Copy_DB2_to_ADLS').output.copyDuration` |
| `throughput` | float | 처리량 (KB/s) | `@activity('Copy_DB2_to_ADLS').output.throughput` |
| `errors` | array | 에러 목록 | `@activity('Copy_DB2_to_ADLS').output.errors` |

### 5.2.2 실패 시 에러 속성

| 속성 | 설명 | 표현식 |
|------|------|--------|
| `error.message` | 에러 메시지 | `@activity('Copy_DB2_to_ADLS').error.message` |
| `error.errorCode` | 에러 코드 | `@activity('Copy_DB2_to_ADLS').error.errorCode` |
| `error.failureType` | 실패 유형 | `@activity('Copy_DB2_to_ADLS').error.failureType` |

### 5.2.3 파이프라인 메타 속성

| 속성 | 설명 | 표현식 |
|------|------|--------|
| Pipeline 이름 | 현재 파이프라인 이름 | `@pipeline().Pipeline` |
| Run ID | 실행 고유 ID | `@pipeline().RunId` |
| Trigger 이름 | 트리거 이름 | `@pipeline().TriggerName` |
| Trigger 시간 | 트리거 실행 시간 | `@pipeline().TriggerTime` |

---

## Part 3. 방법 A — Web Activity + Blob REST API (Put Blob)

> **이 방법을 권장합니다.** 별도 Dataset/Linked Service 없이, Web Activity 하나로 JSON 로그를 Blob에 직접 생성합니다.

### 5.3.1 로그 JSON 구조 설계

```json
{
  "log_timestamp": "2026-03-26T10:30:00Z",
  "pipeline_name": "PL_Copy_DB2_to_ADLS_Child",
  "run_id": "a1b2c3d4-...",
  "trigger_name": "Manual",
  "source_table": "ETL_SCHEMA.TB_CUSTOMER",
  "target_path": "datalake/SAMPLEDB/ETL_SCHEMA/TB_CUSTOMER_20260326.parquet",
  "load_date": "20260326",
  "status": "SUCCESS",
  "rows_read": 20,
  "rows_copied": 20,
  "data_read_bytes": 4560,
  "data_written_bytes": 3820,
  "copy_duration_sec": 5,
  "throughput_kbps": 0.89,
  "error_message": null
}
```

### 5.3.2 차일드 파이프라인 Variables 추가

| Name | Type | Default |
|------|------|---------|
| `v_log_json` | String | (비워둠) |
| `v_log_filepath` | String | (비워둠) |

### 5.3.3 Activity: Set_Log_FilePath (성공/실패 공통)

Copy Activity 앞에 배치할 필요 없이, 성공/실패 분기 내에서 각각 사용합니다.
하지만 로그 경로를 공통으로 쓸 수 있도록 Variable에 먼저 세팅합니다.

> 이 Activity는 Copy 이전에 배치해도 되고, 성공/실패 분기 내에서 인라인으로 작성해도 됩니다.

### 5.3.4 Activity: Log_Success (Web Activity — 성공 시)

**Activity 이름:** `Log_Success`

**연결:** `Copy_DB2_to_ADLS` → **(On success)** → `Log_Success`

| 설정 | 값 |
|------|-----|
| Type | Web |
| Method | **PUT** |
| Authentication | **Managed Identity** |
| Resource | `https://storage.azure.com/` |

**URL:**
```
@concat(
    'https://<storage_account>.blob.core.windows.net/pipeline-logs/',
    formatDateTime(utcNow(), 'yyyy'),
    '/',
    formatDateTime(utcNow(), 'MM'),
    '/',
    formatDateTime(utcNow(), 'dd'),
    '/',
    pipeline().Pipeline,
    '_',
    pipeline().RunId,
    '_',
    pipeline().parameters.p_table_name,
    '_SUCCESS.json'
)
```

> `<storage_account>` 부분을 실제 스토리지 계정명으로 교체하세요.

**Headers:**

| Header | Value |
|--------|-------|
| `x-ms-blob-type` | `BlockBlob` |
| `x-ms-version` | `2021-08-06` |
| `Content-Type` | `application/json` |

**Body:**
```
@json(
    concat(
        '{',
        '"log_timestamp":"', utcNow(), '",',
        '"pipeline_name":"', pipeline().Pipeline, '",',
        '"run_id":"', pipeline().RunId, '",',
        '"trigger_name":"', pipeline().TriggerName, '",',
        '"source_table":"', pipeline().parameters.p_schema_name, '.', pipeline().parameters.p_table_name, '",',
        '"target_path":"', pipeline().parameters.p_container, '/', pipeline().parameters.p_db_name, '/', pipeline().parameters.p_schema_name, '/', pipeline().parameters.p_table_name, '_', pipeline().parameters.p_load_date, '.parquet",',
        '"load_date":"', pipeline().parameters.p_load_date, '",',
        '"status":"SUCCESS",',
        '"rows_read":', string(activity('Copy_DB2_to_ADLS').output.rowsRead), ',',
        '"rows_copied":', string(activity('Copy_DB2_to_ADLS').output.rowsCopied), ',',
        '"data_read_bytes":', string(activity('Copy_DB2_to_ADLS').output.dataRead), ',',
        '"data_written_bytes":', string(activity('Copy_DB2_to_ADLS').output.dataWritten), ',',
        '"copy_duration_sec":', string(activity('Copy_DB2_to_ADLS').output.copyDuration), ',',
        '"throughput_kbps":', string(activity('Copy_DB2_to_ADLS').output.throughput), ',',
        '"error_message":null',
        '}'
    )
)
```

### 5.3.5 Activity: Log_Failure (Web Activity — 실패 시)

**Activity 이름:** `Log_Failure`

**연결:** `Copy_DB2_to_ADLS` → **(On failure)** → `Log_Failure`

URL, Headers는 `Log_Success`와 동일 (파일명만 `_FAILED.json`으로 변경):

**URL:**
```
@concat(
    'https://<storage_account>.blob.core.windows.net/pipeline-logs/',
    formatDateTime(utcNow(), 'yyyy'),
    '/',
    formatDateTime(utcNow(), 'MM'),
    '/',
    formatDateTime(utcNow(), 'dd'),
    '/',
    pipeline().Pipeline,
    '_',
    pipeline().RunId,
    '_',
    pipeline().parameters.p_table_name,
    '_FAILED.json'
)
```

**Body:**
```
@json(
    concat(
        '{',
        '"log_timestamp":"', utcNow(), '",',
        '"pipeline_name":"', pipeline().Pipeline, '",',
        '"run_id":"', pipeline().RunId, '",',
        '"trigger_name":"', pipeline().TriggerName, '",',
        '"source_table":"', pipeline().parameters.p_schema_name, '.', pipeline().parameters.p_table_name, '",',
        '"target_path":"', pipeline().parameters.p_container, '/', pipeline().parameters.p_db_name, '/', pipeline().parameters.p_schema_name, '/', pipeline().parameters.p_table_name, '_', pipeline().parameters.p_load_date, '.parquet",',
        '"load_date":"', pipeline().parameters.p_load_date, '",',
        '"status":"FAILED",',
        '"rows_read":null,',
        '"rows_copied":null,',
        '"data_read_bytes":null,',
        '"data_written_bytes":null,',
        '"copy_duration_sec":null,',
        '"throughput_kbps":null,',
        '"error_message":"', replace(activity('Copy_DB2_to_ADLS').error.message, '"', '\\"'), '"',
        '}'
    )
)
```

> **주의:** `error.message`에 큰따옴표가 포함될 수 있으므로 `replace(..., '"', '\\"')`로 이스케이프합니다.

### 5.3.6 최종 차일드 파이프라인 흐름 (Lab 5 반영)

```
┌──────────┐ comp. ┌──────────────┐ success ┌──────────────┐
│ Delete   │──────▶│ Copy         │────────▶│ Log_Success  │
│ Existing │       │ DB2→ADLS     │         │ (Web→Blob)   │
└──────────┘       └──────┬───────┘         └──────────────┘
                          │ failure
                          ▼
                   ┌──────────────┐
                   │ Log_Failure  │
                   │ (Web→Blob)   │
                   └──────────────┘
```

---

## Part 4. 방법 B — Copy Activity로 Append Blob에 로그 추가

> 일자별 로그를 **하나의 파일에 append** 하고 싶을 때 사용합니다. 단, 설정이 방법 A보다 복잡합니다.

### 5.4.1 개념

1. Set Variable로 로그 JSON 한 줄 생성
2. Copy Activity (Source: 인라인 JSON, Sink: Blob Append)로 기존 파일에 추가

### 5.4.2 로그용 Dataset 생성

**Dataset 이름:** `DS_Blob_Log_Append`

| 설정 | 값 |
|------|-----|
| Type | Azure Blob Storage (JSON) |
| Linked Service | `LS_ADLS_Gen2` |
| File Path | 파라메터화 |

**Dataset Parameters:**

| Name | Type |
|------|------|
| `ds_log_path` | String |

**Connection:**
```
Container : pipeline-logs
File      : @dataset().ds_log_path
```

### 5.4.3 Set Variable: v_log_json

**Activity 이름:** `Set_Success_Log_Json`

**연결:** `Copy_DB2_to_ADLS` → (On success) → `Set_Success_Log_Json`

```
@concat(
    '{"log_timestamp":"', utcNow(),
    '","pipeline":"', pipeline().Pipeline,
    '","run_id":"', pipeline().RunId,
    '","table":"', pipeline().parameters.p_schema_name, '.', pipeline().parameters.p_table_name,
    '","status":"SUCCESS',
    '","rows_read":', string(activity('Copy_DB2_to_ADLS').output.rowsRead),
    ',"rows_copied":', string(activity('Copy_DB2_to_ADLS').output.rowsCopied),
    ',"duration_sec":', string(activity('Copy_DB2_to_ADLS').output.copyDuration),
    ',"error":null}',
    char(10)
)
```

> `char(10)` = 개행문자. JSONL (JSON Lines) 형식으로 한 줄씩 append 합니다.

### 5.4.4 Copy Activity: Append Log

**Activity 이름:** `Append_Log_To_Blob`

**연결:** `Set_Success_Log_Json` → (On success) → `Append_Log_To_Blob`

| 설정 | 값 |
|------|-----|
| Source | Inline content = `@variables('v_log_json')` |
| Sink dataset | `DS_Blob_Log_Append` |
| Sink `ds_log_path` | `@concat(formatDateTime(utcNow(),'yyyy/MM/dd'), '/pipeline_log.jsonl')` |
| Write behavior | **Append** (기존 파일에 추가) |

**결과 파일:**
```
pipeline-logs/2026/03/26/pipeline_log.jsonl
```

파일 내용 (JSONL — 한 줄씩 누적):
```json
{"log_timestamp":"2026-03-26T10:30:00Z","pipeline":"PL_Copy_DB2_to_ADLS_Child","run_id":"abc...","table":"ETL_SCHEMA.TB_CUSTOMER","status":"SUCCESS","rows_read":20,"rows_copied":20,"duration_sec":5,"error":null}
{"log_timestamp":"2026-03-26T10:30:05Z","pipeline":"PL_Copy_DB2_to_ADLS_Child","run_id":"def...","table":"ETL_SCHEMA.TB_ORDER","status":"SUCCESS","rows_read":150,"rows_copied":150,"duration_sec":8,"error":null}
{"log_timestamp":"2026-03-26T10:30:12Z","pipeline":"PL_Copy_DB2_to_ADLS_Child","run_id":"ghi...","table":"ETL_SCHEMA.TB_PRODUCT","status":"FAILED","rows_read":null,"rows_copied":null,"duration_sec":null,"error":"Connection timeout"}
```

---

## Part 5. 방법 C — Script Activity (간편 대안)

> ADF에 Script Activity가 있는 경우, Azure SQL에 직접 INSERT하는 가장 간단한 방법입니다. Blob 대신 DB 로그를 원할 때 사용합니다.

### 5.5.1 Script Activity 구성

**Activity 이름:** `Script_Log_Success`

**연결:** `Copy_DB2_to_ADLS` → (On success) → `Script_Log_Success`

| 설정 | 값 |
|------|-----|
| Type | Script |
| Linked Service | `LS_AzureSQLDB_Config` |
| Script type | NonQuery |

**Script:**
```sql
@concat(
    'INSERT INTO dbo.ADF_PIPELINE_LOG ',
    '(pipeline_name, run_id, table_name, load_date, status, rows_copied, error_message, start_time) ',
    'VALUES (''',
    pipeline().Pipeline, ''', ''',
    pipeline().RunId, ''', ''',
    pipeline().parameters.p_schema_name, '.', pipeline().parameters.p_table_name, ''', ''',
    pipeline().parameters.p_load_date, ''', ',
    '''SUCCESS'', ',
    string(activity('Copy_DB2_to_ADLS').output.rowsCopied), ', ',
    'NULL, ',
    '''', utcNow(), ''')'
)
```

---

## Part 6. 3가지 방법 비교

| 항목 | 방법 A: Web + REST API | 방법 B: Copy Append | 방법 C: Script Activity |
|------|----------------------|--------------------|-----------------------|
| 로그 저장소 | Blob Storage (JSON) | Blob Storage (JSONL) | Azure SQL Database |
| 추가 Dataset | 불필요 | 필요 (1개) | 불필요 |
| 추가 LS | 불필요 (MI 인증) | 불필요 | 필요 (Azure SQL) |
| 파일 구조 | 건별 개별 JSON | 일자별 JSONL (append) | DB 테이블 행 |
| 설정 복잡도 | 중간 | 높음 | 낮음 |
| 분석 용이성 | Databricks/Synapse | Databricks/Synapse | SQL 쿼리 |
| 비용 | 최저 (Blob) | 최저 (Blob) | DB 비용 발생 |
| **권장 시나리오** | **범용 (추천)** | 대량 로그 통합 | 실시간 조회 필요 시 |

---

## Part 7. 실행 및 검증

### 7.1 검증 체크리스트

- [ ] `pipeline-logs` 컨테이너 생성 확인
- [ ] ADF Managed Identity에 Blob Data Contributor 역할 확인
- [ ] 차일드 파이프라인에 Log_Success / Log_Failure Activity 추가
- [ ] 마스터 파이프라인 Debug 실행

### 7.2 성공 시 로그 확인

```
pipeline-logs/
└── 2026/
    └── 03/
        └── 26/
            ├── PL_Copy_DB2_to_ADLS_Child_{runid1}_TB_CUSTOMER_SUCCESS.json
            ├── PL_Copy_DB2_to_ADLS_Child_{runid2}_TB_ORDER_SUCCESS.json
            ├── PL_Copy_DB2_to_ADLS_Child_{runid3}_TB_PRODUCT_SUCCESS.json
            └── PL_Copy_DB2_to_ADLS_Child_{runid4}_TB_INVENTORY_SUCCESS.json
```

### 7.3 실패 테스트

의도적으로 실패를 발생시켜 로그를 확인합니다:

1. DB2 테이블명을 존재하지 않는 이름으로 변경 (Config 테이블 UPDATE)
2. 마스터 파이프라인 실행
3. `_FAILED.json` 파일 생성 확인
4. JSON 내 `error_message` 필드에 에러 내용 기록 확인

### 7.4 Databricks에서 로그 분석 (선택)

```sql
-- 로그 파일 전체 읽기
SELECT *
FROM json.`abfss://pipeline-logs@<account>.dfs.core.windows.net/2026/03/26/*.json`;

-- 일자별 성공/실패 요약
SELECT load_date, status, COUNT(*) as cnt,
       SUM(rows_copied) as total_rows
FROM json.`abfss://pipeline-logs@<account>.dfs.core.windows.net/2026/03/**/*.json`
GROUP BY load_date, status
ORDER BY load_date;
```

---

## Part 8. Web Activity Blob REST API 주의사항

### 8.1 인증 관련

| 항목 | 설명 |
|------|------|
| Authentication | **Managed Identity** 선택 |
| Resource | `https://storage.azure.com/` (고정값) |
| 권한 | Storage Blob Data Contributor (IAM) |

### 8.2 필수 Headers

| Header | 값 | 설명 |
|--------|-----|------|
| `x-ms-blob-type` | `BlockBlob` | Blob 유형 (필수) |
| `x-ms-version` | `2021-08-06` | Blob REST API 버전 (필수) |
| `Content-Type` | `application/json` | Body 형식 |

> `x-ms-version`을 누락하면 `AuthenticationFailed` 또는 `InvalidHeaderValue` 에러가 발생합니다.

### 8.3 URL 구성 규칙

```
https://{storage_account}.blob.core.windows.net/{container}/{blob_path}
```

- `blob_path`에 `/`를 포함하면 가상 디렉터리가 자동 생성됩니다
- 동일 경로에 PUT하면 기존 파일을 **덮어씁니다**
- RunId를 파일명에 포함하면 실행마다 고유 파일이 생성됩니다

### 8.4 Body 크기 제한

- Web Activity Body: **최대 256KB**
- 일반적인 로그 JSON은 수백 바이트이므로 문제없음
- 대용량 에러 메시지는 `substring()`으로 잘라서 저장 권장:
  ```
  substring(activity('Copy_DB2_to_ADLS').error.message, 0, min(length(activity('Copy_DB2_to_ADLS').error.message), 2000))
  ```

---

**참고:** [Lab 3 — 에러 핸들링](lab3-delete-error-handling.md) | [부록 D — ADF 표현식](appendix-d-expression-reference.md)
