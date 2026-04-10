"""
REBINCOOP Secure Erase — Erase Engine
Implements DoD 5220.22-M (7-pass), NIST 800-88, ATA Secure Erase, NVMe Sanitize.
Falls back to a realistic simulation on Windows/macOS.
"""

import asyncio
import math
import os
import sys
import time
from datetime import datetime
from typing import Callable, Dict, List, Optional

IS_LINUX = sys.platform.startswith("linux")
IS_MOCK = not IS_LINUX

BLOCK_SIZE = 4 * 1024 * 1024  # 4 MiB

# DoD 5220.22-M pass descriptors  (None = random)
DOD_PASSES: List[Optional[bytes]] = [
    b"\x00",   # 1: zeros
    b"\xFF",   # 2: ones
    b"\x00",   # 3: zeros
    None,      # 4: random
    b"\x00",   # 5: zeros
    b"\xFF",   # 6: ones
    None,      # 7: random
]


# ── Task state ─────────────────────────────────────────────────────────────────

class DiskEraseTask:
    def __init__(self, disk_path: str, method: str):
        self.disk_path = disk_path
        self.method = method
        self.status: str = "PENDING"
        self.progress: float = 0.0
        self.current_pass: int = 0
        self.total_passes: int = 7
        self.speed_mbs: float = 0.0
        self.eta_seconds: int = 0
        self.bytes_written: int = 0
        self.total_bytes: int = 0
        self.start_time: Optional[datetime] = None
        self.end_time: Optional[datetime] = None
        self.error: Optional[str] = None
        self.cancelled: bool = False

    def to_dict(self) -> dict:
        return {
            "disk": self.disk_path,
            "status": self.status,
            "progress": round(self.progress, 2),
            "current_pass": self.current_pass,
            "total_passes": self.total_passes,
            "speed_mbs": round(self.speed_mbs, 1),
            "eta_seconds": self.eta_seconds,
            "bytes_written": self.bytes_written,
            "total_bytes": self.total_bytes,
            "start_time": self.start_time.isoformat() if self.start_time else None,
            "end_time": self.end_time.isoformat() if self.end_time else None,
            "error": self.error,
        }


# ── Manager ────────────────────────────────────────────────────────────────────

class EraseManager:
    def __init__(self):
        self._active: Dict[str, DiskEraseTask] = {}
        self._done: Dict[str, DiskEraseTask] = {}

    def get_all_status(self) -> dict:
        result = {}
        for path, task in {**self._done, **self._active}.items():
            result[path] = task.to_dict()
        return result

    def reset_disk(self, disk_path: str):
        """Allow a disk to be re-erased (e.g. after failure)."""
        self._done.pop(disk_path, None)
        self._active.pop(disk_path, None)

    async def start_erase(
        self,
        job_id: str,
        disk_paths: List[str],
        method: str,
        job_data: dict,
        progress_callback: Callable,
    ):
        tasks = []
        for path in disk_paths:
            task = DiskEraseTask(path, method)
            self._active[path] = task
            fn = self._mock_erase if IS_MOCK else self._real_erase
            tasks.append(asyncio.create_task(fn(task, progress_callback)))

        results = await asyncio.gather(*tasks, return_exceptions=True)

        for i, path in enumerate(disk_paths):
            t = self._active.pop(path, None)
            if t:
                if isinstance(results[i], Exception) and t.status != "FAILED":
                    t.status = "FAILED"
                    t.error = str(results[i])
                    t.end_time = datetime.now()
                self._done[path] = t


    # ── Mock simulation ────────────────────────────────────────────────────────

    async def _mock_erase(self, task: DiskEraseTask, cb: Callable):
        PASS_SECONDS = 7.0        # simulated seconds per pass
        UPDATE_HZ = 10            # updates per second
        UPDATE_INTERVAL = 1.0 / UPDATE_HZ

        method_passes = {
            "DoD 5220.22-M (7 pasadas)": 7,
            "NIST 800-88 Clear": 1,
            "NIST 800-88 Purge": 1,
            "ATA Secure Erase (SSDs only)": 1,
            "NVMe Sanitize (NVMe only)": 1,
        }

        task.total_passes = method_passes.get(task.method, 7)
        task.total_bytes = 500 * 1024 ** 3          # nominal 500 GB
        task.status = "ERASING"
        task.start_time = datetime.now()

        steps_per_pass = int(PASS_SECONDS / UPDATE_INTERVAL)

        for p in range(1, task.total_passes + 1):
            task.current_pass = p

            for step in range(steps_per_pass + 1):
                if task.cancelled:
                    task.status = "FAILED"
                    task.error = "Cancelado por el usuario"
                    task.end_time = datetime.now()
                    await cb(task.disk_path, task.to_dict())
                    return

                frac_pass = step / steps_per_pass
                overall = ((p - 1) + frac_pass) / task.total_passes * 100.0

                task.progress = overall
                task.bytes_written = int(task.total_bytes * overall / 100.0)

                # Simulate realistic but varied speed (MB/s)
                wave = 0.5 + 0.5 * math.sin(step * 0.4 + p * 1.3)
                task.speed_mbs = 85.0 + 70.0 * wave

                remaining = task.total_bytes - task.bytes_written
                if task.speed_mbs > 0:
                    task.eta_seconds = int(
                        remaining / (task.speed_mbs * 1024 ** 2)
                    )

                await cb(task.disk_path, task.to_dict())
                await asyncio.sleep(UPDATE_INTERVAL)

        task.status = "COMPLETED"
        task.progress = 100.0
        task.current_pass = task.total_passes
        task.bytes_written = task.total_bytes
        task.speed_mbs = 0.0
        task.eta_seconds = 0
        task.end_time = datetime.now()
        await cb(task.disk_path, task.to_dict())


    # ── Real erase (Linux) ─────────────────────────────────────────────────────

    async def _real_erase(self, task: DiskEraseTask, cb: Callable):
        task.status = "ERASING"
        task.start_time = datetime.now()
        loop = asyncio.get_event_loop()

        try:
            task.total_bytes = await loop.run_in_executor(
                None, _disk_size, task.disk_path
            )
        except Exception as e:
            task.status = "FAILED"
            task.error = f"No se pudo leer el tamaño del disco: {e}"
            task.end_time = datetime.now()
            await cb(task.disk_path, task.to_dict())
            return

        try:
            m = task.method
            if m == "DoD 5220.22-M (7 pasadas)":
                await self._dod_erase(task, cb, loop)
            elif m == "NIST 800-88 Clear":
                task.total_passes = 1
                await self._write_pass_async(task, b"\x00", 1, cb, loop)
            elif m in ("NIST 800-88 Purge", "ATA Secure Erase (SSDs only)"):
                await self._ata_secure_erase(task, cb)
            elif m == "NVMe Sanitize (NVMe only)":
                await self._nvme_sanitize(task, cb)
            else:
                await self._dod_erase(task, cb, loop)

            task.status = "COMPLETED"
            task.progress = 100.0
            task.speed_mbs = 0.0
            task.eta_seconds = 0
            task.end_time = datetime.now()
            await cb(task.disk_path, task.to_dict())

        except Exception as e:
            task.status = "FAILED"
            task.error = str(e)
            task.end_time = datetime.now()
            await cb(task.disk_path, task.to_dict())

    async def _dod_erase(self, task: DiskEraseTask, cb: Callable, loop):
        task.total_passes = 7
        for i, pattern in enumerate(DOD_PASSES):
            await self._write_pass_async(task, pattern, i + 1, cb, loop)
            if task.cancelled:
                break

    async def _write_pass_async(
        self,
        task: DiskEraseTask,
        pattern: Optional[bytes],
        pass_num: int,
        cb: Callable,
        loop,
    ):
        """Run a write pass in a thread executor while reporting progress."""
        task.current_pass = pass_num
        task.bytes_written = 0

        write_task = loop.run_in_executor(
            None, _write_pass_threaded, task, pattern
        )
        write_future = asyncio.ensure_future(write_task)

        while not write_future.done():
            p_in_pass = (task.bytes_written / task.total_bytes
                         if task.total_bytes else 0)
            overall = ((pass_num - 1) + p_in_pass) / task.total_passes * 100.0
            task.progress = overall

            remaining = task.total_bytes - task.bytes_written
            if task.speed_mbs > 0:
                remaining_passes = task.total_passes - pass_num + 1 - p_in_pass
                task.eta_seconds = int(
                    remaining / (task.speed_mbs * 1024 ** 2) * remaining_passes
                )

            await cb(task.disk_path, task.to_dict())
            await asyncio.sleep(0.5)

        await write_future   # re-raise any exception from the thread

    async def _ata_secure_erase(self, task: DiskEraseTask, cb: Callable):
        task.total_passes = 1
        task.current_pass = 1
        await cb(task.disk_path, task.to_dict())

        proc = await asyncio.create_subprocess_exec(
            "hdparm", "--security-set-pass", "rebincoop", task.disk_path,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()

        proc = await asyncio.create_subprocess_exec(
            "hdparm", "--security-erase", "rebincoop", task.disk_path,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        task.progress = 100.0

    async def _nvme_sanitize(self, task: DiskEraseTask, cb: Callable):
        task.total_passes = 1
        task.current_pass = 1
        await cb(task.disk_path, task.to_dict())

        proc = await asyncio.create_subprocess_exec(
            "nvme", "format", "--ses=1", task.disk_path,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        task.progress = 100.0


# ── Thread-safe helpers ────────────────────────────────────────────────────────

def _disk_size(device: str) -> int:
    """Return disk size in bytes (Linux)."""
    dev_name = device.replace("/dev/", "")
    size_path = f"/sys/block/{dev_name}/size"
    try:
        with open(size_path) as f:
            return int(f.read().strip()) * 512
    except (OSError, ValueError):
        fd = os.open(device, os.O_RDONLY)
        try:
            return os.lseek(fd, 0, os.SEEK_END)
        finally:
            os.close(fd)


def _write_pass_threaded(task: DiskEraseTask, pattern: Optional[bytes]):
    """Threaded write pass — updates task.bytes_written and task.speed_mbs."""
    flags = os.O_WRONLY | os.O_SYNC
    if hasattr(os, "O_DIRECT"):
        flags |= os.O_DIRECT  # bypass page cache; requires aligned buffers

    try:
        fd = os.open(task.disk_path, flags)
    except OSError:
        # Fall back without O_DIRECT
        fd = os.open(task.disk_path, os.O_WRONLY | os.O_SYNC)

    try:
        if pattern is None:
            block = os.urandom(BLOCK_SIZE)
        else:
            block = pattern * BLOCK_SIZE

        written = 0
        t0 = time.monotonic()
        last_speed_bytes = 0
        last_speed_t = t0

        while written < task.total_bytes:
            if task.cancelled:
                return

            remaining = task.total_bytes - written
            chunk_size = min(BLOCK_SIZE, remaining)

            # For random passes, refresh entropy each block
            if pattern is None:
                block = os.urandom(BLOCK_SIZE)

            chunk = block[:chunk_size] if chunk_size < BLOCK_SIZE else block

            try:
                n = os.write(fd, chunk)
            except OSError:
                # Truncate to written so far on I/O error
                break

            written += n
            task.bytes_written = written

            # Update speed every ~1 s
            now = time.monotonic()
            elapsed = now - last_speed_t
            if elapsed >= 1.0:
                delta_b = written - last_speed_bytes
                task.speed_mbs = delta_b / elapsed / (1024 ** 2)
                last_speed_t = now
                last_speed_bytes = written

        try:
            os.fsync(fd)
        except OSError:
            pass
    finally:
        os.close(fd)
