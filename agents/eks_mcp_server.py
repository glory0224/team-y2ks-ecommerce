"""
Y2KS EKS MCP 서버
kubectl 명령을 MCP Tool로 노출합니다.

실행:
    python agents/eks_mcp_server.py
"""

import subprocess
import json
import boto3
import os
import time
import urllib.request
from mcp.server.fastmcp import FastMCP

# .env 로드
try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
except ImportError:
    pass

AWS_REGION    = os.environ.get("AWS_REGION", "ap-northeast-2")
SLACK_WEBHOOK = os.environ.get("SLACK_WEBHOOK_URL", "")
DDB_TABLE  = os.environ.get("DDB_TABLE",  "y2ks-coupon-claims")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")

mcp = FastMCP("eks-expert")

# ── kubectl helpers ───────────────────────

MAX_OUTPUT = 3000  # 툴 출력 최대 글자 수

def _kubectl(*args) -> str:
    try:
        r = subprocess.run(
            ["kubectl", *args],
            capture_output=True, text=True, timeout=15
        )
        out = r.stdout or r.stderr or "(출력 없음)"
        if len(out) > MAX_OUTPUT:
            out = out[:MAX_OUTPUT] + f"\n...(출력 길이 초과로 잘림, 총 {len(out)}자)"
        return out
    except Exception as e:
        return f"오류: {e}"

# ── MCP Tools ────────────────────────────

@mcp.tool()
def get_all_pods() -> str:
    """전체 네임스페이스의 파드 목록과 상태를 조회합니다. 마지막 줄에 총 개수를 포함합니다."""
    output = _kubectl("get", "pods", "-A", "-o", "wide")
    lines = [l for l in output.strip().split("\n") if l]
    total = len(lines) - 1 if lines else 0  # 헤더 제외
    running = sum(1 for l in lines if "Running" in l)
    pending = sum(1 for l in lines if "Pending" in l)
    return output + f"\n\n[요약] 전체: {total}개, Running: {running}개, Pending: {pending}개"

@mcp.tool()
def get_nodes() -> str:
    """노드 목록과 상태, Spot/OnDemand 구분을 조회합니다."""
    return _kubectl("get", "nodes", "-o", "wide", "--show-labels")

@mcp.tool()
def get_node_resources() -> str:
    """노드별 CPU/메모리 사용량을 조회합니다."""
    return _kubectl("top", "nodes")

@mcp.tool()
def get_pod_resources() -> str:
    """파드별 CPU/메모리 사용량을 조회합니다."""
    return _kubectl("top", "pods", "-A")

@mcp.tool()
def get_pending_pods() -> str:
    """Pending 상태인 파드와 원인을 조회합니다."""
    return _kubectl("get", "pods", "-A", "--field-selector=status.phase=Pending", "-o", "wide")

@mcp.tool()
def get_hpa() -> str:
    """KEDA HPA 스케일 상태를 조회합니다."""
    return _kubectl("get", "hpa", "-A")

@mcp.tool()
def get_karpenter_nodeclaims() -> str:
    """Karpenter가 생성한 NodeClaim 목록을 조회합니다."""
    return _kubectl("get", "nodeclaims", "-A")

@mcp.tool()
def describe_pod(namespace: str, pod_name: str) -> str:
    """특정 파드의 상세 정보와 이벤트를 조회합니다."""
    return _kubectl("describe", "pod", "-n", namespace, pod_name)

@mcp.tool()
def get_pod_logs(namespace: str, pod_name: str, lines: int = 50) -> str:
    """특정 파드의 최근 로그를 조회합니다."""
    return _kubectl("logs", "-n", namespace, pod_name, f"--tail={lines}")

@mcp.tool()
def restart_deployment(namespace: str, deployment: str) -> str:
    """[위험] 특정 Deployment를 재시작합니다. 실제 운영에 영향을 줍니다."""
    return _kubectl("rollout", "restart", f"deployment/{deployment}", "-n", namespace)

@mcp.tool()
def get_events() -> str:
    """클러스터 전체 이벤트(경고 포함)를 조회합니다."""
    return _kubectl("get", "events", "-A", "--sort-by=.lastTimestamp")

@mcp.tool()
def get_dynamodb_stats() -> str:
    """DynamoDB에서 당첨자/낙첨자 수를 조회합니다."""
    try:
        ddb = boto3.resource("dynamodb", region_name=AWS_REGION)
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
                if s == "winner": winner += 1
                elif s == "loser": loser += 1
            if "LastEvaluatedKey" not in resp:
                break
            scan_kw["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        total = winner + loser
        return json.dumps({
            "total": total,
            "winner": winner,
            "loser": loser,
            "win_rate": f"{winner/total*100:.1f}%" if total else "0%"
        }, ensure_ascii=False)
    except Exception as e:
        return f"DynamoDB 오류: {e}"

@mcp.tool()
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
        return json.dumps({
            "waiting": attrs.get("ApproximateNumberOfMessages", 0),
            "in_flight": attrs.get("ApproximateNumberOfMessagesNotVisible", 0)
        })
    except Exception as e:
        return f"SQS 오류: {e}"

# ── DataSherlock Tools ───────────────────────────────────────

@mcp.tool()
def detect_bot_patterns() -> str:
    """DynamoDB 닉네임 패턴을 분석하여 봇 참여자를 탐지합니다."""
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

        return json.dumps({
            "total_participants": total,
            "suspected_bots": len(bots),
            "bot_rate": f"{bot_rate:.1f}%",
            "bot_nicknames": [b["request_id"] for b in bots[:20]],
            "판정": "봇 트래픽 의심" if bot_rate > 20 else "정상 트래픽"
        }, ensure_ascii=False)
    except Exception as e:
        return f"봇 탐지 오류: {e}"

@mcp.tool()
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
        return json.dumps({
            "total": len(items),
            "timeline": timeline,
            "peak_hour": peak_hour,
            "peak_count": timeline.get(peak_hour, 0)
        }, ensure_ascii=False)
    except Exception as e:
        return f"타임라인 분석 오류: {e}"


# ── DevOpsGuru Tools ─────────────────────────────────────────

@mcp.tool()
def get_prometheus_metrics() -> str:
    """Prometheus에서 주요 메트릭(CPU, 메모리, 요청 수)을 조회합니다."""
    import urllib.request as _req
    PROM_URL = "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
    queries = {
        "node_cpu_avg": 'avg(100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100))',
        "node_mem_avg": 'avg((1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100)',
        "http_requests_total": 'sum(rate(flask_http_request_total[5m]))',
    }
    results = {}
    for name, query in queries.items():
        try:
            url = f"{PROM_URL}/api/v1/query?query={urllib.parse.quote(query)}"
            with _req.urlopen(url, timeout=5) as r:
                data = json.loads(r.read())
                val = data["data"]["result"]
                results[name] = round(float(val[0]["value"][1]), 2) if val else "no data"
        except Exception as ex:
            results[name] = f"error: {ex}"
    return json.dumps(results, ensure_ascii=False)

@mcp.tool()
def calculate_cost_savings() -> str:
    """현재 온디맨드 비용 vs Graviton Spot 전환 시 예상 절감액을 계산합니다."""
    # ap-northeast-2 기준 시간당 비용 (USD)
    costs = {
        "t3.medium_ondemand":  0.0520,
        "t4g.medium_ondemand": 0.0416,
        "t3.medium_spot_avg":  0.0156,  # ~70% 할인
        "t4g.medium_spot_avg": 0.0125,  # ~70% 할인
    }
    try:
        r = subprocess.run(["kubectl", "get", "nodes", "--no-headers"],
                           capture_output=True, text=True, timeout=5)
        node_count = len([l for l in r.stdout.strip().split("\n") if l])
    except Exception:
        node_count = 2

    monthly_hours = 24 * 30
    current_monthly = costs["t3.medium_ondemand"] * node_count * monthly_hours
    graviton_monthly = costs["t4g.medium_spot_avg"] * node_count * monthly_hours
    saving = current_monthly - graviton_monthly

    return json.dumps({
        "current_setup": f"t3.medium OnDemand x{node_count}",
        "target_setup": f"t4g.medium Spot x{node_count}",
        "current_monthly_usd": round(current_monthly, 2),
        "graviton_monthly_usd": round(graviton_monthly, 2),
        "monthly_saving_usd": round(saving, 2),
        "saving_rate": f"{saving/current_monthly*100:.1f}%",
        "migration_steps": [
            "1. Dockerfile.frontend/worker에 --platform=linux/arm64 추가",
            "2. Karpenter NodePool에 arm64 arch 추가",
            "3. GitHub Actions에 ARM64 멀티 플랫폼 빌드 확인",
            "4. ECR에 ARM64 이미지 푸시 후 롤링 배포"
        ]
    }, ensure_ascii=False)

@mcp.tool()
def get_karpenter_status() -> str:
    """Karpenter NodePool, NodeClaim 전체 상태를 조회합니다."""
    nodepool = _kubectl("get", "nodepool", "-o", "wide")
    nodeclaim = _kubectl("get", "nodeclaim", "-o", "wide")
    return f"[NodePool]\n{nodepool}\n\n[NodeClaim]\n{nodeclaim}"


# ── Slack Tools ──────────────────────────────────────────────

@mcp.tool()
def send_slack_message(message: str, level: str = "info") -> str:
    """Slack 채널에 메시지를 전송합니다. level: info / warning / critical / ok"""
    if not SLACK_WEBHOOK:
        return "오류: SLACK_WEBHOOK_URL 환경변수가 설정되지 않았습니다."
    color = {
        "critical": "#e53e3e",
        "warning":  "#d97706",
        "ok":       "#22c55e",
        "info":     "#3b82f6",
    }.get(level, "#94a3b8")
    payload = {
        "attachments": [{
            "color": color,
            "text": message,
            "footer": "Y2KS EKS Agent",
            "ts": int(time.time()),
        }]
    }
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            SLACK_WEBHOOK, data=data,
            headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=5)
        return f"Slack 전송 완료: {message[:80]}"
    except Exception as e:
        return f"Slack 전송 실패: {e}"


@mcp.tool()
def send_slack_alert(title: str, body: str, level: str = "warning") -> str:
    """Slack에 제목+본문 형식의 알림을 전송합니다."""
    message = f"*{title}*\n{body}"
    return send_slack_message(message, level)


if __name__ == "__main__":
    mcp.run(transport="stdio")
