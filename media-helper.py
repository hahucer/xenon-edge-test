"""Publish Windows GSMTC metadata and handle explicit dashboard controls.

Run with the same Python that installed media-requirements.txt into .media-runtime.
The launcher owns the PID, duplicate-process checks, and process shutdown. This
helper never launches media apps or changes Windows policy. Validated, short-lived
commands from the loopback bridge can control the exact displayed session/track.

Optional artwork is a fixed data/media-art.bin file, never an arbitrary path.
The bridge may expose GET /media-art?v=<artworkVersion>, using artworkMime and
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
import re
import sys
import tempfile
import time
from typing import Any


MAX_ART_BYTES = 2 * 1024 * 1024
MAX_TEXT = 1024
MAX_COMMAND_BYTES = 8192
MAX_COMMAND_RESULTS = 32
COMMAND_TTL_MS = 15_000
CONTROL_PROPERTIES = {
    "play": "is_play_enabled", "pause": "is_pause_enabled",
    "previous": "is_previous_enabled", "next": "is_next_enabled",
    "seek": "is_playback_position_enabled"
}
CONTROL_METHODS = {
    "play": "try_play_async", "pause": "try_pause_async",
    "previous": "try_skip_previous_async", "next": "try_skip_next_async"
}
COMMAND_REASONS = {
    "success", "unsupported", "track_changed", "no_session", "expired",
    "media_control_failed", "media_control_timeout"
}
STATUS_NAMES = {
    0: "Closed", 1: "Opened", 2: "Changing", 3: "Stopped",
    4: "Playing", 5: "Paused"
}


def now_ms() -> int:
    return time.time_ns() // 1_000_000


def text(value: Any) -> str:
    # The bridge validates .NET string lengths in UTF-16 code units. Keep
    # supplementary characters within that limit without cutting a surrogate pair.
    raw = str(value or "").encode("utf-16-le", errors="surrogatepass")
    return raw[:MAX_TEXT * 2].decode("utf-16-le", errors="ignore")


def track_token(source: str, title: str, artist: str, album: str) -> str:
    identity = json.dumps([source, title, artist, album], ensure_ascii=False,
                          allow_nan=False, separators=(",", ":"))
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def available_controls(playback: Any) -> dict[str, bool]:
    controls = getattr(playback, "controls", None)
    flags = {action: bool(getattr(controls, property_name, False))
             for action, property_name in CONTROL_PROPERTIES.items()}
    # Some providers briefly disable the direct button while switching states,
    # or expose only the Windows play/pause toggle capability.
    toggle = bool(getattr(controls, "is_play_pause_toggle_enabled", False))
    flags["play"] = flags["play"] or toggle
    flags["pause"] = flags["pause"] or toggle
    return flags


def desired_playback(action: str, status: int) -> bool:
    return (action == "play" and status == 4) or (action == "pause" and status in (3, 5))


def empty_state(reason: str = "") -> dict[str, Any]:
    return {
        "schema": 1, "updatedAt": now_ms(), "bridge": True,
        "helper": True, "available": False, "playing": False,
        "status": "Stopped", "title": "", "artist": "", "album": "",
        "source": "", "positionSeconds": 0, "durationSeconds": 0,
        "reason": reason, "stale": False,
        "trackToken": "", "controls": {action: False for action in CONTROL_PROPERTIES},
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
        self.manager_lock = asyncio.Lock()
        self.refresh = asyncio.Event()
        self.change_generation = 0
        self.art_path = data_dir / "media-art.bin"
        self.art_key: tuple[str, ...] | None = None
        self.art_info = {"artworkVersion": "", "artworkMime": "", "artworkBytes": 0}
        self.art_checked_at = 0.0
        self.art_task: asyncio.Task[None] | None = None
        self.art_generation = 0
        self.transport_key: tuple[str, str] | None = None
        self.transport_action = ""
        self.transport_accepted_at = 0.0
        self.transport_settled = True

    async def connect(self) -> None:
        async with self.manager_lock:
            if self.manager is None:
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

    def cached_artwork(self, properties: Any, key: tuple[str, ...]) -> dict[str, Any]:
        """Return immediately; optional artwork never delays fresh playback state."""
        if key != self.art_key:
            if self.art_task is not None and not self.art_task.done():
                self.art_task.cancel()
            self.art_task = None
            self.art_key = key
            self.art_info = {"artworkVersion": "", "artworkMime": "", "artworkBytes": 0}
            self.art_checked_at = 0.0
        if self.art_task is not None and not self.art_task.done():
            if self.art_generation == self.change_generation:
                return dict(self.art_info)
            self.art_task.cancel()
            self.art_task = None
            if not self.art_info["artworkVersion"]:
                self.art_checked_at = 0.0
        # Retry initially missing art, and allow a provider to replace art for the same track.
        interval = 30.0 if self.art_info["artworkVersion"] else 5.0
        if time.monotonic() - self.art_checked_at >= interval:
            self.art_checked_at = time.monotonic()
            self.art_generation = self.change_generation
            self.art_task = asyncio.create_task(self.artwork(properties, key, self.art_generation))
        return dict(self.art_info)

    async def artwork(self, properties: Any, key: tuple[str, ...], generation: int) -> None:
        try:
            thumbnail = properties.thumbnail
            if thumbnail is None:
                return
            stream = await asyncio.wait_for(thumbnail.open_read_async(), timeout=1.5)
            with stream:
                size = int(stream.size)
                if not 0 < size <= MAX_ART_BYTES:
                    return
                buffer = bytearray(size)
                result = await asyncio.wait_for(stream.read_async(buffer, size, self.stream_options.NONE), timeout=1.5)
                raw = bytes(result)
                mime = image_type(raw)
                if len(raw) != size or not mime:
                    return
            # Discard an old optional fetch if the track or a command changed while
            # its asynchronous stream was being read.
            if key != self.art_key or generation != self.change_generation:
                return
            version = hashlib.sha256(raw).hexdigest()
            if version != self.art_info["artworkVersion"]:
                await atomic_write(self.art_path, raw)
            if key != self.art_key or generation != self.change_generation:
                return
            changed = version != self.art_info["artworkVersion"]
            self.art_info = {"artworkVersion": version, "artworkMime": mime, "artworkBytes": len(raw)}
            if changed:
                self.refresh.set()
        except (OSError, RuntimeError, AttributeError, TypeError, ValueError, asyncio.TimeoutError):
            # Artwork is optional; its failure must not hide valid title/artist/playback.
            pass

    async def snapshot(self) -> dict[str, Any]:
        if self.manager is None:
            await self.connect()
        session, playback = self.select_session()
        if session is None:
            if self.art_task is not None and not self.art_task.done():
                self.art_task.cancel()
            self.art_key = None
            self.art_info = {"artworkVersion": "", "artworkMime": "", "artworkBytes": 0}
            return empty_state()
        properties = await asyncio.wait_for(session.try_get_media_properties_async(), timeout=2.0)
        if properties is None:
            return empty_state("media_properties_unavailable")
        # Get playback state after the async metadata read: a quick pause/resume
        # may have happened while the provider was returning its song details.
        playback = session.get_playback_info()
        status = STATUS_NAMES.get(int(playback.playback_status), "Unknown")
        position, duration = self.timeline(session, playback)
        state = empty_state()
        state.update({
            "available": True, "playing": status == "Playing", "status": status,
            "title": text(properties.title), "artist": text(properties.artist),
            "album": text(properties.album_title), "source": text(session.source_app_user_model_id),
            "positionSeconds": position, "durationSeconds": duration,
            "controls": available_controls(playback)
        })
        key = (state["source"], state["title"], state["artist"], state["album"])
        state["trackToken"] = track_token(*key)
        state.update(self.cached_artwork(properties, key))
        return state

    async def control(self, command: dict[str, Any]) -> str:
        """Check fresh provider capabilities and track identity before one action."""
        if self.manager is None:
            await self.connect()
        session, _ = self.select_session()
        if session is None:
            return "no_session"
        source = text(session.source_app_user_model_id)
        if source != command["source"]:
            return "track_changed"
        properties = await session.try_get_media_properties_async()
        if properties is None:
            return "media_control_failed"
        identity = track_token(source, text(properties.title), text(properties.artist),
                               text(properties.album_title))
        if identity != command["trackToken"]:
            return "track_changed"
        # Metadata reads may take time. Recheck expiry and current capability now.
        if now_ms() - command["createdAt"] > COMMAND_TTL_MS:
            return "expired"
        playback = session.get_playback_info()
        action = command["action"]
        status = int(playback.playback_status)
        controls = getattr(playback, "controls", None)
        direct = bool(getattr(controls, CONTROL_PROPERTIES[action], False))
        if action in ("play", "pause"):
            # Providers can temporarily report Changing or disable every button
            # just after an acknowledged pause/resume. Give that transition a
            # short chance to settle inside the command's overall 3 s budget.
            retry_deadline = time.monotonic() + 0.8
            pending_reverse = (self.transport_key == (command["source"], command["trackToken"])
                               and self.transport_action != action and not self.transport_settled
                               and time.monotonic() - self.transport_accepted_at < 3.0)
            while True:
                playback = session.get_playback_info()
                status = int(playback.playback_status)
                controls = getattr(playback, "controls", None)
                direct = bool(getattr(controls, CONTROL_PROPERTIES[action], False))
                toggle = bool(getattr(controls, "is_play_pause_toggle_enabled", False))
                stable_opposite = status in (1, 3, 5) if action == "play" else status == 4
                # Explicit play/pause safely reasserts the desired state even
                # when the provider still reports the previous command's state.
                if status != 2 and direct:
                    break
                if pending_reverse and desired_playback(self.transport_action, status):
                    self.transport_settled = True
                    pending_reverse = False
                if not pending_reverse:
                    if desired_playback(action, status):
                        return "success"
                    if status != 2 and toggle and stable_opposite:
                        break
                if time.monotonic() >= retry_deadline:
                    return "media_control_timeout" if pending_reverse else "unsupported"
                await asyncio.sleep(0.1)
                # Every retry followed an await. Revalidate the selected source
                # and song before allowing either a noop or a toggle next time.
                current, _ = self.select_session()
                if current is None:
                    return "no_session"
                if text(current.source_app_user_model_id) != command["source"]:
                    return "track_changed"
                session = current
                properties = await session.try_get_media_properties_async()
                if properties is None:
                    return "media_control_failed"
                identity = track_token(text(session.source_app_user_model_id), text(properties.title),
                                       text(properties.artist), text(properties.album_title))
                if identity != command["trackToken"]:
                    return "track_changed"
                if now_ms() - command["createdAt"] > COMMAND_TTL_MS:
                    return "expired"
            if not direct:
                accepted = await session.try_toggle_play_pause_async()
                return await self.transport_result(session, command, accepted)
        if not direct:
            return "unsupported"
        if action == "seek":
            timeline = session.get_timeline_properties()
            start = seconds(timeline.start_time)
            end = seconds(timeline.end_time)
            duration = max(0.0, end - start)
            if duration <= 0:
                return "unsupported"
            requested = start + min(duration, max(0.0, command["positionSeconds"]))
            minimum = seconds(timeline.min_seek_time)
            maximum = seconds(timeline.max_seek_time)
            if maximum > minimum:
                lower = max(start, minimum)
                upper = min(end, maximum)
                if upper <= lower:
                    return "unsupported"
                requested = min(upper, max(lower, requested))
            # Windows TimeSpan ticks are 100 ns; timeline start need not be zero.
            ticks = int(round(requested * 10_000_000))
            if not -(2 ** 63) <= ticks < 2 ** 63:
                return "media_control_failed"
            accepted = await session.try_change_playback_position_async(ticks)
        else:
            accepted = await getattr(session, CONTROL_METHODS[action])()
        if action in ("play", "pause"):
            return await self.transport_result(session, command, accepted)
        return "success" if accepted is True else "media_control_failed"

    async def transport_result(self, session: Any, command: dict[str, Any], accepted: bool) -> str:
        if accepted is not True:
            return "media_control_failed"
        self.transport_key = (command["source"], command["trackToken"])
        self.transport_action = command["action"]
        self.transport_accepted_at = time.monotonic()
        self.transport_settled = False
        self.change_generation += 1
        self.refresh.set()
        # Acknowledgement of the Windows call can precede the provider's state
        # update. Observe it briefly before allowing a quick reverse command.
        deadline = time.monotonic() + 0.8
        while True:
            status = int(session.get_playback_info().playback_status)
            if desired_playback(command["action"], status):
                self.transport_settled = True
                self.refresh.set()
                break
            if time.monotonic() >= deadline:
                break
            await asyncio.sleep(0.05)
        return "success"


class MediaCommands:
    """Serial private-file queue: each action is claimed before any Windows call."""

    def __init__(self, data_dir: Path, reader: MediaReader) -> None:
        self.directory = data_dir / "media-commands"
        self.directory.mkdir(parents=True, exist_ok=True)
        self.results_path = data_dir / "media-control-results.json"
        self.reader = reader
        self.results: list[dict[str, Any]] = []
        try:
            if self.results_path.stat().st_size <= 32768:
                saved = json.loads(self.results_path.read_text(encoding="utf-8"))
                if saved.get("schema") == 1 and isinstance(saved.get("results"), list):
                    for item in saved["results"][-MAX_COMMAND_RESULTS:]:
                        if (isinstance(item, dict) and re.fullmatch(r"[0-9a-f]{32}", str(item.get("id", "")))
                                and type(item.get("ok")) is bool
                                and item.get("reason") in COMMAND_REASONS
                                and type(item.get("completedAt")) is int
                                and 0 < item["completedAt"] <= 253402300799999):
                            self.results.append({key: item[key] for key in ("id", "ok", "reason", "completedAt")})
        except (OSError, UnicodeError, ValueError, AttributeError, TypeError):
            pass

    async def save_result(self, command_id: str, reason: str) -> None:
        self.results = [item for item in self.results if item["id"] != command_id]
        self.results.append({"id": command_id, "ok": reason == "success", "reason": reason,
                             "completedAt": now_ms()})
        self.results = self.results[-MAX_COMMAND_RESULTS:]
        payload = json.dumps({"schema": 1, "results": self.results}, ensure_ascii=False,
                             allow_nan=False, separators=(",", ":")).encode("utf-8")
        await atomic_write(self.results_path, payload)

    def read_command(self, path: Path, command_id: str) -> dict[str, Any] | None:
        if path.is_symlink() or not 0 < path.stat().st_size <= MAX_COMMAND_BYTES:
            return None
        command = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(command, dict):
            return None
        action = command.get("action")
        keys = {"schema", "id", "action", "source", "trackToken", "createdAt"}
        if action == "seek":
            keys.add("positionSeconds")
        if (set(command) != keys or type(command.get("schema")) is not int or command["schema"] != 1
                or command.get("id") != command_id or action not in CONTROL_PROPERTIES
                or not isinstance(command.get("source"), str) or not 0 < len(command["source"]) <= MAX_TEXT
                or not isinstance(command.get("trackToken"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", command["trackToken"])
                or type(command.get("createdAt")) is not int
                or not 0 < command["createdAt"] <= 253402300799999):
            return None
        if action == "seek":
            position = command.get("positionSeconds")
            if (type(position) not in (int, float) or not math.isfinite(position)
                    or not 0 <= position <= 31_536_000):
                return None
        return command

    async def finish(self, path: Path, command_id: str, reason: str) -> None:
        await self.save_result(command_id, reason)
        path.unlink(missing_ok=True)

    async def discard_interrupted(self) -> None:
        # Never replay a claimed action after restart: it may already have happened.
        for path in self.directory.glob("*.working"):
            if re.fullmatch(r"[0-9a-f]{32}", path.stem):
                previous = next((item for item in self.results if item["id"] == path.stem), None)
                await self.finish(path, path.stem,
                                  previous["reason"] if previous else "media_control_failed")

    async def process(self, path: Path) -> None:
        command_id = path.stem
        if not re.fullmatch(r"[0-9a-f]{32}", command_id) or path.is_symlink():
            return
        working = path.with_suffix(".working")
        if working.exists():
            return
        try:
            path.rename(working)
        except (FileNotFoundError, FileExistsError, PermissionError):
            return
        previous = next((item for item in self.results if item["id"] == command_id), None)
        if previous is not None:
            await self.finish(working, command_id, previous["reason"])
            return
        try:
            command = self.read_command(working, command_id)
            age = now_ms() - command["createdAt"] if command else 0
            if command is None:
                reason = "media_control_failed"
            elif age > COMMAND_TTL_MS or age < -5000:
                reason = "expired"
            else:
                try:
                    reason = await asyncio.wait_for(self.reader.control(command), timeout=3.0)
                except asyncio.TimeoutError:
                    reason = "media_control_timeout"
                except (OSError, RuntimeError, AttributeError, TypeError, ValueError, OverflowError):
                    reason = "media_control_failed"
                # Ask the independent metadata loop for a fresh snapshot, including
                # on timeout: the provider may have accepted an action late.
                self.reader.change_generation += 1
                self.reader.refresh.set()
        except (OSError, UnicodeError, ValueError, TypeError):
            reason = "media_control_failed"
        await self.finish(working, command_id, reason)

    async def run(self) -> None:
        while True:
            try:
                await self.discard_interrupted()
                break
            except OSError as error:
                print("Media command recovery failed: " + type(error).__name__, file=sys.stderr)
                await asyncio.sleep(1.0)
        while True:
            try:
                pending = sorted(self.directory.glob("*.json"), key=lambda item: item.stat().st_mtime_ns)
                for path in pending[:64]:
                    await self.process(path)
            except (OSError, ValueError, TypeError) as error:
                # Preserve .working if acknowledgement could not be published.
                # The command remains claimed and is never executed again.
                print("Media command storage failed: " + type(error).__name__, file=sys.stderr)
            await asyncio.sleep(0.15)


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
    commands = MediaCommands(args.data_dir, reader)
    command_task = asyncio.create_task(commands.run())
    try:
        while True:
            started_at = time.monotonic()
            reader.refresh.clear()
            generation = reader.change_generation
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
            if generation != reader.change_generation:
                continue
            await publish_state(state_path, state)
            try:
                await asyncio.wait_for(reader.refresh.wait(),
                                       timeout=max(0.1, args.interval - (time.monotonic() - started_at)))
            except asyncio.TimeoutError:
                pass
    finally:
        command_task.cancel()
        try:
            await command_task
        except asyncio.CancelledError:
            pass
        if reader.art_task is not None:
            reader.art_task.cancel()
            try:
                await reader.art_task
            except asyncio.CancelledError:
                pass
        await publish_state(state_path, empty_state("helper_stopped"))


def main() -> int:
    home = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Publish Windows media metadata and apply Edge Desk controls.")
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
