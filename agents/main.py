"""
Y2KS 멀티 에이전트 자율 운영 시스템
AWS Strands Agents SDK 기반

설치:
    pip install strands-agents strands-agents-tools boto3 prometheus-api-client

실행:
    python main.py
"""

import boto3
import json
import os
import subprocess
from datetime import datetime, timezone
from strands import Agent, tool
from strands.models.bedrock import BedrockModel

# ──────────────────────────────────────────
# 설정
# ──────────────────────────────────────────
AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
DDB_TABLE = os.environ.get("DDB_TABLE", "y2ks-coupon-claims")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")

MODEL = BedrockModel(
    model_id="apac.anthropic.claude-sonnet-4-20250514-v1:0",
    region_name=AWS_REGION,
)

# ──────────────────────────────────────────
# OpsCommander Tools (EKS 팀장)
# ──────────────────────────────────────────

@tool
def get_pod_status() -> str:
    """전체 파드 상태를 조회합니다."""
    try:
        result = subprocess.run(
            ["kubectl", "get", "pods", "-A", "-o", "wide", "--no-headers"],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout if result.stdout else "파드 정보 없음"
    except Exception as e:
        return f"오류: {e}"

@tool
def get_node_status() -> str:
    """노드 CPU/메모리 사용량을 조회합니다."""
    try:
        result = subprocess.run(
            ["kubectl", "top", "nodes"],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout if result.stdout else "노드 정보 없음"
    except Exception as e:
        return f"오류: {e}"

@tool
def get_pending_pods() -> str:
    """Pending 상태인 파드 목록과 원인을 조회합니다."""
    try:
        result = subprocess.run(
            ["kubectl", "get", "pods", "-A", "--field-selector=status.phase=Pending", "-o", "wide"],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout if result.stdout else "Pending 파드 없음"
    except Exception as e:
        return f"오류: {e}"

@tool
def get_hpa_status() -> str:
    """KEDA HPA 스케일 상태를 조회합니다."""
    try:
        result = subprocess.run(
            ["kubectl", "get", "hpa", "-A"],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout if result.stdout else "HPA 정보 없음"
    except Exception as e:
        return f"오류: {e}"

@tool
def get_karpenter_nodes() -> str:
    """Karpenter가 생성한 Spot 노드 목록을 조회합니다."""
    try:
        result = subprocess.run(
            ["kubectl", "get", "nodes", "--show-labels", "-o", "wide"],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout if result.stdout else "노드 정보 없음"
    except Exception as e:
        return f"오류: {e}"

# ──────────────────────────────────────────
# DataSherlock Tools (데이터 분석가)
# ──────────────────────────────────────────

@tool
def query_dynamodb_stats() -> str:
    """DynamoDB에서 당첨자/낙첨자 수와 전체 참여자 수를 조회합니다."""
    try:
        ddb = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = ddb.Table(DDB_TABLE)

        winner_count = loser_count = 0
        scan_kwargs = {"ProjectionExpression": "#s", "ExpressionAttributeNames": {"#s": "status"}}

        while True:
            resp = table.scan(**scan_kwargs)
            for item in resp.get("Items", []):
                if item.get("status") == "winner":
                    winner_count += 1
                elif item.get("status") == "loser":
                    loser_count += 1
            if "LastEvaluatedKey" not in resp:
                break
            scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

        total = winner_count + loser_count
        return json.dumps({
            "total_participants": total,
            "winner_count": winner_count,
            "loser_count": loser_count,
            "win_rate": f"{(winner_count/total*100):.1f}%" if total > 0 else "0%"
        }, ensure_ascii=False)
    except Exception as e:
        return f"오류: {e}"

@tool
def detect_bot_pattern() -> str:
    """DynamoDB 닉네임 패턴을 분석하여 봇 트래픽을 탐지합니다.
    k6 부하테스트 패턴(user_VU_ITER)을 봇으로 간주합니다."""
    import re
    try:
        ddb = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = ddb.Table(DDB_TABLE)

        bot_pattern = re.compile(r"^user_\d+_\d+$")
        bot_count = normal_count = 0
        bot_examples = []

        scan_kwargs = {"ProjectionExpression": "request_id"}
        while True:
            resp = table.scan(**scan_kwargs)
            for item in resp.get("Items", []):
                nickname = item.get("request_id", "")
                if bot_pattern.match(nickname):
                    bot_count += 1
                    if len(bot_examples) < 5:
                        bot_examples.append(nickname)
                else:
                    normal_count += 1
            if "LastEvaluatedKey" not in resp:
                break
            scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

        total = bot_count + normal_count
        return json.dumps({
            "total": total,
            "bot_count": bot_count,
            "normal_count": normal_count,
            "bot_ratio": f"{(bot_count/total*100):.1f}%" if total > 0 else "0%",
            "bot_examples": bot_examples,
            "verdict": "봇 공격 의심" if bot_count > normal_count else "정상 트래픽"
        }, ensure_ascii=False)
    except Exception as e:
        return f"오류: {e}"

@tool
def get_participation_timeline() -> str:
    """시간대별 참여 추이를 분석합니다."""
    try:
        ddb = boto3.resource("dynamodb", region_name=AWS_REGION)
        table = ddb.Table(DDB_TABLE)

        timeline = {}
        scan_kwargs = {"ProjectionExpression": "claimed_at, #s", "ExpressionAttributeNames": {"#s": "status"}}

        while True:
            resp = table.scan(**scan_kwargs)
            for item in resp.get("Items", []):
                claimed_at = item.get("claimed_at", "")
                if claimed_at:
                    hour = claimed_at[:13]  # YYYY-MM-DDTHH
                    timeline[hour] = timeline.get(hour, 0) + 1
            if "LastEvaluatedKey" not in resp:
                break
            scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

        sorted_timeline = dict(sorted(timeline.items()))
        return json.dumps({"timeline": sorted_timeline}, ensure_ascii=False)
    except Exception as e:
        return f"오류: {e}"

# ──────────────────────────────────────────
# DevOpsGuru Tools (데브옵스 전문가)
# ──────────────────────────────────────────

@tool
def get_prometheus_metrics() -> str:
    """Prometheus API에서 주요 메트릭을 조회합니다."""
    try:
        import urllib.request
        queries = {
            "sqs_queue_depth": 'aws_sqs_approximate_number_of_messages_visible_average',
            "worker_replicas": 'kube_deployment_status_replicas{deployment="y2ks-worker"}',
            "frontend_rps": 'rate(flask_http_request_total[1m])',
        }
        results = {}
        for name, query in queries.items():
            url = f"{PROMETHEUS_URL}/api/v1/query?query={urllib.parse.quote(query)}"
            with urllib.request.urlopen(url, timeout=5) as resp:
                data = json.loads(resp.read())
                results[name] = data.get("data", {}).get("result", [])
        return json.dumps(results, ensure_ascii=False)
    except Exception as e:
        return f"Prometheus 연결 실패 (클러스터 미연결 상태): {e}"

# ──────────────────────────────────────────
# 에이전트 정의
# ──────────────────────────────────────────

ops_commander = Agent(
    model=MODEL,
    system_prompt="""당신은 Y2KS EKS 클러스터의 팀장 에이전트입니다.
클러스터 상태를 진단하고, 문제를 감지하면 명확한 대응 방안을 제시합니다.
결과는 항상 한국어로 작성하며, 심각도(Critical/Warning/Info)를 명시합니다.""",
    tools=[get_pod_status, get_node_status, get_pending_pods, get_hpa_status, get_karpenter_nodes],
)

data_sherlock = Agent(
    model=MODEL,
    system_prompt="""당신은 Y2KS 이벤트 데이터 분석가 에이전트입니다.
DynamoDB 데이터를 분석하여 봇 트래픽, 이상 패턴, 참여 추이를 탐지합니다.
결과는 항상 한국어로 작성하며, 수치 근거를 명확히 제시합니다.""",
    tools=[query_dynamodb_stats, detect_bot_pattern, get_participation_timeline],
)

devops_guru = Agent(
    model=MODEL,
    system_prompt="""당신은 Y2KS 데브옵스 전문가 에이전트입니다.
비용 최적화, 리소스 사용률 분석을 담당합니다.
구체적인 수치와 실행 가능한 액션 아이템을 제시합니다.""",
    tools=[get_prometheus_metrics],
)

# ──────────────────────────────────────────
# 오케스트레이터
# ──────────────────────────────────────────

def run_multi_agent_analysis():
    """세 에이전트를 순차 실행하고 결과를 final_report.md로 저장합니다."""
    print("=" * 60)
    print("Y2KS 멀티 에이전트 자율 운영 시스템 시작")
    print("=" * 60)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "agents": {}
    }

    # 1. OpsCommander 실행
    print("\n[1/3] OpsCommander: EKS 클러스터 상태 분석 중...")
    ops_result = ops_commander(
        "현재 EKS 클러스터 상태를 전체 분석해줘. "
        "파드 상태, 노드 상태, Pending 파드, HPA 상태를 확인하고 "
        "문제점과 권고사항을 정리해줘."
    )
    report["agents"]["OpsCommander"] = str(ops_result)
    print(f"OpsCommander 완료\n{ops_result}")

    # 2. DataSherlock 실행
    print("\n[2/3] DataSherlock: 이벤트 데이터 분석 중...")
    data_result = data_sherlock(
        "DynamoDB 이벤트 데이터를 분석해줘. "
        "당첨/낙첨 현황, 봇 트래픽 탐지, 시간대별 참여 추이를 분석하고 "
        "이상 패턴이 있으면 알려줘."
    )
    report["agents"]["DataSherlock"] = str(data_result)
    print(f"DataSherlock 완료\n{data_result}")

    # 3. DevOpsGuru 실행
    print("\n[3/3] DevOpsGuru: 비용 최적화 분석 중...")
    devops_result = devops_guru(
        "현재 인프라 비용 최적화 방안을 분석해줘. "
        "SQS 큐 깊이, Worker 스케일 상태, Frontend RPS를 확인하고 "
        "리소스 최적화 권고사항을 제시해줘."
    )
    report["agents"]["DevOpsGuru"] = str(devops_result)
    print(f"DevOpsGuru 완료\n{devops_result}")

    # final_report.md 저장
    save_final_report(report)
    print("\n✅ final_report.md 저장 완료")

def save_final_report(report: dict):
    """에이전트 결과를 final_report.md로 저장합니다."""
    content = f"""# Y2KS 자율 운영 시스템 최종 보고서

생성 시각: {report['generated_at']}

---

## OpsCommander 분석 결과 (EKS 팀장)

{report['agents'].get('OpsCommander', '결과 없음')}

---

## DataSherlock 분석 결과 (데이터 분석가)

{report['agents'].get('DataSherlock', '결과 없음')}

---

## DevOpsGuru 분석 결과 (데브옵스 전문가)

{report['agents'].get('DevOpsGuru', '결과 없음')}

---

## 종합 권고사항

1. **즉시 조치**: OpsCommander 결과의 Critical 항목 우선 처리
2. **단기 (1주)**: DataSherlock의 봇 탐지 결과 기반 차단 로직 구현
3. **중기 (1개월)**: DevOpsGuru의 리소스 최적화 권고사항 적용
"""
    with open("agents/final_report.md", "w", encoding="utf-8") as f:
        f.write(content)

if __name__ == "__main__":
    run_multi_agent_analysis()
