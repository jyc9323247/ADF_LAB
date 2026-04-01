# Lab 2 확장. Config 테이블 Lookup + ForEach Copy 파이프라인

> **난이도:** ⭐⭐⭐ 중급+ | **소요시간:** 60분 | **사전 조건:** [Lab 2](lab2-parameterized-pipeline.md) 완료

## 목표

- Azure SQL DB에 Config 테이블을 생성하여 수집 대상을 관리
- Lookup Activity로 Config 조회 → ForEach로 동적 병렬 수집
- 테이블 추가/삭제 시 **파이프라인 수정 없이 DB만 UPDATE**

## 왜 Config 테이블 Lookup 패턴이 필요한가?

Lab 2.7의 ForEach 방식은 파이프라인 파라메터에 테이블 목록을 JSON 배열로 하드코딩합니다. Config 테이블 Lookup 패턴을 사용하면:

- ✅ 수집 대상 추가/삭제 시 DB 테이블만 UPDATE (파이프라인 수정 불필요)
- ✅ 테이블별 활성/비활성 플래그로 선택적 수집 가능
- ✅ 테이블별 수집 모드(Full/Incremental), 쿼리 조건 등 개별 설정 가능
- ✅ 운영팀이 SQL만으로 수집 대상을 관리

### 파이프라인 흐름

```
┌────────────┐  success  ┌────────────┐  success  ┌─────────────┐
│ Set        │──────────▶│ Lookup     │──────────▶│ ForEach     │
│ Load_Date  │           │ Config     │           │ Config      │
│            │           │ (Azure SQL)│           │ Tables      │
└────────────┘           └────────────┘           └──────┬──────┘
                                                         │ (each)
                                                  ┌──────▼──────┐
                                                  │ Execute     │
                                                  │ Pipeline    │
                                                  │ → Child     │
                                                  └─────────────┘
```

---

## 2.8 Config 테이블 설계 및 생성

### 2.8.1 Azure SQL Database 준비

| 설정 | 값 |
|------|-----|
| Linked Service | `LS_AzureSQLDB_Config` |
| Type | Azure SQL Database |
| Connect via IR | AutoResolveIntegrationRuntime |
| Server | `<서버명>.database.windows.net` |
| Database | `ConfigDB` |
| Authentication | Managed Identity 권장 |

### 2.8.2 Config 테이블 DDL

> SQL 스크립트: [sql/04_config_table.sql](../sql/04_config_table.sql)

```sql
CREATE TABLE dbo.ADF_PIPELINE_CONFIG
(
    config_id        INT IDENTITY(1,1) PRIMARY KEY,
    source_system    VARCHAR(50)   NOT NULL,
    db_name          VARCHAR(100)  NOT NULL,
    schema_name      VARCHAR(100)  NOT NULL,
    table_name       VARCHAR(200)  NOT NULL,
    load_type        VARCHAR(20)   NOT NULL,   -- FULL / INCR
    incr_column      VARCHAR(100)  NULL,
    custom_query     VARCHAR(2000) NULL,
    target_container VARCHAR(100)  NOT NULL,
    is_active        BIT           NOT NULL DEFAULT 1,
    priority_order   INT           NOT NULL DEFAULT 100,
    description      VARCHAR(500)  NULL,
    created_dt       DATETIME2     NOT NULL DEFAULT GETUTCDATE(),
    updated_dt       DATETIME2     NOT NULL DEFAULT GETUTCDATE()
);
```

### 2.8.3 Config 샘플 데이터

```sql
INSERT INTO dbo.ADF_PIPELINE_CONFIG
    (source_system, db_name, schema_name, table_name,
     load_type, incr_column, custom_query,
     target_container, is_active, priority_order, description)
VALUES
('DB2_ONPREM', 'SAMPLEDB', 'ETL_SCHEMA', 'TB_CUSTOMER',
 'FULL', NULL, NULL, 'datalake', 1, 10, '고객 마스터 전체 수집'),

('DB2_ONPREM', 'SAMPLEDB', 'ETL_SCHEMA', 'TB_ORDER',
 'INCR', 'UPD_DT', NULL, 'datalake', 1, 20, '주문 데이터 일별 증분'),

('DB2_ONPREM', 'SAMPLEDB', 'ETL_SCHEMA', 'TB_PRODUCT',
 'FULL', NULL, NULL, 'datalake', 1, 30, '상품 마스터 전체 수집'),

('DB2_ONPREM', 'SAMPLEDB', 'ETL_SCHEMA', 'TB_INVENTORY',
 'FULL', NULL,
 'SELECT ITEM_CD, WH_CD, QTY, UPD_DT FROM ETL_SCHEMA.TB_INVENTORY WHERE QTY > 0 WITH UR',
 'datalake', 1, 40, '재고 > 0 건만 수집'),

('DB2_ONPREM', 'SAMPLEDB', 'ETL_SCHEMA', 'TB_ACCESS_LOG',
 'INCR', 'LOG_DT', NULL, 'datalake', 0, 99, '접속 로그 - 현재 비활성');
```

## 2.9 Config Lookup용 Dataset

**Dataset 이름:** `DS_AzureSQL_Config`

```
Type     : Azure SQL Database
Linked   : LS_AzureSQLDB_Config
Table    : (선택 안 함 — Lookup에서 Query 사용)
```

## 2.10 마스터 파이프라인 생성 (Lookup + ForEach)

**파이프라인 이름:** `PL_Master_DB2_Ingestion_V2`

### 2.10.1 파라메터

| Name | Type | Default Value |
|------|------|--------------|
| `p_source_system` | String | `DB2_ONPREM` |
| `p_load_date` | String | (빈 값 — 트리거에서 주입) |

### 2.10.2 Variables

| Name | Type | Default Value |
|------|------|--------------|
| `v_load_date` | String | (비워둠) |

### 2.10.3 Activity 1: Set Variable — 날짜 결정

**Activity 이름:** `Set_Load_Date`

```
@if(
    empty(pipeline().parameters.p_load_date),
    formatDateTime(addHours(utcNow(), 9), 'yyyyMMdd'),
    pipeline().parameters.p_load_date
)
```

> 파라메터가 비어있으면 한국시간(UTC+9) 기준 당일 날짜를 자동 설정. 명시적으로 날짜를 전달하면 해당 날짜를 사용 (재수집 시 유용).

### 2.10.4 Activity 2: Lookup — Config 테이블 조회

**Activity 이름:** `Lookup_Config`

**연결:** `Set_Load_Date` → (On success) → `Lookup_Config`

**Source 탭:**

| 설정 | 값 |
|------|-----|
| Source dataset | `DS_AzureSQL_Config` |
| Use query | Query |
| ☑ First row only | ❌ **체크 해제!!!** |

**Query:**
```sql
SELECT config_id, source_system, db_name, schema_name,
       table_name, load_type, incr_column, custom_query,
       target_container
FROM dbo.ADF_PIPELINE_CONFIG
WHERE source_system = '@{pipeline().parameters.p_source_system}'
  AND is_active = 1
ORDER BY priority_order
```

> ### ★ "First row only" 체크 해제 필수
>
> | 설정 | output 구조 | ForEach 사용 |
> |------|------------|-------------|
> | ✅ 체크 (기본값) | `output.firstRow` = 단일 객체 | ❌ 불가 |
> | ❌ **체크 해제** | `output.value` = JSON 배열 | ✅ 가능 |

### 2.10.5 Activity 3: ForEach — 테이블별 반복 실행

**Activity 이름:** `ForEach_Config_Tables`

**연결:** `Lookup_Config` → (On success) → `ForEach_Config_Tables`

| 설정 | 값 |
|------|-----|
| Sequential | false (병렬 실행) |
| Batch count | 4 (SHIR 부하에 따라 조정) |
| Items | `@activity('Lookup_Config').output.value` |

### 2.10.6 ForEach 내부: Execute Pipeline

**Activity 이름:** `Exec_Child_Copy`

| Parameter Name | Value |
|---------------|-------|
| `p_container` | `@item().target_container` |
| `p_db_name` | `@item().db_name` |
| `p_schema_name` | `@item().schema_name` |
| `p_table_name` | `@item().table_name` |
| `p_load_date` | `@variables('v_load_date')` |

> `@item()`은 ForEach가 현재 반복 중인 Config 행의 JSON 객체입니다.

## 2.11 차일드 파이프라인 개선 (load_type / custom_query 지원)

### 2.11.1 차일드 파라메터 추가

기존 5개에 3개 추가:

| Name | Type | Default Value | 비고 |
|------|------|--------------|------|
| `p_load_type` | String | `FULL` | 추가 |
| `p_incr_column` | String | (빈 값) | 추가 |
| `p_custom_query` | String | (빈 값) | 추가 |

### 2.11.2 Copy Activity Source 쿼리 — 동적 분기 표현식

Copy Activity → Source 탭 → Use query: **Query** → Add dynamic content:

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
            ' WHERE ',
            pipeline().parameters.p_incr_column,
            ' >= ''',
            formatDateTime(
                addDays(formatDateTime(pipeline().parameters.p_load_date, 'yyyy-MM-dd'), -1),
                'yyyy-MM-dd'
            ),
            ''' AND ',
            pipeline().parameters.p_incr_column,
            ' < ''',
            formatDateTime(
                pipeline().parameters.p_load_date,
                'yyyy-MM-dd'
            ),
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

**분기 로직 요약:**

| 우선순위 | 조건 | 생성 SQL |
|---------|------|---------|
| 1순위 | `p_custom_query` 있음 | 그대로 사용 |
| 2순위 | `p_load_type = 'INCR'` | `WHERE + WITH UR` 자동 생성 |
| 3순위 | `p_load_type = 'FULL'` | `SELECT * ... WITH UR` |

### 2.11.3 마스터 ForEach 파라메터 매핑 업데이트

| Parameter Name | Value |
|---------------|-------|
| `p_load_type` | `@item().load_type` |
| `p_incr_column` | `@coalesce(item().incr_column, '')` |
| `p_custom_query` | `@coalesce(item().custom_query, '')` |

> `@coalesce()`로 NULL을 빈 문자열로 변환하여 차일드 파라메터 에러를 방지합니다.

## 2.12 Config 테이블 운영 가이드

### 테이블 추가

```sql
INSERT INTO dbo.ADF_PIPELINE_CONFIG
    (source_system, db_name, schema_name, table_name,
     load_type, incr_column, custom_query,
     target_container, is_active, priority_order, description)
VALUES
('DB2_ONPREM', 'SAMPLEDB', 'ETL_SCHEMA', 'TB_SHIPPING',
 'INCR', 'SHIP_DT', NULL, 'datalake', 1, 50, '배송 데이터 일별 증분');
```

### 테이블 비활성화

```sql
UPDATE dbo.ADF_PIPELINE_CONFIG
SET    is_active = 0, updated_dt = GETUTCDATE()
WHERE  table_name = 'TB_ORDER';
```

## 2.13 실행 및 검증 체크리스트

- [ ] Config 테이블 데이터 확인 (is_active=1 → 4건)
- [ ] 마스터 파이프라인 Debug 실행
- [ ] Lookup 출력: count = 4
- [ ] ForEach: 4건 반복, 차일드 4개 모두 Succeeded
- [ ] ADLS Gen2 4개 파일 생성 확인
- [ ] Config 변경 후 재실행 테스트

## 2.14 Lookup 주의사항

| 항목 | 내용 |
|------|------|
| 최대 행 수 | 5,000건 (초과 시 Stored Procedure + Copy로 전환) |
| NULL 처리 | `@coalesce(item().incr_column, '')` 필수 |
| 출력 참조 | 전체: `output.value` / 건수: `output.count` / ForEach 내: `@item().컬럼명` |
| 디버깅 | Lookup Activity Output 탭에서 JSON 결과 확인 가능 |

---

**다음 단계:** [Lab 3 — 파일 삭제 + 실패 핸들링](lab3-delete-error-handling.md)
