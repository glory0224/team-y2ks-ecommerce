"""
Y2KS EKS 전문가 에이전트
MCP 서버(eks_mcp_server.py)와 연동하여 실제 kubectl 명령을 실행합니다.

실행:
    python agents/eks_agent.py

모델: meta.llama3-70b-instruct-v1:0 (저렴, RAG/파인튜닝 추후 가능)
"""

import asyncio
import os
from strands import Agent
from strands.models.bedrock import BedrockModel
from strands.tools.mcp import MCPClient
from mcp import StdioServerParameters

AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")

# ── 모델 설정 (Llama3 70B - 저렴 + 파인튜닝 가능) ──
MODEL = BedrockModel(
    model_id="meta.llama3-70b-instruct-v1:0",
    region_name=AWS_REGION,
)

# ── MCP 서버 연결 설정 ──
MCP_SERVER = StdioServerParameters(
    command="python",
    args=["agents/eks_mcp_server.py"],
    env={
        "AWS_REGION": AWS_REGION,
        "DDB_TABLE": os.environ.get("DDB_TABLE", "y2ks-coupon-claims"),
        "SQS_QUEUE_URL": os.environ.get("SQS_QUEUE_URL", ""),
        **os.environ,
    }
)

SYSTEM_PROMPT = """당신은 Y2KS EKS 클러스터 전문가 에이전트입니다.

담당 역할:
- EKS 클러스터 상태 진단 및 장애 감지
- 파드/노드 리소스 분석
- KEDA 오토스케일 상태 모니터링
- Karpenter Spot 노드 프로비저닝 상태 확인
- DynamoDB 이벤트 결과 조회
- SQS 큐 상태 모니터링

응답 원칙:
- 항상 한국어로 답변
- 문제 감지 시 심각도 표시 (🔴 Critical / 🟡 Warning / 🟢 Info)
- 구체적인 수치와 함께 원인 분석
- 실행 가능한 조치 방안 제시
- restart_deployment 같은 위험한 Tool은 사용자 확인 후 실행"""


async def run_agent(user_message: str):
    """MCP 서버와 연결하여 에이전트를 실행합니다."""
    async with MCPClient(MCP_SERVER) as mcp_client:
        tools = await mcp_client.list_tools_async()

        agent = Agent(
            model=MODEL,
            system_prompt=SYSTEM_PROMPT,
            tools=tools,
        )

        print(f"\n사용자: {user_message}")
        print("-" * 50)
        result = await agent.invoke_async(user_message)
        print(f"\n에이전트:\n{result}")
        return result


async def interactive_mode():
    """대화형 모드로 에이전트를 실행합니다."""
    print("=" * 60)
    print("Y2KS EKS 전문가 에이전트 (Llama3 70B + MCP)")
    print("종료: 'exit' 또는 Ctrl+C")
    print("=" * 60)

    # 미리 정의된 시나리오
    SCENARIOS = {
        "1": "현재 EKS 클러스터 전체 상태를 진단해줘. 파드, 노드, Pending 상황, KEDA 스케일 상태를 모두 확인하고 문제점을 알려줘.",
        "2": "DynamoDB 이벤트 결과와 SQS 큐 상태를 확인해서 지금 이벤트가 정상적으로 처리되고 있는지 알려줘.",
        "3": "Pending 파드가 있으면 원인을 분석하고 해결 방법을 제시해줘.",
        "4": "Worker 파드 로그에서 에러가 있는지 확인해줘.",
    }

    print("\n빠른 시나리오:")
    for k, v in SCENARIOS.items():
        print(f"  [{k}] {v[:50]}...")
    print()

    while True:
        try:
            user_input = input("\n질문 (또는 시나리오 번호): ").strip()
            if not user_input or user_input.lower() == "exit":
                print("종료합니다.")
                break

            # 시나리오 번호 입력 시 치환
            message = SCENARIOS.get(user_input, user_input)
            await run_agent(message)

        except KeyboardInterrupt:
            print("\n종료합니다.")
            break
        except Exception as e:
            print(f"오류: {e}")


async def auto_diagnosis():
    """자동 진단 모드 - 클러스터 전체 상태를 분석하고 final_report.md 저장"""
    print("자동 진단 시작...")

    result = await run_agent(
        "EKS 클러스터 전체를 진단해줘. "
        "1) 파드 상태 확인 "
        "2) 노드 리소스 확인 "
        "3) Pending 파드 원인 분석 "
        "4) KEDA/Karpenter 상태 확인 "
        "5) DynamoDB 이벤트 결과 확인 "
        "6) SQS 큐 상태 확인 "
        "마지막에 심각도별 문제점과 조치 방안을 정리해줘."
    )

    # 결과 저장
    from datetime import datetime, timezone
    with open("agents/final_report.md", "w", encoding="utf-8") as f:
        f.write(f"# Y2KS EKS 자동 진단 보고서\n\n")
        f.write(f"생성 시각: {datetime.now(timezone.utc).isoformat()}\n\n")
        f.write("---\n\n")
        f.write(str(result))

    print("\n✅ final_report.md 저장 완료")


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "--auto":
        # 자동 진단 모드
        asyncio.run(auto_diagnosis())
    else:
        # 대화형 모드
        asyncio.run(interactive_mode())
