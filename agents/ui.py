"""
Y2KS EKS 전문가 에이전트 모니터링 UI
Streamlit 기반

실행:
    streamlit run agents/ui.py
"""

import os
import re
import time
import json
import boto3
import urllib.request
import subprocess
import pandas as pd
import streamlit as st
from datetime import datetime, timezone

AWS_REGION       = os.environ.get("AWS_REGION", "ap-northeast-2")
DDB_TABLE        = os.environ.get("DDB_TABLE",  "y2ks-coupon-claims")
SLACK_WEBHOOK    = os.environ.get("SLACK_WEBHOOK_URL", "")
HISTORY_MAX      = 30  # 최대 보관 데이터 포인트 수

# ── Slack 알림 ────────────────────────────────────────────────
def send_slack(message: str, level: str = "warning") -> bool:
    if not SLACK_WEBHOOK:
        return False
    color = {"critical": "#e53e3e", "warning": "#d97706", "ok": "#22c55e", "info": "#3b82f6"}.get(level, "#94a3b8")
    payload = {
        "attachments": [{
            "color": color,
            "text": message,
            "footer": "Y2KS EKS Console",
            "ts": int(time.time()),
        }]
    }
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(SLACK_WEBHOOK, data=data, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5)
        return True
    except Exception:
        return False


def send_cluster_report_to_slack(running: int, pending: int, nodes: int,
                                  winner: int, loser: int, node_res: list):
    """현재 클러스터 상태 요약을 Slack으로 전송"""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    status = "정상" if pending == 0 else f"⚠️ Pending {pending}개"
    node_lines = "\n".join(
        f"  • {n['Node']}: CPU {n['CPU%']}% / Mem {n['Mem%']}%"
        for n in node_res
    ) if node_res else "  • 데이터 없음"

    message = (
        f"*Y2KS EKS 클러스터 상태 보고* — {now}\n\n"
        f"*클러스터 상태*: {status}\n"
        f"*노드 수*: {nodes}개\n"
        f"*Running 파드*: {running}개\n"
        f"*Pending 파드*: {pending}개\n\n"
        f"*노드 리소스*:\n{node_lines}\n\n"
        f"*이벤트 현황*: 당첨 {winner}명 / 낙첨 {loser}명"
    )
    level = "critical" if pending > 0 else "ok"
    return send_slack(message, level)


def get_spot_node_count():
    try:
        r = subprocess.run(
            ["kubectl", "get", "nodeclaims", "--no-headers"],
            capture_output=True, text=True, timeout=5
        )
        lines = [l for l in r.stdout.strip().split("\n") if l and "No resources" not in l]
        return len(lines)
    except:
        return 0

def get_preempted_pods():
    """선점(Preempted)된 파드 탐지 — 이벤트에서 Preempting 확인"""
    try:
        r = subprocess.run(
            ["kubectl", "get", "events", "-A", "--no-headers",
             "--field-selector=reason=Preempting"],
            capture_output=True, text=True, timeout=5
        )
        lines = [l for l in r.stdout.strip().split("\n") if l]
        return lines
    except:
        return []


def check_and_alert(pending: int, node_res: list):
    """이상 감지 시 Slack 자동 알림 (세션당 중복 방지)"""
    if "alerted" not in st.session_state:
        st.session_state["alerted"] = set()
    if "prev_spot_count" not in st.session_state:
        st.session_state["prev_spot_count"] = 0

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    # Pending 파드 (개수 무관하게 1회만 알림)
    if pending > 0:
        if "pending" not in st.session_state["alerted"]:
            send_slack(f"*[CRITICAL] Pending 파드 감지*\n`{pending}`개 Pending — 즉시 확인 필요\n시각: {now}", "critical")
            st.session_state["alerted"].add("pending")
    else:
        if "pending" in st.session_state["alerted"]:
            send_slack(f"*[OK] Pending 파드 해소*\n모든 파드 Running 상태 복구\n시각: {now}", "ok")
            st.session_state["alerted"].discard("pending")

    # CPU 60% 초과 (임계값 낮춤)
    for node in node_res:
        if node["CPU%"] >= 60:
            key = f"cpu_{node['Node']}"
            if key not in st.session_state["alerted"]:
                send_slack(
                    f"*[WARNING] 노드 CPU 높음*\n`{node['Node']}` CPU `{node['CPU%']}%`\n시각: {now}",
                    "warning"
                )
                st.session_state["alerted"].add(key)
        else:
            st.session_state["alerted"].discard(f"cpu_{node['Node']}")

    # 메모리 70% 초과 (임계값 낮춤)
    for node in node_res:
        if node["Mem%"] >= 70:
            key = f"mem_{node['Node']}"
            if key not in st.session_state["alerted"]:
                send_slack(
                    f"*[WARNING] 노드 메모리 높음*\n`{node['Node']}` Memory `{node['Mem%']}%`\n시각: {now}",
                    "warning"
                )
                st.session_state["alerted"].add(key)
        else:
            st.session_state["alerted"].discard(f"mem_{node['Node']}")

    # Spot 노드 생성/삭제 알림
    curr_spot = get_spot_node_count()
    prev_spot = st.session_state["prev_spot_count"]
    if curr_spot > prev_spot:
        diff = curr_spot - prev_spot
        send_slack(
            f"*[INFO] Karpenter Spot 노드 생성*\n"
            f"`{diff}`개 추가 → 현재 총 `{curr_spot}`개\n"
            f"트래픽 증가로 Worker 스케일 아웃 중\n시각: {now}",
            "info"
        )
    elif curr_spot < prev_spot:
        diff = prev_spot - curr_spot
        send_slack(
            f"*[INFO] Karpenter Spot 노드 반납*\n"
            f"`{diff}`개 삭제 → 현재 총 `{curr_spot}`개\n"
            f"트래픽 감소로 노드 통합 완료\n시각: {now}",
            "ok"
        )
    st.session_state["prev_spot_count"] = curr_spot

    # Worker 선점(Preemption) 알림
    preempted = get_preempted_pods()
    if preempted:
        key = f"preempt_{len(preempted)}"
        if key not in st.session_state["alerted"]:
            send_slack(
                f"*[WARNING] 파드 선점 발생*\n"
                f"Worker(y2ks-normal)가 우선순위 낮은 파드를 밀어내고 온디맨드 노드에 배치됨\n"
                f"선점 이벤트 `{len(preempted)}`건\n시각: {now}",
                "warning"
            )
            st.session_state["alerted"].add(key)
    else:
        # 선점 해소 시 이전 키 제거
        prev_keys = [k for k in st.session_state["alerted"] if k.startswith("preempt_")]
        for k in prev_keys:
            st.session_state["alerted"].discard(k)

st.set_page_config(
    page_title="Y2KS EKS Console",
    page_icon=None,
    layout="wide",
    initial_sidebar_state="expanded"
)


st.markdown("""
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600&display=swap');

html, body, [class*="css"] {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
}

[data-testid="stAppViewContainer"] {
    background: #f8fafc;
}

[data-testid="stSidebar"] {
    background: #0f172a;
    border-right: none;
}

[data-testid="stSidebar"] * {
    color: #94a3b8;
}

[data-testid="stHeader"] {
    background: transparent;
    border-bottom: 1px solid #e2e8f0;
}

[data-testid="metric-container"] {
    background: #ffffff;
    border: 1px solid #e2e8f0;
    border-radius: 10px;
    padding: 20px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
}
[data-testid="stMetricValue"] {
    color: #0f172a !important;
    font-size: 1.8rem !important;
    font-weight: 600 !important;
    letter-spacing: -0.02em;
}
[data-testid="stMetricLabel"] {
    color: #64748b !important;
    font-size: 0.72rem !important;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    font-weight: 500;
}

[data-testid="stChatMessage"] {
    background: #ffffff;
    border: 1px solid #e2e8f0;
    border-radius: 10px;
    margin-bottom: 6px;
    box-shadow: 0 1px 2px rgba(0,0,0,0.03);
}

[data-testid="stChatInputContainer"] {
    border: 1px solid #e2e8f0;
    border-radius: 10px;
    background: #ffffff;
}

[data-testid="baseButton-secondary"] {
    background: #ffffff !important;
    border: 1px solid #e2e8f0 !important;
    color: #475569 !important;
    border-radius: 7px !important;
    font-size: 0.8rem !important;
    font-weight: 400 !important;
    transition: all 0.15s ease;
}
[data-testid="baseButton-secondary"]:hover {
    border-color: #94a3b8 !important;
    color: #0f172a !important;
    background: #f8fafc !important;
}

[data-testid="baseButton-primary"] {
    background: #0f172a !important;
    border: none !important;
    color: #f8fafc !important;
    border-radius: 7px !important;
    font-size: 0.85rem !important;
    font-weight: 500 !important;
}
[data-testid="baseButton-primary"]:hover {
    background: #1e293b !important;
}

hr {
    border-color: #e2e8f0 !important;
    margin: 24px 0 !important;
}

[data-testid="stExpander"] {
    background: #ffffff;
    border: 1px solid #e2e8f0 !important;
    border-radius: 10px;
    box-shadow: 0 1px 2px rgba(0,0,0,0.03);
}

h1, h2, h3 {
    color: #0f172a !important;
    font-weight: 600 !important;
    letter-spacing: -0.02em;
}

[data-testid="stSidebar"] [data-testid="baseButton-secondary"] {
    background: rgba(255,255,255,0.05) !important;
    border: 1px solid rgba(255,255,255,0.1) !important;
    color: #94a3b8 !important;
    text-align: left;
}
[data-testid="stSidebar"] [data-testid="baseButton-secondary"]:hover {
    background: rgba(255,255,255,0.1) !important;
    color: #f1f5f9 !important;
    border-color: rgba(255,255,255,0.2) !important;
}

.banner {
    background: #ffffff;
    border: 1px solid #e2e8f0;
    border-radius: 10px;
    padding: 14px 20px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 20px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
}
.banner-status-ok   { color: #16a34a; font-weight: 600; font-size: 0.9rem; }
.banner-status-warn { color: #d97706; font-weight: 600; font-size: 0.9rem; }
.banner-dot-ok      { width:8px;height:8px;border-radius:50%;background:#22c55e;display:inline-block;margin-right:8px; }
.banner-dot-warn    { width:8px;height:8px;border-radius:50%;background:#f59e0b;display:inline-block;margin-right:8px; }

.chat-empty {
    text-align: center;
    color: #94a3b8;
    padding: 48px 0;
    font-size: 0.88rem;
    font-weight: 400;
}

.section-title {
    font-size: 1rem;
    font-weight: 600;
    color: #0f172a;
    margin-bottom: 4px;
}
.section-sub {
    font-size: 0.8rem;
    color: #94a3b8;
    margin-bottom: 16px;
}
</style>
""", unsafe_allow_html=True)


# ── 사이드바 ────────────────────────────────────────────────
with st.sidebar:
    st.markdown(
        "<div style='padding:24px 0 8px'>"
        "<div style='color:#f1f5f9;font-size:1rem;font-weight:600;letter-spacing:-0.01em'>Y2KS Console</div>"
        "<div style='color:#475569;font-size:0.75rem;margin-top:2px'>EKS Operations</div>"
        "</div>",
        unsafe_allow_html=True,
    )
    st.markdown("<hr style='border-color:rgba(255,255,255,0.08);margin:12px 0'>", unsafe_allow_html=True)

    st.markdown(
        "<div style='font-size:0.7rem;color:#475569;text-transform:uppercase;letter-spacing:.1em;margin-bottom:8px'>Cluster</div>",
        unsafe_allow_html=True,
    )
    st.markdown(
        "<div style='color:#e2e8f0;font-size:0.82rem;font-family:monospace;margin-bottom:16px'>y2ks-eks-cluster</div>",
        unsafe_allow_html=True,
    )

    st.markdown(
        "<div style='font-size:0.7rem;color:#475569;text-transform:uppercase;letter-spacing:.1em;margin-bottom:8px'>Region / Model</div>",
        unsafe_allow_html=True,
    )
    st.markdown(
        f"<div style='color:#64748b;font-size:0.78rem;font-family:monospace;line-height:1.8'>{AWS_REGION}<br>nova-micro-v1:0</div>",
        unsafe_allow_html=True,
    )

    st.markdown("<hr style='border-color:rgba(255,255,255,0.08);margin:16px 0'>", unsafe_allow_html=True)

    st.markdown(
        "<div style='font-size:0.7rem;color:#475569;text-transform:uppercase;letter-spacing:.1em;margin-bottom:10px'>Quick Actions</div>",
        unsafe_allow_html=True,
    )

    scenario_1 = st.button("Cluster overview", width="stretch")
    scenario_2 = st.button("Pending pod analysis", width="stretch")
    scenario_3 = st.button("DynamoDB / SQS status", width="stretch")
    scenario_4 = st.button("Worker pod logs", width="stretch")
    scenario_5 = st.button("Graviton cost report", width="stretch")

    st.markdown("<hr style='border-color:rgba(255,255,255,0.08);margin:16px 0'>", unsafe_allow_html=True)

    if st.button("Refresh metrics", width="stretch"):
        st.cache_data.clear()
        st.rerun()

    st.markdown("<hr style='border-color:rgba(255,255,255,0.08);margin:16px 0'>", unsafe_allow_html=True)

    st.markdown(
        "<div style='font-size:0.7rem;color:#475569;text-transform:uppercase;letter-spacing:.1em;margin-bottom:10px'>Slack</div>",
        unsafe_allow_html=True,
    )

    slack_report_btn = st.button("Send cluster report", width="stretch")
    slack_test_btn   = st.button("Send test ping", width="stretch")

    if SLACK_WEBHOOK:
        st.markdown(
            "<div style='font-size:0.68rem;color:#22c55e;margin-top:6px'>Webhook connected</div>",
            unsafe_allow_html=True,
        )
    else:
        st.markdown(
            "<div style='font-size:0.68rem;color:#ef4444;margin-top:6px'>Webhook not set</div>",
            unsafe_allow_html=True,
        )

    st.markdown(
        "<div style='color:#1e293b;font-size:0.7rem;margin-top:24px'>Strands Agents + MCP</div>",
        unsafe_allow_html=True,
    )


# ── 데이터 수집 함수 ─────────────────────────────────────────
@st.cache_data(ttl=10)
def get_ddb_stats():
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
        return winner, loser
    except:
        return 0, 0

@st.cache_data(ttl=10)
def get_pod_counts():
    try:
        r = subprocess.run(
            ["kubectl", "get", "pods", "-A", "--no-headers"],
            capture_output=True, text=True, timeout=5
        )
        lines = [l for l in r.stdout.strip().split("\n") if l]
        running = sum(1 for l in lines if "Running" in l)
        pending = sum(1 for l in lines if "Pending" in l)
        return running, pending
    except:
        return 0, 0

@st.cache_data(ttl=10)
def get_node_count():
    try:
        r = subprocess.run(
            ["kubectl", "get", "nodes", "--no-headers"],
            capture_output=True, text=True, timeout=5
        )
        lines = [l for l in r.stdout.strip().split("\n") if l]
        return len(lines)
    except:
        return 0

@st.cache_data(ttl=15)
def get_node_resources():
    """kubectl top nodes — 노드별 CPU/메모리 사용량"""
    try:
        r = subprocess.run(
            ["kubectl", "top", "nodes", "--no-headers"],
            capture_output=True, text=True, timeout=10
        )
        rows = []
        for line in r.stdout.strip().split("\n"):
            parts = line.split()
            if len(parts) >= 5:
                name = parts[0].split(".")[0]  # 짧게
                rows.append({
                    "Node": name,
                    "CPU(m)": int(parts[1].replace("m", "")),
                    "CPU%": int(parts[2].replace("%", "")),
                    "Mem(Mi)": int(parts[3].replace("Mi", "")),
                    "Mem%": int(parts[4].replace("%", "")),
                })
        return rows
    except:
        return []

@st.cache_data(ttl=15)
def get_pod_resources():
    """kubectl top pods — 상위 리소스 사용 파드"""
    try:
        r = subprocess.run(
            ["kubectl", "top", "pods", "-A", "--no-headers"],
            capture_output=True, text=True, timeout=10
        )
        rows = []
        for line in r.stdout.strip().split("\n"):
            parts = line.split()
            if len(parts) >= 4:
                cpu = int(parts[2].replace("m", "")) if "m" in parts[2] else int(parts[2]) * 1000
                mem = int(parts[3].replace("Mi", "")) if "Mi" in parts[3] else 0
                rows.append({
                    "Namespace": parts[0],
                    "Pod": parts[1],
                    "CPU(m)": cpu,
                    "Mem(Mi)": mem,
                })
        return sorted(rows, key=lambda x: x["CPU(m)"], reverse=True)
    except:
        return []

@st.cache_data(ttl=15)
def get_keda_replicas():
    """KEDA HPA 현재 replica 수"""
    try:
        r = subprocess.run(
            ["kubectl", "get", "hpa", "-A", "--no-headers"],
            capture_output=True, text=True, timeout=5
        )
        for line in r.stdout.strip().split("\n"):
            parts = line.split()
            if len(parts) >= 7:
                return int(parts[6])  # REPLICAS 컬럼
        return 0
    except:
        return 0

@st.cache_data(ttl=15)
def get_spot_nodes():
    """Karpenter Spot 노드 수"""
    try:
        r = subprocess.run(
            ["kubectl", "get", "nodeclaims", "--no-headers"],
            capture_output=True, text=True, timeout=5
        )
        lines = [l for l in r.stdout.strip().split("\n") if l and "No resources" not in l]
        return len(lines)
    except:
        return 0


# ── 히스토리 데이터 수집 ─────────────────────────────────────
def collect_history():
    now = datetime.now(timezone.utc).strftime("%H:%M:%S")
    running, pending = get_pod_counts()
    nodes = get_node_count()
    replicas = get_keda_replicas()
    spot = get_spot_nodes()
    node_res = get_node_resources()

    avg_cpu = sum(n["CPU%"] for n in node_res) / len(node_res) if node_res else 0
    avg_mem = sum(n["Mem%"] for n in node_res) / len(node_res) if node_res else 0

    point = {
        "time": now,
        "running_pods": running,
        "pending_pods": pending,
        "nodes": nodes,
        "worker_replicas": replicas,
        "spot_nodes": spot,
        "avg_cpu_pct": round(avg_cpu, 1),
        "avg_mem_pct": round(avg_mem, 1),
    }

    if "history" not in st.session_state:
        st.session_state["history"] = []

    # 마지막 수집과 5초 이상 차이날 때만 추가 (중복 방지)
    hist = st.session_state["history"]
    if not hist or hist[-1]["time"] != now:
        hist.append(point)
        if len(hist) > HISTORY_MAX:
            hist.pop(0)

collect_history()

winner, loser = get_ddb_stats()
running, pending = get_pod_counts()
nodes = get_node_count()
now_str = datetime.now(timezone.utc).strftime("%Y-%m-%d  %H:%M UTC")

# 알림 체크
_node_res_for_alert = get_node_resources()
check_and_alert(pending, _node_res_for_alert)

# Slack 버튼 처리
if slack_report_btn:
    ok = send_cluster_report_to_slack(
        running, pending, nodes, winner, loser, _node_res_for_alert
    )
    if ok:
        st.sidebar.success("Slack 전송 완료")
    else:
        st.sidebar.error("전송 실패 — Webhook URL 확인")

if slack_test_btn:
    now_ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    ok = send_slack(f"*[TEST] Y2KS EKS Console 연결 확인*\n시각: {now_ts}", "info")
    if ok:
        st.sidebar.success("Slack 테스트 전송 완료")
    else:
        st.sidebar.error("전송 실패 — Webhook URL 확인")

is_warn = isinstance(pending, int) and pending > 0
status_label = f"Degraded  —  {pending} pods pending" if is_warn else "Operational"
dot_class    = "banner-dot-warn" if is_warn else "banner-dot-ok"
text_class   = "banner-status-warn" if is_warn else "banner-status-ok"


# ── 헤더 ────────────────────────────────────────────────────
st.markdown(
    "<div style='padding:8px 0 4px'>"
    "<div style='font-size:1.4rem;font-weight:600;color:#0f172a;letter-spacing:-0.02em'>EKS Operations Console</div>"
    "<div style='font-size:0.82rem;color:#94a3b8;margin-top:2px'>Real-time cluster monitoring with AI-powered diagnostics</div>"
    "</div>",
    unsafe_allow_html=True,
)
st.markdown("---")

# 상태 배너
st.markdown(
    f"<div class='banner'>"
    f"<div style='display:flex;align-items:center'>"
    f"<span class='{dot_class}'></span>"
    f"<span class='{text_class}'>{status_label}</span>"
    f"</div>"
    f"<div style='color:#94a3b8;font-size:0.78rem'>{now_str}</div>"
    f"</div>",
    unsafe_allow_html=True,
)

# 상단 메트릭
m1, m2, m3, m4, m5 = st.columns(5)
m1.metric("Winners", f"{winner}")
m2.metric("Losers", f"{loser}")
m3.metric("Nodes", f"{nodes}")
m4.metric("Running pods", f"{running}")
m5.metric(
    "Pending pods", f"{pending}",
    delta=f"+{pending}" if isinstance(pending, int) and pending > 0 else None,
    delta_color="inverse",
)

st.markdown("---")


# ── 실시간 모니터링 ──────────────────────────────────────────
st.markdown(
    "<div class='section-title'>Real-time Monitoring</div>"
    "<div class='section-sub'>Cluster resource usage and scaling trends (updated every 30s)</div>",
    unsafe_allow_html=True,
)

hist = st.session_state.get("history", [])

if len(hist) >= 2:
    df = pd.DataFrame(hist)

    col_left, col_right = st.columns(2)

    with col_left:
        st.markdown("**Node CPU / Memory Usage (%)**")
        st.line_chart(
            df.set_index("time")[["avg_cpu_pct", "avg_mem_pct"]],
            color=["#3b82f6", "#f59e0b"],
        )

    with col_right:
        st.markdown("**Pod Count Trend**")
        st.line_chart(
            df.set_index("time")[["running_pods", "pending_pods"]],
            color=["#22c55e", "#ef4444"],
        )

    col_left2, col_right2 = st.columns(2)

    with col_left2:
        st.markdown("**Worker Replicas (KEDA)**")
        st.line_chart(
            df.set_index("time")[["worker_replicas"]],
            color=["#8b5cf6"],
        )

    with col_right2:
        st.markdown("**Spot Nodes (Karpenter)**")
        st.line_chart(
            df.set_index("time")[["spot_nodes"]],
            color=["#06b6d4"],
        )
else:
    st.info("Collecting data — charts will appear after 2+ data points (auto-refreshes every 30s)")

st.markdown("---")


# ── 노드 / 파드 리소스 현황 ──────────────────────────────────
st.markdown(
    "<div class='section-title'>Resource Usage</div>"
    "<div class='section-sub'>Current CPU and memory per node and top pods</div>",
    unsafe_allow_html=True,
)

col_node, col_pod = st.columns(2)

with col_node:
    st.markdown("**Node Resources**")
    node_res = get_node_resources()
    if node_res:
        df_node = pd.DataFrame(node_res)
        st.dataframe(df_node, width="stretch", hide_index=True)
        st.bar_chart(df_node.set_index("Node")[["CPU%", "Mem%"]])
    else:
        st.caption("metrics-server 데이터 없음")

with col_pod:
    st.markdown("**Top Pods by CPU**")
    pod_res = get_pod_resources()
    if pod_res:
        df_pod = pd.DataFrame(pod_res[:10])
        st.dataframe(df_pod, width="stretch", hide_index=True)
    else:
        st.caption("metrics-server 데이터 없음")

st.markdown("---")


# ── 채팅 ────────────────────────────────────────────────────
st.markdown(
    "<div class='section-title'>AI Assistant</div>"
    "<div class='section-sub'>Ask anything about cluster health, incident analysis, or cost optimization</div>",
    unsafe_allow_html=True,
)

SIDEBAR_MESSAGES = {
    "scenario_1": "현재 EKS 클러스터 전체 상태를 진단해줘. 파드, 노드, Pending 상황, KEDA 스케일 상태를 모두 확인하고 문제점을 알려줘.",
    "scenario_2": "Pending 파드가 있으면 원인을 분석하고 해결 방법을 제시해줘.",
    "scenario_3": "DynamoDB 이벤트 결과와 SQS 큐 상태를 확인해서 지금 이벤트가 정상적으로 처리되고 있는지 알려줘.",
    "scenario_4": "Worker 파드 로그에서 에러가 있는지 확인해줘.",
    "scenario_5": "Graviton(ARM64) Spot 노드로 전환 시 예상 비용 절감 규모와 현재 Karpenter 상태를 알려줘.",
}

if "messages" not in st.session_state:
    st.session_state["messages"] = []

for key, msg in SIDEBAR_MESSAGES.items():
    if locals().get(key):
        st.session_state["messages"].append({"role": "user", "content": msg})

if not st.session_state["messages"]:
    st.markdown(
        "<div class='chat-empty'>No messages yet.<br>Use quick actions on the left or type a question below.</div>",
        unsafe_allow_html=True,
    )

for msg in st.session_state["messages"]:
    with st.chat_message(msg["role"]):
        st.write(msg["content"])

user_input = st.chat_input("Ask about pods, nodes, logs, costs...")
if user_input:
    st.session_state["messages"].append({"role": "user", "content": user_input})
    with st.chat_message("user"):
        st.write(user_input)

    with st.chat_message("assistant"):
        with st.spinner("Routing to specialist agents..."):
            try:
                from eks_agent import run_agent, _route
                routes = _route(user_input)
                label_map = {"eks": "EKS Agent", "db": "DB Agent", "observe": "Observe Agent"}
                specialists = " + ".join(label_map[r] for r in routes)
                st.caption(f"Specialists: {specialists} → 팀장 종합")

                result = run_agent(user_input)

                # 전문가 의견 펼치기
                expert_labels = {"eks": "EKS Agent", "db": "DB Agent", "observe": "Observe Agent"}
                for key, label in expert_labels.items():
                    if key in result:
                        with st.expander(f"{label} 의견"):
                            st.markdown(result[key])

                # 팀장 최종 판단은 메인에 표시
                final = result.get("final", "")
                st.markdown("---")
                st.markdown("**팀장 최종 판단**")
                st.markdown(final)
                response = final

            except Exception as e:
                response = (
                    f"Agent error\n\n```\n{e}\n```\n\n"
                    "Check that the EKS cluster is running and kubeconfig is configured."
                )
                st.write(response)

        st.session_state["messages"].append({"role": "assistant", "content": response})

col_clear, _ = st.columns([1, 5])
with col_clear:
    if st.button("Clear conversation"):
        st.session_state["messages"] = []
        st.rerun()

st.markdown("---")


# ── 자동 진단 ───────────────────────────────────────────────
st.markdown(
    "<div class='section-title'>Full Cluster Diagnosis</div>"
    "<div class='section-sub'>Runs a complete cluster inspection and saves the report to final_report.md (approx. 1-2 min)</div>",
    unsafe_allow_html=True,
)

if st.button("Run diagnosis", type="primary"):
    with st.spinner("Running full cluster diagnosis..."):
        try:
            from eks_agent import auto_diagnosis
            auto_diagnosis()
            st.success("Diagnosis complete — report saved to final_report.md")
        except Exception as e:
            st.error(f"Error: {e}")

_report_path = os.path.join(os.path.dirname(__file__), "final_report.md")
if os.path.exists(_report_path):
    with st.expander("View latest report"):
        with open(_report_path, "r", encoding="utf-8") as f:
            st.markdown(f.read())
