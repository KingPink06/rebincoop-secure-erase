"""
REBINCOOP Secure Erase — PDF Report Generator
Uses fpdf2 to generate a professional, dark-themed certificate of erasure.
"""

import hashlib
import json
import random
import tempfile
from datetime import datetime
from pathlib import Path
from typing import List

try:
    from fpdf import FPDF
    HAS_FPDF = True
except ImportError:
    HAS_FPDF = False


# ── Color palette (R, G, B 0-255) ─────────────────────────────────────────────
BG       = (13,  15,  18)
SURFACE  = (22,  26,  31)
SURFACE2 = (28,  34,  42)
HDR      = (8,   10,  13)
ACCENT   = (0,   194, 255)
SUCCESS  = (0,   200, 100)
DANGER   = (220, 50,  50)
WHITE    = (255, 255, 255)
MUTED    = (107, 122, 141)
TEXT     = (220, 228, 240)


def _fmt_duration(seconds: float) -> str:
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m {s % 60}s"
    return f"{s // 3600}h {(s % 3600) // 60}m"


def _report_hash(data: dict) -> str:
    canonical = json.dumps(data, sort_keys=True, default=str, ensure_ascii=True)
    return hashlib.sha256(canonical.encode()).hexdigest()


# ── PDF class ──────────────────────────────────────────────────────────────────

class RebinPDF(FPDF):
    def __init__(self):
        super().__init__(orientation="P", unit="mm", format="A4")
        self.set_auto_page_break(auto=True, margin=20)
        self.set_margins(14, 30, 14)

    def header(self):
        # Full-page dark background (drawn on every page)
        self.set_fill_color(*BG)
        self.rect(0, 0, self.w, self.h, style="F")

        # Header strip
        self.set_fill_color(*HDR)
        self.rect(0, 0, self.w, 24, style="F")

        # Left: brand
        self.set_xy(14, 5)
        self.set_font("Helvetica", "B", 13)
        self.set_text_color(*ACCENT)
        self.cell(80, 7, "REBINCOOP", ln=False)

        self.set_xy(14, 13)
        self.set_font("Helvetica", "", 7)
        self.set_text_color(*MUTED)
        self.cell(80, 5, "Secure Erase System v1.0", ln=False)

        # Right: page number
        self.set_xy(self.w - 50, 9)
        self.set_font("Helvetica", "", 8)
        self.set_text_color(*MUTED)
        self.cell(36, 5, f"Página {self.page_no()}", align="R")

        self.set_xy(14, 27)

    def footer(self):
        self.set_y(-14)
        self.set_font("Helvetica", "I", 7)
        self.set_text_color(*MUTED)
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")
        self.cell(0, 8,
                  f"Generado por REBINCOOP Secure Erase  ·  {ts}",
                  align="C")

    # ── Layout helpers ─────────────────────────────────────────────────────────

    def section_header(self, title: str):
        self.ln(3)
        self.set_fill_color(*SURFACE)
        self.set_font("Helvetica", "B", 9)
        self.set_text_color(*ACCENT)
        self.cell(0, 8, f"  {title}", fill=True, ln=True)
        self.ln(1)

    def kv(self, key: str, value: str, shade: bool = False):
        fill = SURFACE2 if shade else SURFACE
        self.set_fill_color(*fill)
        self.set_font("Helvetica", "", 8)
        self.set_text_color(*MUTED)
        self.cell(58, 6.5, f"  {key}", fill=True, ln=False)
        self.set_text_color(*TEXT)
        self.cell(0, 6.5, f"  {value}", fill=True, ln=True)

    def result_kv(self, key: str, value: str, ok: bool, shade: bool = False):
        fill = SURFACE2 if shade else SURFACE
        self.set_fill_color(*fill)
        self.set_font("Helvetica", "", 8)
        self.set_text_color(*MUTED)
        self.cell(58, 6.5, f"  {key}", fill=True, ln=False)
        self.set_font("Helvetica", "B", 8)
        self.set_text_color(*(SUCCESS if ok else DANGER))
        self.cell(0, 6.5, f"  {value}", fill=True, ln=True)

    def accent_rule(self):
        y = self.get_y()
        self.set_fill_color(*ACCENT)
        self.rect(14, y, self.w - 28, 0.6, style="F")
        self.ln(3)


# ── Public API ─────────────────────────────────────────────────────────────────

async def generate_pdf_report(
    job_data: dict,
    disk_results: List[dict],
    system_info: dict,
) -> Path:
    if not HAS_FPDF:
        raise RuntimeError(
            "fpdf2 not installed. Run: pip install fpdf2"
        )

    now = datetime.now()
    report_payload = {
        "job": job_data,
        "disks": disk_results,
        "system": system_info,
        "generated_at": now.isoformat(),
    }
    h = _report_hash(report_payload)

    pdf = RebinPDF()
    pdf.add_page()

    # ── Title ──────────────────────────────────────────────────────────────────
    pdf.set_font("Helvetica", "B", 17)
    pdf.set_text_color(*WHITE)
    pdf.cell(0, 11, "CERTIFICADO DE BORRADO SEGURO", ln=True, align="C")
    pdf.accent_rule()

    # ── Job info ───────────────────────────────────────────────────────────────
    pdf.section_header("INFORMACIÓN DEL TRABAJO")
    rows = [
        ("Número de referencia", job_data.get("referencia", "N/A")),
        ("Técnico responsable",  job_data.get("tecnico", "N/A")),
        ("Empresa cliente",      job_data.get("empresa", "N/A")),
        ("Fecha de ejecución",   job_data.get("fecha",
                                              now.strftime("%Y-%m-%d"))),
    ]
    for i, (k, v) in enumerate(rows):
        pdf.kv(k, str(v), shade=(i % 2 == 1))
    pdf.ln(3)

    # ── System info ────────────────────────────────────────────────────────────
    pdf.section_header("INFORMACIÓN DEL EQUIPO")
    mb = (f"{system_info.get('motherboard_manufacturer', '')} "
          f"{system_info.get('motherboard_model', '')}").strip()
    macs = ", ".join(system_info.get("mac_addresses") or ["N/A"])
    sys_rows = [
        ("Hostname",                  system_info.get("hostname", "N/A")),
        ("CPU",                       system_info.get("cpu", "N/A")),
        ("Memoria RAM",               system_info.get("ram", "N/A")),
        ("Placa base",                mb or "N/A"),
        ("Versión BIOS",              system_info.get("bios_version", "N/A")),
        ("SO detectado en disco",     system_info.get("os_detected", "N/A")),
        ("Direcciones MAC",           macs),
    ]
    for i, (k, v) in enumerate(sys_rows):
        pdf.kv(k, str(v), shade=(i % 2 == 1))
    pdf.ln(3)

    # ── Disk results ───────────────────────────────────────────────────────────
    pdf.section_header("DISCOS BORRADOS")

    for idx, disk in enumerate(disk_results):
        ok = disk.get("status") == "COMPLETED"
        result_label = "ÉXITO" if ok else "FALLO"

        # Disk sub-header
        pdf.set_fill_color(*SURFACE2)
        pdf.set_font("Helvetica", "B", 8)
        pdf.set_text_color(*ACCENT)
        pdf.cell(
            0, 7,
            f"  Disco {idx + 1}  ·  {disk.get('path', '?')}  ·  "
            f"{disk.get('model', '?')}",
            fill=True, ln=True,
        )

        # Duration
        try:
            start = datetime.fromisoformat(disk["start_time"])
            end   = datetime.fromisoformat(disk["end_time"])
            dur   = _fmt_duration((end - start).total_seconds())
        except (TypeError, KeyError, ValueError):
            dur = "N/A"
            start = end = None

        disk_rows = [
            ("Número de serie",      disk.get("serial", "N/A")),
            ("Capacidad",            disk.get("size_str", "N/A")),
            ("Tipo de disco",        disk.get("type", "N/A")),
            ("Método de borrado",    disk.get("method", "N/A")),
            ("Pasadas completadas",
             f"{disk.get('current_pass', 0)} / {disk.get('total_passes', 0)}"),
            ("Inicio",               disk["start_time"] if disk.get("start_time") else "N/A"),
            ("Fin",                  disk["end_time"]   if disk.get("end_time")   else "N/A"),
            ("Duración",             dur),
        ]
        for i, (k, v) in enumerate(disk_rows):
            pdf.kv(k, str(v), shade=(i % 2 == 1))

        # Result row (colored)
        pdf.result_kv("Resultado", result_label, ok=ok, shade=len(disk_rows) % 2 == 1)

        if not ok and disk.get("error"):
            pdf.kv("Error", disk["error"], shade=False)

        pdf.ln(3)

    # ── Notes ──────────────────────────────────────────────────────────────────
    notes = job_data.get("notas", "").strip()
    if notes:
        pdf.section_header("NOTAS ADICIONALES")
        pdf.set_fill_color(*SURFACE)
        pdf.set_font("Helvetica", "", 8)
        pdf.set_text_color(*TEXT)
        pdf.multi_cell(0, 6, f"  {notes}", fill=True)
        pdf.ln(3)

    # ── Integrity hash ─────────────────────────────────────────────────────────
    pdf.section_header("VERIFICACIÓN DE INTEGRIDAD DEL REPORTE")
    pdf.set_fill_color(*SURFACE)
    pdf.set_font("Helvetica", "", 7)
    pdf.set_text_color(*MUTED)
    pdf.cell(0, 5.5, "  Algoritmo: SHA-256", fill=True, ln=True)
    pdf.set_font("Helvetica", "B", 7)
    pdf.set_text_color(*ACCENT)
    pdf.set_fill_color(*SURFACE2)
    pdf.cell(0, 5.5, f"  {h}", fill=True, ln=True)
    pdf.ln(2)

    # ── Save ───────────────────────────────────────────────────────────────────
    ref = "".join(
        c for c in job_data.get("referencia", "X") if c.isalnum() or c in "-_"
    )[:20]
    suffix = random.randint(1000, 9999)
    date_str = now.strftime("%Y%m%d")
    filename = f"REBINCOOP_{date_str}_{ref}_{suffix}.pdf"

    out_path = Path(tempfile.gettempdir()) / filename
    pdf.output(str(out_path))
    return out_path
