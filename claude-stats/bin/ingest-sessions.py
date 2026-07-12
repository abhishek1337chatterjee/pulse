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
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from datetime import datetime
from pathlib import Path

HOME = Path.home()
PROJECTS = HOME / ".claude" / "projects"
DB = HOME / "Documents" / "claude-stats" / "claude.duckdb"
DUCKDB = HOME / ".local" / "bin" / "duckdb"

# v7: idle cutoff for capped active-time. A gap between two consecutive message
# timestamps longer than this means the user stepped away, so only this many
# seconds of it count as active work. 900s = 15min (WakaTime's heartbeat model).
IDLE_CAP_SECONDS = 900


def _parse_ts(s):
    """Parse an ISO-8601 message timestamp to datetime, or None."""
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None

# Subagent dispatch leaves "agentId: <hex>" in the parent's tool_result text.
# That hex id matches the subagent JSONL filename (agent-<id>.jsonl), so we can
# pair subagents with their subagent_type without depending on dispatch order.
AGENT_ID_RE = re.compile(r"agentId:\s*([0-9a-f]+)")

# Only needs python3 (already running) + duckdb (absolute path below); no node.
# Point at ~/.local/bin for duckdb rather than a pinned nvm version that rots.
os.environ["PATH"] = (
    f"{HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:" + os.environ.get("PATH", "")
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
    """Parse one JSONL.

    Returns (conv, tool_items, skill_items, agent_id_to_type) or None.

    agent_id_to_type is only populated when kind='main' — it maps the agentId
    extracted from each tool_result back to the subagent_type from the matching
    Agent tool_use. The caller merges these across all parents and uses the
    map to backfill the agent_type column on subagent rows.
    """
    session_id = path.stem
    kind, project_path, parent_sid = classify_path(path)
    started_at = ended_at = cwd = git_branch = summary = None
    timestamps: list = []  # v7: parsed msg timestamps, for capped active-time
    n_user = n_assistant = n_tool_calls = 0
    total_output = 0
    max_ctx = 0
    max_ctx_model = ""
    tools: Counter = Counter()
    skills: Counter = Counter()
    pending_agent_uses: dict = {}  # tool_use_id -> subagent_type (main only)
    agent_id_to_type: dict = {}    # agent_id    -> subagent_type (main only)

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
                    dt = _parse_ts(ts)
                    if dt is not None:
                        timestamps.append(dt)
                if cwd is None and "cwd" in d:
                    cwd = d["cwd"]
                if git_branch is None and "gitBranch" in d:
                    git_branch = d["gitBranch"]

                t = d.get("type")
                if t == "summary" and summary is None:
                    summary = d.get("summary")
                elif t == "user":
                    n_user += 1
                    if kind == "main" and pending_agent_uses:
                        msg = d.get("message", {}) or {}
                        content = msg.get("content") or []
                        if isinstance(content, list):
                            for block in content:
                                if not isinstance(block, dict):
                                    continue
                                if block.get("type") != "tool_result":
                                    continue
                                tuid = block.get("tool_use_id")
                                sub_type = pending_agent_uses.get(tuid)
                                if not sub_type:
                                    continue
                                m = AGENT_ID_RE.search(json.dumps(block.get("content")))
                                if m:
                                    agent_id_to_type[m.group(1)] = sub_type
                elif t == "assistant":
                    n_assistant += 1
                    msg = d.get("message", {}) or {}
                    model = msg.get("model") or ""
                    usage = msg.get("usage") or {}
                    if usage:
                        total_output += usage.get("output_tokens") or 0
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
                                elif name == "Agent" and kind == "main":
                                    sub_type = (block.get("input") or {}).get("subagent_type")
                                    tuid = block.get("id")
                                    if sub_type and tuid:
                                        pending_agent_uses[tuid] = sub_type
    except OSError as e:
        print(f"[ingest-sessions] skip {path}: {e}", file=sys.stderr)
        return None

    if n_user == 0 and n_assistant == 0:
        return None

    # v7: capped active-time. Sort timestamps, sum gaps, cap each at the idle
    # cutoff so idle stretches (a session resumed hours/days later) don't inflate.
    active_seconds = 0.0
    if len(timestamps) >= 2:
        timestamps.sort()
        for a, b in zip(timestamps, timestamps[1:]):
            gap = (b - a).total_seconds()
            if gap > 0:
                active_seconds += min(gap, IDLE_CAP_SECONDS)

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
        "total_output_tokens": total_output,
        "active_seconds": int(round(active_seconds)),
        "model": max_ctx_model,
        "summary": (summary or "")[:500],
        "agent_type": "",  # backfilled for subagents in main()
    }
    return conv, list(tools.items()), list(skills.items()), agent_id_to_type


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
    'total_output_tokens': 'BIGINT', 'active_seconds': 'BIGINT',
    'model': 'VARCHAR', 'summary': 'VARCHAR', 'agent_type': 'VARCHAR'
  }});

INSERT OR REPLACE INTO conversations
  (session_id, project_path, cwd, git_branch, kind, parent_session_id,
   started_at, ended_at, n_user_msgs, n_assistant_msgs, n_tool_calls,
   max_context_tokens, total_output_tokens, active_seconds, model, summary, agent_type, ingested_at)
SELECT session_id, project_path, cwd, git_branch, kind, parent_session_id,
       started_at, ended_at, n_user_msgs, n_assistant_msgs, n_tool_calls,
       max_context_tokens, total_output_tokens, active_seconds, model, summary,
       NULLIF(agent_type, '') AS agent_type, CURRENT_TIMESTAMP
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
        agent_type_map: dict = {}  # agent_id -> subagent_type, merged across all parents

        for jsonl in sorted(PROJECTS.rglob("*.jsonl")):
            result = parse_jsonl(jsonl)
            if not result:
                continue
            conv, tools, skills, agent_map = result
            conv_rows.append(conv)
            agent_type_map.update(agent_map)
            for tool_name, count in tools:
                tool_rows.append(
                    {"session_id": conv["session_id"], "tool_name": tool_name, "call_count": count}
                )
            for skill_name, count in skills:
                skill_rows.append(
                    {"session_id": conv["session_id"], "skill_name": skill_name, "call_count": count}
                )

        # Backfill agent_type on subagent rows now that we've seen all parents.
        # Subagent JSONL filenames are `agent-<hex>.jsonl`, so session_id == "agent-<hex>".
        matched = total_sub = 0
        for conv in conv_rows:
            if conv["kind"] != "subagent":
                continue
            total_sub += 1
            sid = conv["session_id"]
            if sid.startswith("agent-"):
                aid = sid[len("agent-"):]
                t = agent_type_map.get(aid)
                if t:
                    conv["agent_type"] = t
                    matched += 1

        write_csv(
            conv_rows,
            ["session_id", "project_path", "cwd", "git_branch", "kind", "parent_session_id",
             "started_at", "ended_at", "n_user_msgs", "n_assistant_msgs", "n_tool_calls",
             "max_context_tokens", "total_output_tokens", "active_seconds", "model", "summary", "agent_type"],
            tmpdir / "conversations.csv",
        )
        write_csv(tool_rows, ["session_id", "tool_name", "call_count"], tmpdir / "tools.csv")
        write_csv(skill_rows, ["session_id", "skill_name", "call_count"], tmpdir / "skills.csv")
        print(f"[ingest-sessions] subagent agent_type matched: {matched}/{total_sub}")
        duckdb_load(str(tmpdir))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
