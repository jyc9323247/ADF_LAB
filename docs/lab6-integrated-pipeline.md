# Lab 6. 통합 파이프라인: Config Lookup + ForEach + Copy + 로깅

> **난이도:** ⭐⭐⭐ 중급+ | **소요시간:** 90분 | **사전 조건:** [Lab 2 확장](lab2-ext-lookup-foreach.md), [Lab 5](lab5-logging-to-blob.md) 이해

## 목표

- Lab 2 확장 (Config Lookup + ForEach)과 Lab 5 (차일드 로깅)를 **하나의 운영 파이프라인으로 통합**
- 3단 파이프라인 구조: **마스터 → 복사 차일드 → 로깅 차일드**
- Config 테이블 기반 동적 수집 + 테이블별 성공/실패 Blob 로그 기록
- 실제 운영 환경에서 바로 사용할 수 있는 완성형 파이프라인

---

## 전체 아키텍처 (3단 파이프라인)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  PL_Master_Ingestion (마스터)                                               │
│                                                                             │
│  ┌────────────┐  success  ┌────────────┐  success  ┌─────────────────────┐  │
│  │ Set        │──────────▶│ Lookup     │──────────▶│ ForEach             │  │
│  │ Load_Date  │           │ Config     │           │ Config_Tables       │  │
│  └────────────┘           └────────────┘           └─────────┬───────────┘  │
│                                                              │ (each item)  │
│                                                    ┌─────────▼───────────┐  │
│                                                    │ Execute Pipeline    │  │
│                                                    │ → PL_Copy_Child     │  │
│                                                    └─────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  PL_Copy_Child (복사 차일드)                                                │
│                                                                             │
│  ┌──────────┐ comp. ┌──────────┐ success ┌──────────────────────────────┐   │
│  │ Delete   │──────▶│ Copy     │────────▶│ Exec_Log_Success            │   │
│  │ Existing │       │ DB2→ADLS │         │ → PL_Log_To_Blob            │   │
│  └──────────┘       └────┬─────┘         │   (output 파라메터 전달)    │   │
│                          │ failure       └──────────────────────────────┘   │
│                          ▼                                                  │
│                   ┌──────────────────────────────┐                          │
│                   │ Exec_Log_Failure             │                          │
│                   │ → PL_Log_To_Blob             │                          │
│                   │   (error 파라메터 전달)       │                          │
│                   └──────────────────────────────┘                          │
└──────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  PL_Log_To_Blob (로깅 차일드)                                               │
│                                                                             │
│  ┌──────────────────────────────┐                                           │
│  │ Write_Log (Web Activity)    │                                            │
│  │ PUT → Blob REST API         │                                            │
│  │ 파라메터 → JSON → Blob 저장 │                                            │
│  └──────────────────────────────┘                                           │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Part 1. 사전 준비 체크리스트

이전 Lab에서 만든 리소스를 확인합니다. 누락된 항목이 있으면 해당 Lab을 참고하세요.

| 항목 | 출처 | 확인 |
|------|------|------|
| `LS_DB2_OnPrem` (Linked Service) | [부록 B](appendix-b-linked-service.md) | ☐ |
| `LS_ADLS_Gen2` (Linked Service) | [부록 B](appendix-b-linked-service.md) | ☐ |
| `LS_AzureSQLDB_Config` (Linked Service) | [Lab 2 확장](lab2-ext-lookup-foreach.md) | ☐ |
| `DS_DB2_Parameterized` (Dataset) | [Lab 2](lab2-parameterized-pipeline.md) | ☐ |
| `DS_ADLS_Parquet_Parameterized` (Dataset) | [Lab 2](lab2-parameterized-pipeline.md) | ☐ |
| `DS_AzureSQL_Config` (Dataset) | [Lab 2 확장](lab2-ext-lookup-foreach.md) | ☐ |
| `dbo.ADF_PIPELINE_CONFIG` (테이블) | [sql/04_config_table.sql](../sql/04_config_table.sql) | ☐ |
| `pipeline-logs` (Blob 컨테이너) | [Lab 5](lab5-logging-to-blob.md) | ☐ |
| ADF MI → Storage Blob Data Contributor | [Lab 5](lab5-logging-to-blob.md) | ☐ |

---

## Part 2. 파이프라인 3개 생성 개요

| # | 파이프라인 이름 | 역할 | Activity 수 |
|---|---------------|------|------------|
| ① | `PL_Log_To_Blob` | 로깅 전용 차일드 | Web Activity 1개 |
| ② | `PL_Copy_Child` | 복사 + 로깅 호출 | Delete + Copy + Execute Pipeline 2개 |
| ③ | `PL_Master_Ingestion` | Config 조회 + ForEach 오케스트레이션 | Set Variable + Lookup + ForEach |

> **생성 순서:** ① → ② → ③ (차일드부터 만들어야 마스터에서 참조 가능)

---

## Part 3. ① PL_Log_To_Blob (로깅 차일드)

> Lab 5에서 이미 생성했다면 **그대로 재사용**합니다. 새로 만드는 경우 아래를 따르세요.

### 3.1 파이프라인 생성

```
[Author] → [Pipelines] → [+] → [Pipeline]
→ Name: PL_Log_To_Blob
```

### 3.2 파라메터 (13개)

| Name | Type | Default | 설명 |
|------|------|---------|------|
| `p_log_status` | String | `SUCCESS` | SUCCESS / FAILED |
| `p_pipeline_name` | String | | 호출 파이프라인 이름 |
| `p_run_id` | String | | 호출 파이프라인 RunId |
| `p_trigger_name` | String | `Manual` | 트리거 이름 |
| `p_source_table` | String | | schema.table |
| `p_target_path` | String | | Parquet 전체 경로 |
| `p_load_date` | String | | yyyyMMdd |
| `p_rows_read` | String | `0` | 읽은 행 수 |
| `p_rows_copied` | String | `0` | 복사 행 수 |
| `p_data_read` | String | `0` | 읽은 바이트 |
| `p_data_written` | String | `0` | 쓴 바이트 |
| `p_duration_sec` | String | `0` | 소요 시간(초) |
| `p_error_message` | String | | 에러 메시지 |

### 3.3 Activity: Write_Log (Web Activity)

| 설정 | 값 |
|------|-----|
| Method | **PUT** |
| Authentication | **Managed Identity** |
| Resource | `https://storage.azure.com/` |

**URL:**
```
@concat(
    'https://<storage_account>.blob.core.windows.net/pipeline-logs/',
    formatDateTime(utcNow(), 'yyyy'), '/',
    formatDateTime(utcNow(), 'MM'), '/',
    formatDateTime(utcNow(), 'dd'), '/',
    pipeline().parameters.p_pipeline_name, '_',
    pipeline().parameters.p_run_id, '_',
    replace(pipeline().parameters.p_source_table, '.', '_'), '_',
    pipeline().parameters.p_log_status, '.json'
)
```

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
            if(empty(pipeline().parameters.p_error_message),
               'null',
               concat('"', pipeline().parameters.p_error_message, '"')),
        '}'
    )
)
```

---

## Part 4. ② PL_Copy_Child (복사 + 로깅 호출 차일드)

### 4.1 파이프라인 생성

```
[Author] → [Pipelines] → [+] → [Pipeline]
→ Name: PL_Copy_Child
```

### 4.2 파라메터 (8개)

| Name | Type | Default | 설명 |
|------|------|---------|------|
| `p_container` | String | `datalake` | ADLS 컨테이너 |
| `p_db_name` | String | `SAMPLEDB` | DB2 데이터베이스명 |
| `p_schema_name` | String | `ETL_SCHEMA` | DB2 스키마명 |
| `p_table_name` | String | | DB2 테이블명 |
| `p_load_date` | String | | 수집 날짜 (yyyyMMdd) |
| `p_load_type` | String | `FULL` | FULL / INCR |
| `p_incr_column` | String | | 증분 기준 컬럼 |
| `p_custom_query` | String | | 커스텀 쿼리 |

### 4.3 파이프라인 흐름

```
┌──────────────┐ comp. ┌──────────────┐ success ┌────────────────────┐
│ Delete       │──────▶│ Copy         │────────▶│ Exec_Log_Success   │
│ Existing     │       │ DB2_to_ADLS  │         │ → PL_Log_To_Blob   │
│ Parquet      │       │              │         └────────────────────┘
└──────────────┘       └──────┬───────┘
                              │ failure
                              ▼
                       ┌────────────────────┐
                       │ Exec_Log_Failure   │
                       │ → PL_Log_To_Blob   │
                       └────────────────────┘
```

### 4.4 Activity 1: Delete_Existing_Parquet

```
[Activities] → [General] → Delete → 드래그
Activity 이름: Delete_Existing_Parquet
```

| 설정 | 값 |
|------|-----|
| Dataset | `DS_ADLS_Parquet_Parameterized` |
| `ds_container` | `@pipeline().parameters.p_container` |
| `ds_directory` | `@concat(pipeline().parameters.p_db_name, '/', pipeline().parameters.p_schema_name)` |
| `ds_filename` | `@concat(pipeline().parameters.p_table_name, '_', pipeline().parameters.p_load_date, '.parquet')` |

### 4.5 Activity 2: Copy_DB2_to_ADLS

**연결:** `Delete_Existing_Parquet` → **(On completion)** → `Copy_DB2_to_ADLS`

#### Source 탭

| 설정 | 값 |
|------|-----|
| Dataset | `DS_DB2_Parameterized` |
| Use query | **Query** |

**Query (동적 분기 — FULL / INCR / custom_query):**
```
@if(
    not(empty(pipeline().parameters.p_custom_query)),
    pipeline().parameters.p_custom_query,
    if(
        equals(pipeline().parameters.p_load_type, 'INCR'),
        concat(
            'SELECT * FROM ',
            pipeline().parameters.p_schema_name, '.',
            pipeline().parameters.p_table_name,
            ' WHERE ', pipeline().parameters.p_incr_column,
            ' >= ''',
            formatDateTime(addDays(parseDateTime(pipeline().parameters.p_load_date,'yyyyMMdd'),-1),'yyyy-MM-dd'),
            ''' AND ', pipeline().parameters.p_incr_column,
            ' < ''',
            formatDateTime(parseDateTime(pipeline().parameters.p_load_date,'yyyyMMdd'),'yyyy-MM-dd'),
            ''' WITH UR'
        ),
        concat(
            'SELECT * FROM ',
            pipeline().parameters.p_schema_name, '.',
            pipeline().parameters.p_table_name,
            ' WITH UR'
        )
    )
)
```

#### Sink 탭

| 설정 | 값 |
|------|-----|
| Dataset | `DS_ADLS_Parquet_Parameterized` |
| `ds_container` | `@pipeline().parameters.p_container` |
| `ds_directory` | `@concat(pipeline().parameters.p_db_name, '/', pipeline().parameters.p_schema_name)` |
| `ds_filename` | `@concat(pipeline().parameters.p_table_name, '_', pipeline().parameters.p_load_date, '.parquet')` |
| Compression | snappy |

### 4.6 Activity 3: Exec_Log_Success (성공 시)

```
[Activities] → [General] → Execute Pipeline → 드래그
Activity 이름: Exec_Log_Success
```

**연결:** `Copy_DB2_to_ADLS` → **(On success)** → `Exec_Log_Success`

| 설정 | 값 |
|------|-----|
| Invoked pipeline | `PL_Log_To_Blob` |
| Wait on completion | ❌ 해제 (로깅 실패가 복사 결과에 영향 안 줌) |

**Parameters 매핑:**

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

### 4.7 Activity 4: Exec_Log_Failure (실패 시)

```
[Activities] → [General] → Execute Pipeline → 드래그
Activity 이름: Exec_Log_Failure
```

**연결:** `Copy_DB2_to_ADLS` → **(On failure)** → `Exec_Log_Failure`

| 설정 | 값 |
|------|-----|
| Invoked pipeline | `PL_Log_To_Blob` |
| Wait on completion | ❌ 해제 |

**Parameters 매핑:**

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

---

## Part 5. ③ PL_Master_Ingestion (마스터)

### 5.1 파이프라인 생성

```
[Author] → [Pipelines] → [+] → [Pipeline]
→ Name: PL_Master_Ingestion
```

### 5.2 파라메터

| Name | Type | Default |
|------|------|---------|
| `p_source_system` | String | `DB2_ONPREM` |
| `p_load_date` | String | (빈 값 — 트리거에서 주입 또는 자동 생성) |

### 5.3 Variables

| Name | Type | Default |
|------|------|---------|
| `v_load_date` | String | |

### 5.4 파이프라인 흐름

```
┌────────────┐ success ┌────────────┐ success ┌────────────────────┐
│ Set        │────────▶│ Lookup     │────────▶│ ForEach            │
│ Load_Date  │         │ Config     │         │ Config_Tables      │
└────────────┘         └────────────┘         └─────────┬──────────┘
                                                        │ (each)
                                              ┌─────────▼──────────┐
                                              │ Exec_Copy_Child    │
                                              │ → PL_Copy_Child    │
                                              └────────────────────┘
```

### 5.5 Activity 1: Set_Load_Date

```
[Activities] → [General] → Set variable → 드래그
Activity 이름: Set_Load_Date
```

| 설정 | 값 |
|------|-----|
| Name | `v_load_date` |
| Value | (아래 표현식) |

```
@if(
    empty(pipeline().parameters.p_load_date),
    formatDateTime(addHours(utcNow(), 9), 'yyyyMMdd'),
    pipeline().parameters.p_load_date
)
```

> 빈 값이면 한국시간(UTC+9) 당일 날짜 자동 생성. 명시적 날짜 전달 시 그대로 사용 (재수집용).

### 5.6 Activity 2: Lookup_Config

**연결:** `Set_Load_Date` → (On success) → `Lookup_Config`

| 설정 | 값 |
|------|-----|
| Source dataset | `DS_AzureSQL_Config` |
| Use query | Query |
| ☑ First row only | **❌ 체크 해제** |

**Query:**
```
@concat(
    'SELECT config_id, source_system, db_name, schema_name, ',
    'table_name, load_type, incr_column, custom_query, ',
    'target_container ',
    'FROM dbo.ADF_PIPELINE_CONFIG ',
    'WHERE source_system = ''', pipeline().parameters.p_source_system,
    ''' AND is_active = 1 ',
    'ORDER BY priority_order'
)
```

### 5.7 Activity 3: ForEach_Config_Tables

**연결:** `Lookup_Config` → (On success) → `ForEach_Config_Tables`

| 설정 | 값 |
|------|-----|
| Items | `@activity('Lookup_Config').output.value` |
| Sequential | false |
| Batch count | 4 (SHIR 부하에 따라 조정) |

### 5.8 ForEach 내부: Exec_Copy_Child

ForEach 더블클릭 → 내부 캔버스

```
[Activities] → [General] → Execute Pipeline → 드래그
Activity 이름: Exec_Copy_Child
```

| 설정 | 값 |
|------|-----|
| Invoked pipeline | `PL_Copy_Child` |
| Wait on completion | ✅ 체크 |

**Parameters 매핑:**

| Parameter | Value |
|-----------|-------|
| `p_container` | `@item().target_container` |
| `p_db_name` | `@item().db_name` |
| `p_schema_name` | `@item().schema_name` |
| `p_table_name` | `@item().table_name` |
| `p_load_date` | `@variables('v_load_date')` |
| `p_load_type` | `@item().load_type` |
| `p_incr_column` | `@coalesce(item().incr_column, '')` |
| `p_custom_query` | `@coalesce(item().custom_query, '')` |

---

## Part 6. 실행 및 검증

### 6.1 Config 테이블 확인

```sql
SELECT config_id, table_name, load_type, is_active, priority_order
FROM dbo.ADF_PIPELINE_CONFIG
WHERE source_system = 'DB2_ONPREM' AND is_active = 1
ORDER BY priority_order;
```

예상 결과: 4건 (TB_CUSTOMER, TB_ORDER, TB_PRODUCT, TB_INVENTORY)

### 6.2 마스터 파이프라인 Debug 실행

```
PL_Master_Ingestion → [Debug]
  p_source_system: DB2_ONPREM
  p_load_date: (비워둠 → 당일 자동)
```

### 6.3 Monitor 추적 (3단 파이프라인)

```
PL_Master_Ingestion                              ← 마스터
│
├─ Set_Load_Date                                  (v_load_date = 20260326)
├─ Lookup_Config                                  (count = 4)
└─ ForEach_Config_Tables                          (4건 병렬)
     │
     ├─ Exec_Copy_Child (TB_CUSTOMER) ────────────── PL_Copy_Child
     │    ├─ Delete_Existing_Parquet                   ← 삭제 (또는 skip)
     │    ├─ Copy_DB2_to_ADLS                          ← 20건 복사 ✅
     │    └─ Exec_Log_Success ────────────────────── PL_Log_To_Blob
     │         └─ Write_Log (Web PUT)                  ← SUCCESS.json 생성
     │
     ├─ Exec_Copy_Child (TB_ORDER) ───────────────── PL_Copy_Child
     │    ├─ Delete_Existing_Parquet
     │    ├─ Copy_DB2_to_ADLS                          ← INCR 증분 복사 ✅
     │    └─ Exec_Log_Success ────────────────────── PL_Log_To_Blob
     │         └─ Write_Log                            ← SUCCESS.json 생성
     │
     ├─ Exec_Copy_Child (TB_PRODUCT) ─────────────── PL_Copy_Child
     │    ├─ Delete_Existing_Parquet
     │    ├─ Copy_DB2_to_ADLS                          ← 전체 복사 ✅
     │    └─ Exec_Log_Success ────────────────────── PL_Log_To_Blob
     │         └─ Write_Log                            ← SUCCESS.json 생성
     │
     └─ Exec_Copy_Child (TB_INVENTORY) ───────────── PL_Copy_Child
          ├─ Delete_Existing_Parquet
          ├─ Copy_DB2_to_ADLS                          ← custom_query 복사 ✅
          └─ Exec_Log_Success ────────────────────── PL_Log_To_Blob
               └─ Write_Log                            ← SUCCESS.json 생성
```

### 6.4 ADLS Gen2 파일 확인

**데이터 파일:**
```
datalake/
└── SAMPLEDB/
    └── ETL_SCHEMA/
        ├── TB_CUSTOMER_20260326.parquet      ← FULL (20건)
        ├── TB_ORDER_20260326.parquet         ← INCR (변경분)
        ├── TB_PRODUCT_20260326.parquet       ← FULL
        └── TB_INVENTORY_20260326.parquet     ← custom_query
```

**로그 파일:**
```
pipeline-logs/
└── 2026/
    └── 03/
        └── 26/
            ├── PL_Copy_Child_{runid1}_ETL_SCHEMA_TB_CUSTOMER_SUCCESS.json
            ├── PL_Copy_Child_{runid2}_ETL_SCHEMA_TB_ORDER_SUCCESS.json
            ├── PL_Copy_Child_{runid3}_ETL_SCHEMA_TB_PRODUCT_SUCCESS.json
            └── PL_Copy_Child_{runid4}_ETL_SCHEMA_TB_INVENTORY_SUCCESS.json
```

### 6.5 실패 테스트

1. Config에서 존재하지 않는 테이블로 변경:
   ```sql
   UPDATE dbo.ADF_PIPELINE_CONFIG
   SET table_name = 'TB_NOT_EXIST', updated_dt = GETUTCDATE()
   WHERE table_name = 'TB_PRODUCT';
   ```

2. Debug 실행 → Monitor 확인:
   - TB_CUSTOMER, TB_ORDER, TB_INVENTORY: 성공
   - TB_NOT_EXIST: Copy 실패 → Exec_Log_Failure → PL_Log_To_Blob 실행

3. 로그 파일 확인:
   ```
   pipeline-logs/2026/03/26/
   ├── ..._TB_CUSTOMER_SUCCESS.json
   ├── ..._TB_ORDER_SUCCESS.json
   ├── ..._TB_NOT_EXIST_FAILED.json        ← 실패 로그
   └── ..._TB_INVENTORY_SUCCESS.json
   ```

4. FAILED.json 내용 확인:
   ```json
   {
     "status": "FAILED",
     "source_table": "ETL_SCHEMA.TB_NOT_EXIST",
     "rows_read": 0,
     "rows_copied": 0,
     "error_message": "The table doesn't exist..."
   }
   ```

5. Config 원복:
   ```sql
   UPDATE dbo.ADF_PIPELINE_CONFIG
   SET table_name = 'TB_PRODUCT', updated_dt = GETUTCDATE()
   WHERE table_name = 'TB_NOT_EXIST';
   ```

### 6.6 재수집 테스트 (특정 날짜)

```
PL_Master_Ingestion → [Debug]
  p_source_system: DB2_ONPREM
  p_load_date: 20260325               ← 어제 날짜 명시
```

→ Delete로 기존 파일 삭제 → 재수집 → 로그에 `load_date: 20260325` 기록

---

## Part 7. 전체 파라메터 흐름 정리

```
Config 테이블                  마스터               복사 차일드             로깅 차일드
─────────────                ─────────           ──────────────          ──────────────
                            Set_Load_Date
                            v_load_date
                                │
Lookup                         │
├─ table_name ─────────────▶ @item().table_name
├─ schema_name ────────────▶ @item().schema_name ──▶ p_schema_name
├─ db_name ────────────────▶ @item().db_name ──────▶ p_db_name
├─ load_type ──────────────▶ @item().load_type ────▶ p_load_type
├─ incr_column ────────────▶ @coalesce(item()...) ─▶ p_incr_column
├─ custom_query ───────────▶ @coalesce(item()...) ─▶ p_custom_query
├─ target_container ───────▶ @item().target_cont. ─▶ p_container
│                           v_load_date ───────────▶ p_load_date
│                                                       │
│                                                 Copy Activity
│                                                 output.rowsRead ──────▶ p_rows_read
│                                                 output.rowsCopied ────▶ p_rows_copied
│                                                 output.dataRead ──────▶ p_data_read
│                                                 output.dataWritten ───▶ p_data_written
│                                                 output.copyDuration ──▶ p_duration_sec
│                                                 pipeline().Pipeline ──▶ p_pipeline_name
│                                                 pipeline().RunId ─────▶ p_run_id
│                                                 error.message ────────▶ p_error_message
│                                                                            │
│                                                                      Write_Log
│                                                                      PUT → Blob
```

---

## Part 8. 운영 시 Config 관리

### 테이블 추가 (파이프라인 수정 불필요)

```sql
INSERT INTO dbo.ADF_PIPELINE_CONFIG
    (source_system, db_name, schema_name, table_name,
     load_type, incr_column, target_container, is_active, priority_order, description)
VALUES
('DB2_ONPREM', 'SAMPLEDB', 'ETL_SCHEMA', 'TB_SHIPPING',
 'INCR', 'SHIP_DT', 'datalake', 1, 50, N'배송 데이터 일별 증분');
```

### 테이블 비활성화

```sql
UPDATE dbo.ADF_PIPELINE_CONFIG
SET is_active = 0, updated_dt = GETUTCDATE()
WHERE table_name = 'TB_ORDER';
```

### 로그 조회 (Databricks)

```sql
-- 오늘 수집 결과 전체
SELECT source_table, status, rows_copied, copy_duration_sec, error_message
FROM json.`abfss://pipeline-logs@<account>.dfs.core.windows.net/2026/03/26/*.json`
ORDER BY log_timestamp;

-- 최근 7일 실패 건
SELECT load_date, source_table, error_message
FROM json.`abfss://pipeline-logs@<account>.dfs.core.windows.net/2026/03/**/*.json`
WHERE status = 'FAILED'
ORDER BY log_timestamp DESC;

-- 테이블별 일 평균 수집 행 수
SELECT source_table, AVG(rows_copied) AS avg_rows, AVG(copy_duration_sec) AS avg_sec
FROM json.`abfss://pipeline-logs@<account>.dfs.core.windows.net/2026/**/*.json`
WHERE status = 'SUCCESS'
GROUP BY source_table;
```

---

## Part 9. 주의사항

| 항목 | 설명 |
|------|------|
| Lookup 최대 행 수 | 5,000건 (초과 시 Stored Procedure + Copy 패턴 전환) |
| NULL 파라메터 | `@coalesce(item().incr_column, '')` 필수 (null 전달 시 에러) |
| `@string()` 변환 | 숫자 output을 String 파라메터에 전달 시 `@string()` 필수 |
| Wait on completion | 로깅 차일드: ❌ 해제 권장 (데이터 수집에 영향 안 줌) |
| 에러 메시지 이스케이프 | `@replace(..., '"', '\\"')` (JSON 깨짐 방지) |
| ForEach 병렬 수 | SHIR 스펙에 맞게 Batch count 조정 (기본 4) |
| 로그 보존 | Lifecycle Management로 90일 등 자동 삭제 설정 |

---

**이전 Lab:** [Lab 5 — Copy/Pipeline 로깅](lab5-logging-to-blob.md)  
**참고:** [Lab 2 확장 — Config Lookup](lab2-ext-lookup-foreach.md) | [부록 D — ADF 표현식](appendix-d-expression-reference.md)
