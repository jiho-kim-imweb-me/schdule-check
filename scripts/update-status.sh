#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# update-status.sh - GitHub-backed status.json updater
#
# Usage:
#   ./scripts/update-status.sh add --id task-004 --title "ALB 로그 분석" --category analysis
#   ./scripts/update-status.sh update --id task-004 --status in_progress --progress 30 --note "분석중"
#   ./scripts/update-status.sh done --id task-004
#   ./scripts/update-status.sh schedule --time "15:00" --label "인시던트 리뷰"
#   ./scripts/update-status.sh remove --id task-004
#   ./scripts/update-status.sh remove-schedule --time "15:00"
#
# Flags:
#   --notion    Also mirror changes to Notion database
#   --by NAME   Override updated_by field
###############################################################################

VENV_DIR="/tmp/status-update-venv"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install requests --quiet
fi

CREDS_FILE="$HOME/claude-policies/credentials.json"
REPO_NAME="schdule-check"
FILE_PATH="data/status.json"

# --- Parse global flags and subcommand ---
SUBCOMMAND=""
NOTION_FLAG="false"
UPDATED_BY="${USER:-unknown}@$(hostname -s)"
ARGS=()

for arg in "$@"; do
    case "$arg" in
        --notion)
            NOTION_FLAG="true"
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done

if [ ${#ARGS[@]} -eq 0 ]; then
    echo "Usage: $0 <add|update|done|schedule|remove|remove-schedule> [options]"
    echo ""
    echo "Subcommands:"
    echo "  add              Add a new task"
    echo "  update           Update an existing task"
    echo "  done             Mark a task as done"
    echo "  schedule         Add a schedule entry"
    echo "  remove           Remove a task"
    echo "  remove-schedule  Remove a schedule entry"
    echo ""
    echo "Flags:"
    echo "  --notion         Also mirror to Notion"
    echo "  --by NAME        Override updated_by"
    exit 1
fi

SUBCOMMAND="${ARGS[0]}"
REMAINING_ARGS=("${ARGS[@]:1}")

# --- Extract --by from remaining args ---
FILTERED_ARGS=()
i=0
while [ $i -lt ${#REMAINING_ARGS[@]} ]; do
    if [ "${REMAINING_ARGS[$i]}" = "--by" ] && [ $((i + 1)) -lt ${#REMAINING_ARGS[@]} ]; then
        UPDATED_BY="${REMAINING_ARGS[$((i + 1))]}"
        i=$((i + 2))
    else
        FILTERED_ARGS+=("${REMAINING_ARGS[$i]}")
        i=$((i + 1))
    fi
done

# --- Export env vars for Python ---
export STATUS_SUBCOMMAND="$SUBCOMMAND"
export STATUS_CREDS_FILE="$CREDS_FILE"
export STATUS_REPO_NAME="$REPO_NAME"
export STATUS_FILE_PATH="$FILE_PATH"
export STATUS_NOTION_FLAG="$NOTION_FLAG"
export STATUS_UPDATED_BY="$UPDATED_BY"
export STATUS_ARGS="${FILTERED_ARGS[*]:-}"
export NOTION_DASHBOARD_DB_ID="${NOTION_DASHBOARD_DB_ID:-}"

# --- Run Python ---
"$VENV_DIR/bin/python3" << 'PYTHON_EOF'
import json
import os
import sys
import base64
import argparse
from datetime import datetime, timezone, timedelta

import requests

KST = timezone(timedelta(hours=9))

# ── helpers ──────────────────────────────────────────────────────────────────

def now_kst():
    return datetime.now(KST).strftime("%Y-%m-%dT%H:%M:%S+09:00")


def load_creds(path):
    with open(os.path.expanduser(path), "r") as f:
        return json.load(f)


def detect_owner(creds):
    pat = creds["github"]["personal_access_token"]
    r = requests.get(
        "https://api.github.com/user",
        headers={"Authorization": f"token {pat}", "Accept": "application/vnd.github.v3+json"},
        timeout=10,
    )
    r.raise_for_status()
    return r.json()["login"]


def get_file(owner, repo, path, pat):
    url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"
    r = requests.get(
        url,
        headers={"Authorization": f"token {pat}", "Accept": "application/vnd.github.v3+json"},
        timeout=10,
    )
    r.raise_for_status()
    data = r.json()
    content = base64.b64decode(data["content"]).decode("utf-8")
    return json.loads(content), data["sha"]


def put_file(owner, repo, path, pat, content_json, sha, message):
    url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"
    encoded = base64.b64encode(json.dumps(content_json, indent=2, ensure_ascii=False).encode("utf-8")).decode("utf-8")
    payload = {
        "message": message,
        "content": encoded,
        "sha": sha,
    }
    r = requests.put(
        url,
        headers={"Authorization": f"token {pat}", "Accept": "application/vnd.github.v3+json"},
        json=payload,
        timeout=10,
    )
    return r


def update_with_retry(owner, repo, path, pat, modify_fn, commit_msg, max_retries=3):
    for attempt in range(max_retries):
        status_data, sha = get_file(owner, repo, path, pat)
        status_data = modify_fn(status_data)
        r = put_file(owner, repo, path, pat, status_data, sha, commit_msg)
        if r.status_code == 200 or r.status_code == 201:
            print(f"[OK] {commit_msg}")
            return status_data
        elif r.status_code == 409:
            print(f"[CONFLICT] Retry {attempt + 1}/{max_retries}...")
            continue
        else:
            print(f"[ERROR] GitHub API returned {r.status_code}: {r.text}", file=sys.stderr)
            sys.exit(1)
    print("[ERROR] Max retries exceeded on 409 Conflict", file=sys.stderr)
    sys.exit(1)


# ── Notion mirroring ────────────────────────────────────────────────────────

def notion_upsert_task(token, db_id, task):
    """Search for existing page by Task ID; update or create."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Notion-Version": "2022-06-28",
        "Content-Type": "application/json",
    }

    # Search existing
    search_payload = {
        "filter": {
            "property": "Task ID",
            "title": {"equals": task["id"]},
        }
    }
    r = requests.post(
        f"https://api.notion.com/v1/databases/{db_id}/query",
        headers=headers,
        json=search_payload,
        timeout=10,
    )
    r.raise_for_status()
    results = r.json().get("results", [])

    properties = {
        "Task ID": {"title": [{"text": {"content": task["id"]}}]},
        "제목": {"rich_text": [{"text": {"content": task.get("title", "")}}]},
        "상태": {"select": {"name": task.get("status", "waiting")}},
        "카테고리": {"select": {"name": task.get("category", "general")}},
        "진행률": {"number": task.get("progress", 0)},
        "메모": {"rich_text": [{"text": {"content": task.get("note", "")}}]},
        "최종 업데이트": {"date": {"start": task.get("updated_at", now_kst())}},
    }

    if results:
        page_id = results[0]["id"]
        r = requests.patch(
            f"https://api.notion.com/v1/pages/{page_id}",
            headers=headers,
            json={"properties": properties},
            timeout=10,
        )
        r.raise_for_status()
        print(f"[Notion] Updated page for {task['id']}")
    else:
        r = requests.post(
            "https://api.notion.com/v1/pages",
            headers=headers,
            json={"parent": {"database_id": db_id}, "properties": properties},
            timeout=10,
        )
        r.raise_for_status()
        print(f"[Notion] Created page for {task['id']}")


def notion_delete_task(token, db_id, task_id):
    """Archive the Notion page for a given task ID."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Notion-Version": "2022-06-28",
        "Content-Type": "application/json",
    }
    search_payload = {
        "filter": {
            "property": "Task ID",
            "title": {"equals": task_id},
        }
    }
    r = requests.post(
        f"https://api.notion.com/v1/databases/{db_id}/query",
        headers=headers,
        json=search_payload,
        timeout=10,
    )
    r.raise_for_status()
    results = r.json().get("results", [])
    if results:
        page_id = results[0]["id"]
        r = requests.patch(
            f"https://api.notion.com/v1/pages/{page_id}",
            headers=headers,
            json={"archived": True},
            timeout=10,
        )
        r.raise_for_status()
        print(f"[Notion] Archived page for {task_id}")


# ── subcommand parsers ──────────────────────────────────────────────────────

def parse_add(raw_args):
    p = argparse.ArgumentParser(prog="add")
    p.add_argument("--id", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--category", default="general")
    p.add_argument("--note", default="")
    return p.parse_args(raw_args)


def parse_update(raw_args):
    p = argparse.ArgumentParser(prog="update")
    p.add_argument("--id", required=True)
    p.add_argument("--status", default=None)
    p.add_argument("--progress", type=int, default=None)
    p.add_argument("--note", default=None)
    p.add_argument("--title", default=None)
    p.add_argument("--category", default=None)
    return p.parse_args(raw_args)


def parse_done(raw_args):
    p = argparse.ArgumentParser(prog="done")
    p.add_argument("--id", required=True)
    return p.parse_args(raw_args)


def parse_schedule(raw_args):
    p = argparse.ArgumentParser(prog="schedule")
    p.add_argument("--time", required=True)
    p.add_argument("--label", required=True)
    return p.parse_args(raw_args)


def parse_remove(raw_args):
    p = argparse.ArgumentParser(prog="remove")
    p.add_argument("--id", required=True)
    return p.parse_args(raw_args)


def parse_remove_schedule(raw_args):
    p = argparse.ArgumentParser(prog="remove-schedule")
    p.add_argument("--time", required=True)
    return p.parse_args(raw_args)


# ── main ────────────────────────────────────────────────────────────────────

def main():
    subcmd = os.environ["STATUS_SUBCOMMAND"]
    creds_file = os.environ["STATUS_CREDS_FILE"]
    repo = os.environ["STATUS_REPO_NAME"]
    file_path = os.environ["STATUS_FILE_PATH"]
    notion_flag = os.environ["STATUS_NOTION_FLAG"] == "true"
    updated_by = os.environ["STATUS_UPDATED_BY"]
    raw_args = os.environ.get("STATUS_ARGS", "").split()

    creds = load_creds(creds_file)
    pat = creds["github"]["personal_access_token"]
    owner = detect_owner(creds)

    notion_token = creds.get("notion", {}).get("integration_token", "")
    notion_db_id = os.environ.get("NOTION_DASHBOARD_DB_ID", "")

    # Track the affected task for Notion mirroring
    affected_task = None
    removed_task_id = None

    if subcmd == "add":
        args = parse_add(raw_args)

        def modify(data):
            for t in data["tasks"]:
                if t["id"] == args.id:
                    print(f"[ERROR] Task {args.id} already exists", file=sys.stderr)
                    sys.exit(1)
            new_task = {
                "id": args.id,
                "title": args.title,
                "status": "waiting",
                "category": args.category,
                "started_at": None,
                "updated_at": now_kst(),
                "progress": 0,
                "note": args.note,
            }
            data["tasks"].append(new_task)
            data["meta"]["updated_at"] = now_kst()
            data["meta"]["updated_by"] = updated_by
            return data

        result = update_with_retry(owner, repo, file_path, pat, modify, f"add task {args.id}: {args.title}")
        affected_task = next((t for t in result["tasks"] if t["id"] == args.id), None)

    elif subcmd == "update":
        args = parse_update(raw_args)

        def modify(data):
            task = next((t for t in data["tasks"] if t["id"] == args.id), None)
            if not task:
                print(f"[ERROR] Task {args.id} not found", file=sys.stderr)
                sys.exit(1)
            if args.status is not None:
                task["status"] = args.status
                if args.status == "in_progress" and task.get("started_at") is None:
                    task["started_at"] = now_kst()
            if args.progress is not None:
                task["progress"] = args.progress
            if args.note is not None:
                task["note"] = args.note
            if args.title is not None:
                task["title"] = args.title
            if args.category is not None:
                task["category"] = args.category
            task["updated_at"] = now_kst()
            data["meta"]["updated_at"] = now_kst()
            data["meta"]["updated_by"] = updated_by
            return data

        result = update_with_retry(owner, repo, file_path, pat, modify, f"update task {args.id}")
        affected_task = next((t for t in result["tasks"] if t["id"] == args.id), None)

    elif subcmd == "done":
        args = parse_done(raw_args)

        def modify(data):
            task = next((t for t in data["tasks"] if t["id"] == args.id), None)
            if not task:
                print(f"[ERROR] Task {args.id} not found", file=sys.stderr)
                sys.exit(1)
            task["status"] = "done"
            task["progress"] = 100
            task["updated_at"] = now_kst()
            data["meta"]["updated_at"] = now_kst()
            data["meta"]["updated_by"] = updated_by
            return data

        result = update_with_retry(owner, repo, file_path, pat, modify, f"complete task {args.id}")
        affected_task = next((t for t in result["tasks"] if t["id"] == args.id), None)

    elif subcmd == "schedule":
        args = parse_schedule(raw_args)

        def modify(data):
            for s in data["schedule"]:
                if s["time"] == args.time:
                    s["label"] = args.label
                    data["meta"]["updated_at"] = now_kst()
                    data["meta"]["updated_by"] = updated_by
                    return data
            data["schedule"].append({"time": args.time, "label": args.label})
            data["schedule"].sort(key=lambda x: x["time"])
            data["meta"]["updated_at"] = now_kst()
            data["meta"]["updated_by"] = updated_by
            return data

        update_with_retry(owner, repo, file_path, pat, modify, f"add schedule {args.time}: {args.label}")

    elif subcmd == "remove":
        args = parse_remove(raw_args)

        def modify(data):
            original_len = len(data["tasks"])
            data["tasks"] = [t for t in data["tasks"] if t["id"] != args.id]
            if len(data["tasks"]) == original_len:
                print(f"[ERROR] Task {args.id} not found", file=sys.stderr)
                sys.exit(1)
            data["meta"]["updated_at"] = now_kst()
            data["meta"]["updated_by"] = updated_by
            return data

        update_with_retry(owner, repo, file_path, pat, modify, f"remove task {args.id}")
        removed_task_id = args.id

    elif subcmd == "remove-schedule":
        args = parse_remove_schedule(raw_args)

        def modify(data):
            original_len = len(data["schedule"])
            data["schedule"] = [s for s in data["schedule"] if s["time"] != args.time]
            if len(data["schedule"]) == original_len:
                print(f"[ERROR] Schedule entry at {args.time} not found", file=sys.stderr)
                sys.exit(1)
            data["meta"]["updated_at"] = now_kst()
            data["meta"]["updated_by"] = updated_by
            return data

        update_with_retry(owner, repo, file_path, pat, modify, f"remove schedule {args.time}")

    else:
        print(f"[ERROR] Unknown subcommand: {subcmd}", file=sys.stderr)
        print("Valid subcommands: add, update, done, schedule, remove, remove-schedule", file=sys.stderr)
        sys.exit(1)

    # ── Notion mirroring ──
    if notion_flag:
        if not notion_token:
            print("[WARN] Notion token not found in credentials, skipping", file=sys.stderr)
        elif not notion_db_id:
            print("[WARN] NOTION_DASHBOARD_DB_ID not set, skipping Notion mirroring", file=sys.stderr)
        else:
            if removed_task_id:
                notion_delete_task(notion_token, notion_db_id, removed_task_id)
            elif affected_task:
                notion_upsert_task(notion_token, notion_db_id, affected_task)
            else:
                print("[INFO] No task to mirror to Notion (schedule changes are not mirrored)")


if __name__ == "__main__":
    main()
PYTHON_EOF
