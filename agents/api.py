import os
os.environ["OTEL_SDK_DISABLED"] = "true"

try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
except ImportError:
    pass

import uvicorn
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, HTMLResponse
import os
from eks_agent import run_agent, auto_diagnosis

app = FastAPI(title="Y2KS Agent API")

# 로컬 웹 테스트를 위해 모든 도메인(CORS) 허용
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
async def get_admin_page():
    html_path = os.path.join(os.path.dirname(__file__), "admin_local.html")
    if os.path.exists(html_path):
        with open(html_path, "r", encoding="utf-8") as f:
            content = f.read()
        # Inject local AGENT_API automatically
        content = content.replace(
            "var AGENT_API = window.AGENT_API_URL || 'https://constant-unviable-dispersal.ngrok-free.dev';",
            "var AGENT_API = 'http://localhost:8000';"
        )
        return HTMLResponse(content)
    return HTMLResponse("<h1>admin_local.html 파일을 찾을 수 없습니다.</h1>", status_code=404)

import asyncio

@app.post("/api/query")
async def api_query(request: Request):
    try:
        data = await request.json()
        user_message = data.get("message", "")
        if not user_message:
            return JSONResponse({"ok": False, "error": "메시지가 없습니다."})
        
        result = await run_agent(user_message)
        return JSONResponse({"ok": True, "result": result})
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e)})

@app.post("/api/auto-diagnosis")
async def api_auto_diagnosis():
    try:
        result = await auto_diagnosis()
        return JSONResponse({"ok": True, "result": {"final": result}})
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e)})

if __name__ == "__main__":
    print("=====================================================")
    print("웹 테스트용 로컬 API 서버가 8000 포트에서 실행됩니다.")
    print("웹 브라우저 콘솔에서 다음 명령어를 입력 후 테스트하세요:")
    print("window.AGENT_API_URL = 'http://localhost:8000';")
    print("=====================================================")
    uvicorn.run(app, host="0.0.0.0", port=8000)
