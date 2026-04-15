# MODO Fashion - 시스템 아키텍처

## 전체 흐름

```mermaid
flowchart TD
    User([사용자])

    subgraph EKS[AWS EKS]
        subgraph AppNodes[App Nodes]
            Frontend[Frontend - Flask]
            Redis[Redis]
        end
        subgraph KarpenterNodes[Karpenter Nodes]
            Worker[SQS Worker]
        end
        KEDA[KEDA]
        Karpenter[Karpenter]
    end

    subgraph AWS[AWS Services]
        SQS[SQS Queue]
        DynamoDB[DynamoDB]
        SES[AWS SES]
    end

    User --> Frontend
    Frontend --> SQS
    Frontend --> Redis
    Redis --> Frontend
    KEDA --> SQS
    KEDA --> Worker
    Karpenter --> KarpenterNodes
    Worker --> SQS
    Worker --> Redis
    Worker --> DynamoDB
    Worker --> SES

    style EKS fill:#e8f4f8,stroke:#2196F3
    style AppNodes fill:#fff9e6,stroke:#FFC107
    style KarpenterNodes fill:#fff9e6,stroke:#FFC107
    style AWS fill:#f0f4e8,stroke:#4CAF50
    style Redis fill:#ffcccc,stroke:#f44336
    style Frontend fill:#cce5ff,stroke:#2196F3
    style Worker fill:#e8ffe8,stroke:#4CAF50
    style KEDA fill:#f3e5f5,stroke:#9C27B0
    style Karpenter fill:#f3e5f5,stroke:#9C27B0
```

## PriorityClass

```mermaid
flowchart LR
    A[modo-critical 100000 - Redis] --> B[modo-high 10000 - Frontend]
    B --> C[modo-normal 1000 - Worker]

    style A fill:#ffcccc,stroke:#f44336
    style B fill:#fff9e6,stroke:#FFC107
    style C fill:#e8ffe8,stroke:#4CAF50
```

## 쿠폰 처리 시퀀스

```mermaid
sequenceDiagram
    actor User as 사용자
    participant FE as Frontend
    participant SQS as SQS Queue
    participant Worker as Worker Pod
    participant Redis as Redis
    participant DB as DynamoDB
    participant SES as SES

    User->>FE: 쿠폰 버튼 클릭
    FE->>SQS: 메시지 전송
    FE-->>User: 대기 중

    loop 폴링
        User->>FE: 상태 조회
        FE->>Redis: 결과 조회
        Redis-->>FE: null
        FE-->>User: 처리 중
    end

    Worker->>SQS: 메시지 소비
    alt 쿠폰 재고 있음
        Worker->>Redis: winner 저장
        Worker->>DB: 당첨 기록 저장
        FE-->>User: 이메일 입력 화면
        User->>FE: 이메일 제출
        FE->>DB: email 업데이트
        FE->>SES: 이메일 발송
        SES-->>User: 쿠폰 이메일 수신
    else 쿠폰 소진
        Worker->>Redis: loser 저장
        Worker->>DB: 낙첨 기록 저장
        FE-->>User: 낙첨 안내
    end
```

## DynamoDB 스키마

| 필드 | 타입 | 설명 |
|------|------|------|
| request_id | String PK | 쿠폰 클릭 시 생성되는 UUID |
| status | String | winner / loser |
| coupon_code | String | 발급된 쿠폰 코드 당첨자만 |
| claimed_at | String | 처리된 ISO 타임스탬프 |
| email | String | 당첨자 이메일 |
| email_sent | Boolean | SES 발송 완료 여부 |

## KEDA 스케일링

| 항목 | 값 |
|------|----|
| 대상 | concert-worker Deployment |
| 트리거 | SQS 메시지 수 |
| 임계값 | 5개 per replica |
| 최소 replica | 1 |
| 최대 replica | 50 |

## Karpenter 노드

| 항목 | 값 |
|------|----|
| 인스턴스 | t3.small |
| 아키텍처 | amd64 linux |
| 용량 타입 | on-demand + spot |
| 최대 CPU | 20 core |
| 노드 만료 | 72시간 |
| 통합 정책 | WhenEmptyOrUnderutilized 30초 |
