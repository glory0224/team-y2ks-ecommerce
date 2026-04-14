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
from mcp.server.fastmcp import FastMCP

AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
DDB_TABLE  = os.environ.get("DDB_TABLE",  "y2ks-coupon-claims")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")

mcp = FastMCP("eks-expert")

# ── kubectl helpers ───────────────────────

def _kubectl(*args) -> str:
    try:
        r = subprocess.run(
            ["kubectl", *args],
            capture_output=True, text=True, timeout=15
        )
        return r.stdout or r.stderr or "(출력 없음)"
    except Exception as e:
        return f"오류: {e}"

# ── MCP Tools ────────────────────────────

@mcp.tool()
def get_all_pods() -> str:
    """전체 네임스페이스의 파드 목록과 상태를 조회합니다."""
    return _kubectl("get", "pods", "-A", "-o", "wide")

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

if __name__ == "__main__":
    mcp.run(transport="stdio")
