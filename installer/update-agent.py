#!/usr/bin/env python3
from __future__ import annotations

import hmac
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BIND = os.environ.get("MEDIA_VISION_UPDATE_BIND", "127.0.0.1")
PORT = int(os.environ.get("MEDIA_VISION_UPDATE_PORT", "18991"))
COMPOSE_FILE = Path(os.environ.get("MEDIA_VISION_UPDATE_COMPOSE_FILE", "/opt/media-vision/compose.yml"))
ENV_FILE = Path(os.environ.get("MEDIA_VISION_UPDATE_ENV_FILE", "/opt/media-vision/media-vision.env"))
SECRET_FILE = Path(os.environ.get("MEDIA_VISION_UPDATE_SECRET_FILE", "/opt/media-vision/secrets/update_agent_key"))
HEALTH_URL = os.environ.get("MEDIA_VISION_UPDATE_HEALTH_URL", "http://127.0.0.1:8989/ping")
ALLOWED_IMAGE = os.environ.get("MEDIA_VISION_UPDATE_ALLOWED_IMAGE", "ghcr.io/zemerdon/media-vision")
HEALTH_TIMEOUT = int(os.environ.get("MEDIA_VISION_UPDATE_HEALTH_TIMEOUT", "120"))
CONTAINER_NAME = os.environ.get("MEDIA_VISION_UPDATE_CONTAINER", "media-vision")

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){2,3}$")

_state_lock = threading.Lock()
_update_lock = threading.Lock()
_state = {
    "status": "idle",
    "version": None,
    "target": None,
    "previous": None,
    "error": None,
    "updatedAt": None,
}


def _read_secret() -> str:
    value = SECRET_FILE.read_text(encoding="utf-8").strip()
    if not value:
        raise RuntimeError("update-agent secret is empty")
    return value


def _set_state(**values) -> None:
    with _state_lock:
        _state.update(values)
        _state["updatedAt"] = time.time()


def _get_state() -> dict:
    with _state_lock:
        return dict(_state)


def _run(*args: str) -> None:
    subprocess.run(args, check=True)


def _compose(*args: str) -> None:
    _run(
        "docker",
        "compose",
        "--env-file",
        str(ENV_FILE),
        "-f",
        str(COMPOSE_FILE),
        *args,
    )


def _read_env() -> list[str]:
    return ENV_FILE.read_text(encoding="utf-8").splitlines()


def _configured_image() -> str | None:
    for line in _read_env():
        if line.startswith("MEDIA_VISION_IMAGE="):
            return line.split("=", 1)[1].strip()
    return None


def _current_image() -> str | None:
    try:
        image_id = subprocess.run(
            ["docker", "inspect", CONTAINER_NAME, "--format", "{{.Image}}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        repo_digests_json = subprocess.run(
            [
                "docker",
                "image",
                "inspect",
                image_id,
                "--format",
                "{{json .RepoDigests}}",
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

        for repo_digest in json.loads(repo_digests_json or "[]"):
            if repo_digest.startswith(ALLOWED_IMAGE + "@"):
                return repo_digest
    except (subprocess.CalledProcessError, json.JSONDecodeError, TypeError):
        pass

    configured = _configured_image()
    if configured and configured.startswith(ALLOWED_IMAGE + "@"):
        return configured

    return configured


def _write_image(image: str) -> None:
    lines = _read_env()
    replaced = False
    output: list[str] = []

    for line in lines:
        if line.startswith("MEDIA_VISION_IMAGE="):
            output.append(f"MEDIA_VISION_IMAGE={image}")
            replaced = True
        else:
            output.append(line)

    if not replaced:
        output.append(f"MEDIA_VISION_IMAGE={image}")

    mode = ENV_FILE.stat().st_mode & 0o777
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=ENV_FILE.parent,
        prefix=ENV_FILE.name + ".",
        suffix=".tmp",
        delete=False,
    ) as handle:
        handle.write("\n".join(output) + "\n")
        temp_name = Path(handle.name)

    os.chmod(temp_name, mode)
    os.replace(temp_name, ENV_FILE)


def _healthy() -> bool:
    try:
        with urllib.request.urlopen(HEALTH_URL, timeout=5) as response:
            return 200 <= response.status < 300
    except Exception:
        return False


def _wait_for_health(timeout: int = HEALTH_TIMEOUT) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _healthy():
            return True
        time.sleep(2)
    return False


def _perform_update(version: str, image: str, digest: str) -> None:
    target = f"{image}@{digest}"
    previous = _current_image()

    _set_state(
        status="updating",
        version=version,
        target=target,
        previous=previous,
        error=None,
    )

    try:
        _write_image(target)
        _compose("pull")
        _compose("up", "-d", "--force-recreate")

        if not _wait_for_health():
            raise RuntimeError("updated Media Vision container did not become healthy")

        _set_state(status="healthy")
    except Exception as update_error:
        rollback_error = None

        try:
            if previous:
                _write_image(previous)
                _compose("pull")
                _compose("up", "-d", "--force-recreate")

                if not _wait_for_health():
                    raise RuntimeError("rollback container did not become healthy")
        except Exception as error:
            rollback_error = error

        if rollback_error is None:
            _set_state(
                status="rolled-back",
                error=str(update_error),
            )
        else:
            _set_state(
                status="failed",
                error=f"{update_error}; rollback failed: {rollback_error}",
            )
    finally:
        _update_lock.release()


def _validate_request(payload: dict) -> tuple[str, str, str]:
    version = str(payload.get("version", ""))
    image = str(payload.get("image", ""))
    digest = str(payload.get("digest", ""))

    if not VERSION_RE.fullmatch(version):
        raise ValueError("invalid version")

    if image != ALLOWED_IMAGE:
        raise ValueError("image is not the configured Media Vision end-user image")

    if not DIGEST_RE.fullmatch(digest):
        raise ValueError("invalid immutable container digest")

    return version, image, digest


class Handler(BaseHTTPRequestHandler):
    server_version = "MediaVisionUpdateAgent/1"

    def log_message(self, fmt: str, *args) -> None:
        print(fmt % args, flush=True)

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._json(200, {"status": "ok"})
            return

        if self.path == "/v1/status":
            self._json(200, _get_state())
            return

        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/v1/update":
            self._json(404, {"error": "not found"})
            return

        expected = "Bearer " + _read_secret()
        supplied = self.headers.get("Authorization", "")

        if not hmac.compare_digest(supplied, expected):
            self._json(401, {"error": "unauthorized"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0 or content_length > 8192:
                raise ValueError("invalid request size")

            payload = json.loads(self.rfile.read(content_length).decode("utf-8"))
            version, image, digest = _validate_request(payload)
        except (ValueError, json.JSONDecodeError) as error:
            self._json(400, {"error": str(error)})
            return

        if not _update_lock.acquire(blocking=False):
            self._json(409, {"error": "update already in progress"})
            return

        worker = threading.Thread(
            target=_perform_update,
            args=(version, image, digest),
            daemon=True,
        )
        worker.start()

        self._json(
            202,
            {
                "status": "accepted",
                "version": version,
                "image": image,
                "digest": digest,
            },
        )


def main() -> int:
    if BIND not in {"127.0.0.1", "::1"}:
        raise RuntimeError("Media Vision update agent must bind to loopback")

    if not COMPOSE_FILE.is_file():
        raise RuntimeError(f"compose file does not exist: {COMPOSE_FILE}")
    if not ENV_FILE.is_file():
        raise RuntimeError(f"environment file does not exist: {ENV_FILE}")
    if not SECRET_FILE.is_file():
        raise RuntimeError(f"secret file does not exist: {SECRET_FILE}")

    server = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"Media Vision update agent listening on {BIND}:{PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
