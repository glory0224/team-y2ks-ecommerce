# Y2KS AIOps 멀티 에이전트 시스템 구현 가이드

> AWS Strands Agents SDK + Claude Sonnet 4.6 / Haiku 3 기반  
> Sherlock 스타일 Swarm 패턴 적용

---

## 목차

1. [시스템 개요](#1-시스템-개요)
2. [사전 요구사항](#2-사전-요구사항)
3. [환경 설정](#3-환경-설정)
4. [파일 구조](#4-파일-구조)
5. [에이전트 구조 상세](#5-에이전트-구조-상세)
6. [핵심 설계 패턴](#6-핵심-설계-패턴)
7. [실행 방법](#7-실행-방법)
8. [API 명세](#8-api-명세)
9. [트러블슈팅](#9-트러블슈팅)

---

## 1. 시스템 개요

### 아키텍처

```
사용자 질문 (React UI / Slack)
        ↓
   [Router] - Claude Sonnet 4.6
   질문 분석 → 전문가 배열 결정
        ↓
단일 전문가         복수 전문가
    ↓                  ↓
직접 처리          [Swarm 패턴]
                  전문가끼리 핸드오프
                  EKS ↔ DB ↔ Observe
                       ↓
              [Orchestrator] - Claude Sonnet 4.6
              교차 분석 + 최종 판단
```

### 에이전트별 역할

| 에이전트 | 모델 | 담당 영역 |
|---------|------|---------|
| Router | Claude Sonnet 4.6 | 질문 분석 → 전문가 선택 |
| EKS Agent | Claude Haiku 3 | kubectl / KEDA / Karpenter / SQS |
| DB Agent | Claude Haiku 3 | DynamoDB / 봇 탐지 / 참여 분석 |
| Observe Agent | Claude Haiku 3 | 리소스 / 비용 / 성능 |
| Orchestrator | Claude Sonnet 4.6 | Swarm 결과 교차 분석 + 최종 판단 |

### 설계 근거

- **팀장(Sonnet)**: 복잡한 판단 + 교차 분석 → 비싼 모델 필요
- **전문가(Haiku)**: kubectl/AWS API 호출 후 해석 → Nova Micro보다 추론력 우수, 저렴
- **Swarm 패턴**: 복합 장애 시 전문가끼리 핸드오프하며 맥락 공유 (Sherlock 참고)

---

## 2. 사전 요구사항

### 필수 설치

| 항목 | 버전 | 용도 |
|------|------|------|
| Python | **3.12.x** | MCP 호환 (3.14는 anyio 충돌) |
| kubectl | 최신 | EKS 클러스터 접근 |
| AWS CLI | v2 | Bedrock / SQS / DynamoDB |

> ⚠️ Python 3.14는 anyio 4.x와 충돌합니다. 반드시 3.12 사용하세요.

### Python 3.12 설치 (Windows)

```powershell
winget install Python.Python.3.12
```

### AWS 권한 확인

에이전트 실행 환경에 아래 IAM 권한이 필요합니다:

```json
{
  "Effect": "Allow",
  "Action": [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream",
    "sqs:GetQueueAttributes",
    "dynamodb:Scan",
    "dynamodb:GetItem"
  ],
  "Resource": "*"
}
```

### Bedrock 모델 접근 활성화

AWS 콘솔 → Bedrock → Model access에서 아래 모델 활성화:

- `Claude Sonnet 4` (APAC 리전)
- `Claude Haiku 3` (APAC 리전)

### EKS 클러스터 연결 확인

```bash
aws eks update-kubeconfig --name y2ks-eks-cluster --region ap-northeast-2
kubectl get nodes  # 노드 목록 나오면 OK
```

---

## 3. 환경 설정

### 가상환경 생성

```powershell
cd team-y2ks-ecommerce/agents
py -3.12 -m venv venv312
venv312\Scripts\activate
```

### 패키지 설치

```powershell
pip install strands-agents boto3 python-dotenv slack_bolt streamlit pandas fastapi uvicorn
```

### .env 파일 설정

`agents/.env` 파일을 아래와 같이 작성:

```env
# AWS
AWS_REGION=ap-northeast-2
DDB_TABLE=y2ks-coupon-claims
SQS_QUEUE_URL=https://sqs.ap-northeast-2.amazonaws.com/{ACCOUNT_ID}/y2ks-queue

# Slack Webhook (단방향 알림)
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...

# Slack Bot (양방향)
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_SIGNING_SECRET=...
SLACK_CHANNEL_ID=...
```

---

## 4. 파일 구조

```
agents/
├── eks_agent.py        # 핵심: 멀티에이전트 + Swarm 로직
├── api.py              # FastAPI 백엔드 (React UI용)
├── slack_bot.py        # Slack Socket Mode 봇
├── ui.py               # Streamlit 모니터링 UI
├── web/
│   └── index.html      # React CDN 기반 UI
├── .env                # 환경변수
├── requirements.txt    # 패키지 목록
└── AGENT_GUIDE.md      # 이 문서
```

---

## 5. 에이전트 구조 상세

### 5.1 모델 설정

```python
# eks_agent.py

# 팀장/라우터: 판단력 중요 → Sonnet 4.6
ORCHESTRATOR_MODEL = BedrockModel(
    model_id="apac.anthropic.claude-sonnet-4-20250514-v1:0",
    region_name="ap-northeast-2",
)

# 전문가: 빠른 처리 + 추론 → Haiku 3
SPECIALIST_MODEL = BedrockModel(
    model_id="apac.anthropic.claude-3-haiku-20240307-v1:0",
    region_name="ap-northeast-2",
)
```

### 5.2 툴(@tool) 목록

#### EKS Agent 툴

| 툴 함수 | 호출 명령 | 설명 |
|--------|---------|------|
| `get_all_pods()` | `kubectl get pods -A -o wide` | 전체 파드 상태 |
| `get_nodes()` | `kubectl get nodes --show-labels` | 노드 목록/라벨 |
| `get_node_resources()` | `kubectl top nodes` | 노드 CPU/메모리 실시간 |
| `get_pod_resources()` | `kubectl top pods -A` | 파드 CPU/메모리 실시간 |
| `get_pending_pods()` | `kubectl get pods --field-selector=Pending` | Pending 파드만 |
| `get_hpa()` | `kubectl get hpa -A` | KEDA ScaledObject 상태 |
| `get_karpenter_status()` | `kubectl get nodepool/nodeclaim` | Karpenter 노드 |
| `get_events()` | `kubectl get events --sort-by=.lastTimestamp` | 클러스터 이벤트 |
| `describe_pod(ns, name)` | `kubectl describe pod` | 파드 상세 + Events |
| `get_pod_logs(ns, name)` | `kubectl logs --tail=50` | 파드 로그 |
| `get_sqs_depth()` | boto3 SQS API | 큐 깊이 조회 |
| `send_slack_message(msg)` | Slack Webhook | Slack 알림 |

#### DB Agent 툴

| 툴 함수 | 호출 서비스 | 설명 |
|--------|-----------|------|
| `get_dynamodb_stats()` | DynamoDB Scan | 당첨/낙첨 통계 |
| `detect_bot_patterns()` | DynamoDB Scan | 봇 패턴 탐지 |
| `get_participation_timeline()` | DynamoDB Scan | 시간대별 참여 |

#### Observe Agent 툴

| 툴 함수 | 호출 | 설명 |
|--------|------|------|
| `get_node_resources()` | kubectl top | 노드 리소스 |
| `get_pod_resources()` | kubectl top | 파드 리소스 |
| `calculate_cost_savings()` | 계산 | OnDemand vs Spot 비용 절감 |

### 5.3 라우팅 로직

```python
def _route(question: str) -> list:
    """Claude Sonnet이 질문 읽고 필요한 전문가 JSON 배열 반환"""
    router = Agent(model=ORCHESTRATOR_MODEL, system_prompt=ROUTER_PROMPT, tools=[])
    result = router(question)
    # 예: ["eks"] / ["db"] / ["eks","db","observe"]
    return parsed_agents
```

라우팅 기준:

```
eks     → 파드/노드/KEDA/Karpenter/SQS/클러스터/로그/Pending/스케일링/장애
db      → 당첨자/낙첨자/봇/응모/DynamoDB/쿠폰/참여자/데이터
observe → CPU/메모리/비용/성능/리소스/절감/모니터링
```

### 5.4 Swarm 패턴

```python
def run_agent(user_message: str) -> dict:
    routes = _route(user_message)

    # 단일 전문가 → 빠른 직접 처리
    if len(routes) == 1:
        agent = Agent(model=SPECIALIST_MODEL, ...)
        return {key: result, "final": result}

    # 복수 전문가 → Swarm (핸드오프)
    agents = [
        Agent(name="eks", model=SPECIALIST_MODEL, ...),
        Agent(name="db",  model=SPECIALIST_MODEL, ...),
        ...
    ]
    swarm  = Swarm(agents, max_handoffs=6)
    result = asyncio.run(swarm.invoke_async(query))

    # 팀장이 Swarm 결과 종합
    orch = Agent(model=ORCHESTRATOR_MODEL, ...)
    final = orch(expert_summary)
```

**Swarm 핸드오프 예시:**
```
EKS Agent: "파드 Pending, 데이터 정합성도 확인 필요 → DB Agent 핸드오프"
    ↓
DB Agent: "DynamoDB 정상, 리소스 병목 의심 → Observe Agent 핸드오프"
    ↓
Observe Agent: "CPU 92% 포화 확인, 근본 원인 파악"
    ↓
Orchestrator(Sonnet): 전체 교차 분석 → 최종 판단
```

### 5.5 시스템 프롬프트 구조

모든 에이전트 프롬프트에 `ARCH_CONTEXT` 주입:

```python
ARCH_CONTEXT = """
## Y2KS 클러스터 아키텍처
- Frontend(2개) → SQS → Worker(1~50개, Spot) → DynamoDB
- Redis: 티켓 카운터 (ondemand-1 고정)
- KEDA: 큐 10개당 Worker 1개
- Karpenter: Spot 노드 자동 생성, CPU 상한 20코어

## 노드 구성
- ondemand-1: Redis, Frontend-1, Worker, Prometheus
- ondemand-2: Frontend-2, Cart, Product, Payment, Grafana

## 파드 우선순위
Redis(100000) > Frontend(10000) > Worker(1000) > Cart/Payment/Product(100)

## CPU requests
Worker:500m / Cart:400m / Product:400m / Payment:300m / Frontend:200m
"""
```

각 에이전트 프롬프트 구조:

```
역할 설명
+ ARCH_CONTEXT (공통 아키텍처 지식)
+ 도구 선택 전략 (2~3개만 선택)
+ 판단 기준 (수치 기반 임계값)
+ 핸드오프 기준 (언제 다른 전문가에게 넘길지)
+ 응답 형식 (조사대상/발견사항/즉시조치/단기권고)
```

---

## 6. 핵심 설계 패턴

### 6.1 왜 MCP 대신 @tool?

```
Python 3.14 + anyio 4.x → MCPClient 초기화 시 _task_states[host_task] 오류
→ MCP 완전 사용 불가
→ @tool 데코레이터로 전면 교체
```

Python 3.12 환경에서는 MCP 사용 가능 (`venv312`).

### 6.2 왜 Subprocess 격리? (Slack 봇)

```python
# slack_bot.py
def run_agent_isolated(user_text: str) -> dict:
    result = subprocess.run(
        [sys.executable, AGENT_SCRIPT, "--query", user_text],
        ...
    )
```

Slack의 asyncio 루프와 Strands의 asyncio 루프 충돌 방지.

### 6.3 모델 선택 기준

```
비싼 모델로 시작 → 점점 내려보며 품질 비교
Sonnet → Nova Pro → Haiku → Nova Micro

팀장: 판단력 중요 → Sonnet 유지
전문가: 도구 호출 + 수치 해석 → Haiku (Nova Micro는 추론력 부족)
```

### 6.4 응답 형식 (Sherlock 스타일)

```markdown
### 조사 대상
(어떤 리소스를 봤는지)

### 발견 사항
- **근본 원인**: (수치 포함)
- **심각도**: Critical / Warning / Info
- **신뢰도**: High(90%+) / Medium(70%+) / Low(50%+)

### 즉시 조치
(구체적 kubectl 명령어 포함)

### 단기 권고
(예방 조치)

### 추가 조사 필요 여부
(핸드오프 대상 명시)
```

---

## 7. 실행 방법

### 7.1 React 웹 UI + FastAPI

```powershell
cd agents
$env:AWS_REGION="ap-northeast-2"
$env:DDB_TABLE="y2ks-coupon-claims"
venv312\Scripts\python api.py
```

→ `http://localhost:8080` 접속

### 7.2 Slack 봇

```powershell
cd agents
$env:SLACK_BOT_TOKEN="xoxb-..."
$env:SLACK_APP_TOKEN="xapp-..."
$env:AWS_REGION="ap-northeast-2"
$env:DDB_TABLE="y2ks-coupon-claims"
venv312\Scripts\python slack_bot.py
```

Slack에서 `@봇이름 파드 상태 알려줘` 로 질문.

### 7.3 Streamlit 모니터링 UI

```powershell
cd agents
$env:AWS_REGION="ap-northeast-2"
$env:DDB_TABLE="y2ks-coupon-claims"
venv312\Scripts\python -m streamlit run ui.py
```

→ `http://localhost:8501` 접속

### 7.4 CLI 직접 실행

```powershell
# 대화형
venv312\Scripts\python eks_agent.py

# 단일 질문
venv312\Scripts\python eks_agent.py --query "지금 Pending 파드 있어?"

# 전체 자동 진단
venv312\Scripts\python eks_agent.py --auto
```

### 7.5 두 인터페이스 동시 실행 (터미널 2개)

```powershell
# 터미널 1 - 웹 UI
venv312\Scripts\python api.py

# 터미널 2 - Slack 봇
venv312\Scripts\python slack_bot.py
```

---

## 8. API 명세

### POST /api/query

에이전트에 질문

**Request:**
```json
{
  "message": "지금 Pending 파드 있어?"
}
```

**Response:**
```json
{
  "ok": true,
  "result": {
    "eks": "### 조사 대상\n...",
    "final": "**근본 원인**: ..."
  },
  "timestamp": "2026-04-16T10:30:00"
}
```

### POST /api/auto-diagnosis

전체 자동 진단 실행

**Response:**
```json
{
  "ok": true,
  "result": "## EKS Agent\n...\n## 팀장 종합 판단\n...",
  "timestamp": "2026-04-16T10:30:00"
}
```

### GET /api/health

서버 상태 확인

---

## 9. 트러블슈팅

### anyio 오류 (Python 3.14)

```
RuntimeError: Event loop is closed
_task_states[host_task] KeyError
```

→ Python 3.12 가상환경 사용:
```powershell
py -3.12 -m venv venv312
venv312\Scripts\activate
```

### Bedrock 모델 접근 오류

```
ValidationException: The provided model identifier is invalid
```

→ AWS 콘솔에서 해당 리전 모델 접근 활성화 필요.  
→ APAC 리전 모델 ID 형식 확인:
```
apac.anthropic.claude-sonnet-4-20250514-v1:0  ← Sonnet 4.6
apac.anthropic.claude-3-haiku-20240307-v1:0   ← Haiku 3
apac.amazon.nova-pro-v1:0                      ← Nova Pro
apac.amazon.nova-micro-v1:0                    ← Nova Micro
```

### kubectl 연결 오류

```
error: the server doesn't have a resource type "pods"
```

→ kubeconfig 업데이트:
```bash
aws eks update-kubeconfig --name y2ks-eks-cluster --region ap-northeast-2
```

### Slack 봇 응답 없음

1. `slack_bot.py` 실행 중인지 확인
2. `SLACK_APP_TOKEN` (xapp-...) 설정 확인
3. Slack App 설정에서 Socket Mode 활성화 확인
4. `eks_agent.py --query "테스트"` 직접 실행해서 에이전트 동작 확인

### Swarm 타임아웃

```
asyncio.TimeoutError
```

→ `max_handoffs` 줄이기:
```python
swarm = Swarm(agents, max_handoffs=3)  # 6 → 3
```

---

## 참고 레포

- [aws-samples/sample-agentic-aiops-k8s-sherlock](https://github.com/aws-samples/sample-agentic-aiops-k8s-sherlock) — Swarm 패턴, 프롬프트 구조 참고
- [AWS Strands Agents SDK 공식 문서](https://strandsagents.com)
- [composable-models/llm_multiagent_debate](https://github.com/composable-models/llm_multiagent_debate) — Multi-Agent Debate 패턴
