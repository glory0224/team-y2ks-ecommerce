# Requirements: Y2KS 자율 운영 시스템

## 현재 인프라 현황

### EKS 클러스터
- 고정 온디맨드 노드 2개 (t3.medium, x86_64)
- Karpenter 동적 Spot 노드 (최대 CPU 20코어, amd64)
- 네임스페이스: default, karpenter, keda, monitoring

### 애플리케이션 스택
| 컴포넌트 | 역할 | 스케일링 |
|---|---|---|
| Frontend (Flask) | 쿠폰 이벤트 API | 고정 2 replicas |
| Worker (Python) | SQS 소비 + 쿠폰 발급 | KEDA 1~50 replicas |
| Redis | 중복 참여 차단 (SADD), 티켓 카운트 (DECR) | 고정 1 replica |

### AWS 서비스
- **SQS**: 비동기 쿠폰 처리 큐 (Standard Queue)
- **DynamoDB**: 테이블 `y2ks-coupon-claims` (PK: request_id = nickname)
- **ECR**: y2ks-frontend, y2ks-worker 이미지 저장소
- **S3 + Athena**: 이벤트 로그 분석용 (terraform 구성 완료)

### 모니터링
- Prometheus (kube-prometheus-stack, EBS PVC 5Gi)
- Grafana (ALB 외부 접근)
- 메트릭: http_request_duration_seconds, http_requests_total (url_rule별)

### 오토스케일링
- **KEDA**: SQS 메시지 수 기반 Worker 스케일 (target: 10메시지/파드)
- **Karpenter**: Pending 파드 감지 → Spot EC2 자동 프로비저닝

### 우선순위 (PriorityClass)
| 클래스 | 값 | 대상 |
|---|---|---|
| critical | 100000 | Frontend, Redis |
| high | 10000 | Prometheus, Grafana |
| normal | 1000 | Worker |
| low | 100 | Cart, Payment, Product (더미) |

---

## 문제점 및 개선 필요 사항

### 1. 운영 자동화 부재
- 장애 감지 → 수동 대응 (kubectl 명령 직접 실행)
- 이상 트래픽 탐지 로직 없음
- 배포 자동화 없음 (수동 helm upgrade)

### 2. 비용 최적화 여지
- 현재 모든 노드 x86_64 (amd64)
- Graviton (ARM64) 전환 시 약 20~30% 비용 절감 가능
- Spot 노드 최대 CPU 20코어 제한 → 피크 시 병목 가능성

### 3. 데이터 분석 파이프라인 미구축
- DynamoDB 데이터 S3 export 미구현
- Athena 테이블/쿼리 미활용
- 이벤트 사후 분석 불가

### 4. 보안
- DynamoDB VPC Endpoint 미적용 (인터넷 경유)
- Admin 페이지 인증 없음

---

## Success Criteria

### 1. 장애 복구 시간 단축
- **현재**: 장애 감지 → 수동 대응 (수분~수십분)
- **목표**: 에이전트 자동 감지 → 자동 복구 액션 (1분 이내)
- **측정**: MTTR (Mean Time To Recovery) 단축

### 2. Graviton 전환을 통한 비용 30% 절감
- **현재**: t3.medium (x86_64) 온디맨드 + Spot amd64
- **목표**: t4g.medium (ARM64) 온디맨드 + Spot arm64
- **측정**: AWS Cost Explorer 월별 EC2 비용 비교

### 3. 멀티 에이전트 자율 운영
- EKS 상태 자동 진단
- 이상 트래픽 자동 탐지
- 운영 보고서 자동 생성

---

## 멀티 에이전트 역할 정의

| 에이전트 | 역할 | 담당 도구 |
|---|---|---|
| **OpsCommander** (EKS 팀장) | 클러스터 상태 총괄, 장애 대응 지시 | kubectl, Karpenter API |
| **DataSherlock** (데이터 분석가) | 이벤트 로그 분석, 봇 탐지 | Athena, DynamoDB |
| **DevOpsGuru** (데브옵스 전문가) | 비용 최적화, 배포 전략 | Prometheus, Cost API |
