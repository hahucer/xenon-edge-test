"""Read Windows GSMTC metadata; atomically publish data/media-state.json.

Run with the same Python that installed media-requirements.txt into .media-runtime.
The launcher owns the PID, duplicate-process checks, and process shutdown. This
helper does not launch or control media apps and does not change Windows policy.

Optional artwork is a fixed data/media-art.bin file, never an arbitrary path.
The bridge may expose GET /media-art?rev=<artworkVersion>, using artworkMime and
a 2 MiB size limit, with no-store and the same loopback/Origin rules as /now-playing.
Artwork is written before its matching JSON snapshot. The JSON never contains a
filesystem path, user credential, or remote artwork URL.
"""

from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time
from typing import Any


MAX_ART_BYTES = 2 * 1024 * 1024
MAX_TEXT = 1024
STATUS_NAMES = {
    0: "Closed", 1: "Opened", 2: "Changing", 3: "Stopped",
    4: "Playing", 5: "Paused"
}


def now_ms() -> int:
    return time.time_ns() // 1_000_000


def text(value: Any) -> str:
    return str(value or "")[:MAX_TEXT]


def empty_state(reason: str = "") -> dict[str, Any]:
    return {
        "schema": 1, "updatedAt": now_ms(), "bridge": True,
        "helper": True, "available": False, "playing": False,
        "status": "Stopped", "title": "", "artist": "", "album": "",
        "source": "", "positionSeconds": 0, "durationSeconds": 0,
        "reason": reason, "stale": False,
        "artworkVersion": "", "artworkMime": "", "artworkBytes": 0
    }


async def atomic_write(path: Path, payload: bytes) -> None:
    """Replace a completed file; brief Windows reader locks are retried."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(prefix="." + path.name + "-", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(handle, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        for attempt in range(5):
            try:
                os.replace(temporary, path)
                return
            except PermissionError:
                if attempt == 4:
                    raise
                await asyncio.sleep(0.05)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


async def publish_state(path: Path, state: dict[str, Any]) -> None:
    state["updatedAt"] = now_ms()
    payload = json.dumps(state, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
    await atomic_write(path, payload)


def seconds(value: Any) -> float:
    try:
        result = float(value.total_seconds())
        return result if math.isfinite(result) else 0.0
    except (AttributeError, TypeError, ValueError, OverflowError):
        return 0.0


def image_type(raw: bytes) -> str:
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if raw.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if raw.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if len(raw) >= 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return "image/webp"
    return ""


class MediaReader:
    def __init__(self, data_dir: Path) -> None:
        # Import before use: projections live only in the dedicated runtime directory.
        import winrt.windows.foundation  # noqa: F401
        import winrt.windows.foundation.collections  # noqa: F401
        import winrt.windows.media  # noqa: F401
        from winrt.windows.media.control import GlobalSystemMediaTransportControlsSessionManager
        from winrt.windows.storage.streams import InputStreamOptions

        self.manager_type = GlobalSystemMediaTransportControlsSessionManager
        self.stream_options = InputStreamOptions
        self.manager: Any = None
        self.art_path = data_dir / "media-art.bin"
        self.art_key: tuple[str, ...] | None = None
        self.art_info = {"artworkVersion": "", "artworkMime": "", "artworkBytes": 0}
        self.art_checked_at = 0.0

    async def connect(self) -> None:
        self.manager = await asyncio.wait_for(self.manager_type.request_async(), timeout=3.0)

    def select_session(self) -> tuple[Any, Any]:
        """Prefer current playback; a paused current session must not hide playing media."""
        current = self.manager.get_current_session()
        candidates = ([current] if current is not None else []) + list(self.manager.get_sessions())[:32]
        fallback = None
        for session in candidates:
            try:
                playback = session.get_playback_info()
                status = int(playback.playback_status)
                if status == 4:
                    return session, playback
                if status != 0 and fallback is None:
                    fallback = (session, playback)
            except OSError:
                continue
        return fallback if fallback is not None else (None, None)

    def timeline(self, session: Any, playback: Any) -> tuple[float, float]:
        try:
            timeline = session.get_timeline_properties()
            start = seconds(timeline.start_time)
            duration = max(0.0, seconds(timeline.end_time) - start)
            position = max(0.0, seconds(timeline.position) - start)
            if int(playback.playback_status) == 4 and duration > 0:
                updated = timeline.last_updated_time
                if isinstance(updated, datetime):
                    if updated.tzinfo is None:
                        updated = updated.replace(tzinfo=timezone.utc)
                    elapsed = max(0.0, (datetime.now(timezone.utc) - updated).total_seconds())
                    rate = playback.playback_rate
                    rate = float(rate) if rate is not None else 1.0
                    if math.isfinite(rate) and 0 < rate <= 16:
                        position += elapsed * rate
            if duration > 0:
                position = min(position, duration)
            return round(position, 3), round(duration, 3)
        except (OSError, AttributeError, TypeError, ValueError, OverflowError):
            return 0.0, 0.0

    async def artwork(self, properties: Any, key: tuple[str, ...]) -> dict[str, Any]:
        changed = key != self.art_key
        if changed:
            self.art_key = key
            self.art_info = {"artworkVersion": "", "artworkMime": "", "artworkBytes": 0}
            self.art_checked_at = 0.0
        # Retry initially missing art, and allow a provider to replace art for the same track.
        interval = 30.0 if self.art_info["artworkVersion"] else 5.0
        if time.monotonic() - self.art_checked_at < interval:
            return dict(self.art_info)
        self.art_checked_at = time.monotonic()
        try:
            thumbnail = properties.thumbnail
            if thumbnail is None:
                return dict(self.art_info)
            stream = await asyncio.wait_for(thumbnail.open_read_async(), timeout=1.5)
            with stream:
                size = int(stream.size)
                if not 0 < size <= MAX_ART_BYTES:
                    return dict(self.art_info)
                buffer = bytearray(size)
                result = await asyncio.wait_for(stream.read_async(buffer, size, self.stream_options.NONE), timeout=1.5)
                raw = bytes(result)
                mime = image_type(raw)
                if len(raw) != size or not mime:
                    return dict(self.art_info)
            version = hashlib.sha256(raw).hexdigest()
            if version != self.art_info["artworkVersion"]:
                await atomic_write(self.art_path, raw)
            self.art_info = {"artworkVersion": version, "artworkMime": mime, "artworkBytes": len(raw)}
        except (OSError, RuntimeError, AttributeError, TypeError, ValueError, asyncio.TimeoutError):
            # Artwork is optional; its failure must not hide valid title/artist/playback.
            pass
        return dict(self.art_info)

    async def snapshot(self) -> dict[str, Any]:
        if self.manager is None:
            await self.connect()
        session, playback = self.select_session()
        if session is None:
            self.art_key = None
            return empty_state()
        properties = await asyncio.wait_for(session.try_get_media_properties_async(), timeout=2.0)
        if properties is None:
            return empty_state("media_properties_unavailable")
        status = STATUS_NAMES.get(int(playback.playback_status), "Unknown")
        position, duration = self.timeline(session, playback)
        state = empty_state()
        state.update({
            "available": True, "playing": status == "Playing", "status": status,
            "title": text(properties.title), "artist": text(properties.artist),
            "album": text(properties.album_title), "source": text(session.source_app_user_model_id),
            "positionSeconds": position, "durationSeconds": duration
        })
        key = (state["source"], state["title"], state["artist"], state["album"])
        state.update(await self.artwork(properties, key))
        return state


async def run(args: argparse.Namespace) -> int:
    state_path = args.data_dir / "media-state.json"
    # A stopped/restarted helper must not leave an old playing snapshot as current.
    await publish_state(state_path, empty_state("starting"))
    try:
        reader = MediaReader(args.data_dir)
    except (ImportError, OSError, RuntimeError) as error:
        await publish_state(state_path, empty_state("runtime_unavailable"))
        print("Media runtime unavailable: " + type(error).__name__, file=sys.stderr)
        return 2
    failures = 0
    last_error = ""
    try:
        while True:
            started_at = time.monotonic()
            try:
                state = await reader.snapshot()
                failures = 0
                last_error = ""
            except (OSError, RuntimeError, AttributeError, TypeError, ValueError, asyncio.TimeoutError) as error:
                failures += 1
                state = empty_state("media_read_timeout" if isinstance(error, asyncio.TimeoutError) else "media_read_failed")
                if failures >= 3:
                    reader.manager = None
                # Do not print song metadata, credentials, or filesystem paths.
                error_name = type(error).__name__
                if error_name != last_error:
                    print("Windows media read failed: " + error_name, file=sys.stderr)
                    last_error = error_name
            await publish_state(state_path, state)
            await asyncio.sleep(max(0.1, args.interval - (time.monotonic() - started_at)))
    finally:
        await publish_state(state_path, empty_state("helper_stopped"))


def main() -> int:
    home = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Publish Windows media metadata for Edge Desk.")
    parser.add_argument("--runtime-dir", type=Path, default=home / ".media-runtime")
    parser.add_argument("--data-dir", type=Path, default=home / "data")
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("Windows is required.")
    if not math.isfinite(args.interval) or not 1.0 <= args.interval <= 10.0:
        parser.error("--interval must be between 1 and 10 seconds.")
    args.runtime_dir = args.runtime_dir.resolve()
    args.data_dir = args.data_dir.resolve()
    sys.path.insert(0, str(args.runtime_dir))
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
