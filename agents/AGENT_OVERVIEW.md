# Y2KS 멀티 에이전트 시스템 — 기능 정리

## 시스템 개요

Y2KS 이커머스 플랫폼의 EKS 클러스터를 자율 운영하는 멀티 에이전트 시스템입니다.  
AWS Strands Agents SDK + Amazon Bedrock(Nova Micro) + MCP 기반으로 구성되며,  
Streamlit UI를 통해 실시간 모니터링 및 AI 진단을 제공합니다.

```
사용자 (Streamlit UI)
        ↓  질문
   LLM 라우터 (Router Agent)
    ↙        ↓        ↘
EKS Agent  DB Agent  Observe Agent
    ↘        ↓        ↙
       팀장 (Orchestrator)
              ↓
         최종 판단 출력
```

---

## 기술 스택

| 항목 | 선택 | 비고 |
|---|---|---|
| 에이전트 프레임워크 | AWS Strands Agents SDK | Bedrock 네이티브 연동 |
| LLM | Amazon Nova Micro (`apac.amazon.nova-micro-v1:0`) | ap-northeast-2 |
| Tool 연결 | MCP (Model Context Protocol) | stdio transport |
| UI | Streamlit | 실시간 차트 + 챗봇 |
| 인프라 조회 | kubectl + boto3 | 파드/노드/DynamoDB/SQS |
| 메트릭 | Prometheus HTTP API + kubectl top | CPU/메모리 |
| 알림 | Slack Incoming Webhook | HTTP POST |

---

## 에이전트 구성

### 1. LLM 라우터 (Router Agent)
> `eks_agent.py` — `_route()` 함수

**역할**: 사용자 질문을 이해하고 어떤 전문가에게 보낼지 결정

**동작 방식**:
- 키워드 매칭 X → LLM이 직접 판단
- JSON 배열 형태로 전문가 선택 반환 (예: `["eks", "db"]`)
- 파싱 실패 시 기본값 `["eks"]` 반환

**라우팅 예시**:
| 질문 | 선택된 전문가 |
|---|---|
| "파드 몇 개야?" | `["eks"]` |
| "봇 있어?" | `["db"]` |
| "지금 문제 있어?" | `["eks", "db", "observe"]` |
| "비용이랑 파드 알려줘" | `["eks", "observe"]` |
| "전체 진단해줘" | `["eks", "db", "observe"]` |

---

### 2. EKS Agent (OpsCommander)
> `eks_agent.py` — `EKS_PROMPT`

**역할**: EKS 클러스터 운영 전문가 — 파드/노드/스케일링 담당

**판단 기준**:
- Running 아닌 파드 존재 → 즉시 장애 (Critical)
- Pending 파드 존재 → 노드 자원 부족 또는 스케줄링 문제
- SQS 큐 100건 이상 → Worker 스케일 부족
- KEDA 복제본이 maxReplicas 도달 → Karpenter 확장 필요

**사용 MCP 툴**:
| 툴 | 설명 |
|---|---|
| `get_all_pods()` | 전체 네임스페이스 파드 목록 + Running/Pending 요약 |
| `get_nodes()` | 노드 목록 + Spot/OnDemand 구분 |
| `get_node_resources()` | kubectl top nodes — CPU/메모리 |
| `get_pod_resources()` | kubectl top pods — 파드별 사용량 |
| `get_pending_pods()` | Pending 파드 + 원인 |
| `get_hpa()` | KEDA HPA 스케일 상태 (현재/최소/최대 복제본) |
| `get_karpenter_nodeclaims()` | Karpenter NodeClaim 목록 |
| `get_karpenter_status()` | NodePool + NodeClaim 전체 상태 |
| `describe_pod()` | 특정 파드 상세 정보 + 이벤트 |
| `get_pod_logs()` | 특정 파드 최근 로그 |
| `restart_deployment()` | Deployment 재시작 (위험) |
| `get_events()` | 클러스터 전체 이벤트 (경고 포함) |
| `get_sqs_depth()` | SQS 큐 대기/처리 중 메시지 수 |

---

### 3. DB Agent (DataSherlock)
> `eks_agent.py` — `DB_PROMPT`

**역할**: 데이터 정합성 및 봇 트래픽 탐지 전문가

**판단 기준**:
- 봇 패턴 닉네임 비율 20% 초과 → 이벤트 중단 검토
- 단시간 참여 급증 (정상 대비 3배 이상) → 봇 공격 의심
- winner + loser 합계 ≠ 응모 수 → 데이터 정합성 이상

**사용 MCP 툴**:
| 툴 | 설명 |
|---|---|
| `get_dynamodb_stats()` | DynamoDB 당첨자/낙첨자 수 + 당첨률 |
| `detect_bot_patterns()` | 닉네임 패턴 분석 — `user_숫자_숫자`, `VU_숫자` 형태 탐지 |
| `get_participation_timeline()` | 시간대별 응모 참여 추이 + 피크 시간 |

**봇 탐지 패턴**:
```python
r"^(user_\d+_\d+|VU_\d+|vu\d+|test_?\d+)$"
# 예: user_1_5, VU_12, vu3, test_001
```

---

### 4. Observe Agent (DevOpsGuru)
> `eks_agent.py` — `OBSERVE_PROMPT`

**역할**: 메트릭/성능 관측 및 비용 최적화 전문가

**판단 기준**:
- 노드 CPU 80% 초과 → 즉시 스케일 아웃 권고
- 노드 메모리 85% 초과 → OOM 위험, 즉시 조치
- 파드 CPU가 limits의 90% 도달 → throttling 발생 가능
- OnDemand → Spot 전환 절감 분석 → 최적화 권고

**사용 MCP 툴**:
| 툴 | 설명 |
|---|---|
| `get_prometheus_metrics()` | Prometheus HTTP API — CPU%, 메모리%, HTTP 요청 수 |
| `get_node_resources()` | kubectl top nodes |
| `get_pod_resources()` | kubectl top pods |
| `calculate_cost_savings()` | t3.medium OnDemand vs t3.medium Spot 비용 비교 |

**비용 계산 기준** (ap-northeast-2):
| 인스턴스 | 시간당 USD |
|---|---|
| t3.medium OnDemand | $0.0520 |
| t3.medium Spot (평균) | $0.0156 |

---

### 5. 팀장 Orchestrator
> `eks_agent.py` — `ORCHESTRATOR_PROMPT`

**역할**: 세 전문가 의견을 교차 분석하여 최종 판단 도출

**1단계 — 교차 분석**:
- 여러 전문가 동시 이상 보고 → 연관성/원인-결과 파악
- 한 전문가만 이상 → 해당 도메인 단독 문제
- 의견 모순 → 더 많은 데이터를 가진 쪽 우선

**인과관계 패턴 예시**:
```
봇 급증(DB) + SQS 폭증(EKS) + CPU 급증(Observe)
→ 봇 공격이 근본 원인

Pending 파드(EKS) + CPU 높음(Observe)
→ 노드 자원 부족이 근본 원인

SQS 적체(EKS) + KEDA 정상(EKS)
→ Worker 처리 능력 한계
```

**2단계 — 우선순위**:
1. 서비스 중단 (파드 Running 아님) → 즉각 조치
2. 데이터 정합성 이상 → 이벤트 즉시 중단
3. Pending 파드 → 5분 내 해소
4. 봇 트래픽 20% 초과 → 이벤트 중단 검토
5. CPU/메모리 70% 초과 → 스케일 아웃 권고
6. SQS 적체 100건 미만 → 모니터링 유지
7. 비용 최적화 → 여유 시 진행

**출력 형식**:
```
근본 원인: ...
현재 상황: ...
즉시 조치: ...
단기 권고 (24시간 내): ...
장기 권고 (여유 시): ...
```

---

## MCP 서버 구조
> `eks_mcp_server.py`

- FastMCP 기반 stdio transport
- 툴 출력 최대 **3,000자** 제한 (토큰 절약)
- 각 에이전트에 전체 툴 목록 제공 (LLM이 필요한 것만 선택)

```python
MAX_OUTPUT = 3000

def _kubectl(*args) -> str:
    out = r.stdout or r.stderr
    if len(out) > MAX_OUTPUT:
        out = out[:MAX_OUTPUT] + f"\n...(잘림, 총 {len(out)}자)"
    return out
```

---

## Streamlit UI 기능
> `ui.py`

### 실시간 모니터링 (30초 자동 갱신)
| 차트 | 내용 |
|---|---|
| Node CPU / Memory Usage | 노드 평균 CPU%, 메모리% 시계열 |
| Pod Count Trend | Running/Pending 파드 수 시계열 |
| Worker Replicas (KEDA) | KEDA HPA 복제본 수 시계열 |
| Spot Nodes (Karpenter) | Karpenter Spot 노드 수 시계열 |

### 상단 메트릭 카드 (5개)
- Winners (당첨자 수)
- Losers (낙첨자 수)
- Nodes (노드 수)
- Running pods
- Pending pods

### 리소스 현황 테이블
- **Node Resources**: 노드별 CPU(m), CPU%, Mem(Mi), Mem% + 바 차트
- **Top Pods by CPU**: CPU 사용량 상위 10개 파드

### AI 어시스턴트 (챗봇)
- 자유 질문 입력
- LLM 라우터가 전문가 자동 선택 (표시됨)
- 각 전문가 의견 → expander로 접기/펼치기
- 팀장 최종 판단 → 메인 영역에 표시

### Quick Actions (사이드바)
| 버튼 | 실행 질문 |
|---|---|
| Cluster overview | 클러스터 전체 상태 진단 |
| Pending pod analysis | Pending 파드 원인 분석 |
| DynamoDB / SQS status | 이벤트 결과 + SQS 상태 확인 |
| Worker pod logs | Worker 로그 에러 확인 |
| Cost report | OnDemand vs Spot 비용 절감 계산 |

### 전체 자동 진단
- **Run diagnosis** 버튼으로 세 전문가 + 팀장 전체 진단 실행
- `final_report.md` 자동 저장 (UTC 타임스탬프 포함)
- 최신 보고서 UI에서 바로 조회 가능

---

## Slack 알림 (Incoming Webhook)

### 자동 알림 조건
| 조건 | 레벨 | 비고 |
|---|---|---|
| Pending 파드 발생 | Critical | 세션당 1회만 |
| Pending 파드 해소 | OK | 복구 확인용 |
| 노드 CPU 60% 초과 | Warning | 노드별 개별 추적 |
| 노드 메모리 70% 초과 | Warning | 노드별 개별 추적 |
| Karpenter Spot 노드 생성 | Info | 개수 변화 감지 |
| Karpenter Spot 노드 반납 | OK | 통합 완료 알림 |
| Worker 파드 선점(Preemption) | Warning | 우선순위 밀어내기 감지 |

### 수동 알림 (사이드바 버튼)
- **Send cluster report**: 현재 클러스터 상태 요약 전송
- **Send test ping**: 연결 확인용 테스트 메시지

### 알림 색상
| 레벨 | 색상 |
|---|---|
| Critical | 빨강 (#e53e3e) |
| Warning | 주황 (#d97706) |
| OK | 초록 (#22c55e) |
| Info | 파랑 (#3b82f6) |

---

## 파드 우선순위 구조

```
Worker (y2ks-normal)    → priorityClass: high-priority    (1000)
Cart / Payment / Product → priorityClass: normal-priority  (100)

Pending 시 Worker가 낮은 우선순위 파드를 선점(Preempt)하여
온디맨드 노드에 강제 배치됨
```

## 스케일링 흐름

```
트래픽 증가
→ SQS 메시지 적체
→ KEDA가 Worker HPA 스케일 업 (복제본 증가)
→ 온디맨드 노드 자원 부족 (requests 초과)
→ Karpenter가 Spot 노드 프로비저닝
→ Worker 파드 Spot 노드에 배치
→ 트래픽 감소 시 Karpenter가 Spot 노드 반납
```

---

## 실행 방법

```bash
# 환경변수 설정
export AWS_REGION=ap-northeast-2
export DDB_TABLE=y2ks-coupon-claims
export SQS_QUEUE_URL=https://sqs.ap-northeast-2.amazonaws.com/...
export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...

# UI 실행
cd team-y2ks-ecommerce/agents
streamlit run ui.py

# CLI 자동 진단
python eks_agent.py --auto

# CLI 대화형
python eks_agent.py
```

---

## 파일 구조

```
agents/
├── eks_agent.py        # 멀티 에이전트 + 라우터 + 오케스트레이터
├── eks_mcp_server.py   # MCP 툴 서버 (kubectl + boto3 + Prometheus)
├── ui.py               # Streamlit UI (모니터링 + 챗봇 + Slack)
├── final_report.md     # 자동 진단 보고서 (자동 생성)
└── AGENT_OVERVIEW.md   # 이 파일
```
