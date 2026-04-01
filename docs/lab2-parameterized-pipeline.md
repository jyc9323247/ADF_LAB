# Lab 2. 마스터-차일드 파이프라인 (파라메터화)

> **난이도:** ⭐⭐ 중급 | **소요시간:** 45분 | **사전 조건:** [Lab 1-B](lab1b-incremental-load.md) 완료

## 목표

- Lab 1 파이프라인을 복사하여 파라메터화
- 마스터 파이프라인에서 파라메터 값을 전달하여 차일드 실행
- Parquet 경로: `{container}/{db_name}/{schema}/{table}_yyyymmdd.parquet`

---

## 2.1 차일드 파이프라인 생성 (Lab 1 복사 후 파라메터화)

**파이프라인 이름:** `PL_Copy_DB2_to_ADLS_Child`

Lab 1의 `PL_Copy_DB2_to_ADLS_Full_HC` 파이프라인을 우클릭 → **Clone** → 이름 변경

## 2.2 차일드 파이프라인 파라메터 정의

파이프라인 캔버스 빈 영역 클릭 → 하단 **[Parameters]** 탭

| Name | Type | Default Value (예시) |
|------|------|---------------------|
| `p_container` | String | `datalake` |
| `p_db_name` | String | `SAMPLEDB` |
| `p_schema_name` | String | `ETL_SCHEMA` |
| `p_table_name` | String | `TB_CUSTOMER` |
| `p_load_date` | String | `20260326` |

> `p_load_date`는 마스터에서 `utcNow()` 기반으로 자동 생성하여 전달합니다.

## 2.3 파라메터화 Dataset 생성 (Source - DB2)

**Dataset 이름:** `DS_DB2_Parameterized`

**Dataset Parameters 탭:**

| Name | Type | Default Value |
|------|------|--------------|
| `ds_schema_name` | String | (비워둠) |
| `ds_table_name` | String | (비워둠) |

**Connection 탭:**

```
Linked Service : LS_DB2_OnPrem
Table 설정:
    Schema : @dataset().ds_schema_name
    Table  : @dataset().ds_table_name
```

> **Tip:** Edit 체크박스를 선택하면 동적 값 입력이 가능합니다.

## 2.4 파라메터화 Dataset 생성 (Sink - ADLS Parquet)

**Dataset 이름:** `DS_ADLS_Parquet_Parameterized`

**Dataset Parameters 탭:**

| Name | Type | Default Value |
|------|------|--------------|
| `ds_container` | String | (비워둠) |
| `ds_directory` | String | (비워둠) |
| `ds_filename` | String | (비워둠) |

**Connection 탭:**

```
Linked Service : LS_ADLS_Gen2
File Path 설정:
    Container : @dataset().ds_container
    Directory : @dataset().ds_directory
    File      : @dataset().ds_filename
```

## 2.5 Copy Activity에서 Dataset 파라메터 매핑

**Copy Activity 이름 변경:** `Copy_DB2_to_ADLS`

### Source 탭

- Source dataset: `DS_DB2_Parameterized`
- Dataset properties:

| Property | Value |
|----------|-------|
| `ds_schema_name` | `@pipeline().parameters.p_schema_name` |
| `ds_table_name` | `@pipeline().parameters.p_table_name` |

### Sink 탭

- Sink dataset: `DS_ADLS_Parquet_Parameterized`
- Dataset properties:

**ds_container:**
```
@pipeline().parameters.p_container
```

**ds_directory:**
```
@concat(
    pipeline().parameters.p_db_name,
    '/',
    pipeline().parameters.p_schema_name
)
```

**ds_filename:**
```
@concat(
    pipeline().parameters.p_table_name,
    '_',
    pipeline().parameters.p_load_date,
    '.parquet'
)
```

**결과 파일 경로 예시:**
```
datalake/SAMPLEDB/ETL_SCHEMA/TB_CUSTOMER_20260326.parquet
```

## 2.6 마스터 파이프라인 생성

**파이프라인 이름:** `PL_Master_DB2_Ingestion`

```
[Activities] → [General] → Execute Pipeline → 캔버스에 드래그
```

**Activity 이름:** `Exec_Copy_Customer`

### Settings 탭

| 설정 | 값 |
|------|-----|
| Invoked pipeline | `PL_Copy_DB2_to_ADLS_Child` |
| Wait on completion | ✅ 체크 |

**Parameters:**

| Name | Value |
|------|-------|
| `p_container` | `datalake` |
| `p_db_name` | `SAMPLEDB` |
| `p_schema_name` | `ETL_SCHEMA` |
| `p_table_name` | `TB_CUSTOMER` |
| `p_load_date` | `@formatDateTime(utcNow())` |

## 2.7 (선택) 여러 테이블 수집 — ForEach 확장

마스터 파이프라인에 ForEach를 사용하면 여러 테이블을 순차/병렬 수집 가능합니다.

### 마스터 파이프라인 파라메터 추가

| Name | Type | Default Value |
|------|------|--------------|
| `p_table_list` | Array | (아래 JSON) |

```json
[
  {
    "db_name": "SAMPLEDB",
    "schema_name": "ETL_SCHEMA",
    "table_name": "TB_CUSTOMER"
  },
  {
    "db_name": "SAMPLEDB",
    "schema_name": "ETL_SCHEMA",
    "table_name": "TB_ORDER"
  },
  {
    "db_name": "SAMPLEDB",
    "schema_name": "ETL_SCHEMA",
    "table_name": "TB_PRODUCT"
  }
]
```

### ForEach Activity

**Activity 이름:** `ForEach_Tables`

| 설정 | 값 |
|------|-----|
| Items | `@pipeline().parameters.p_table_list` |
| Sequential | false (병렬 실행 시) |
| Batch count | 4 (병렬 수) |

### ForEach 내부 → Execute Pipeline

| Parameter | Value |
|-----------|-------|
| `p_container` | `datalake` |
| `p_db_name` | `@item().db_name` |
| `p_schema_name` | `@item().schema_name` |
| `p_table_name` | `@item().table_name` |
| `p_load_date` | `@formatDateTime(utcNow())` |

## 2.8 실행 및 검증

1. `PL_Master_DB2_Ingestion` → **[Debug]** 실행
2. Monitor에서 마스터 → 차일드 파이프라인 실행 추적
3. ADLS Gen2 확인:
   ```
   datalake/SAMPLEDB/ETL_SCHEMA/TB_CUSTOMER_20260326.parquet
   datalake/SAMPLEDB/ETL_SCHEMA/TB_ORDER_20260326.parquet
   datalake/SAMPLEDB/ETL_SCHEMA/TB_PRODUCT_20260326.parquet
   ```

---

**다음 단계:** [Lab 2 확장 — Config Lookup + ForEach](lab2-ext-lookup-foreach.md) 또는 [Lab 3 — 파일 삭제 + 실패 핸들링](lab3-delete-error-handling.md)
