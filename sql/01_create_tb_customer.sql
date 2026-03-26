-- ============================================================================
-- 01_create_tb_customer.sql
-- DB2 TB_CUSTOMER 테이블 DDL (스키마 + 테이블 + 인덱스 + 코멘트)
-- ============================================================================
-- 실행 환경: DB2 CLP / IBM Data Studio / DBeaver
-- 사전 조건: SAMPLEDB에 CONNECT 완료
-- ============================================================================

-- 1) 스키마 생성 (스키마가 없는 경우)
--CREATE SCHEMA ETL_SCHEMA AUTHORIZATION DB2ADMIN;
CREATE SCHEMA ETL_SCHEMA ;


-- 2) TB_CUSTOMER 테이블 DDL (고객 마스터)
CREATE TABLE ETL_SCHEMA.TB_CUSTOMER
(
    CUSTOMER_ID       INTEGER        NOT NULL GENERATED ALWAYS AS IDENTITY
                                     (START WITH 1, INCREMENT BY 1),
    CUSTOMER_CD       VARCHAR(20)    NOT NULL,
    CUSTOMER_NAME     VARCHAR(100)   NOT NULL,
    CUSTOMER_NAME_EN  VARCHAR(100),
    CUSTOMER_TYPE     CHAR(1)        NOT NULL DEFAULT 'P',
                                     -- P: 개인, B: 기업
    BIRTH_DATE        DATE,
    GENDER            CHAR(1),       -- M: 남, F: 여, NULL: 기업
    PHONE             VARCHAR(20),
    EMAIL             VARCHAR(100),
    POSTAL_CODE       VARCHAR(10),
    ADDRESS           VARCHAR(300),
    ADDRESS_DETAIL    VARCHAR(200),
    CITY              VARCHAR(50),
    REGION            VARCHAR(50),
    COUNTRY           CHAR(2)        NOT NULL DEFAULT 'KR',
    CREDIT_GRADE      CHAR(1),       -- A, B, C, D, E
    CREDIT_LIMIT      DECIMAL(15,2)  DEFAULT 0,
    TOTAL_PURCHASE    DECIMAL(15,2)  DEFAULT 0,
    MEMBERSHIP_LEVEL  VARCHAR(10)    DEFAULT 'BASIC',
                                     -- BASIC, SILVER, GOLD, VIP
    JOIN_DATE         DATE           NOT NULL,
    LAST_LOGIN_DT     TIMESTAMP,
    STATUS            CHAR(1)        NOT NULL DEFAULT 'A',
                                     -- A: 활성, I: 비활성, D: 탈퇴
    REMARK            VARCHAR(500),
    CRT_USER          VARCHAR(30)    NOT NULL DEFAULT 'SYSTEM',
    CRT_DT            TIMESTAMP      NOT NULL DEFAULT CURRENT TIMESTAMP,
    UPD_USER          VARCHAR(30)    NOT NULL DEFAULT 'SYSTEM',
    UPD_DT            TIMESTAMP      NOT NULL DEFAULT CURRENT TIMESTAMP,

    CONSTRAINT PK_TB_CUSTOMER PRIMARY KEY (CUSTOMER_ID),
    CONSTRAINT UK_TB_CUSTOMER_CD UNIQUE (CUSTOMER_CD)
)
IN USERSPACE1;


-- 3) 코멘트
COMMENT ON TABLE ETL_SCHEMA.TB_CUSTOMER IS '고객 마스터 테이블';
COMMENT ON COLUMN ETL_SCHEMA.TB_CUSTOMER.CUSTOMER_ID IS '고객ID (자동채번)';
COMMENT ON COLUMN ETL_SCHEMA.TB_CUSTOMER.CUSTOMER_CD IS '고객코드 (업무키)';
COMMENT ON COLUMN ETL_SCHEMA.TB_CUSTOMER.CUSTOMER_TYPE IS '고객유형 (P:개인, B:기업)';
COMMENT ON COLUMN ETL_SCHEMA.TB_CUSTOMER.CREDIT_GRADE IS '신용등급 (A~E)';
COMMENT ON COLUMN ETL_SCHEMA.TB_CUSTOMER.STATUS IS '상태 (A:활성, I:비활성, D:탈퇴)';
COMMENT ON COLUMN ETL_SCHEMA.TB_CUSTOMER.UPD_DT IS '수정일시 (증분수집 기준컬럼)';


-- 4) 인덱스
CREATE INDEX ETL_SCHEMA.IX_CUSTOMER_UPD_DT
    ON ETL_SCHEMA.TB_CUSTOMER (UPD_DT DESC);

CREATE INDEX ETL_SCHEMA.IX_CUSTOMER_STATUS
    ON ETL_SCHEMA.TB_CUSTOMER (STATUS, CUSTOMER_TYPE);

CREATE INDEX ETL_SCHEMA.IX_CUSTOMER_JOIN_DATE
    ON ETL_SCHEMA.TB_CUSTOMER (JOIN_DATE);
