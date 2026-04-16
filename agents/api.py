"""
Y2KS AIOps Agent - FastAPI 백엔드
React UI와 통신하는 API 서버
"""

import os
import sys
import json
import asyncio
from datetime import datetime

try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
except ImportError:
    pass

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from eks_agent import run_agent, auto_diagnosis

app = FastAPI(title="Y2KS AIOps Agent API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class QueryRequest(BaseModel):
    message: str


@app.post("/api/query")
async def query(req: QueryRequest):
    """에이전트에 질문"""
    try:
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(None, run_agent, req.message)
        return {"ok": True, "result": result, "timestamp": datetime.now().isoformat()}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/auto-diagnosis")
async def diagnosis():
    """전체 자동 진단"""
    try:
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(None, auto_diagnosis)
        return {"ok": True, "result": result, "timestamp": datetime.now().isoformat()}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.get("/api/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now().isoformat()}


@app.get("/", response_class=HTMLResponse)
async def index():
    with open(os.path.join(os.path.dirname(__file__), "web", "index.html"), encoding="utf-8") as f:
        return f.read()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, reload=False)
