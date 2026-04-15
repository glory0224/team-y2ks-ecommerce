"""
Y2KS Slack Bot — Socket Mode
@멘션으로 에이전트에게 질문 → Slack으로 응답

실행:
    pip install slack_bolt python-dotenv
    python agents/slack_bot.py
"""

import os
import re
import sys
import json
import subprocess
import threading
from dotenv import load_dotenv
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

SLACK_BOT_TOKEN = os.environ.get("SLACK_BOT_TOKEN", "")
SLACK_APP_TOKEN = os.environ.get("SLACK_APP_TOKEN", "")

app = App(token=SLACK_BOT_TOKEN)

AGENTS_DIR = os.path.dirname(os.path.abspath(__file__))
AGENT_SCRIPT = os.path.join(AGENTS_DIR, "eks_agent.py")


def run_agent_isolated(user_text: str) -> dict:
    """subprocess로 eks_agent.py --query 호출 (asyncio 충돌 완전 방지)"""
    try:
        env = {**os.environ, "PYTHONPATH": AGENTS_DIR}
        result = subprocess.run(
            [sys.executable, AGENT_SCRIPT, "--query", user_text],
            capture_output=True, text=True, timeout=120,
            cwd=AGENTS_DIR, env=env
        )
        # __RESULT__ 마커 뒤에서 JSON 추출
        output = result.stdout
        marker = "__RESULT__"
        if marker in output:
            json_str = output[output.index(marker) + len(marker):]
            return {"ok": True, "result": json.loads(json_str)}
        return {"ok": False, "error": f"출력 파싱 실패:\n{output[-500:]}\n{result.stderr[-300:]}"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "타임아웃 (120초 초과)"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ── Slack 응답 ───────────────────────────────────────────────
def run_and_reply(client, channel: str, thread_ts: str, user_text: str):
    try:
        client.chat_postMessage(
            channel=channel,
            thread_ts=thread_ts,
            text="분석 중입니다... (30~60초 소요)"
        )

        data = run_agent_isolated(user_text)

        if not data.get("ok"):
            client.chat_postMessage(
                channel=channel,
                thread_ts=thread_ts,
                text=f"에이전트 오류: {data.get('error')}\n```{data.get('trace', '')[:400]}```"
            )
            return

        result = data["result"]
        label_map = {"eks": "EKS Agent", "db": "DB Agent", "observe": "Observe Agent"}
        final = result.get("final", "응답 없음")

        expert_lines = []
        for key, label in label_map.items():
            if key in result:
                summary = result[key][:300].replace("\n", " ")
                expert_lines.append(f"*{label}*: {summary}...")

        specialists = " + ".join(label_map[k] for k in label_map if k in result)
        reply = (
            f"*담당 전문가*: {specialists}\n\n"
            + "\n".join(expert_lines)
            + f"\n\n*팀장 최종 판단*\n{final}"
        )

        client.chat_postMessage(
            channel=channel,
            thread_ts=thread_ts,
            text=reply
        )

    except Exception as e:
        import traceback
        print(traceback.format_exc())
        client.chat_postMessage(
            channel=channel,
            thread_ts=thread_ts,
            text=f"오류: {e}"
        )


# ── 멘션 이벤트 ──────────────────────────────────────────────
@app.event("app_mention")
def handle_mention(event, client):
    channel   = event["channel"]
    thread_ts = event.get("thread_ts", event.get("ts"))
    text      = re.sub(r"<@\w+>", "", event.get("text", "")).strip()

    if not text:
        text = "현재 EKS 클러스터 전체 상태를 진단해줘"

    threading.Thread(
        target=run_and_reply,
        args=(client, channel, thread_ts, text),
        daemon=True
    ).start()


if __name__ == "__main__":
    print("Y2KS Slack Bot 시작 (Socket Mode)")
    handler = SocketModeHandler(app, SLACK_APP_TOKEN)
    handler.start()
