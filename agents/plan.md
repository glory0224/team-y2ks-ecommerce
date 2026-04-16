# Plan: Y2KS 멀티 에이전트 자율 운영 시스템

## 아키텍처 개요

```
사용자 (Streamlit UI)
        ↓
Orchestrator (오케스트레이터)
    ↙        ↓        ↘
OpsCommander  DataSherlock  DevOpsGuru
(EKS 팀장)  (데이터 분석가) (데브옵스 전문가)
    ↓              ↓            ↓
 kubectl        Athena      Prometheus
 Karpenter     DynamoDB     Cost API
```

---

## 에이전트 상세 설계

### 1. OpsCommander (EKS 팀장)
**역할**: EKS 클러스터 상태 총괄 감시 및 장애 대응

**Tools**:
- `get_pod_status()`: 전체 파드 상태 조회
- `get_node_status()`: 노드 CPU/메모리 사용량 조회
- `get_pending_pods()`: Pending 파드 및 원인 분석
- `get_hpa_status()`: KEDA HPA 스케일 상태 조회
- `restart_deployment()`: 장애 파드 재시작 (권고 후 실행)

**시나리오**:
```
Worker 파드 다수 Pending 감지
→ Karpenter 노드 생성 상태 확인
→ CPU limit 초과 여부 판단
→ DevOpsGuru에게 비용 최적화 권고 요청
```

---

### 2. DataSherlock (데이터 분석가)
**역할**: 이벤트 로그 분석 및 이상 트래픽(봇) 탐지

**Tools**:
- `query_dynamodb_stats()`: 당첨자/낙첨자 수 조회
- `query_athena_logs()`: S3 로그 Athena SQL 쿼리
- `detect_bot_pattern()`: 닉네임 패턴 분석 (user_VU_ITER 형태)
- `get_participation_timeline()`: 시간대별 참여 추이 분석

**봇 탐지 로직**:
```python
# 정상 사용자: 랜덤 닉네임
# 봇 패턴: user_숫자_숫자 형태 다수 반복
# 동일 IP 다수 요청 (향후 확장)
# 1초 내 수십 건 참여
```

**시나리오**:
```
DynamoDB에서 닉네임 패턴 분석
→ user_VU_ITER 형태 비율 계산
→ 전체 참여자 중 봇 추정 비율 리포트
→ final_report.md에 결과 저장
```

---

### 3. DevOpsGuru (데브옵스 전문가)
**역할**: 비용 최적화 및 배포 전략 수립

**Tools**:
- `get_prometheus_metrics()`: Prometheus API로 메트릭 조회
- `analyze_resource_usage()`: CPU/메모리 실사용률 분석
- `graviton_migration_plan()`: Graviton 전환 계획 생성
- `calculate_cost_saving()`: 비용 절감액 계산

**Graviton 전환 계획**:
```
현재: t3.medium (x86_64) → 목표: t4g.medium (ARM64)
현재: amd64 Spot → 목표: arm64 Spot

변경 필요:
1. Dockerfile: --platform=linux/arm64
2. Karpenter NodePool: arm64 추가
3. ECR: ARM64 이미지 빌드/푸시
예상 절감: ~30% (t4g가 t3 대비 약 20% 저렴 + Spot 할인)
```

---

## 구현 계획

### Phase 1: 기반 구조 (main.py)
- Strands Agents SDK 설치 및 설정
- AWS Bedrock 연결 (Claude Sonnet)
- 기본 Tool 함수 구현

### Phase 2: 에이전트 구현
- OpsCommander: kubectl 기반 Tool
- DataSherlock: boto3 기반 DynamoDB/Athena Tool
- DevOpsGuru: Prometheus HTTP API Tool

### Phase 3: 오케스트레이션
- Orchestrator가 세 에이전트 순차 호출
- 각 에이전트 결과 취합
- final_report.md 자동 생성

### Phase 4: UI
- Streamlit 챗봇 UI
- 실시간 메트릭 시각화
- 에이전트 대화 히스토리 표시

### Phase 5: Graviton 전환
- Dockerfile.frontend, Dockerfile.worker ARM64 빌드 설정
- Karpenter NodePool arm64 추가
- GitHub Actions ARM64 빌드 워크플로우

---

## 기술 스택

| 항목 | 선택 | 이유 |
|---|---|---|
| 에이전트 프레임워크 | AWS Strands Agents | AWS 네이티브, Bedrock 연동 |
| LLM | Claude Sonnet (Bedrock) | 한국어 우수, 추론 능력 |
| UI | Streamlit | 빠른 구현, Python 친화 |
| 인프라 조회 | kubectl + boto3 | 기존 권한 활용 |
| 메트릭 | Prometheus HTTP API | 기존 스택 활용 |

---

## 성공 기준 측정 방법

### 장애 복구 시간 단축
```
시뮬레이션: Worker 파드 강제 종료
측정: OpsCommander 감지 시간 + 재시작 권고까지 시간
목표: 60초 이내
```

### 비용 30% 절감
```
계산: (t3.medium 시간당 비용 - t4g.medium 시간당 비용) / t3.medium
ap-northeast-2 기준:
  t3.medium On-Demand: $0.052/h
  t4g.medium On-Demand: $0.0416/h
  절감률: 약 20% (Spot 포함 시 추가 절감)
```
