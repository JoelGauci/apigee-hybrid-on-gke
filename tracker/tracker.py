#!/usr/bin/env python3
"""Lightweight task progress tracker and web server for Apigee Hybrid deployment.

Provides CLI commands matching the lab-bootstrap workflow:
  - tracker.py init <mode>
  - tracker.py begin <task_id> <task_name> <eta_seconds>
  - tracker.py end <task_id>
  - tracker.py fail <task_id>
  - tracker.py serve [--host HOST] [--port PORT]
  - tracker.py monitor
"""

import argparse
import http.server
import json
import os
import socketserver
import sys
import tempfile
import time
from pathlib import Path

TRACKER_DIR = Path(__file__).resolve().parent
STATUS_FILE = TRACKER_DIR / "status.json"

PREDEFINED_TASKS = {
    "full": [
        ("setup-project", "Prepare GCP project & enable APIs", 60),
        ("setup-gke", "Create GKE cluster & node pools", 600),
        ("create-org", "Create Apigee hybrid organization", 180),
        ("create-ip", "Reserve external IP address for ingress", 30),
        ("create-env", "Create Apigee environment & env group", 120),
        ("download-charts", "Download Apigee hybrid Helm charts", 45),
        ("create-ns", "Create Kubernetes apigee namespace", 10),
        ("create-sa", "Create GCP Service Accounts", 300),
        ("setup-wif", "Configure Workload Identity bindings", 150),
        ("create-certs", "Generate TLS certificates", 15),
        ("create-overrides", "Create & configure overrides.yaml", 10),
        ("enable-cpa", "Enable Control Plane access", 30),
        ("install-certmgr", "Install cert-manager on GKE", 90),
        ("install-crds", "Install Apigee hybrid CRDs", 30),
        ("helm-operator", "Install Apigee Operator (Helm)", 120),
        ("helm-datastore", "Install Apigee Cassandra Datastore (Helm)", 480),
        ("helm-telemetry", "Install Apigee Telemetry (Helm)", 90),
        ("helm-redis", "Install Apigee Redis (Helm)", 120),
        ("helm-ingress", "Install Apigee Ingress Manager (Helm)", 90),
        ("helm-org", "Install Apigee Organization (Helm)", 180),
        ("helm-env", "Install Apigee Environment (Helm)", 240),
        ("helm-envgroup", "Install Apigee Env Group / Virtualhost (Helm)", 120),
    ],
    "full-mcp": [
        ("setup-project", "Prepare GCP project & enable APIs", 60),
        ("setup-gke", "Create GKE cluster & node pools", 600),
        ("create-org", "Create Apigee hybrid organization", 180),
        ("create-ip", "Reserve external IP address for ingress", 30),
        ("create-env", "Create Apigee environment & env group", 120),
        ("download-charts", "Download Apigee hybrid Helm charts", 45),
        ("create-ns", "Create Kubernetes apigee namespace", 10),
        ("create-sa", "Create GCP Service Accounts", 300),
        ("setup-wif", "Configure Workload Identity bindings", 150),
        ("create-certs", "Generate TLS certificates", 15),
        ("create-overrides", "Create & configure overrides.yaml (MCP enabled)", 10),
        ("enable-cpa", "Enable Control Plane & MCP watcher access", 30),
        ("install-certmgr", "Install cert-manager on GKE", 90),
        ("install-crds", "Install Apigee hybrid CRDs", 30),
        ("helm-operator", "Install Apigee Operator (Helm)", 120),
        ("helm-datastore", "Install Apigee Cassandra Datastore (Helm)", 480),
        ("helm-telemetry", "Install Apigee Telemetry (Helm)", 90),
        ("helm-redis", "Install Apigee Redis (Helm)", 120),
        ("helm-ingress", "Install Apigee Ingress Manager (Helm)", 90),
        ("helm-org", "Install Apigee Organization (Helm)", 180),
        ("helm-env", "Install Apigee Environment (Helm)", 240),
        ("helm-envgroup", "Install Apigee Env Group / Virtualhost (Helm)", 120),
        ("verify-mcp", "Verify Apigee MCP Server installation", 120),
    ],
    "mcp-only": [
        ("mcp-version", "Check Apigee Hybrid version & Helm charts", 30),
        ("mcp-creds", "Fetch GKE cluster credentials", 15),
        ("mcp-overrides", "Configure enableMcpServer in overrides.yaml", 10),
        ("mcp-cpa", "Grant watcher identity access on Control Plane", 30),
        ("mcp-wif", "Ensure Workload Identity bindings for MCP", 30),
        ("mcp-helm", "Upgrade apigee-operator and apigee-org charts", 180),
        ("mcp-verify", "Verify MCP installation & MP hostAliases", 120),
    ],
}


def load_status():
    if not STATUS_FILE.exists():
        return {
            "title": "- Lab Startup Tasks -",
            "updated_at": time.time(),
            "tasks": [],
        }
    try:
        with open(STATUS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {
            "title": "- Lab Startup Tasks -",
            "updated_at": time.time(),
            "tasks": [],
        }


def save_status(data):
    data["updated_at"] = time.time()
    TRACKER_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=str(TRACKER_DIR), prefix=".status_", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, STATUS_FILE)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


def cmd_init(mode, title):
    tasks_spec = PREDEFINED_TASKS.get(mode, [])
    tasks = []
    for task_id, task_name, eta in tasks_spec:
        tasks.append({
            "id": task_id,
            "name": task_name,
            "eta": int(eta),
            "state": "pending",
            "start_time": None,
            "end_time": None,
            "elapsed": 0,
        })
    data = {
        "title": title or "- Lab Startup Tasks -",
        "mode": mode,
        "started_at": time.time(),
        "updated_at": time.time(),
        "tasks": tasks,
    }
    save_status(data)


def cmd_begin(task_id, task_name, eta):
    now = time.time()
    data = load_status()
    tasks = data.setdefault("tasks", [])

    # Automatically complete any previous task still marked as in-progress
    for t in tasks:
        if t.get("state") == "in-progress" and t.get("id") != task_id:
            t["state"] = "completed"
            t["end_time"] = now
            if t.get("start_time"):
                t["elapsed"] = max(0, int(round(now - t["start_time"])))

    target = None
    for t in tasks:
        if t.get("id") == task_id:
            target = t
            break

    if target is None:
        target = {
            "id": task_id,
            "name": task_name,
            "eta": int(eta),
            "state": "in-progress",
            "start_time": now,
            "end_time": None,
            "elapsed": 0,
        }
        tasks.append(target)
    else:
        if task_name:
            target["name"] = task_name
        if eta:
            target["eta"] = int(eta)
        target["state"] = "in-progress"
        target["start_time"] = now
        target["end_time"] = None
        target["elapsed"] = 0

    save_status(data)


def cmd_end(task_id):
    now = time.time()
    data = load_status()
    for t in data.get("tasks", []):
        if t.get("id") == task_id:
            t["state"] = "completed"
            t["end_time"] = now
            if t.get("start_time"):
                t["elapsed"] = max(0, int(round(now - t["start_time"])))
            break
    save_status(data)


def cmd_fail(task_id):
    now = time.time()
    data = load_status()
    for t in data.get("tasks", []):
        if t.get("id") == task_id:
            t["state"] = "failed"
            t["end_time"] = now
            if t.get("start_time"):
                t["elapsed"] = max(0, int(round(now - t["start_time"])))
            break
    save_status(data)


def get_live_status():
    now = time.time()
    data = load_status()
    for t in data.get("tasks", []):
        if t.get("state") == "in-progress" and t.get("start_time"):
            t["elapsed"] = max(0, int(round(now - t["start_time"])))
    data["server_time"] = now
    return data


def format_mm_ss(seconds):
    seconds = max(0, int(seconds))
    mins = seconds // 60
    secs = seconds % 60
    return f"{mins:02d}:{secs:02d}"


def cmd_monitor():
    try:
        while True:
            data = get_live_status()
            lines = []
            lines.append("\033[2J\033[H")
            lines.append(f"                  {data.get('title', '- Lab Startup Tasks -')}\n")
            lines.append(f"            {'Progress':<22} {'Time':<7} {'State':<11} {'Task'}")
            lines.append("")
            bar_width = 30
            for t in data.get("tasks", []):
                state = t.get("state", "pending")
                elapsed = t.get("elapsed", 0)
                eta = max(1, int(t.get("eta", 60)))
                if state == "completed":
                    filled = bar_width
                elif state == "pending":
                    filled = 0
                else:
                    pct = min(0.97, elapsed / eta)
                    filled = max(1, int(round(pct * bar_width)))
                bar = ("█" * filled) + ("░" * (bar_width - filled))
                time_str = format_mm_ss(elapsed)
                lines.append(f" {bar} | {time_str} | {state:<9} | {t.get('name', '')}")
            sys.stdout.write("\n".join(lines) + "\n")
            sys.stdout.flush()
            time.sleep(1)
    except KeyboardInterrupt:
        pass


ALLOWED_STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "application/javascript; charset=utf-8"),
}


class TrackerRequestHandler(http.server.BaseHTTPRequestHandler):
    # TODO(security): Local read-only deployment status dashboard does not use user accounts/OAuth/MFA.
    def _send_security_headers(self, content_type):
        self.send_header("Content-Type", content_type)
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'",
        )
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")

    def do_GET(self):
        clean_path = self.path.split("?", 1)[0]

        if clean_path == "/status.json":
            payload = json.dumps(get_live_status()).encode("utf-8")
            self.send_response(200)
            self._send_security_headers("application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if clean_path in ALLOWED_STATIC_FILES:
            filename, content_type = ALLOWED_STATIC_FILES[clean_path]
            file_path = (TRACKER_DIR / filename).resolve()
            if not str(file_path).startswith(str(TRACKER_DIR) + os.sep) or not file_path.is_file():
                self.send_error(404, "Not Found")
                return
            content = file_path.read_bytes()
            self.send_response(200)
            self._send_security_headers(content_type)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return

        self.send_error(404, "Not Found")

    def do_HEAD(self):
        clean_path = self.path.split("?", 1)[0]
        if clean_path == "/status.json" or clean_path in ALLOWED_STATIC_FILES:
            self.send_response(200)
            self._send_security_headers("text/plain; charset=utf-8")
            self.end_headers()
        else:
            self.send_error(404, "Not Found")

    def do_POST(self):
        self.send_error(405, "Method Not Allowed")

    def do_PUT(self):
        self.send_error(405, "Method Not Allowed")

    def do_DELETE(self):
        self.send_error(405, "Method Not Allowed")

    def log_message(self, format_str, *args):
        # Silence standard HTTP access logs so background server never pollutes deployment terminal
        pass


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


def cmd_serve(host, port):
    with ReusableTCPServer((host, int(port)), TrackerRequestHandler) as httpd:
        httpd.serve_forever()


def main():
    parser = argparse.ArgumentParser(description="Apigee Hybrid Deployment Task Tracker")
    subparsers = parser.add_subparsers(dest="command", required=True)

    p_init = subparsers.add_parser("init")
    p_init.add_argument("mode", nargs="?", default="full", choices=["full", "full-mcp", "mcp-only"])
    p_init.add_argument("--title", default="- Lab Startup Tasks -")

    p_begin = subparsers.add_parser("begin")
    p_begin.add_argument("task_id")
    p_begin.add_argument("task_name")
    p_begin.add_argument("eta", nargs="?", type=int, default=60)

    p_end = subparsers.add_parser("end")
    p_end.add_argument("task_id")

    p_fail = subparsers.add_parser("fail")
    p_fail.add_argument("task_id")

    p_serve = subparsers.add_parser("serve")
    p_serve.add_argument("--host", default="127.0.0.1")
    p_serve.add_argument("--port", type=int, default=8080)

    subparsers.add_parser("monitor")

    args = parser.parse_args()
    if args.command == "init":
        cmd_init(args.mode, args.title)
    elif args.command == "begin":
        cmd_begin(args.task_id, args.task_name, args.eta)
    elif args.command == "end":
        cmd_end(args.task_id)
    elif args.command == "fail":
        cmd_fail(args.task_id)
    elif args.command == "serve":
        cmd_serve(args.host, args.port)
    elif args.command == "monitor":
        cmd_monitor()


if __name__ == "__main__":
    main()
