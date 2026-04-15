"""
Y2KS EKS 전문가 에이전트 모니터링 UI
Streamlit 기반

실행:
    streamlit run agents/ui.py
"""

import os
import boto3
import subprocess
import streamlit as st
from datetime import datetime, timezone

AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
DDB_TABLE  = os.environ.get("DDB_TABLE",  "y2ks-coupon-claims")

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

/* 메트릭 카드 */
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

/* 채팅 */
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

/* 버튼 */
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

/* 구분선 */
hr {
    border-color: #e2e8f0 !important;
    margin: 24px 0 !important;
}

/* 익스팬더 */
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

/* 사이드바 버튼 */
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

/* 상태 배너 */
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

/* 빈 채팅 안내 */
.chat-empty {
    text-align: center;
    color: #94a3b8;
    padding: 48px 0;
    font-size: 0.88rem;
    font-weight: 400;
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

    scenario_1 = st.button("Cluster overview", use_container_width=True)
    scenario_2 = st.button("Pending pod analysis", use_container_width=True)
    scenario_3 = st.button("DynamoDB / SQS status", use_container_width=True)
    scenario_4 = st.button("Worker pod logs", use_container_width=True)
    scenario_5 = st.button("Graviton cost report", use_container_width=True)

    st.markdown("<hr style='border-color:rgba(255,255,255,0.08);margin:16px 0'>", unsafe_allow_html=True)

    if st.button("Refresh metrics", use_container_width=True):
        st.cache_data.clear()
        st.rerun()

    st.markdown(
        "<div style='color:#1e293b;font-size:0.7rem;margin-top:24px'>Strands Agents + MCP</div>",
        unsafe_allow_html=True,
    )


# ── 데이터 ──────────────────────────────────────────────────
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
        return "-", "-"

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
        return "-", "-"

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
        return "-"

winner, loser = get_ddb_stats()
running, pending = get_pod_counts()
nodes = get_node_count()
now_str = datetime.now(timezone.utc).strftime("%Y-%m-%d  %H:%M UTC")

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

# 메트릭
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


# ── 채팅 ────────────────────────────────────────────────────
st.markdown(
    "<div style='font-size:1rem;font-weight:600;color:#0f172a;margin-bottom:4px'>AI Assistant</div>"
    "<div style='font-size:0.8rem;color:#94a3b8;margin-bottom:16px'>"
    "Ask anything about cluster health, incident analysis, or cost optimization</div>",
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
        with st.spinner("Analyzing..."):
            try:
                from eks_agent import run_agent
                result = run_agent(user_input)
                response = str(result)
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
    "<div style='font-size:1rem;font-weight:600;color:#0f172a;margin-bottom:4px'>Full Cluster Diagnosis</div>"
    "<div style='font-size:0.8rem;color:#94a3b8;margin-bottom:16px'>"
    "Runs a complete cluster inspection and saves the report to final_report.md (approx. 1-2 min)</div>",
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

if os.path.exists("agents/final_report.md"):
    with st.expander("View latest report"):
        with open("agents/final_report.md", "r", encoding="utf-8") as f:
            st.markdown(f.read())
