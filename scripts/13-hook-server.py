#!/usr/bin/env python3
# Step 13: Claude Inference hooks verdict server (AI security server).
# Receives signed POSTs from Anthropic (via Kong), verifies the Standard Webhooks
# signature, evaluates a demo policy, and answers {"action":"allow"|"deny",...}.
#
# Env (secrets/hook.env):
#   HOOK_SIGNING_SECRET  whsec_... shown ONCE in claude.ai when the endpoint is saved
#   HOOK_MODE            enforce | alert | off   (default: alert)
#     enforce -> policy hits return a deny verdict
#     alert   -> policy hits are logged as ALERT but the verdict is allow
#     off     -> policy is skipped, everything is allowed (signature still checked)
#   HOOK_PORT            listen port (default 8200)
#
# Rules that matter (platform.claude.com/docs/en/manage-claude/inference-hooks-endpoint):
# - Always HTTP 200 with a JSON verdict. A non-200 is a webhook FAILURE, not a deny.
# - Unknown top-level "type" -> allow (forward compatibility).
# - Verify HMAC over the RAW body bytes; decode the secret with STANDARD base64.
# - Bodies can be large (up to 64 MiB); drain them even when rejecting.
import base64
import collections
import hashlib
import hmac
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("HOOK_SIGNING_SECRET", "")
MODE = os.environ.get("HOOK_MODE", "alert").lower()
PORT = int(os.environ.get("HOOK_PORT", "8200"))
ALLOW_UNSIGNED = os.environ.get("HOOK_ALLOW_UNSIGNED", "") == "1"  # local tests only
TOLERANCE_SECONDS = 300
MAX_BODY = 64 * 1024 * 1024  # Anthropic sends up to 64 MiB; anything larger isn't them

# Connection-failure retries reuse the same webhook-id: answer them with the same
# verdict instead of logging the event twice.
SEEN_LOCK = threading.Lock()
SEEN = collections.OrderedDict()  # webhook-id -> verdict bytes
SEEN_MAX = 4096

# Demo policy: things that must never leave for the model. Replace with the real engine.
POLICY = [
    ("payment card number", re.compile(r"\b(?:\d[ -]?){13,16}\b")),
    ("AWS secret access key", re.compile(r"\b[A-Za-z0-9/+=]{40}\b")),
    ("internal marker", re.compile(r"\bCVS-CONFIDENTIAL\b", re.I)),
]


def verify(headers, body: bytes) -> bool:
    lowered = {k.lower(): v for k, v in headers.items()}
    try:
        message_id = lowered["webhook-id"]
        timestamp = lowered["webhook-timestamp"]
        signatures = lowered["webhook-signature"]
    except KeyError:
        return False  # unsigned: not from Anthropic
    try:
        signed_at = int(timestamp)
    except ValueError:
        return False
    if abs(time.time() - signed_at) > TOLERANCE_SECONDS:
        return False  # replayed, or clocks disagree
    try:
        key = base64.b64decode(SECRET.removeprefix("whsec_"), validate=True)
    except ValueError:
        return False
    payload = f"{message_id}.{timestamp}.".encode() + body
    expected = b"v1," + base64.b64encode(hmac.new(key, payload, hashlib.sha256).digest())
    return any(hmac.compare_digest(expected, c.encode()) for c in signatures.split())


def transcript_text(frame: dict) -> str:
    parts = []
    for message in frame.get("messages", []):
        if not isinstance(message, dict):
            continue
        content = message.get("content", [])
        if isinstance(content, str):  # tolerate string-form content
            parts.append(content)
            continue
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict):
                continue
            for field in ("text", "content"):
                value = block.get(field)
                if isinstance(value, str):
                    parts.append(value)
            if block.get("type") == "tool_use":
                parts.append(json.dumps(block.get("input", {}), ensure_ascii=False))
    return "\n".join(parts)


def decide(frame: dict) -> dict:
    if MODE == "off":
        return {"action": "allow"}
    if frame.get("type") not in ("prompt", "tool_call"):
        return {"action": "allow"}  # unknown future event type: never error on it
    text = transcript_text(frame)
    for label, pattern in POLICY:
        if pattern.search(text):
            reference = f"hook:{frame.get('request_id', 'unknown')}"
            log("ALERT" if MODE == "alert" else "DENY", frame, label, reference)
            if MODE == "alert":
                return {"action": "allow"}
            return {
                "action": "deny",
                "deny_reason": f"Blocked by policy: the request appears to contain {label}. "
                               "Remove it and try again.",
                "reference_id": reference,
            }
    return {"action": "allow"}


def log(kind, frame, label="", reference=""):
    print(json.dumps({
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "kind": kind, "mode": MODE, "label": label, "reference_id": reference,
        "type": frame.get("type"), "request_id": frame.get("request_id"),
        "source": (frame.get("source") or {}).get("application"),
        "actor": ((frame.get("actor") or {}).get("email_address")),
        "model": frame.get("model"), "session_id": frame.get("session_id"),
    }, ensure_ascii=False), flush=True)


class VerdictHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep the connection open between verdicts
    timeout = 30  # drop stalled connections instead of pinning a thread

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY:
            self.answer(413, b'{"error": "body too large"}')
            return
        body = self.rfile.read(length)
        if SECRET and not verify(self.headers, body):
            # Bad signature: genuinely not Anthropic, so a 401 (webhook failure) is right.
            self.answer(401, b'{"error": "bad signature"}')
            return
        webhook_id = self.headers.get("webhook-id")
        if webhook_id:
            with SEEN_LOCK:
                cached = SEEN.get(webhook_id)
            if cached is not None:
                self.answer(200, cached)
                return
        try:
            frame = json.loads(body)
        except ValueError:
            frame = {}
        if not isinstance(frame, dict):
            frame = {}
        verdict = decide(frame)
        log("verdict:" + verdict["action"], frame)
        payload = json.dumps(verdict).encode()
        if webhook_id:
            with SEEN_LOCK:
                SEEN[webhook_id] = payload
                while len(SEEN) > SEEN_MAX:
                    SEEN.popitem(last=False)
        self.answer(200, payload)

    def do_GET(self):  # health check for the Kong upstream / ALB target group
        self.answer(200, b'{"status": "ok", "mode": "' + MODE.encode() + b'"}')

    def answer(self, status, payload):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass  # JSON lines above are the access log


if __name__ == "__main__":
    if MODE not in ("enforce", "alert", "off"):
        sys.exit(f"HOOK_MODE must be enforce|alert|off, got {MODE!r}")
    if not SECRET and not ALLOW_UNSIGNED:
        sys.exit("HOOK_SIGNING_SECRET is empty. Set it, or HOOK_ALLOW_UNSIGNED=1 for local tests.")
    if not SECRET:
        print("WARNING: accepting unsigned requests (HOOK_ALLOW_UNSIGNED=1, test only)",
              file=sys.stderr)
    print(f"verdict server on :{PORT}, mode={MODE}", file=sys.stderr)
    ThreadingHTTPServer(("", PORT), VerdictHandler).serve_forever()
