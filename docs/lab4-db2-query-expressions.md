# Lab 4. DB2 소스 쿼리 표현식 실습

> **난이도:** ⭐⭐ 중급 | **소요시간:** 30분 | **사전 조건:** [Lab 2](lab2-parameterized-pipeline.md) 완료

## 목표

- DB2 특유의 `WITH UR` (Uncommitted Read) 활용
- Copy Activity Source에서 Query 사용 시 표현식 작성법
- 자주 쓰이는 DB2 + ADF 표현식 패턴 8가지 실습

---

## 4.1 DB2 "WITH UR" 기본 개념

`WITH UR` = **Uncommitted Read** (= SQL Server의 `NOLOCK`)

- 다른 트랜잭션이 커밋하지 않은 데이터도 읽기 가능
- **락(lock) 대기 없이** 데이터 조회 → 대량 데이터 추출 시 필수
- DB2에서 배치 ETL 수행 시 거의 항상 사용

```sql
SELECT * FROM ETL_SCHEMA.TB_CUSTOMER WITH UR
```

> **주의:** `WITH UR`은 SELECT 문 끝에 위치하며, WHERE 절이 있는 경우 WHERE 뒤에 위치합니다.
> ```sql
> SELECT * FROM ETL_SCHEMA.TB_CUSTOMER WHERE STATUS = 'A' WITH UR
> ```

## 4.2 Copy Activity에서 Query 모드로 전환

Copy Activity → Source 탭 → Use query: **"Query"** 선택 → Query 입력란에 동적 표현식 입력

---

## 패턴 1: 기본 WITH UR 쿼리 (하드코딩)

```sql
SELECT * FROM ETL_SCHEMA.TB_CUSTOMER WITH UR
```

## 패턴 2: 파라메터화 + WITH UR

파이프라인 파라메터로 스키마/테이블명을 동적으로 조합:

**표현식:**
```
@concat(
    'SELECT * FROM ',
    pipeline().parameters.p_schema_name,
    '.',
    pipeline().parameters.p_table_name,
    ' WITH UR'
)
```

**결과 SQL:**
```sql
SELECT * FROM ETL_SCHEMA.TB_CUSTOMER WITH UR
```

> Source Dataset에서 테이블을 지정하지 않고 Query로 대체할 수 있습니다.

## 패턴 3: WHERE 조건 + WITH UR (증분 수집)

**추가 파라메터:**

| Name | Type | Default Value |
|------|------|--------------|
| `p_start_date` | String | `2026-03-25` |
| `p_end_date` | String | `2026-03-26` |

**표현식:**
```
@concat(
    'SELECT * FROM ',
    pipeline().parameters.p_schema_name,
    '.',
    pipeline().parameters.p_table_name,
    ' WHERE UPD_DT >= ''',
    pipeline().parameters.p_start_date,
    ''' AND UPD_DT < ''',
    pipeline().parameters.p_end_date,
    ''' WITH UR'
)
```

**결과 SQL:**
```sql
SELECT * FROM ETL_SCHEMA.TB_CUSTOMER
WHERE UPD_DT >= '2026-03-25'
  AND UPD_DT < '2026-03-26'
WITH UR
```

> DB2에서 문자열 내 작은따옴표(`'`)는 `''` (두 개)로 이스케이프합니다. ADF 표현식에서도 동일하게 `'''` 로 작성합니다.

## 패턴 4: DB2 날짜 함수 활용 (CURRENT DATE)

**당일 데이터:**
```
@concat(
    'SELECT * FROM ',
    pipeline().parameters.p_schema_name, '.',
    pipeline().parameters.p_table_name,
    ' WHERE DATE(UPD_DT) = CURRENT DATE WITH UR'
)
```

**전일 데이터:**
```
@concat(
    'SELECT * FROM ',
    pipeline().parameters.p_schema_name, '.',
    pipeline().parameters.p_table_name,
    ' WHERE DATE(UPD_DT) = CURRENT DATE - 1 DAY WITH UR'
)
```

## 패턴 5: 컬럼 선택 + COALESCE + TRIM (데이터 정제)

```
@concat(
    'SELECT ',
    '  CUSTOMER_ID, ',
    '  TRIM(CUSTOMER_NAME) AS CUSTOMER_NAME, ',
    '  COALESCE(PHONE, ''N/A'') AS PHONE, ',
    '  COALESCE(EMAIL, ''N/A'') AS EMAIL, ',
    '  UPD_DT ',
    'FROM ',
    pipeline().parameters.p_schema_name, '.',
    pipeline().parameters.p_table_name,
    ' WITH UR'
)
```

**결과 SQL:**
```sql
SELECT
  CUSTOMER_ID,
  TRIM(CUSTOMER_NAME) AS CUSTOMER_NAME,
  COALESCE(PHONE, 'N/A') AS PHONE,
  COALESCE(EMAIL, 'N/A') AS EMAIL,
  UPD_DT
FROM ETL_SCHEMA.TB_CUSTOMER
WITH UR
```

## 패턴 6: DB2 FETCH FIRST (행 수 제한 테스트)

대용량 테이블 테스트 시 일부 행만 추출:

```
@concat(
    'SELECT * FROM ',
    pipeline().parameters.p_schema_name, '.',
    pipeline().parameters.p_table_name,
    ' FETCH FIRST 1000 ROWS ONLY WITH UR'
)
```

> **DB2 절 순서:** `SELECT → FROM → WHERE → FETCH FIRST → WITH UR`

## 패턴 7: ADF utcNow()로 DB2 날짜 조건 생성

마스터에서 날짜를 전달하지 않고, 차일드 내에서 직접 생성:

```
@concat(
    'SELECT * FROM ',
    pipeline().parameters.p_schema_name, '.',
    pipeline().parameters.p_table_name,
    ' WHERE UPD_DT >= ''',
    formatDateTime(addDays(utcNow(), -1), 'yyyy-MM-dd'),
    ''' AND UPD_DT < ''',
    formatDateTime(utcNow(), 'yyyy-MM-dd'),
    ''' WITH UR'
)
```

**결과 SQL (2026-03-26 기준):**
```sql
SELECT * FROM ETL_SCHEMA.TB_CUSTOMER
WHERE UPD_DT >= '2026-03-25'
  AND UPD_DT < '2026-03-26'
WITH UR
```

## 패턴 8: DB2 TIMESTAMP 형식 조건

DB2의 TIMESTAMP 컬럼 조건에 ADF 날짜를 매핑:

```
@concat(
    'SELECT * FROM ',
    pipeline().parameters.p_schema_name, '.',
    pipeline().parameters.p_table_name,
    ' WHERE UPD_TS >= TIMESTAMP(''',
    formatDateTime(addDays(utcNow(), -1), 'yyyy-MM-dd'),
    ''', ''00:00:00'') ',
    'AND UPD_TS < TIMESTAMP(''',
    formatDateTime(utcNow(), 'yyyy-MM-dd'),
    ''', ''00:00:00'') ',
    'WITH UR'
)
```

**결과 SQL:**
```sql
SELECT * FROM ETL_SCHEMA.TB_CUSTOMER
WHERE UPD_TS >= TIMESTAMP('2026-03-25', '00:00:00')
  AND UPD_TS < TIMESTAMP('2026-03-26', '00:00:00')
WITH UR
```

---

## 패턴 요약

| # | 패턴 | 용도 |
|---|------|------|
| 1 | 기본 WITH UR | 전체 수집 (하드코딩) |
| 2 | 파라메터화 + WITH UR | 전체 수집 (동적) |
| 3 | WHERE + WITH UR | 증분 수집 (파라메터 날짜) |
| 4 | CURRENT DATE | 증분 수집 (DB2 서버 날짜) |
| 5 | TRIM/COALESCE | 데이터 정제 |
| 6 | FETCH FIRST | 테스트용 행 수 제한 |
| 7 | utcNow() | 증분 수집 (ADF 날짜 자동 생성) |
| 8 | TIMESTAMP() | TIMESTAMP 컬럼 증분 수집 |

---

**참고:** [ADF 표현식 Quick Reference](appendix-d-expression-reference.md)

---

**다음 단계:** [Lab 5 — Copy/Pipeline 실행 로깅 (Azure Blob Storage)](lab5-logging-to-blob.md)
