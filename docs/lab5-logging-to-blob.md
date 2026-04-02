# Lab 5. Copy/Pipeline 실행 로깅 (차일드 파이프라인 방식)

> **난이도:** ⭐⭐⭐ 중급+ | **소요시간:** 60분 | **사전 조건:** [Lab 3](lab3-delete-error-handling.md) 완료

## 목표

- Copy Activity 실행 결과를 **마스터 파이프라인에서 수집**
- 로그 정보를 **파라메터로 차일드 로깅 파이프라인에 전달**
- 차일드 파이프라인이 **Web Activity + Blob REST API**로 JSON 로그 저장
- 성공/실패 **모든 케이스** 로그 기록

## 왜 차일드 파이프라인으로 분리하나?

| 구분 | 같은 파이프라인 내 Web Activity | 차일드 파이프라인 분리 |
|------|-------------------------------|---------------------|
| 재사용 | Copy마다 Web Activity 2개 반복 추가 | **로깅 파이프라인 1개로 전체 공유** |
| 유지보수 | 로그 포맷 변경 시 모든 파이프라인 수정 | **차일드 1개만 수정** |
| 로그 대상 변경 | Blob→DB 전환 시 전체 수정 | **차일드만 교체** |
| 복사 파이프라인 | Web Activity로 복잡해짐 | **Copy + Execute Pipeline만** 깔끔 |

---

## 전체 아키텍처

```
┌──────────────────────────────────────────────────────────────────────────┐
│  PL_Copy_DB2_to_ADLS_Child (마스터 = 복사 파이프라인)                    │
│                                                                         │
│  ┌──────────┐ comp. ┌──────────────┐ success ┌────────────────────────┐ │
│  │ Delete   │──────▶│ Copy         │────────▶│ Exec_Log_Success      │ │
│  │ Existing │       │ DB2→ADLS     │         │ (Execute Pipeline)    │ │
│  └──────────┘       └──────┬───────┘         │ → PL_Log_To_Blob     │ │
│                            │ failure         └────────────────────────┘ │
│                            ▼                                            │
│                     ┌────────────────────────┐                          │
│                     │ Exec_Log_Failure       │                          │
│                     │ (Execute Pipeline)     │                          │
│                     │ → PL_Log_To_Blob       │                          │
│                     └────────────────────────┘                          │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PL_Log_To_Blob (차일드 = 로깅 전용 파이프라인)                         │
│                                                                         │
│  ┌──────────────────────────────┐                                       │
│  │ Web Activity: Write_Log     │                                        │
│  │ PUT → Blob REST API         │                                        │
│  │ Body = 파라메터로 받은 JSON │                                        │
│  └──────────────────────────────┘                                       │
│                                                                         │
│  파라메터로 받는 값:                                                     │
│    p_log_status, p_pipeline_name, p_run_id, p_table_name,               │
│    p_load_date, p_target_path, p_rows_read, p_rows_copied,              │
│    p_data_read, p_data_written, p_duration, p_error_message             │
└──────────────────────────────────────────────────────────────────────────┘

로그 저장 경로:
  pipeline-logs/YYYY/MM/DD/{pipeline}_{runid}_{table}_{status}.json
```

---

## Part 1. 사전 구성

### 1.1 Blob Storage 로그 컨테이너 준비

기존 ADLS Gen2 스토리지 계정에 로그 전용 컨테이너를 생성합니다.

```
Storage Account → Containers → + Container
  Name       : pipeline-logs
  Access level: Private
```

### 1.2 ADF Managed Identity 권한 확인

```
Storage Account → Access Control (IAM) → + Add role assignment
  Role       : Storage Blob Data Contributor
  Assign to  : Managed identity → <ADF 인스턴스 이름>
```

> Lab 1에서 계정 수준으로 이미 할당했다면 추가 작업 불필요합니다.

### 1.3 Copy Activity output 속성 참고

마스터에서 차일드로 전달할 데이터입니다.

**성공 시 사용 가능 속성:**

| 속성 | 표현식 | 예시 값 |
|------|--------|--------|
| 읽은 행 수 | `activity('Copy_DB2_to_ADLS').output.rowsRead` | `20` |
| 복사 행 수 | `activity('Copy_DB2_to_ADLS').output.rowsCopied` | `20` |
| 읽은 바이트 | `activity('Copy_DB2_to_ADLS').output.dataRead` | `4560` |
| 쓴 바이트 | `activity('Copy_DB2_to_ADLS').output.dataWritten` | `3820` |
| 소요 시간(초) | `activity('Copy_DB2_to_ADLS').output.copyDuration` | `5` |
| 처리량(KB/s) | `activity('Copy_DB2_to_ADLS').output.throughput` | `0.89` |

**실패 시 사용 가능 속성:**

| 속성 | 표현식 |
|------|--------|
| 에러 메시지 | `activity('Copy_DB2_to_ADLS').error.message` |
| 에러 코드 | `activity('Copy_DB2_to_ADLS').error.errorCode` |

> **주의:** 실패 시 `output.rowsRead` 등은 존재하지 않습니다.
> 성공/실패 분기에서 각각 다른 값을 전달해야 합니다.

---

## Part 2. 차일드 로깅 파이프라인 생성 (PL_Log_To_Blob)

### 2.1 파이프라인 생성

```
[Author] → [Pipelines] → [+] → [Pipeline] → [Blank Pipeline]
→ Name: PL_Log_To_Blob
```

### 2.2 파라메터 정의

파이프라인 캔버스 빈 영역 클릭 → 하단 **[Parameters]** 탭

| Name | Type | Default Value | 설명 |
|------|------|--------------|------|
| `p_log_status` | String | `SUCCESS` | SUCCESS / FAILED |
| `p_pipeline_name` | String | (비워둠) | 호출한 파이프라인 이름 |
| `p_run_id` | String | (비워둠) | 호출한 파이프라인 RunId |
| `p_trigger_name` | String | `Manual` | 트리거 이름 |
| `p_source_table` | String | (비워둠) | 소스 테이블 (schema.table) |
| `p_target_path` | String | (비워둠) | Parquet 파일 전체 경로 |
| `p_load_date` | String | (비워둠) | 수집 날짜 (yyyyMMdd) |
| `p_rows_read` | String | `0` | 읽은 행 수 |
| `p_rows_copied` | String | `0` | 복사 행 수 |
| `p_data_read` | String | `0` | 읽은 바이트 |
| `p_data_written` | String | `0` | 쓴 바이트 |
| `p_duration_sec` | String | `0` | 소요 시간 (초) |
| `p_error_message` | String | (비워둠) | 에러 메시지 (실패 시) |

> 모든 파라메터를 **String 타입**으로 통일합니다.
> 숫자도 String으로 받아서 JSON Body 조립 시 그대로 사용합니다.

### 2.3 Activity: Write_Log (Web Activity)

```
[Activities] → [General] → Web → 캔버스에 드래그
Activity 이름: Write_Log
```

#### General 탭

| 설정 | 값 |
|------|-----|
| Name | `Write_Log` |
| Timeout | `0.00:01:00` |
| Retry | 2 |
| Retry interval (sec) | 10 |

#### Settings 탭

| 설정 | 값 |
|------|-----|
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
    pipeline().parameters.p_pipeline_name,
    '_',
    pipeline().parameters.p_run_id,
    '_',
    replace(pipeline().parameters.p_source_table, '.', '_'),
    '_',
    pipeline().parameters.p_log_status,
    '.json'
)
```

> `<storage_account>`을 실제 스토리지 계정명으로 교체하세요.
>
> `replace(..., '.', '_')` — 테이블명의 `ETL_SCHEMA.TB_CUSTOMER`에서 `.`을 `_`로 변환하여 파일명에 사용합니다.

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
        '"pipeline_name":"', pipeline().parameters.p_pipeline_name, '",',
        '"run_id":"', pipeline().parameters.p_run_id, '",',
        '"trigger_name":"', pipeline().parameters.p_trigger_name, '",',
        '"source_table":"', pipeline().parameters.p_source_table, '",',
        '"target_path":"', pipeline().parameters.p_target_path, '",',
        '"load_date":"', pipeline().parameters.p_load_date, '",',
        '"status":"', pipeline().parameters.p_log_status, '",',
        '"rows_read":', pipeline().parameters.p_rows_read, ',',
        '"rows_copied":', pipeline().parameters.p_rows_copied, ',',
        '"data_read_bytes":', pipeline().parameters.p_data_read, ',',
        '"data_written_bytes":', pipeline().parameters.p_data_written, ',',
        '"copy_duration_sec":', pipeline().parameters.p_duration_sec, ',',
        '"error_message":',
            if(
                empty(pipeline().parameters.p_error_message),
                'null',
                concat('"', pipeline().parameters.p_error_message, '"')
            ),
        '}'
    )
)
```

> **포인트:** 차일드 파이프라인은 파라메터만 받아서 JSON을 조립하고 Blob에 PUT합니다.
> Copy Activity 참조가 없으므로 **어떤 파이프라인에서든 호출 가능**합니다.

### 2.4 차일드 파이프라인 완성 흐름

```
PL_Log_To_Blob

  Parameters (13개)
       │
       ▼
  ┌──────────────────┐
  │ Write_Log        │
  │ (Web Activity)   │
  │ PUT → Blob REST  │
  └──────────────────┘
```

---

## Part 3. 마스터 파이프라인에서 차일드 호출

### 3.1 기존 차일드(복사) 파이프라인에 Execute Pipeline 추가

기존 `PL_Copy_DB2_to_ADLS_Child` 파이프라인을 수정합니다.

현재 흐름 (Lab 3):
```
Delete → (comp.) → Copy_DB2_to_ADLS → (failure) → Set_Error_Message
```

변경 후 흐름 (Lab 5):
```
Delete → (comp.) → Copy_DB2_to_ADLS → (success) → Exec_Log_Success
                                     → (failure) → Exec_Log_Failure
```

### 3.2 Activity: Exec_Log_Success (성공 시)

```
[Activities] → [General] → Execute Pipeline → 캔버스에 드래그
Activity 이름: Exec_Log_Success
```

**연결:** `Copy_DB2_to_ADLS` → **(On success)** → `Exec_Log_Success`

#### Settings 탭

| 설정 | 값 |
|------|-----|
| Invoked pipeline | `PL_Log_To_Blob` |
| Wait on completion | ✅ 체크 |

#### Parameters 매핑 (성공)

| Parameter | Value |
|-----------|-------|
| `p_log_status` | `SUCCESS` |
| `p_pipeline_name` | `@pipeline().Pipeline` |
| `p_run_id` | `@pipeline().RunId` |
| `p_trigger_name` | `@pipeline().TriggerName` |
| `p_source_table` | `@concat(pipeline().parameters.p_schema_name, '.', pipeline().parameters.p_table_name)` |
| `p_target_path` | `@concat(pipeline().parameters.p_container, '/', pipeline().parameters.p_db_name, '/', pipeline().parameters.p_schema_name, '/', pipeline().parameters.p_table_name, '_', pipeline().parameters.p_load_date, '.parquet')` |
| `p_load_date` | `@pipeline().parameters.p_load_date` |
| `p_rows_read` | `@string(activity('Copy_DB2_to_ADLS').output.rowsRead)` |
| `p_rows_copied` | `@string(activity('Copy_DB2_to_ADLS').output.rowsCopied)` |
| `p_data_read` | `@string(activity('Copy_DB2_to_ADLS').output.dataRead)` |
| `p_data_written` | `@string(activity('Copy_DB2_to_ADLS').output.dataWritten)` |
| `p_duration_sec` | `@string(activity('Copy_DB2_to_ADLS').output.copyDuration)` |
| `p_error_message` | (빈 값) |

> **핵심:** `@string()`으로 숫자를 문자열로 변환하여 전달합니다.
> 차일드 파라메터가 모두 String 타입이므로 형 변환이 필수입니다.

### 3.3 Activity: Exec_Log_Failure (실패 시)

```
[Activities] → [General] → Execute Pipeline → 캔버스에 드래그
Activity 이름: Exec_Log_Failure
```

**연결:** `Copy_DB2_to_ADLS` → **(On failure)** → `Exec_Log_Failure`

#### Settings 탭

| 설정 | 값 |
|------|-----|
| Invoked pipeline | `PL_Log_To_Blob` |
| Wait on completion | ✅ 체크 |

#### Parameters 매핑 (실패)

| Parameter | Value |
|-----------|-------|
| `p_log_status` | `FAILED` |
| `p_pipeline_name` | `@pipeline().Pipeline` |
| `p_run_id` | `@pipeline().RunId` |
| `p_trigger_name` | `@pipeline().TriggerName` |
| `p_source_table` | `@concat(pipeline().parameters.p_schema_name, '.', pipeline().parameters.p_table_name)` |
| `p_target_path` | `@concat(pipeline().parameters.p_container, '/', pipeline().parameters.p_db_name, '/', pipeline().parameters.p_schema_name, '/', pipeline().parameters.p_table_name, '_', pipeline().parameters.p_load_date, '.parquet')` |
| `p_load_date` | `@pipeline().parameters.p_load_date` |
| `p_rows_read` | `0` |
| `p_rows_copied` | `0` |
| `p_data_read` | `0` |
| `p_data_written` | `0` |
| `p_duration_sec` | `0` |
| `p_error_message` | `@replace(activity('Copy_DB2_to_ADLS').error.message, '"', '\\"')` |

> **주의 사항:**
> - 실패 시 `output.rowsRead` 등은 **존재하지 않으므로** 하드코딩 `0`을 전달합니다
> - `error.message`에 큰따옴표(`"`)가 포함될 수 있으므로 `replace()`로 이스케이프합니다
> - 에러 메시지가 매우 긴 경우:
>   ```
>   @substring(
>       replace(activity('Copy_DB2_to_ADLS').error.message, '"', '\\"'),
>       0,
>       min(length(activity('Copy_DB2_to_ADLS').error.message), 2000)
>   )
>   ```

### 3.4 최종 복사 파이프라인 흐름 (Lab 5 반영)

```
PL_Copy_DB2_to_ADLS_Child

  ┌──────────┐ comp. ┌──────────────┐ success ┌─────────────────────┐
  │ Delete   │──────▶│ Copy         │────────▶│ Exec_Log_Success    │
  │ Existing │       │ DB2_to_ADLS  │         │ → PL_Log_To_Blob    │
  │ Parquet  │       │              │         │   (파라메터 전달)    │
  └──────────┘       └──────┬───────┘         └─────────────────────┘
                            │ failure
                            ▼
                     ┌─────────────────────┐
                     │ Exec_Log_Failure    │
                     │ → PL_Log_To_Blob    │
                     │   (파라메터 전달)    │
                     └─────────────────────┘
```

---

## Part 4. Web Activity Blob REST API 설정 상세

### 4.1 인증 구성

| 항목 | 값 | 설명 |
|------|-----|------|
| Authentication | **Managed Identity** | System-assigned MI 사용 |
| Resource | `https://storage.azure.com/` | 이 값은 고정 (변경하면 인증 실패) |

### 4.2 필수 Headers

| Header | 값 | 누락 시 에러 |
|--------|-----|-------------|
| `x-ms-blob-type` | `BlockBlob` | `InvalidHeaderValue` |
| `x-ms-version` | `2021-08-06` | `AuthenticationFailed` |
| `Content-Type` | `application/json` | (선택이지만 권장) |

### 4.3 PUT URL 구성

```
https://{storage_account}.blob.core.windows.net/{container}/{virtual_directory}/{filename}
```

- URL에 `/`를 포함하면 **가상 디렉터리가 자동 생성**됩니다
- 동일 URL로 PUT하면 **기존 파일 덮어쓰기**
- `RunId`를 파일명에 포함하면 **실행마다 고유 파일 보장**

### 4.4 Body 크기 제한

| 제한 | 값 |
|------|-----|
| Web Activity Body 최대 | **256 KB** |
| 일반 로그 JSON 크기 | 500 ~ 2,000 bytes |

---

## Part 5. 실행 및 검증

### 5.1 검증 체크리스트

- [ ] `pipeline-logs` 컨테이너 생성 완료
- [ ] ADF Managed Identity에 Storage Blob Data Contributor 할당 완료
- [ ] `PL_Log_To_Blob` 차일드 파이프라인 생성 (파라메터 13개, Web Activity 1개)
- [ ] `PL_Copy_DB2_to_ADLS_Child`에 Exec_Log_Success / Exec_Log_Failure 추가
- [ ] 마스터 파이프라인 Debug 실행

### 5.2 성공 시 로그 파일 확인

```
pipeline-logs/
└── 2026/
    └── 03/
        └── 26/
            ├── PL_Copy_DB2_to_ADLS_Child_{runid1}_ETL_SCHEMA_TB_CUSTOMER_SUCCESS.json
            ├── PL_Copy_DB2_to_ADLS_Child_{runid2}_ETL_SCHEMA_TB_ORDER_SUCCESS.json
            ├── PL_Copy_DB2_to_ADLS_Child_{runid3}_ETL_SCHEMA_TB_PRODUCT_SUCCESS.json
            └── PL_Copy_DB2_to_ADLS_Child_{runid4}_ETL_SCHEMA_TB_INVENTORY_SUCCESS.json
```

**파일 내용 예시:**
```json
{
  "log_timestamp": "2026-03-26T10:30:00.1234567Z",
  "pipeline_name": "PL_Copy_DB2_to_ADLS_Child",
  "run_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
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
  "error_message": null
}
```

### 5.3 실패 테스트

1. Config 테이블에서 존재하지 않는 테이블명으로 변경
2. 마스터 파이프라인 Debug 실행
3. Blob 확인: `..._FAILED.json` 파일 내 `error_message` 확인
4. Config 원복

### 5.4 Monitor에서 실행 추적

```
PL_Master_DB2_Ingestion_V2
  └─ ForEach_Config_Tables
       ├─ PL_Copy_DB2_to_ADLS_Child (TB_CUSTOMER)
       │    ├─ Delete_Existing_Parquet
       │    ├─ Copy_DB2_to_ADLS              ← 성공
       │    └─ Exec_Log_Success
       │         └─ PL_Log_To_Blob           ← 로그 기록
       │              └─ Write_Log (Web PUT)
       │
       ├─ PL_Copy_DB2_to_ADLS_Child (TB_NOT_EXIST)
       │    ├─ Delete_Existing_Parquet
       │    ├─ Copy_DB2_to_ADLS              ← 실패!
       │    └─ Exec_Log_Failure
       │         └─ PL_Log_To_Blob           ← 실패 로그 기록
       │              └─ Write_Log (Web PUT)
       ...
```

### 5.5 Databricks에서 로그 분석 (선택)

```sql
-- 전체 로그 조회
SELECT * FROM json.`abfss://pipeline-logs@<account>.dfs.core.windows.net/2026/03/26/*.json`;

-- 일자별 성공/실패 요약
SELECT load_date, status, COUNT(*) AS cnt, SUM(rows_copied) AS total_rows
FROM json.`abfss://pipeline-logs@<account>.dfs.core.windows.net/2026/**/*.json`
GROUP BY load_date, status
ORDER BY load_date;
```

---

## Part 6. 다른 파이프라인에서 PL_Log_To_Blob 재사용

`PL_Log_To_Blob`는 **Copy Activity 참조가 없는 독립 파이프라인**이므로 어디서든 호출 가능합니다.

```
PL_DataFlow_Transform
  └─ Data Flow → (success) → Execute Pipeline → PL_Log_To_Blob
                → (failure) → Execute Pipeline → PL_Log_To_Blob

PL_API_Ingestion
  └─ Web GET → Copy → (success) → Execute Pipeline → PL_Log_To_Blob
```

> 파라메터만 채워서 호출하면 되므로 **모든 ADF 파이프라인의 공통 로깅 모듈**로 활용됩니다.

---

## Part 7. 주의사항 및 팁

### 7.1 Wait on completion 설정

| 설정 | 동작 | 권장 |
|------|------|------|
| ✅ 체크 | 로깅 실패 시 복사 파이프라인도 실패 표시 | 로그 누락 불허 시 |
| ❌ 해제 | 로깅 실패해도 복사 파이프라인 성공 유지 | **운영 환경 권장** |

### 7.2 ForEach 병렬 실행 시 로그 충돌?

RunId가 파일명에 포함되므로 **파일 충돌 없음**. 4개 테이블 병렬 → 4개 로그 파일 독립 생성.

### 7.3 로그 보존 정책 (Lifecycle Management)

```
Storage Account → Lifecycle management → + Add a rule
  Name   : delete-old-pipeline-logs
  Filter : pipeline-logs/
  Action : Delete blob after 90 days
```

---

**참고:** [Lab 3 — 에러 핸들링](lab3-delete-error-handling.md) | [부록 D — ADF 표현식](appendix-d-expression-reference.md)
