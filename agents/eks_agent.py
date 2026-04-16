"""
Y2KS AIOps 멀티 에이전트 시스템
Sherlock 스타일 Swarm 패턴 + 프롬프트 강화

에이전트 구성:
- EKS Agent     : kubectl + KEDA + Karpenter + SQS  (Nova Pro)
- DB Agent      : DynamoDB + 봇 탐지 + 참여 분석   (Nova Pro)
- Observe Agent : 리소스 + 비용 + 성능 분석        (Nova Pro)
- Orchestrator  : Swarm 결과 종합 + 최종 판단      (Nova Pro)
  * Claude 모델은 AWS Bedrock use case form 제출 후 사용 가능
  * 신청: AWS Console → Bedrock → Model access → Anthropic 모델 신청

패턴:
- Swarm: 전문가끼리 서로 핸드오프하며 협력 분석
- Router: 단일 전문가 질문은 Swarm 없이 직접 처리
"""

import os
import re
import sys
import json
import asyncio
import subprocess
import boto3
import time
import urllib.request
from datetime import datetime, timezone

try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
except ImportError:
    pass

from strands import Agent, tool
from strands.models.bedrock import BedrockModel
from strands.multiagent.swarm import Swarm

AWS_REGION    = os.environ.get("AWS_REGION", "ap-northeast-2")
DDB_TABLE     = os.environ.get("DDB_TABLE", "y2ks-coupon-claims")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
SLACK_WEBHOOK = os.environ.get("SLACK_WEBHOOK_URL", "")
MAX_OUT       = 3000

# ── 모델 ─────────────────────────────────────────────────────
ORCHESTRATOR_MODEL = BedrockModel(
    model_id="apac.anthropic.claude-sonnet-4-20250514-v1:0",
    region_name=AWS_REGION,
)
SPECIALIST_MODEL = BedrockModel(
    model_id="apac.anthropic.claude-3-haiku-20240307-v1:0",
    region_name=AWS_REGION,
)


def _kubectl(*args) -> str:
    try:
        r = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=15)
        out = r.stdout or r.stderr or "(출력 없음)"
        return out[:MAX_OUT] + "\n...(잘림)" if len(out) > MAX_OUT else out
    except Exception as e:
        return f"오류: {e}"


# ── EKS 툴 ───────────────────────────────────────────────────

@tool
def get_all_pods() -> str:
    """전체 네임스페이스의 파드 목록과 상태를 조회합니다."""
    output = _kubectl("get", "pods", "-A", "-o", "wide")
    lines = [l for l in output.strip().split("\n") if l]
    total   = len(lines) - 1 if lines else 0
    running = sum(1 for l in lines if "Running" in l)
    pending = sum(1 for l in lines if "Pending" in l)
    return output + f"\n\n[요약] 전체: {total}개, Running: {running}개, Pending: {pending}개"

@tool
def get_nodes() -> str:
    """노드 목록과 상태, 라벨을 조회합니다."""
    return _kubectl("get", "nodes", "-o", "wide", "--show-labels")

@tool
def get_node_resources() -> str:
    """노드별 CPU/메모리 실시간 사용량을 조회합니다."""
    return _kubectl("top", "nodes")

@tool
def get_pod_resources() -> str:
    """파드별 CPU/메모리 실시간 사용량을 조회합니다."""
    return _kubectl("top", "pods", "-A")

@tool
def get_pending_pods() -> str:
    """Pending 상태인 파드만 조회합니다."""
    return _kubectl("get", "pods", "-A", "--field-selector=status.phase=Pending", "-o", "wide")

@tool
def get_hpa() -> str:
    """KEDA ScaledObject / HPA 스케일 상태를 조회합니다."""
    return _kubectl("get", "hpa", "-A")

@tool
def get_karpenter_status() -> str:
    """Karpenter NodePool, NodeClaim 상태를 조회합니다."""
    nodepool  = _kubectl("get", "nodepool", "-o", "wide")
    nodeclaim = _kubectl("get", "nodeclaim", "-o", "wide")
    return f"[NodePool]\n{nodepool}\n\n[NodeClaim]\n{nodeclaim}"

@tool
def get_events() -> str:
    """클러스터 전체 이벤트를 최신순으로 조회합니다."""
    return _kubectl("get", "events", "-A", "--sort-by=.lastTimestamp")

@tool
def describe_pod(namespace: str, pod_name: str) -> str:
    """특정 파드의 상세 정보(Events 포함)를 조회합니다."""
    return _kubectl("describe", "pod", "-n", namespace, pod_name)

@tool
def get_pod_logs(namespace: str, pod_name: str, lines: int = 50) -> str:
    """특정 파드의 최근 로그를 조회합니다."""
    return _kubectl("logs", "-n", namespace, pod_name, f"--tail={lines}")

@tool
def get_sqs_depth() -> str:
    """SQS 큐 대기/처리중 메시지 수를 조회합니다."""
    try:
        if not SQS_QUEUE_URL:
            return "SQS_QUEUE_URL 환경변수가 설정되지 않았습니다."
        sqs  = boto3.client("sqs", region_name=AWS_REGION)
        resp = sqs.get_queue_attributes(
            QueueUrl=SQS_QUEUE_URL,
            AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
        )
        attrs = resp["Attributes"]
        return json.dumps({
            "waiting":   attrs.get("ApproximateNumberOfMessages", 0),
            "in_flight": attrs.get("ApproximateNumberOfMessagesNotVisible", 0)
        })
    except Exception as e:
        return f"SQS 오류: {e}"

@tool
def send_slack_message(message: str, level: str = "info") -> str:
    """Slack 채널에 메시지를 전송합니다. level: info/warning/critical/ok"""
    if not SLACK_WEBHOOK:
        return "SLACK_WEBHOOK_URL 환경변수가 설정되지 않았습니다."
    color   = {"critical": "#e53e3e", "warning": "#d97706",
                "ok": "#22c55e", "info": "#3b82f6"}.get(level, "#94a3b8")
    payload = {"attachments": [{"color": color, "text": message,
                                 "footer": "Y2KS EKS Agent", "ts": int(time.time())}]}
    try:
        data = json.dumps(payload).encode("utf-8")
        req  = urllib.request.Request(
            SLACK_WEBHOOK, data=data, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5)
        return "Slack 전송 완료"
    except Exception as e:
        return f"Slack 전송 실패: {e}"


# ── DB 툴 ────────────────────────────────────────────────────

@tool
def get_dynamodb_stats() -> str:
    """DynamoDB에서 당첨자/낙첨자 수와 당첨률을 조회합니다."""
    try:
        ddb   = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = ddb.Table(DDB_TABLE)
        winner = loser = 0
        scan_kw: dict = {
            "ProjectionExpression": "#s",
            "ExpressionAttributeNames": {"#s": "status"}
        }
        while True:
            resp = table.scan(**scan_kw)
            for item in resp.get("Items", []):
                s = item.get("status")
                if s == "winner":  winner += 1
                elif s == "loser": loser  += 1
            if "LastEvaluatedKey" not in resp:
                break
            scan_kw["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        total = winner + loser
        return json.dumps({
            "total": total, "winner": winner, "loser": loser,
            "win_rate": f"{winner/total*100:.1f}%" if total else "0%"
        }, ensure_ascii=False)
    except Exception as e:
        return f"DynamoDB 오류: {e}"

@tool
def detect_bot_patterns() -> str:
    """DynamoDB request_id 패턴으로 봇 트래픽을 탐지합니다."""
    try:
        ddb   = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = ddb.Table(DDB_TABLE)
        items = []
        scan_kw: dict = {
            "ProjectionExpression": "request_id, #s, claimed_at",
            "ExpressionAttributeNames": {"#s": "status"}
        }
        while True:
            resp = table.scan(**scan_kw)
            items.extend(resp.get("Items", []))
            if "LastEvaluatedKey" not in resp:
                break
            scan_kw["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        total       = len(items)
        bot_pattern = re.compile(r"^(user_\d+_\d+|VU_\d+|vu\d+|test_?\d+)$", re.IGNORECASE)
        bots        = [i for i in items if bot_pattern.match(str(i.get("request_id", "")))]
        bot_rate    = len(bots) / total * 100 if total else 0
        return json.dumps({
            "total_participants": total,
            "suspected_bots":    len(bots),
            "bot_rate":          f"{bot_rate:.1f}%",
            "bot_nicknames":     [b["request_id"] for b in bots[:20]],
            "판정":              "봇 트래픽 의심" if bot_rate > 20 else "정상 트래픽"
        }, ensure_ascii=False)
    except Exception as e:
        return f"봇 탐지 오류: {e}"

@tool
def get_participation_timeline() -> str:
    """시간대별 응모 참여 추이를 분석합니다."""
    from collections import Counter
    try:
        ddb   = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = ddb.Table(DDB_TABLE)
        items = []
        scan_kw: dict = {
            "ProjectionExpression": "claimed_at, #s",
            "ExpressionAttributeNames": {"#s": "status"}
        }
        while True:
            resp = table.scan(**scan_kw)
            items.extend(resp.get("Items", []))
            if "LastEvaluatedKey" not in resp:
                break
            scan_kw["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        hour_counter: Counter = Counter()
        for item in items:
            ts = str(item.get("claimed_at", ""))
            if len(ts) >= 13:
                hour_counter[ts[11:13] + ":00"] += 1
        timeline  = dict(sorted(hour_counter.items()))
        peak_hour = max(timeline, key=timeline.get) if timeline else "없음"
        return json.dumps({
            "total": len(items), "timeline": timeline,
            "peak_hour": peak_hour, "peak_count": timeline.get(peak_hour, 0)
        }, ensure_ascii=False)
    except Exception as e:
        return f"타임라인 분석 오류: {e}"


# ── Observe 툴 ───────────────────────────────────────────────

@tool
def calculate_cost_savings() -> str:
    """t3.medium OnDemand vs t4g.medium Graviton Spot 비용 비교를 계산합니다."""
    costs = {"t3.medium_ondemand": 0.0520, "t4g.medium_spot_avg": 0.0125}
    try:
        r = subprocess.run(["kubectl", "get", "nodes", "--no-headers"],
                           capture_output=True, text=True, timeout=5)
        node_count = len([l for l in r.stdout.strip().split("\n") if l])
    except Exception:
        node_count = 2
    monthly_hours = 24 * 30
    current = costs["t3.medium_ondemand"]  * node_count * monthly_hours
    target  = costs["t4g.medium_spot_avg"] * node_count * monthly_hours
    saving  = current - target
    return json.dumps({
        "current_monthly_usd":  round(current, 2),
        "graviton_monthly_usd": round(target, 2),
        "monthly_saving_usd":   round(saving, 2),
        "saving_rate":          f"{saving/current*100:.1f}%"
    }, ensure_ascii=False)


# ── 툴 목록 ──────────────────────────────────────────────────

EKS_TOOLS     = [get_all_pods, get_nodes, get_node_resources, get_pod_resources,
                 get_pending_pods, get_hpa, get_karpenter_status, get_events,
                 describe_pod, get_pod_logs, get_sqs_depth, send_slack_message]

DB_TOOLS      = [get_dynamodb_stats, detect_bot_patterns,
                 get_participation_timeline, send_slack_message]

OBSERVE_TOOLS = [get_node_resources, get_pod_resources,
                 calculate_cost_savings, send_slack_message]


# ── 아키텍처 컨텍스트 ────────────────────────────────────────

ARCH_CONTEXT = """
## Y2KS 클러스터 아키텍처
- 사용자 요청 → Frontend(2개, ondemand) → SQS → Worker(1~50개, Spot) → DynamoDB
- Redis: 티켓 카운터 원자적 감소 (ondemand-1 고정, 절대 Spot 불가)
- KEDA: SQS 깊이 기준 Worker 자동 스케일링 (큐 10개당 Worker 1개)
- Karpenter: Spot 노드 자동 프로비저닝 (CPU < 8코어, 전체 상한 20코어)

## 노드 구성
- ondemand-1 (t3.medium, 2코어/4GB): Redis, Frontend-1, Worker, Prometheus
- ondemand-2 (t3.medium, 2코어/4GB): Frontend-2, Cart, Product, Payment, Grafana
- Spot 노드 (Karpenter): Worker 전용, 부하 시 자동 생성/삭제

## 파드 우선순위 (PriorityClass)
- Redis(100000) > Frontend(10000) > Worker(1000) > Cart/Payment/Product(100)

## CPU requests
- Worker: 500m / Cart: 400m / Product: 400m / Payment: 300m / Frontend: 200m / Redis: 100m

## 장애 연관관계
- ondemand CPU 포화 → y2ks-low 파드(Cart/Product/Payment) Pending
- Karpenter 20코어 초과 → 신규 Spot 노드 생성 불가 → Worker Pending
- Redis 장애 → 티켓 카운터 불능 → 전체 쿠폰 처리 중단
- SQS 급증 → KEDA 스케일아웃 → Karpenter 노드 생성 1~2분 지연
"""

# ── Swarm 시스템 프롬프트 ─────────────────────────────────────

EKS_SWARM_PROMPT = """당신은 EKS Agent — Y2KS 클러스터 운영 전문가입니다.
담당 영역: kubectl + KEDA + Karpenter + SQS
""" + ARCH_CONTEXT + """
## 도구 선택 전략
- Pending 파드 → get_pending_pods → describe_pod(Events 확인) 순서
- 전체 진단 → get_all_pods → get_node_resources 순서
- 2~3개 툴만 선택, 불필요한 중복 호출 금지

## 판단 기준
- Running 아닌 파드 → Critical, Events까지 반드시 확인
- Pending → 노드 CPU 여유 계산 후 근본원인 파악
- SQS 큐 100건 이상 → Worker 스케일 부족
- Karpenter CPU 18코어 이상 → 한계 근접 경고

## 핸드오프 기준 (Sherlock 스타일)
- 파드 이상 + 데이터 정합성 의심 → DB Agent에게 핸드오프
- 파드 이상 + 리소스 한계 의심 → Observe Agent에게 핸드오프
- 분석이 충분하면 직접 결론 내릴 것

## 응답 형식
### 조사 대상
### 발견 사항
- **근본 원인**: (수치 포함)
- **심각도**: Critical / Warning / Info
- **신뢰도**: High(90%+) / Medium(70%+) / Low(50%+)
### 즉시 조치
### 단기 권고
### 추가 조사 필요 여부 (핸드오프 대상 명시)

규칙: 한국어, 수치 기반"""

DB_SWARM_PROMPT = """당신은 DB Agent — Y2KS 데이터/쿠폰 전문가입니다.
담당 영역: DynamoDB + 봇 탐지 + 참여 분석
""" + ARCH_CONTEXT + """
## 도구 선택 전략
- 봇 의심 → detect_bot_patterns 먼저
- 통계 확인 → get_dynamodb_stats
- 시간대 분석 → get_participation_timeline
- 2~3개만 선택

## 판단 기준
- 봇 비율 20% 초과 → 이벤트 중단 검토
- 단시간 참여 급증 (정상 대비 3배) → 봇 공격 의심
- winner + loser 불일치 → Redis 카운터 오류 가능성

## 핸드오프 기준
- DB 정상인데 파드 이상 의심 → EKS Agent에게 핸드오프
- 리소스 병목 의심 → Observe Agent에게 핸드오프
- 분석이 충분하면 직접 결론 내릴 것

## 응답 형식
### 조사 대상
### 발견 사항
- **근본 원인**: (수치 포함)
- **심각도**: Critical / Warning / Info
- **신뢰도**: High(90%+) / Medium(70%+) / Low(50%+)
### 즉시 조치
### 단기 권고
### 추가 조사 필요 여부

규칙: 한국어, 수치 기반"""

OBSERVE_SWARM_PROMPT = """당신은 Observe Agent — Y2KS 메트릭/비용 전문가입니다.
담당 영역: 노드/파드 리소스 + 비용 최적화
""" + ARCH_CONTEXT + """
## 도구 선택 전략
- 리소스 진단 → get_node_resources + get_pod_resources
- 비용 분석 → calculate_cost_savings
- 2~3개만 선택

## 판단 기준
- 노드 CPU 80% 초과 → 즉시 스케일 아웃 권고
- 노드 메모리 85% 초과 → OOM 위험
- Spot 노드 CPU 합계 18코어 이상 → Karpenter 한계 근접
- Graviton 전환 시 20%+ 절감 → 마이그레이션 권고

## 핸드오프 기준
- 리소스 정상인데 파드 이상 → EKS Agent에게 핸드오프
- 데이터 처리량 이상 → DB Agent에게 핸드오프
- 분석이 충분하면 직접 결론 내릴 것

## 응답 형식
### 조사 대상
### 발견 사항
- **근본 원인**: (수치 포함)
- **심각도**: Critical / Warning / Info
- **신뢰도**: High(90%+) / Medium(70%+) / Low(50%+)
### 즉시 조치
### 단기 권고
### 추가 조사 필요 여부

규칙: 한국어, 수치와 % 기반, 비용은 USD"""

ORCHESTRATOR_PROMPT = """당신은 Y2KS 운영팀 팀장입니다. (Claude Sonnet 4.6)
전문가들의 Swarm 분석을 종합하여 최종 판단을 내립니다.
""" + ARCH_CONTEXT + """
## 분석 방법
1. 교차 분석: 여러 전문가 이상 보고 시 인과관계 파악
2. 신뢰도 가중: High 신뢰도 발견사항 우선 반영
3. 우선순위:
   1순위: 서비스 중단 → 즉각 조치
   2순위: 데이터 정합성 이상 → 이벤트 중단
   3순위: Pending 파드 → 5분 내 해소
   4순위: 봇 트래픽 20% 초과 → 이벤트 중단 검토
   5순위: CPU/메모리 70% 초과 → 스케일 아웃 권고

## 출력 형식
**근본 원인**: (인과관계 포함, 수치 필수)
**현재 상황**: (각 전문가 발견사항 교차 분석)
**즉시 조치**: (구체적 kubectl 명령어 포함)
**단기 권고**: (예방 조치 + 모니터링 기준)
**신뢰도**: High/Medium/Low + 이유

규칙: 항상 한국어, 근거 수치 필수"""

ROUTER_PROMPT = """당신은 Y2KS 멀티에이전트 라우터입니다.
사용자 질문을 읽고 필요한 전문가를 JSON 배열로만 반환하세요.

## 전문가 담당 영역

### eks (EKS 인프라 전문가)
담당: 파드 상태/개수, 노드 목록, KEDA ScaledObject, Karpenter NodePool/NodeClaim,
     SQS 큐 깊이, Worker 스케일링, 파드 로그, 이벤트, Pending/CrashLoop/OOMKilled,
     클러스터 장애, 배포 상태, HPA, 네임스페이스

### db (데이터/이벤트 전문가)
담당: DynamoDB 데이터 조회, 당첨자/낙첨자 수, 쿠폰 현황, 응모 참여자,
     봇 트래픽 탐지, request_id 패턴 분석, 시간대별 참여 추이,
     winner/loser 통계, 이벤트 결과 데이터, DB에 저장된 내용

### observe (리소스/비용 전문가)
담당: 노드별 CPU 사용률, 메모리 사용률, 파드별 리소스 사용량,
     Graviton 전환 비용 절감, OnDemand vs Spot 비용 비교,
     리소스 병목, 성능 모니터링, 비용 최적화

## 라우팅 규칙
- JSON 배열만 반환 (다른 텍스트 절대 금지)
- 질문에 여러 영역이 섞이면 반드시 모두 포함
- 전체 진단/복합 장애/시스템 전체 → ["eks","db","observe"]

## 판단 예시

단일 영역:
- "파드 몇 개야" → ["eks"]
- "Pending 파드 원인이 뭐야" → ["eks"]
- "Worker 몇 개 떠있어" → ["eks"]
- "KEDA 스케일링 상태" → ["eks"]
- "Karpenter 노드 현황" → ["eks"]
- "파드 로그 보여줘" → ["eks"]
- "당첨자 몇 명이야" → ["db"]
- "낙첨자 수 알려줘" → ["db"]
- "DB에 뭐 담겨있어" → ["db"]
- "봇 트래픽 탐지해줘" → ["db"]
- "응모 참여자 현황" → ["db"]
- "쿠폰 이벤트 결과" → ["db"]
- "CPU 사용률 알려줘" → ["observe"]
- "메모리 상태 점검" → ["observe"]
- "비용 얼마야" → ["observe"]
- "Graviton 전환하면 얼마 절약돼" → ["observe"]
- "노드 리소스 현황" → ["observe"]

복합 영역:
- "파드 몇 개고 CPU 상태는" → ["eks","observe"]
- "파드 상태랑 DB 내용도 알려줘" → ["eks","db"]
- "CPU 상태랑 당첨자 현황" → ["observe","db"]
- "온디맨드 스팟 파드 몇 개고 CPU 상태랑 DB에 뭐 담겼는지" → ["eks","observe","db"]
- "Worker 스케일링이랑 비용도 궁금해" → ["eks","observe"]
- "봇 트래픽이랑 파드 상태 같이 봐줘" → ["eks","db"]
- "클러스터 전체 진단해줘" → ["eks","db","observe"]
- "지금 장애야 전부 다 봐줘" → ["eks","db","observe"]
- "이벤트 결과랑 리소스 상태" → ["db","observe"]"""


def _clean(text: str) -> str:
    text = re.sub(r'<thinking>.*?</thinking>', '', text, flags=re.DOTALL).strip()
    text = re.sub(r'<response>(.*?)</response>', r'\1', text, flags=re.DOTALL).strip()
    return text.replace('\\n', '\n')


def _route(question: str) -> list:
    try:
        router = Agent(model=ORCHESTRATOR_MODEL, system_prompt=ROUTER_PROMPT, tools=[])
        result = _clean(str(router(question)))
        match  = re.search(r'\[.*?\]', result, re.DOTALL)
        if match:
            agents = json.loads(match.group())
            valid  = [a for a in agents if a in ("eks", "db", "observe")]
            if valid:
                return valid
    except Exception:
        pass
    return ["eks"]


def run_agent(user_message: str) -> dict:
    """질문 라우팅 후 단일 or Swarm 실행"""
    routes = _route(user_message)

    SPECS = {
        "eks":     ("EKS Agent",     EKS_SWARM_PROMPT,     EKS_TOOLS),
        "db":      ("DB Agent",      DB_SWARM_PROMPT,      DB_TOOLS),
        "observe": ("Observe Agent", OBSERVE_SWARM_PROMPT, OBSERVE_TOOLS),
    }

    # 단일 전문가: Swarm 없이 직접 처리 (빠름)
    if len(routes) == 1:
        key, (label, prompt, tools) = routes[0], SPECS[routes[0]]
        print(f"\n[{label}] 단독 분석 중...")
        agent = Agent(model=SPECIALIST_MODEL, system_prompt=prompt, tools=tools, name=key)
        result = _clean(str(agent(user_message)))
        return {key: result, "final": result}

    # 복수 전문가: Swarm 패턴 (전문가끼리 핸드오프)
    print(f"\n[Swarm] {', '.join(routes)} 협력 분석 중...")
    agents = []
    for key in routes:
        label, prompt, tools = SPECS[key]
        agents.append(Agent(
            model=SPECIALIST_MODEL,
            system_prompt=prompt,
            tools=tools,
            name=key
        ))

    current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S KST")
    enhanced_query = f"현재 시각: {current_time}\n\n질문: {user_message}"

    swarm  = Swarm(agents, max_handoffs=6)
    result = asyncio.run(swarm.invoke_async(enhanced_query))

    opinions = {}
    for name, node_result in result.results.items():
        content = getattr(node_result.result, 'content', str(node_result.result))
        if isinstance(content, list):
            content = " ".join(c.get("text", "") if isinstance(c, dict) else str(c) for c in content)
        opinions[name] = _clean(str(content))

    # 팀장 종합 (Claude Sonnet)
    if opinions:
        expert_summary = "\n\n".join(f"[{k}]\n{v[:2000]}" for k, v in opinions.items())
        orch = Agent(model=ORCHESTRATOR_MODEL, system_prompt=ORCHESTRATOR_PROMPT, tools=[])
        orch_input = (
            f"사용자 질문: {user_message}\n\n"
            f"전문가 Swarm 분석 결과:\n{expert_summary}\n\n"
            "교차 분석 후 근본 원인 중심 최종 판단해주세요."
        )
        print("\n[팀장 - Claude Sonnet] 최종 판단 중...")
        opinions["final"] = _clean(str(orch(orch_input)))

    return opinions


def auto_diagnosis() -> str:
    """전체 자동 진단 - Swarm으로 3전문가 협력"""
    print("\n[전체 자동 진단] Swarm 시작...")

    agents = [
        Agent(model=SPECIALIST_MODEL, system_prompt=EKS_SWARM_PROMPT,
              tools=EKS_TOOLS, name="eks"),
        Agent(model=SPECIALIST_MODEL, system_prompt=DB_SWARM_PROMPT,
              tools=DB_TOOLS, name="db"),
        Agent(model=SPECIALIST_MODEL, system_prompt=OBSERVE_SWARM_PROMPT,
              tools=OBSERVE_TOOLS, name="observe"),
    ]

    current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S KST")
    query = (
        f"현재 시각: {current_time}\n\n"
        "Y2KS 클러스터 전체 자동 진단을 수행하세요.\n"
        "EKS 상태, DynamoDB 이벤트 결과, 리소스 비용 분석을 종합하여 "
        "현재 이상 징후와 개선 방안을 제시하세요."
    )

    swarm  = Swarm(agents, max_handoffs=6)
    result = asyncio.run(swarm.invoke_async(query))

    opinions = {}
    for name, node_result in result.results.items():
        content = getattr(node_result.result, 'content', str(node_result.result))
        if isinstance(content, list):
            content = " ".join(c.get("text", "") if isinstance(c, dict) else str(c) for c in content)
        opinions[name] = _clean(str(content))

    # 팀장 종합
    expert_summary = "\n\n".join(f"[{k}]\n{v[:2000]}" for k, v in opinions.items())
    orch       = Agent(model=ORCHESTRATOR_MODEL, system_prompt=ORCHESTRATOR_PROMPT, tools=[])
    orch_input = f"전체 자동 진단 Swarm 결과:\n\n{expert_summary}\n\n교차 분석 후 근본 원인 중심 종합 판단"
    print("\n[팀장 - Claude Sonnet] 종합 판단 중...")
    opinions["final"] = _clean(str(orch(orch_input)))

    label_map   = {"eks": "EKS Agent", "db": "DB Agent",
                   "observe": "Observe Agent", "final": "팀장 종합 판단"}
    lines       = [f"## {label_map.get(k, k)}\n\n{v}" for k, v in opinions.items()]
    full_report = "\n\n---\n\n".join(lines)

    report_path = os.path.join(os.path.dirname(__file__), "final_report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("# Y2KS EKS 자동 진단 보고서\n\n")
        f.write(f"생성 시각: {datetime.now(timezone.utc).isoformat()}\n\n---\n\n")
        f.write(full_report)
    print("\nfinal_report.md 저장 완료")
    return full_report


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--auto":
        auto_diagnosis()

    elif len(sys.argv) > 2 and sys.argv[1] == "--query":
        q      = sys.argv[2]
        result = run_agent(q)
        print("__RESULT__" + json.dumps(result, ensure_ascii=False))

    else:
        while True:
            try:
                q = input("\n질문: ").strip()
                if not q or q.lower() == "exit":
                    break
                result = run_agent(q)
                for k, v in result.items():
                    print(f"\n{'='*40}\n[{k.upper()}]\n{v}")
            except KeyboardInterrupt:
                break
