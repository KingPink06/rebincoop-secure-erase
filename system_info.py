"""
REBINCOOP Secure Erase — System Information
Gathers PC metadata using dmidecode, lscpu, /proc/meminfo, etc.
Falls back to mock data on Windows/macOS.
"""

import asyncio
import os
import platform
import socket
import subprocess
import sys
from typing import List

IS_LINUX = sys.platform.startswith("linux")
IS_MOCK = not IS_LINUX


def _run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return -1, "", ""


def _hostname() -> str:
    return socket.gethostname()


def _mac_addresses() -> List[str]:
    macs = []
    if IS_LINUX:
        net = "/sys/class/net"
        if os.path.isdir(net):
            for iface in sorted(os.listdir(net)):
                addr_path = f"{net}/{iface}/address"
                try:
                    with open(addr_path) as f:
                        mac = f.read().strip()
                    if mac and mac != "00:00:00:00:00:00":
                        macs.append(f"{iface}: {mac}")
                except OSError:
                    pass
    else:
        import uuid
        raw = uuid.getnode()
        mac = ":".join(f"{(raw >> (8 * i)) & 0xFF:02x}" for i in range(5, -1, -1))
        macs.append(f"eth0: {mac}")
    return macs or ["N/A"]


def _cpu_info() -> str:
    if IS_LINUX:
        rc, out, _ = _run(["lscpu"])
        if rc == 0:
            for line in out.splitlines():
                if line.startswith("Model name"):
                    return line.split(":", 1)[1].strip()
    return platform.processor() or "Desconocido"


def _ram_info() -> str:
    if IS_LINUX:
        try:
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        kb = int(line.split()[1])
                        return f"{kb / 1024 ** 2:.1f} GB"
        except OSError:
            pass
    try:
        import psutil
        return f"{psutil.virtual_memory().total / 1024 ** 3:.1f} GB"
    except ImportError:
        pass
    return "Desconocido"


def _dmi_info() -> dict:
    result = {
        "motherboard_manufacturer": "Desconocido",
        "motherboard_model": "Desconocido",
        "bios_version": "Desconocido",
    }
    if not IS_LINUX:
        return result

    # Motherboard (type 2)
    rc, out, _ = _run(["dmidecode", "-t", "2"])
    if rc == 0:
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("Manufacturer:"):
                result["motherboard_manufacturer"] = line.split(":", 1)[1].strip()
            elif line.startswith("Product Name:"):
                result["motherboard_model"] = line.split(":", 1)[1].strip()

    # BIOS (type 0)
    rc, out, _ = _run(["dmidecode", "-t", "0"])
    if rc == 0:
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("Version:"):
                result["bios_version"] = line.split(":", 1)[1].strip()
                break

    return result


def _detect_host_os() -> str:
    """Attempt to detect what OS lives on any non-live partition."""
    if not IS_LINUX:
        return "N/A"
    probes = [
        ("/mnt/windows/Windows", "Microsoft Windows"),
        ("/mnt/windows/windows", "Microsoft Windows"),
        ("/mnt/root/etc/os-release", None),
        ("/mnt/ubuntu/etc/lsb-release", None),
    ]
    for path, label in probes:
        if os.path.exists(path):
            if label:
                return label
            try:
                with open(path) as f:
                    for line in f:
                        if line.startswith("PRETTY_NAME="):
                            return line.split("=", 1)[1].strip().strip('"')
            except OSError:
                pass
    return "N/A"


def _mock_system_info() -> dict:
    return {
        "hostname": "WORKSTATION-7F2A",
        "cpu": "Intel(R) Core(TM) i7-10700K CPU @ 3.80GHz",
        "ram": "32.0 GB",
        "motherboard_manufacturer": "ASUSTeK COMPUTER INC.",
        "motherboard_model": "ROG STRIX Z490-E GAMING",
        "bios_version": "1401",
        "os_detected": "Windows 10 Pro (22H2)",
        "mac_addresses": ["eth0: 00:1A:2B:3C:4D:5E", "wlan0: AA:BB:CC:DD:EE:FF"],
    }


async def get_system_info() -> dict:
    if IS_MOCK:
        return _mock_system_info()

    loop = asyncio.get_event_loop()
    cpu = await loop.run_in_executor(None, _cpu_info)
    ram = await loop.run_in_executor(None, _ram_info)
    dmi = await loop.run_in_executor(None, _dmi_info)
    macs = await loop.run_in_executor(None, _mac_addresses)
    os_det = await loop.run_in_executor(None, _detect_host_os)

    return {
        "hostname": _hostname(),
        "cpu": cpu,
        "ram": ram,
        "motherboard_manufacturer": dmi["motherboard_manufacturer"],
        "motherboard_model": dmi["motherboard_model"],
        "bios_version": dmi["bios_version"],
        "os_detected": os_det,
        "mac_addresses": macs,
    }
