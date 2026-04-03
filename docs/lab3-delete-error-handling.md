# Lab 3. 파일 삭제 + 실패 핸들링 추가

> **난이도:** ⭐⭐ 중급 | **소요시간:** 40분 | **사전 조건:** [Lab 2](lab2-parameterized-pipeline.md) 완료

## 목표

- Copy 전 ADLS에 동일 파일 존재 시 삭제 (멱등성 보장)
- 실패 시 에러 로깅 / 알림 Activity 추가
- Lab 2 차일드 파이프라인에 기능 추가

## 파이프라인 흐름도

```
┌──────────┐    Success    ┌──────────────┐    Success    ┌──────────┐
│  Delete  │──────────────▶│  Copy Data   │──────────────▶│ Success  │
│  If      │               │  DB2→ADLS    │               │ Log      │
│  Exists  │               │              │               │ (옵션)   │
└──────────┘               └──────┬───────┘               └──────────┘
                                  │ Failure
                                  ▼
                           ┌──────────────┐
                           │  Error       │
                           │  Handling    │
                           └──────────────┘
```

---

## 3.1 Delete Activity 추가 (Copy 전 기존 파일 삭제)

차일드 파이프라인 `PL_Copy_DB2_to_ADLS_Child` 열기

```
[Activities] → [General] → Delete → 캔버스에 드래그
Activity 이름: Delete_Existing_Parquet
```

### General 탭

| 설정 | 값 |
|------|-----|
| Name | `Delete_Existing_Parquet` |
| Timeout | `0.00:10:00` |

### Source 탭 (삭제 대상 경로)

| Property | Value |
|----------|-------|
| Dataset | `DS_ADLS_Parquet_Parameterized` |
| `ds_container` | `@pipeline().parameters.p_container` |
| `ds_directory` | `@concat(pipeline().parameters.p_db_name, '/', pipeline().parameters.p_schema_name)` |
| `ds_filename` | `@concat(pipeline().parameters.p_table_name, '_', pipeline().parameters.p_load_date, '.parquet')` |

### 연결

```
Delete_Existing_Parquet ──(On completion)──▶ Copy_DB2_to_ADLS
```

> ### ★ "On completion" vs "On success"
>
> | 연결 유형 | 동작 | 용도 |
> |----------|------|------|
> | **On success** | 성공 시에만 진행 | 파일 미존재 시 실패하면 멈춤 |
> | **On completion** | 성공/실패 무관하게 진행 | **멱등성 보장 (권장)** |
> | **On failure** | 실패 시에만 진행 | 에러 핸들링 분기용 |

## 3.2 (대안) Get Metadata + If Condition 패턴

파일 존재 여부를 명시적으로 확인 후 삭제하는 더 정교한 패턴:

```
┌──────────┐  success  ┌──────────┐  Exists=True  ┌────────┐  success  ┌──────┐
│ GetMeta  │─────────▶│ If       │──────────────▶│ Delete │─────────▶│ Copy │
│ Check    │          │ Condition│               │ File   │          │ Data │
└──────────┘          └────┬─────┘               └────────┘          └──────┘
                           │ Exists=False
                           └────────────────────────────────────────▶│ Copy │
                                                                     └──────┘
```

### Get Metadata Activity

**Activity 이름:** `GetMeta_Check_File`

| 설정 | 값 |
|------|-----|
| Dataset | `DS_ADLS_Parquet_Parameterized` (동일 파라메터 매핑) |
| Field list | `Exists` 선택 |

### If Condition Activity

**Activity 이름:** `If_File_Exists`

| 설정 | 값 |
|------|-----|
| Expression | `@activity('GetMeta_Check_File').output.exists` |
| True 분기 | Delete Activity (3.1과 동일 설정) |
| False 분기 | 비워둠 |

> 이 패턴은 Monitor 로그가 깔끔하고 불필요한 에러 로그가 남지 않습니다.

## 3.3 실패 핸들링 Activity 추가

Copy Activity 실패 시 에러 정보를 기록하는 3가지 방법:

### 방법 A: Set Variable (에러 메시지 저장)

**Pipeline Variables 추가:** `v_error_msg` (String)

**Activity 이름:** `Set_Error_Message`  
**연결:** `Copy_DB2_to_ADLS` → (On failure) → `Set_Error_Message`

```
@concat(
    'Pipeline: ', pipeline().Pipeline,
    ' | RunId: ', pipeline().RunId,
    ' | Table: ', pipeline().parameters.p_schema_name,
        '.', pipeline().parameters.p_table_name,
    ' | Error: ', activity('Copy_DB2_to_ADLS').error.message,
    ' | Time: ', utcNow()
)
```

### 방법 B: Web Activity (Teams/Slack 알림)

**Activity 이름:** `Notify_Error_Teams`  
**연결:** `Copy_DB2_to_ADLS` → (On failure) → `Notify_Error_Teams`

| 설정 | 값 |
|------|-----|
| URL | Teams Incoming Webhook URL |
| Method | POST |
| Headers | `Content-Type: application/json` |

**Body:**
```
@json(
    concat(
        '{"text":"❌ ADF 파이프라인 실패\\n',
        '**Pipeline:** ', pipeline().Pipeline, '\\n',
        '**Table:** ', pipeline().parameters.p_schema_name,
            '.', pipeline().parameters.p_table_name, '\\n',
        '**Error:** ', activity('Copy_DB2_to_ADLS').error.message, '\\n',
        '**Time:** ', utcNow(), '"}'
    )
)
```

### 방법 C: Stored Procedure (로그 테이블 기록)

**Activity 이름:** `SP_Log_Error`  
**연결:** `Copy_DB2_to_ADLS` → (On failure) → `SP_Log_Error`

> 로그 테이블 DDL: [sql/05_log_table.sql](../sql/05_log_table.sql)

| Parameter | Value |
|-----------|-------|
| `@PipelineName` | `@pipeline().Pipeline` |
| `@RunId` | `@pipeline().RunId` |
| `@TableName` | `@concat(pipeline().parameters.p_schema_name, '.', pipeline().parameters.p_table_name)` |
| `@Status` | `Failed` |
| `@ErrorMessage` | `@activity('Copy_DB2_to_ADLS').error.message` |
| `@ExecutionTime` | `@utcNow()` |

## 3.4 최종 차일드 파이프라인 흐름

```
┌──────────────┐  completion  ┌──────────────┐  success  ┌──────────┐
│ Delete       │─────────────▶│ Copy         │──────────▶│ (완료)   │
│ Existing     │              │ DB2→ADLS     │           └──────────┘
│ Parquet      │              │              │
└──────────────┘              └──────┬───────┘
                                     │ failure
                                     ▼
                              ┌──────────────┐
                              │ Set_Error    │──▶ (추가: Web/SP 알림)
                              │ _Message     │
                              └──────────────┘
```

---

**다음 단계:** [Lab 4 — DB2 소스 쿼리 표현식 실습](lab4-db2-query-expressions.md)
