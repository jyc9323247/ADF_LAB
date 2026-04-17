# Azure Data Factory Pipeline Lab

> **On-Premises IBM DB2 → ADLS Gen2 Parquet 수집 파이프라인 실습 가이드**

ADF 입문 ~ 중급 엔지니어를 위한 단계별 실습 문서입니다.  
하드코딩 파이프라인부터 시작하여 Config 기반 메타데이터 드리븐 아키텍처까지 점진적으로 발전시킵니다.

---

## 📋 Lab 구성

| Lab | 제목 | 핵심 내용 | 난이도 |
|-----|------|-----------|--------|
| [Lab 1-A](docs/lab1a-full-load.md) | 전체 데이터 수집 (Full Load) | 하드코딩 Copy Activity, Query 모드 + WITH UR | ⭐ |
| [Lab 1-B](docs/lab1b-incremental-load.md) | 변경 데이터 수집 (Incremental Load) | WHERE 날짜 조건, DB2 TIMESTAMP 리터럴, 일자별 파일 | ⭐ |
| [Lab 2](docs/lab2-parameterized-pipeline.md) | 마스터-차일드 파이프라인 (파라메터화) | Pipeline Parameters, 동적 Dataset, Execute Pipeline | ⭐⭐ |
| [Lab 2 확장](docs/lab2-ext-lookup-foreach.md) | Config Lookup + ForEach | Azure SQL Config 테이블, Lookup, ForEach 병렬 수집 | ⭐⭐⭐ |
| [Lab 3](docs/lab3-delete-error-handling.md) | 파일 삭제 + 실패 핸들링 | Delete Activity, Get Metadata, Error Handling 패턴 | ⭐⭐ |
| [Lab 4](docs/lab4-db2-query-expressions.md) | DB2 소스 쿼리 표현식 | WITH UR, 증분 쿼리, ADF 표현식, TIMESTAMP 함수 | ⭐⭐ |
| [Lab 5](docs/lab5-logging-to-blob.md) | Copy/Pipeline 실행 로깅 | Web Activity + Blob REST API, JSON 로그, 3가지 방법 비교 | ⭐⭐⭐ |
| [Lab 6](docs/lab6-integrated-pipeline.md) | 통합 파이프라인 (완성형) | Config Lookup + ForEach + Copy + 차일드 로깅 통합 | ⭐⭐⭐ |
| [Lab 7](docs/lab7-triggers.md) | ADF 트리거 (Schedule Trigger) | 5분/1시간/매주일요일/매월말 — 4가지 스케줄 패턴 | ⭐⭐ |
| [Lab 8](docs/lab8-key-vault.md) | Key Vault 연동 (Secrets Management) | Azure Key Vault, Managed Identity, Linked Service Secret 참조 | ⭐⭐⭐ |

## 📁 부록

| 문서 | 내용 |
|------|------|
| [사전 준비사항](docs/appendix-a-prerequisites.md) | Azure 리소스, SHIR, Linked Service, DB2 DDL/DML |
| [Linked Service / Dataset 참고](docs/appendix-b-linked-service.md) | 연결 설정 상세, Dataset 목록 |
| [자주 발생하는 오류](docs/appendix-c-troubleshooting.md) | 에러 코드별 해결 방법 |
| [ADF 표현식 Quick Reference](docs/appendix-d-expression-reference.md) | 날짜, 문자열, 파이프라인, 조건식 치트시트 |

## 📂 SQL 스크립트

| 파일 | 용도 |
|------|------|
| [sql/01_create_tb_customer.sql](sql/01_create_tb_customer.sql) | DB2 TB_CUSTOMER DDL + 인덱스 |
| [sql/02_insert_sample_data.sql](sql/02_insert_sample_data.sql) | TB_CUSTOMER 샘플 20건 INSERT |
| [sql/03_verify_queries.sql](sql/03_verify_queries.sql) | 데이터 검증 쿼리 |
| [sql/04_config_table.sql](sql/04_config_table.sql) | Azure SQL Config 테이블 DDL + INSERT |
| [sql/05_log_table.sql](sql/05_log_table.sql) | 파이프라인 실행 로그 테이블 DDL |

---

## 🏗️ 전체 아키텍처

```
┌─────────────────────────────────┐          ┌──────────────────────────────────┐
│  On-Premises                    │          │  Azure Cloud                     │
│                                 │          │                                  │
│  ┌───────────┐   ┌──────────┐  │  HTTPS   │  ┌──────────┐   ┌────────────┐  │
│  │ IBM DB2   │──▶│  SHIR    │──┼──────────┼─▶│   ADF    │──▶│ ADLS Gen2  │  │
│  │ SAMPLEDB  │   │ (Gateway)│  │   443    │  │ Pipeline │   │ Parquet    │  │
│  └───────────┘   └──────────┘  │          │  └────┬─────┘   └────────────┘  │
│                                 │          │       │                          │
│                                 │          │  ┌────▼─────┐                   │
│                                 │          │  │Azure SQL │ Config / Log      │
│                                 │          │  │ Database │ Tables            │
│                                 │          │  └──────────┘                   │
└─────────────────────────────────┘          └──────────────────────────────────┘
```

## 🚀 학습 순서

```
부록 A (사전 준비) → Lab 1-A (Full) → Lab 1-B (Incr)
    → Lab 2 (파라메터) → Lab 2 확장 (Lookup/ForEach)
    → Lab 3 (삭제/에러) → Lab 4 (DB2 표현식)
    → Lab 5 (Blob 로깅) → Lab 6 (통합 파이프라인)
    → Lab 7 (트리거) → Lab 8 (Key Vault)
```

## 🛠️ 사전 요구사항

- Azure 구독 (참가자/소유자 역할)
- Azure Data Factory V2
- ADLS Gen2 스토리지 계정
- On-Premises IBM DB2 (v11.x+) + SHIR 설치 완료
- Azure SQL Database (Config 테이블용, Lab 2 확장부터)

자세한 사전 준비는 [부록 A](docs/appendix-a-prerequisites.md)를 참고하세요.

---

**Version:** 1.0 (Draft)  
**Last Updated:** 2026-03-26  
**Author:** IT Service Management Team
