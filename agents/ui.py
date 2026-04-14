"""
Y2KS EKS 전문가 에이전트 모니터링 UI
Streamlit 기반

실행:
    streamlit run agents/ui.py
"""

import asyncio
import os
import boto3
import subprocess
import streamlit as st
from datetime import datetime, timezone

AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
DDB_TABLE  = os.environ.get("DDB_TABLE",  "y2ks-coupon-claims")

st.set_page_config(
    page_title="Y2KS EKS 전문가 에이전트",
    page_icon="🤖",
    layout="wide"
)

st.title("🤖 Y2KS EKS 전문가 에이전트")
st.caption("Llama3 70B (Bedrock) + MCP (kubectl / DynamoDB / SQS)")

# ── 실시간 메트릭 ──────────────────────────

st.subheader("📊 실시간 현황")

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

col1, col2, col3, col4, col5 = st.columns(5)
col1.metric("당첨자", f"{winner}명")
col2.metric("낙첨자", f"{loser}명")
col3.metric("노드 수", f"{nodes}개")
col4.metric("Running 파드", f"{running}개")
col5.metric("Pending 파드", f"{pending}개",
            delta=f"-{pending}" if isinstance(pending, int) and pending > 0 else None,
            delta_color="inverse")

if st.button("🔄 새로고침"):
    st.cache_data.clear()
    st.rerun()

st.divider()

# ── 에이전트 챗봇 ──────────────────────────

st.subheader("💬 EKS 전문가 에이전트와 대화")

QUICK_QUESTIONS = [
    "클러스터 전체 상태 진단해줘",
    "Pending 파드 원인 분석해줘",
    "DynamoDB 이벤트 결과 확인해줘",
    "SQS 큐 상태 확인해줘",
    "Worker 파드 로그 확인해줘",
    "Graviton 전환 비용 절감 알려줘",
]

cols = st.columns(3)
for i, q in enumerate(QUICK_QUESTIONS):
    if cols[i % 3].button(q, key=f"q{i}"):
        st.session_state.setdefault("messages", [])
        st.session_state["messages"].append({"role": "user", "content": q})

# 채팅 히스토리
if "messages" not in st.session_state:
    st.session_state["messages"] = []

for msg in st.session_state["messages"]:
    with st.chat_message(msg["role"]):
        st.write(msg["content"])

# 사용자 입력
user_input = st.chat_input("EKS 상태에 대해 질문하세요...")
if user_input:
    st.session_state["messages"].append({"role": "user", "content": user_input})
    with st.chat_message("user"):
        st.write(user_input)

    with st.chat_message("assistant"):
        with st.spinner("에이전트 분석 중..."):
            try:
                from eks_agent import run_agent
                result = asyncio.run(run_agent(user_input))
                response = str(result)
            except Exception as e:
                response = f"⚠️ 에이전트 오류: {e}\n\nEKS 클러스터가 실행 중인지, Bedrock Llama3 모델이 활성화됐는지 확인하세요."

        st.write(response)
        st.session_state["messages"].append({"role": "assistant", "content": response})

st.divider()

# ── 자동 진단 ──────────────────────────────

st.subheader("🚀 자동 전체 진단")

if st.button("전체 진단 실행 → final_report.md 저장", type="primary"):
    with st.spinner("EKS 전체 진단 중... (1~2분 소요)"):
        try:
            from eks_agent import auto_diagnosis
            asyncio.run(auto_diagnosis())
            st.success("✅ 진단 완료!")
        except Exception as e:
            st.error(f"오류: {e}")

if os.path.exists("agents/final_report.md"):
    with st.expander("📄 최근 진단 보고서"):
        with open("agents/final_report.md", "r", encoding="utf-8") as f:
            st.markdown(f.read())
