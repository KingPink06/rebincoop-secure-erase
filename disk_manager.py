"""
REBINCOOP Secure Erase — Disk Manager
Detects disks via lsblk + smartctl. Falls back to mock data on Windows/macOS.
"""

import asyncio
import json
import re
import subprocess
import sys
from typing import List, Optional

IS_LINUX = sys.platform.startswith("linux")
IS_MOCK = not IS_LINUX


# ── low-level helpers ──────────────────────────────────────────────────────────

def _run(cmd: List[str], timeout: int = 12) -> tuple[int, str, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return -1, "", str(e)


def _get_boot_disk() -> str:
    """Return the /dev/xxx device that hosts the root '/' mount."""
    rc, out, _ = _run(["findmnt", "-n", "-o", "SOURCE", "/"])
    if rc != 0 or not out.strip():
        return ""
    device = out.strip()
    # Strip partition suffix:  /dev/sda1 → /dev/sda   /dev/nvme0n1p1 → /dev/nvme0n1
    m = re.match(r"(/dev/nvme\d+n\d+)p\d+", device)
    if m:
        return m.group(1)
    m = re.match(r"(/dev/[a-z]+)\d+", device)
    if m:
        return m.group(1)
    return device


def _smart_info(device: str) -> dict:
    base = {"health": "UNKNOWN", "temperature": None,
            "power_on_hours": None, "reallocated_sectors": None}
    rc, out, _ = _run(["smartctl", "-a", "-j", device], timeout=15)
    if rc == -1 or not out.strip():
        return base
    try:
        d = json.loads(out)
        if "smart_status" in d:
            base["health"] = "GOOD" if d["smart_status"].get("passed") else "FAILING"
        if "temperature" in d:
            base["temperature"] = d["temperature"].get("current")
        if "power_on_time" in d:
            base["power_on_hours"] = d["power_on_time"].get("hours")
        for attr in d.get("ata_smart_attributes", {}).get("table", []):
            aid = attr.get("id")
            raw = attr.get("raw", {}).get("value", 0)
            if aid == 194 and base["temperature"] is None:
                base["temperature"] = raw
            elif aid == 5:
                base["reallocated_sectors"] = raw
    except (json.JSONDecodeError, KeyError):
        pass
    return base


def _parse_lsblk() -> List[dict]:
    rc, out, _ = _run([
        "lsblk", "-J", "-b", "-o",
        "NAME,SIZE,TYPE,MODEL,SERIAL,VENDOR,TRAN,ROTA,HOTPLUG,MOUNTPOINT"
    ])
    if rc != 0:
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return []

    disks = []
    for dev in data.get("blockdevices", []):
        if dev.get("type") != "disk":
            continue
        name = dev.get("name", "")
        if not name:
            continue

        tran = (dev.get("tran") or "").lower()
        rota = dev.get("rota", True)
        if "nvme" in name.lower() or tran == "nvme":
            disk_type = "NVMe"
        elif not rota:
            disk_type = "SSD"
        else:
            disk_type = "HDD"

        size_b = int(dev.get("size") or 0)
        size_gb = size_b / 1024 ** 3
        size_str = f"{size_gb / 1024:.2f} TB" if size_gb >= 1000 else f"{size_gb:.0f} GB"

        vendor = (dev.get("vendor") or "").strip()
        model = (dev.get("model") or "").strip()
        if vendor and vendor.lower() not in model.lower():
            full_model = f"{vendor} {model}".strip()
        else:
            full_model = model or "Desconocido"

        disks.append({
            "path": f"/dev/{name}",
            "name": name,
            "model": full_model,
            "serial": (dev.get("serial") or "N/A").strip(),
            "size_bytes": size_b,
            "size_str": size_str,
            "type": disk_type,
            "removable": bool(dev.get("hotplug")),
            "tran": tran,
            "smart": {},
            "status": "PENDING",
            "is_boot": False,
        })
    return disks


# ── mock data ──────────────────────────────────────────────────────────────────

def _mock_disks() -> List[dict]:
    return [
        {
            "path": "/dev/sda",
            "name": "sda",
            "model": "Seagate BarraCuda ST2000DM008",
            "serial": "ZFN0A2KP",
            "size_bytes": 2_000_398_934_016,
            "size_str": "1.82 TB",
            "type": "HDD",
            "removable": False,
            "tran": "sata",
            "smart": {"health": "GOOD", "temperature": 34,
                      "power_on_hours": 8754, "reallocated_sectors": 0},
            "status": "PENDING",
            "is_boot": False,
        },
        {
            "path": "/dev/sdb",
            "name": "sdb",
            "model": "Samsung SSD 870 EVO 500GB",
            "serial": "S4XXNX0T123456",
            "size_bytes": 500_107_862_016,
            "size_str": "466 GB",
            "type": "SSD",
            "removable": False,
            "tran": "sata",
            "smart": {"health": "GOOD", "temperature": 28,
                      "power_on_hours": 3201, "reallocated_sectors": 0},
            "status": "PENDING",
            "is_boot": False,
        },
        {
            "path": "/dev/nvme0n1",
            "name": "nvme0n1",
            "model": "WD Black SN850X 1TB",
            "serial": "WXA1A23B4567",
            "size_bytes": 1_000_204_886_016,
            "size_str": "932 GB",
            "type": "NVMe",
            "removable": False,
            "tran": "nvme",
            "smart": {"health": "GOOD", "temperature": 42,
                      "power_on_hours": 1205, "reallocated_sectors": None},
            "status": "PENDING",
            "is_boot": True,   # ← boot disk (protected)
        },
        {
            "path": "/dev/sdc",
            "name": "sdc",
            "model": "Toshiba MQ01ABD100",
            "serial": "Y5J00001XXXX",
            "size_bytes": 1_000_204_886_016,
            "size_str": "932 GB",
            "type": "HDD",
            "removable": False,
            "tran": "sata",
            "smart": {"health": "FAILING", "temperature": 51,
                      "power_on_hours": 28400, "reallocated_sectors": 142},
            "status": "PENDING",
            "is_boot": False,
        },
    ]


def _mock_usb_drives() -> List[dict]:
    return [
        {
            "path": "/media/usb1",
            "name": "Kingston DataTraveler 32GB",
            "size_gb": 32.0,
            "free_gb": 28.4,
            "free_str": "28.4 GB libres",
        },
    ]


# ── public API ─────────────────────────────────────────────────────────────────

async def get_disks() -> List[dict]:
    if IS_MOCK:
        return _mock_disks()

    loop = asyncio.get_event_loop()
    disks = await loop.run_in_executor(None, _parse_lsblk)
    boot_disk = await loop.run_in_executor(None, _get_boot_disk)

    for disk in disks:
        disk["smart"] = await loop.run_in_executor(None, _smart_info, disk["path"])
        disk["is_boot"] = disk["path"] == boot_disk

    return disks


async def get_usb_drives() -> List[dict]:
    if IS_MOCK:
        return _mock_usb_drives()

    loop = asyncio.get_event_loop()

    def _scan_usb():
        rc, out, _ = _run([
            "lsblk", "-J", "-b", "-o",
            "NAME,SIZE,TYPE,HOTPLUG,MOUNTPOINT,FSTYPE"
        ])
        drives = []
        if rc != 0:
            return drives
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            return drives

        for dev in data.get("blockdevices", []):
            if not dev.get("hotplug"):
                continue
            for part in dev.get("children", []):
                mp = part.get("mountpoint")
                if not mp or mp == "/":
                    continue
                rc2, out2, _ = _run(["df", "-B1", mp])
                free_b = total_b = 0
                if rc2 == 0:
                    lines = out2.strip().split("\n")
                    if len(lines) >= 2:
                        cols = lines[1].split()
                        if len(cols) >= 4:
                            total_b = int(cols[1])
                            free_b = int(cols[3])
                drives.append({
                    "path": mp,
                    "name": f"USB {dev.get('name', '?')}",
                    "size_gb": total_b / 1024 ** 3,
                    "free_gb": free_b / 1024 ** 3,
                    "free_str": f"{free_b / 1024 ** 3:.1f} GB libres",
                })
        return drives

    return await loop.run_in_executor(None, _scan_usb)
