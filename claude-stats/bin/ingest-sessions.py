#!/usr/bin/env python3
"""Ingest Claude Code session data into the local DuckDB.

Source: JSONL files at ~/.claude/projects/*/*.jsonl  (per-conversation detail).

Writes: conversations, conversation_tool_usage, conversation_skill_usage.
Idempotent via INSERT OR REPLACE.

(Per-project cost lives in `project_daily_usage`, populated by ingest-daily.sh
from `ccusage claude daily --instances --breakdown --json` — that table is the
source of truth for the dashboard's "Top projects" panel.)
"""

import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

HOME = Path.home()
PROJECTS = HOME / ".claude" / "projects"
DB = HOME / "Documents" / "claude-stats" / "claude.duckdb"
DUCKDB = HOME / ".local" / "bin" / "duckdb"

os.environ["PATH"] = (
    f"{HOME}/.nvm/versions/node/v24.14.1/bin:/usr/bin:/bin:" + os.environ.get("PATH", "")
)


def classify_path(path: Path):
    """Return (kind, project_path, parent_session_id) from a JSONL file path."""
    # Main:     .claude/projects/<project>/<uuid>.jsonl
    # Subagent: .claude/projects/<project>/<parent_uuid>/subagents/<agent-id>.jsonl
    parts = path.relative_to(PROJECTS).parts
    project_path = parts[0]
    if len(parts) == 2:
        return "main", project_path, None
    if len(parts) >= 3 and "subagents" in parts:
        parent_uuid = parts[1]
        return "subagent", project_path, parent_uuid
    return "main", project_path, None


def parse_jsonl(path: Path):
    session_id = path.stem
    kind, project_path, parent_sid = classify_path(path)
    started_at = ended_at = cwd = git_branch = summary = None
    n_user = n_assistant = n_tool_calls = 0
    max_ctx = 0
    max_ctx_model = ""
    tools: Counter = Counter()
    skills: Counter = Counter()

    try:
        with path.open(errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue

                ts = d.get("timestamp")
                if ts:
                    if started_at is None or ts < started_at:
                        started_at = ts
                    if ended_at is None or ts > ended_at:
                        ended_at = ts
                if cwd is None and "cwd" in d:
                    cwd = d["cwd"]
                if git_branch is None and "gitBranch" in d:
                    git_branch = d["gitBranch"]

                t = d.get("type")
                if t == "summary" and summary is None:
                    summary = d.get("summary")
                elif t == "user":
                    n_user += 1
                elif t == "assistant":
                    n_assistant += 1
                    msg = d.get("message", {}) or {}
                    model = msg.get("model") or ""
                    usage = msg.get("usage") or {}
                    if usage:
                        ctx = (
                            (usage.get("input_tokens") or 0)
                            + (usage.get("cache_creation_input_tokens") or 0)
                            + (usage.get("cache_read_input_tokens") or 0)
                        )
                        if ctx > max_ctx:
                            max_ctx = ctx
                            max_ctx_model = model
                    content = msg.get("content") or []
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "tool_use":
                                name = block.get("name") or "unknown"
                                tools[name] += 1
                                n_tool_calls += 1
                                if name == "Skill":
                                    skill_name = (block.get("input") or {}).get("skill")
                                    if skill_name:
                                        skills[skill_name] += 1
    except OSError as e:
        print(f"[ingest-sessions] skip {path}: {e}", file=sys.stderr)
        return None

    if n_user == 0 and n_assistant == 0:
        return None

    conv = {
        "session_id": session_id,
        "project_path": project_path,
        "cwd": cwd or "",
        "git_branch": git_branch or "",
        "kind": kind,
        "parent_session_id": parent_sid or "",
        "started_at": started_at or "",
        "ended_at": ended_at or "",
        "n_user_msgs": n_user,
        "n_assistant_msgs": n_assistant,
        "n_tool_calls": n_tool_calls,
        "max_context_tokens": max_ctx,
        "model": max_ctx_model,
        "summary": (summary or "")[:500],
    }
    return conv, list(tools.items()), list(skills.items())


def write_csv(rows, columns, path):
    with open(path, "w", newline="") as f:
        w = csv.writer(f, quoting=csv.QUOTE_MINIMAL)
        for row in rows:
            w.writerow([row[c] for c in columns])


def duckdb_load(tmpdir):
    sql = f"""
CREATE OR REPLACE TEMP TABLE staging_conv AS
SELECT * FROM read_csv('{tmpdir}/conversations.csv',
  header=false,
  columns={{
    'session_id': 'VARCHAR', 'project_path': 'VARCHAR', 'cwd': 'VARCHAR',
    'git_branch': 'VARCHAR', 'kind': 'VARCHAR', 'parent_session_id': 'VARCHAR',
    'started_at': 'TIMESTAMP', 'ended_at': 'TIMESTAMP',
    'n_user_msgs': 'INTEGER', 'n_assistant_msgs': 'INTEGER',
    'n_tool_calls': 'INTEGER', 'max_context_tokens': 'BIGINT',
    'model': 'VARCHAR', 'summary': 'VARCHAR'
  }});

INSERT OR REPLACE INTO conversations
  (session_id, project_path, cwd, git_branch, kind, parent_session_id,
   started_at, ended_at, n_user_msgs, n_assistant_msgs, n_tool_calls,
   max_context_tokens, model, summary, ingested_at)
SELECT session_id, project_path, cwd, git_branch, kind, parent_session_id,
       started_at, ended_at, n_user_msgs, n_assistant_msgs, n_tool_calls,
       max_context_tokens, model, summary, CURRENT_TIMESTAMP
FROM staging_conv;

CREATE OR REPLACE TEMP TABLE staging_tools AS
SELECT * FROM read_csv('{tmpdir}/tools.csv',
  header=false,
  columns={{'session_id':'VARCHAR','tool_name':'VARCHAR','call_count':'INTEGER'}});

INSERT OR REPLACE INTO conversation_tool_usage (session_id, tool_name, call_count)
SELECT session_id, tool_name, call_count FROM staging_tools;

CREATE OR REPLACE TEMP TABLE staging_skills AS
SELECT * FROM read_csv('{tmpdir}/skills.csv',
  header=false,
  columns={{'session_id':'VARCHAR','skill_name':'VARCHAR','call_count':'INTEGER'}});

INSERT OR REPLACE INTO conversation_skill_usage (session_id, skill_name, call_count)
SELECT session_id, skill_name, call_count FROM staging_skills;

SELECT '[ingest-sessions] conversations: ' || (SELECT COUNT(*) FROM staging_conv)
    || ' / tool rows: ' || (SELECT COUNT(*) FROM staging_tools)
    || ' / skill rows: ' || (SELECT COUNT(*) FROM staging_skills) AS msg;
"""
    proc = subprocess.run(
        [str(DUCKDB), str(DB)], input=sql, text=True, capture_output=True
    )
    if proc.returncode != 0:
        print(proc.stdout)
        print(proc.stderr, file=sys.stderr)
        sys.exit(proc.returncode)
    print(proc.stdout.strip())


def main():
    if not PROJECTS.exists():
        print("[ingest-sessions] no ~/.claude/projects yet — nothing to ingest")
        return

    tmpdir = Path(tempfile.mkdtemp(prefix="claude-stats-"))
    try:
        conv_rows, tool_rows, skill_rows = [], [], []
        for jsonl in sorted(PROJECTS.rglob("*.jsonl")):
            result = parse_jsonl(jsonl)
            if not result:
                continue
            conv, tools, skills = result
            conv_rows.append(conv)
            for tool_name, count in tools:
                tool_rows.append(
                    {"session_id": conv["session_id"], "tool_name": tool_name, "call_count": count}
                )
            for skill_name, count in skills:
                skill_rows.append(
                    {"session_id": conv["session_id"], "skill_name": skill_name, "call_count": count}
                )

        write_csv(
            conv_rows,
            ["session_id", "project_path", "cwd", "git_branch", "kind", "parent_session_id",
             "started_at", "ended_at", "n_user_msgs", "n_assistant_msgs", "n_tool_calls",
             "max_context_tokens", "model", "summary"],
            tmpdir / "conversations.csv",
        )
        write_csv(tool_rows, ["session_id", "tool_name", "call_count"], tmpdir / "tools.csv")
        write_csv(skill_rows, ["session_id", "skill_name", "call_count"], tmpdir / "skills.csv")
        duckdb_load(str(tmpdir))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
