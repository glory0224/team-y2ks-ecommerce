"""
Y2KS 멀티 에이전트 시스템 (MCP 없이 @tool 직접 사용)

에이전트 구성:
- EKS Agent    : kubectl + KEDA + SQS
- DB Agent     : DynamoDB + 봇 탐지
- Observe Agent: 리소스 + 비용 분석
- Orchestrator : 교차 분석 후 최종 판단
"""

import os
import re
import json
import subprocess
import boto3
import time
import urllib.request

# .env 로드
try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
except ImportError:
    pass

from strands import Agent, tool
from strands.models.bedrock import BedrockModel

AWS_REGION    = os.environ.get("AWS_REGION", "ap-northeast-2")
DDB_TABLE     = os.environ.get("DDB_TABLE", "y2ks-coupon-claims")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
SLACK_WEBHOOK = os.environ.get("SLACK_WEBHOOK_URL", "")

MODEL = BedrockModel(
    model_id="apac.amazon.nova-micro-v1:0",
    region_name=AWS_REGION,
)

MAX_OUT = 3000

def _kubectl(*args) -> str:
    try:
        r = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=15)
        out = r.stdout or r.stderr or "(출력 없음)"
        return out[:MAX_OUT] + f"\n...(잘림)" if len(out) > MAX_OUT else out
    except Exception as e:
        return f"오류: {e}"


# ── EKS 툴 ───────────────────────────────────────────────────

@tool
def get_all_pods() -> str:
    """전체 네임스페이스의 파드 목록과 상태를 조회합니다."""
    output = _kubectl("get", "pods", "-A", "-o", "wide")
    lines = [l for l in output.strip().split("\n") if l]
    total = len(lines) - 1 if lines else 0
    running = sum(1 for l in lines if "Running" in l)
    pending = sum(1 for l in lines if "Pending" in l)
    return output + f"\n\n[요약] 전체: {total}개, Running: {running}개, Pending: {pending}개"

@tool
def get_nodes() -> str:
    """노드 목록과 상태를 조회합니다."""
    return _kubectl("get", "nodes", "-o", "wide", "--show-labels")

@tool
def get_node_resources() -> str:
    """노드별 CPU/메모리 사용량을 조회합니다."""
    return _kubectl("top", "nodes")

@tool
def get_pod_resources() -> str:
    """파드별 CPU/메모리 사용량을 조회합니다."""
    return _kubectl("top", "pods", "-A")

@tool
def get_pending_pods() -> str:
    """Pending 상태인 파드를 조회합니다."""
    return _kubectl("get", "pods", "-A", "--field-selector=status.phase=Pending", "-o", "wide")

@tool
def get_hpa() -> str:
    """KEDA HPA 스케일 상태를 조회합니다."""
    return _kubectl("get", "hpa", "-A")

@tool
def get_karpenter_status() -> str:
    """Karpenter NodePool, NodeClaim 상태를 조회합니다."""
    nodepool = _kubectl("get", "nodepool", "-o", "wide")
    nodeclaim = _kubectl("get", "nodeclaim", "-o", "wide")
    return f"[NodePool]\n{nodepool}\n\n[NodeClaim]\n{nodeclaim}"

@tool
def get_events() -> str:
    """클러스터 전체 이벤트를 조회합니다."""
    return _kubectl("get", "events", "-A", "--sort-by=.lastTimestamp")

@tool
def describe_pod(namespace: str, pod_name: str) -> str:
    """특정 파드의 상세 정보를 조회합니다."""
    return _kubectl("describe", "pod", "-n", namespace, pod_name)

@tool
def get_pod_logs(namespace: str, pod_name: str, lines: int = 50) -> str:
    """특정 파드의 최근 로그를 조회합니다."""
    return _kubectl("logs", "-n", namespace, pod_name, f"--tail={lines}")

@tool
def get_sqs_depth() -> str:
    """SQS 큐 대기 메시지 수를 조회합니다."""
    try:
        if not SQS_QUEUE_URL:
            return "SQS_QUEUE_URL 환경변수가 설정되지 않았습니다."
        sqs = boto3.client("sqs", region_name=AWS_REGION)
        resp = sqs.get_queue_attributes(
            QueueUrl=SQS_QUEUE_URL,
            AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
        )
        attrs = resp["Attributes"]
        return json.dumps({"waiting": attrs.get("ApproximateNumberOfMessages", 0),
                           "in_flight": attrs.get("ApproximateNumberOfMessagesNotVisible", 0)})
    except Exception as e:
        return f"SQS 오류: {e}"


# ── DB 툴 ────────────────────────────────────────────────────

@tool
def get_dynamodb_stats() -> str:
    """DynamoDB에서 당첨자/낙첨자 수를 조회합니다."""
    try:
        ddb = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = ddb.Table(DDB_TABLE)
        winner = loser = 0
        scan_kw: dict = {"ProjectionExpression": "#s", "ExpressionAttributeNames": {"#s": "status"}}
        while True:
            resp = table.scan(**scan_kw)
            for item in resp.get("Items", []):
                s = item.get("status")
                if s == "winner": winner += 1
                elif s == "loser": loser += 1
            if "LastEvaluatedKey" not in resp:
                break
            scan_kw["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        total = winner + loser
        return json.dumps({"total": total, "winner": winner, "loser": loser,
                           "win_rate": f"{winner/total*100:.1f}%" if total else "0%"}, ensure_ascii=False)
    except Exception as e:
        return f"DynamoDB 오류: {e}"

@tool
def detect_bot_patterns() -> str:
    """DynamoDB 닉네임 패턴으로 봇을 탐지합니다."""
    import re as _re
    try:
        ddb = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = ddb.Table(DDB_TABLE)
        items = []
        scan_kw: dict = {"ProjectionExpression": "request_id, #s, claimed_at",
                         "ExpressionAttributeNames": {"#s": "status"}}
        while True:
            resp = table.scan(**scan_kw)
            items.extend(resp.get("Items", []))
            if "LastEvaluatedKey" not in resp:
                break
            scan_kw["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        total = len(items)
        bot_pattern = _re.compile(r"^(user_\d+_\d+|VU_\d+|vu\d+|test_?\d+)$", _re.IGNORECASE)
        bots = [i for i in items if bot_pattern.match(str(i.get("request_id", "")))]
        bot_rate = len(bots) / total * 100 if total else 0
        return json.dumps({"total_participants": total, "suspected_bots": len(bots),
                           "bot_rate": f"{bot_rate:.1f}%",
                           "bot_nicknames": [b["request_id"] for b in bots[:20]],
                           "판정": "봇 트래픽 의심" if bot_rate > 20 else "정상 트래픽"}, ensure_ascii=False)
    except Exception as e:
        return f"봇 탐지 오류: {e}"

@tool
def get_participation_timeline() -> str:
    """시간대별 응모 참여 추이를 분석합니다."""
    from collections import Counter
    try:
        ddb = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = ddb.Table(DDB_TABLE)
        items = []
        scan_kw: dict = {"ProjectionExpression": "claimed_at, #s",
                         "ExpressionAttributeNames": {"#s": "status"}}
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
        timeline = dict(sorted(hour_counter.items()))
        peak_hour = max(timeline, key=timeline.get) if timeline else "없음"
        return json.dumps({"total": len(items), "timeline": timeline,
                           "peak_hour": peak_hour, "peak_count": timeline.get(peak_hour, 0)}, ensure_ascii=False)
    except Exception as e:
        return f"타임라인 분석 오류: {e}"


# ── Observe 툴 ───────────────────────────────────────────────

@tool
def calculate_cost_savings() -> str:
    """t3.medium OnDemand vs t4g.medium Spot 비용 비교를 계산합니다."""
    costs = {"t3.medium_ondemand": 0.0520, "t4g.medium_spot_avg": 0.0125}
    try:
        r = subprocess.run(["kubectl", "get", "nodes", "--no-headers"],
                           capture_output=True, text=True, timeout=5)
        node_count = len([l for l in r.stdout.strip().split("\n") if l])
    except Exception:
        node_count = 2
    monthly_hours = 24 * 30
    current = costs["t3.medium_ondemand"] * node_count * monthly_hours
    target = costs["t4g.medium_spot_avg"] * node_count * monthly_hours
    saving = current - target
    return json.dumps({"current_monthly_usd": round(current, 2),
                       "graviton_monthly_usd": round(target, 2),
                       "monthly_saving_usd": round(saving, 2),
                       "saving_rate": f"{saving/current*100:.1f}%"}, ensure_ascii=False)


# ── Slack 툴 ─────────────────────────────────────────────────

@tool
def send_slack_message(message: str, level: str = "info") -> str:
    """Slack 채널에 메시지를 전송합니다. level: info / warning / critical / ok"""
    if not SLACK_WEBHOOK:
        return "SLACK_WEBHOOK_URL 환경변수가 설정되지 않았습니다."
    color = {"critical": "#e53e3e", "warning": "#d97706", "ok": "#22c55e", "info": "#3b82f6"}.get(level, "#94a3b8")
    payload = {"attachments": [{"color": color, "text": message,
                                "footer": "Y2KS EKS Agent", "ts": int(time.time())}]}
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(SLACK_WEBHOOK, data=data, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5)
        return f"Slack 전송 완료"
    except Exception as e:
        return f"Slack 전송 실패: {e}"


# ── 툴 목록 ──────────────────────────────────────────────────

EKS_TOOLS     = [get_all_pods, get_nodes, get_node_resources, get_pod_resources,
                 get_pending_pods, get_hpa, get_karpenter_status, get_events,
                 describe_pod, get_pod_logs, get_sqs_depth, send_slack_message]

DB_TOOLS      = [get_dynamodb_stats, detect_bot_patterns, get_participation_timeline,
                 send_slack_message]

OBSERVE_TOOLS = [get_node_resources, get_pod_resources, calculate_cost_savings,
                 send_slack_message]


# ── 시스템 프롬프트 ───────────────────────────────────────────

EKS_PROMPT = """당신은 EKS Agent — Y2KS 클러스터 운영 전문가입니다.
담당 영역: kubectl + KEDA + SQS
판단 기준:
- Running 아닌 파드 존재 → 즉시 장애 (Critical)
- Pending 파드 존재 → 노드 자원 부족 또는 스케줄링 문제
- SQS 큐 100건 이상 적체 → Worker 스케일 부족
- KEDA 복제본이 maxReplicas 도달 → Karpenter 확장 필요
응답: 한국어, 수치 기반, 심각도 명시 (Critical/Warning/Info)"""

DB_PROMPT = """당신은 DB Agent — Y2KS 데이터 관리 전문가입니다.
담당 영역: DynamoDB + 봇 탐지
판단 기준:
- 봇 패턴 닉네임 비율 20% 초과 → 이벤트 중단 검토
- 단시간 참여 급증 (정상 대비 3배 이상) → 봇 공격 의심
- winner + loser 합계 이상 → 데이터 정합성 오류
응답: 한국어, 수치 기반"""

OBSERVE_PROMPT = """당신은 Observe Agent — Y2KS 메트릭/성능 전문가입니다.
담당 영역: 노드 리소스 + 비용 최적화
판단 기준:
- 노드 CPU 80% 초과 → 즉시 스케일 아웃 권고
- 노드 메모리 85% 초과 → OOM 위험
- Graviton 전환 시 20%+ 절감 → 마이그레이션 권고
응답: 한국어, 수치와 % 기반, 비용은 USD로"""

ORCHESTRATOR_PROMPT = """당신은 Y2KS 운영팀 팀장입니다.
세 전문가(EKS/DB/Observe) 의견을 교차 분석하여 최종 판단을 내립니다.

1단계: 교차 분석 — 여러 전문가가 동시에 이상 보고 시 인과관계 파악
2단계: 우선순위 판단
  1. 서비스 중단 → 즉각 조치
  2. 데이터 정합성 이상 → 이벤트 중단
  3. Pending 파드 → 5분 내 해소
  4. 봇 트래픽 20% 초과 → 이벤트 중단 검토
  5. CPU/메모리 70% 초과 → 스케일 아웃 권고

출력 형식:
**근본 원인**: ...
**현재 상황**: ...
**즉시 조치**: ...
**단기 권고**: ...

규칙: 근거 수치 반드시 포함, 항상 한국어"""

ROUTER_PROMPT = """당신은 Y2KS 멀티에이전트 시스템의 라우터입니다.
사용자 질문을 읽고 필요한 전문가를 JSON 배열로만 반환하세요.
- eks: 파드/노드/KEDA/SQS/클러스터/로그
- db: 당첨자/낙첨자/봇/응모/DynamoDB
- observe: CPU/메모리/비용/Graviton/성능
규칙: JSON 배열만 반환, 전체 진단이면 ["eks","db","observe"]"""


def _clean(text: str) -> str:
    text = re.sub(r'<thinking>.*?</thinking>', '', text, flags=re.DOTALL).strip()
    text = re.sub(r'<response>(.*?)</response>', r'\1', text, flags=re.DOTALL).strip()
    return text.replace('\\n', '\n')


def _route(question: str) -> list:
    try:
        router = Agent(model=MODEL, system_prompt=ROUTER_PROMPT, tools=[])
        result = _clean(str(router(question)))
        import json as _json, re as _re
        match = _re.search(r'\[.*?\]', result, _re.DOTALL)
        if match:
            agents = _json.loads(match.group())
            valid = [a for a in agents if a in ("eks", "db", "observe")]
            if valid:
                return valid
    except Exception:
        pass
    return ["eks"]


def run_agent(user_message: str) -> dict:
    routes = _route(user_message)
    opinions = {}

    SPECS = {
        "eks":     ("EKS Agent",     EKS_PROMPT,     EKS_TOOLS),
        "db":      ("DB Agent",      DB_PROMPT,      DB_TOOLS),
        "observe": ("Observe Agent", OBSERVE_PROMPT, OBSERVE_TOOLS),
    }

    for route in routes:
        label, prompt, tools = SPECS[route]
        agent = Agent(model=MODEL, system_prompt=prompt, tools=tools)
        print(f"\n[{label}] 분석 중...")
        opinions[route] = _clean(str(agent(user_message)))

    # 전문가 1명이면 팀장 생략
    if len(opinions) == 1:
        key = list(opinions.keys())[0]
        opinions["final"] = opinions[key]
        return opinions

    expert_summary = "\n\n".join(
        f"[{SPECS[k][0]}]\n{v[:1500]}" for k, v in opinions.items()
    )
    orch = Agent(model=MODEL, system_prompt=ORCHESTRATOR_PROMPT, tools=[])
    orch_input = (
        f"사용자 질문: {user_message}\n\n전문가 분석:\n{expert_summary}\n\n"
        "인과관계 교차 분석 후 근본 원인 중심으로 최종 판단해주세요."
    )
    print("\n[팀장] 최종 판단 중...")
    opinions["final"] = _clean(str(orch(orch_input)))
    return opinions


def auto_diagnosis() -> str:
    opinions = {}
    specs = [
        ("eks",     "EKS Agent",     EKS_PROMPT,     EKS_TOOLS,
         "EKS 클러스터 전체 진단: 파드/노드/KEDA/SQS/Karpenter 상태 확인"),
        ("db",      "DB Agent",      DB_PROMPT,      DB_TOOLS,
         "DynamoDB 이벤트 결과, 봇 트래픽, 시간대별 참여 추이 분석"),
        ("observe", "Observe Agent", OBSERVE_PROMPT, OBSERVE_TOOLS,
         "노드/파드 리소스 사용량 분석, Graviton 전환 비용 절감 계산"),
    ]
    for key, label, prompt, tools, query in specs:
        agent = Agent(model=MODEL, system_prompt=prompt, tools=tools)
        print(f"\n[{label}] 진단 중...")
        opinions[key] = _clean(str(agent(query)))

    expert_summary = "\n\n".join(f"[{specs[i][1]}]\n{opinions[specs[i][0]][:1500]}" for i in range(3))
    orch = Agent(model=MODEL, system_prompt=ORCHESTRATOR_PROMPT, tools=[])
    orch_input = f"전체 자동 진단:\n\n{expert_summary}\n\n교차 분석 후 근본 원인 중심 종합 판단"
    print("\n[팀장] 종합 판단 중...")
    opinions["final"] = _clean(str(orch(orch_input)))

    from datetime import datetime, timezone
    label_map = {"eks": "EKS Agent", "db": "DB Agent", "observe": "Observe Agent", "final": "팀장 종합 판단"}
    lines = [f"## {label_map[k]}\n\n{v}" for k, v in opinions.items()]
    full_report = "\n\n---\n\n".join(lines)

    report_path = os.path.join(os.path.dirname(__file__), "final_report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("# Y2KS EKS 자동 진단 보고서\n\n")
        f.write(f"생성 시각: {datetime.now(timezone.utc).isoformat()}\n\n---\n\n")
        f.write(full_report)
    print("\nfinal_report.md 저장 완료")
    return full_report


if __name__ == "__main__":
    import sys
    import json as _json
    if len(sys.argv) > 1 and sys.argv[1] == "--auto":
        auto_diagnosis()
    elif len(sys.argv) > 2 and sys.argv[1] == "--query":
        q = sys.argv[2]
        result = run_agent(q)
        print("__RESULT__" + _json.dumps(result, ensure_ascii=False))
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
