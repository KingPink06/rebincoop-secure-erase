#!/usr/bin/env python3
"""
REBINCOOP Secure Erase — FastAPI Backend
Entry point: python main.py  →  http://127.0.0.1:8420
"""

import asyncio
import shutil
import uuid
from pathlib import Path
from typing import List

from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

from disk_manager import get_disks, get_usb_drives
from erase_engine import EraseManager
from pdf_generator import generate_pdf_report
from system_info import get_system_info

# ── App setup ──────────────────────────────────────────────────────────────────

app = FastAPI(title="REBINCOOP Secure Erase", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

erase_manager = EraseManager()


# ── WebSocket connection manager ───────────────────────────────────────────────

class WsManager:
    def __init__(self):
        self._conns: List[WebSocket] = []

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self._conns.append(ws)

    def disconnect(self, ws: WebSocket):
        self._conns = [c for c in self._conns if c is not ws]

    async def broadcast(self, msg: dict):
        dead = []
        for ws in self._conns:
            try:
                await ws.send_json(msg)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws)


ws_mgr = WsManager()


# ── Request models ─────────────────────────────────────────────────────────────

class StartEraseReq(BaseModel):
    disks: List[str]
    method: str
    job: dict


class GeneratePDFReq(BaseModel):
    job: dict
    disks: List[dict]
    system_info: dict


class ExportPDFReq(BaseModel):
    pdf_path: str
    usb_path: str
    filename: str


# ── Routes ─────────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def root():
    html = (Path(__file__).parent / "index.html").read_text(encoding="utf-8")
    return HTMLResponse(content=html)


@app.get("/api/disks")
async def api_disks():
    try:
        return {"disks": await get_disks()}
    except Exception as e:
        raise HTTPException(500, detail=str(e))


@app.get("/api/system")
async def api_system():
    try:
        return await get_system_info()
    except Exception as e:
        raise HTTPException(500, detail=str(e))


@app.get("/api/usb-drives")
async def api_usb_drives():
    try:
        return {"drives": await get_usb_drives()}
    except Exception as e:
        raise HTTPException(500, detail=str(e))


@app.get("/api/erase-status")
async def api_erase_status():
    return {"status": erase_manager.get_all_status()}


@app.post("/api/start-erase")
async def api_start_erase(req: StartEraseReq):
    if not req.disks:
        raise HTTPException(400, detail="No hay discos seleccionados")

    job_id = str(uuid.uuid4())[:8].upper()

    async def progress_cb(disk_path: str, data: dict):
        await ws_mgr.broadcast({"type": "progress", "disk": disk_path, "data": data})

    asyncio.create_task(
        erase_manager.start_erase(
            job_id=job_id,
            disk_paths=req.disks,
            method=req.method,
            job_data=req.job,
            progress_callback=progress_cb,
        )
    )
    return {"job_id": job_id, "status": "started", "disks": req.disks}


@app.post("/api/generate-pdf")
async def api_generate_pdf(req: GeneratePDFReq):
    try:
        path = await generate_pdf_report(
            job_data=req.job,
            disk_results=req.disks,
            system_info=req.system_info,
        )
        return {"pdf_path": str(path), "filename": path.name}
    except Exception as e:
        raise HTTPException(500, detail=str(e))


@app.get("/api/download-pdf")
async def api_download_pdf(path: str = Query(...)):
    p = Path(path)
    if not p.exists():
        raise HTTPException(404, detail="PDF no encontrado")
    return FileResponse(path=str(p), media_type="application/pdf", filename=p.name)


@app.post("/api/export-pdf")
async def api_export_pdf(req: ExportPDFReq):
    src = Path(req.pdf_path)
    if not src.exists():
        raise HTTPException(404, detail="PDF no encontrado")

    dst_dir = Path(req.usb_path)
    if not dst_dir.is_dir():
        raise HTTPException(404, detail="Ruta USB no encontrada")

    fname = req.filename if req.filename.lower().endswith(".pdf") else req.filename + ".pdf"
    dst = dst_dir / fname

    try:
        shutil.copy2(str(src), str(dst))
        return {"status": "success", "path": str(dst)}
    except Exception as e:
        raise HTTPException(500, detail=str(e))


# ── WebSocket ──────────────────────────────────────────────────────────────────

@app.websocket("/ws/progress")
async def ws_progress(websocket: WebSocket):
    await ws_mgr.connect(websocket)
    try:
        # Send snapshot of current state right away
        await websocket.send_json({
            "type": "status",
            "data": erase_manager.get_all_status(),
        })
        while True:
            try:
                msg = await asyncio.wait_for(websocket.receive_text(), timeout=25.0)
                if msg == "ping":
                    await websocket.send_json({"type": "pong"})
            except asyncio.TimeoutError:
                await websocket.send_json({"type": "ping"})
    except WebSocketDisconnect:
        ws_mgr.disconnect(websocket)
    except Exception:
        ws_mgr.disconnect(websocket)


# ── Entry ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="127.0.0.1",
        port=8420,
        reload=False,
        log_level="info",
    )
