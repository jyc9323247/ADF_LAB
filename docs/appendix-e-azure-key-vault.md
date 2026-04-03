# 부록 E. Azure Key Vault 사용하여 연결정보 저장하기

## 생성
1. Resource Group에 들어가서 create resource 클릭
2. Key Vault 찾아서 create
3. Korea Central, purge protection 필요시 설정후 create
4. Azure Data Factory에서도 Linked Service를 만들어준다. 생성시 System-Assigned Managed Identity로 인증방법을 설정하고 연결테스트를 해본다. 만약 실패할 경우 ADF에 Secret Read 권한이 있는지 확인한다. 없다면 후술할 권한 설정을 참고.


## Secret 설정
왼쪽 패널의 Objects -> Secrets에서 + 버튼으로 생성할 수 있음.
DB2의 경우, 전체 연결정보를 하나의 Secret으로 넣어주어야 하는데, 아래의 포맷으로 넣어주면 됨
```
server=<server:port>;database=<database>;authenticationType=Basic;username=<username>;password=<password>;packageCollection=<packagecollection>;certificateCommonName=<certname>
```
packageCollection과 certificaeCommonName은 생략 가능.


## 권한 설정
Azure Data Factory에서 Key Vault의 Secret을 읽을 수 있도록 설정해주어야 한다. (유저에게 권한 부여X)
1. Azure 콘솔의 All Resources -> Key Vault -> 왼쪽 패널의 Access Control(IAM) -> Add Role Assignment 선택
2. Role 탭에서 Key Vault 검색해 Secrets User 이상의 권한 선택 
3. Next 클릭후 Member 탭에서 Assign Access to: **Managed Identity** 선택. (유저가 아니라 Data Factory라는 Azure Managed Identity에 권한을 주어야 하므로)
4. 대상 Data Factory를 선택해주고 Review + Assign


