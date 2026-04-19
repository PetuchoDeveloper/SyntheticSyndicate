#!/usr/bin/env bash
# subagent-verifier.sh
# Runs on SubagentStop — verifies that the agent actually delivered
# its required artifacts (reports, test plans, etc.).
#
# Decision control for SubagentStop (same as Stop):
#   - {"decision": "block", "reason": "..."} → prevents the agent from stopping
#   - exit 0 (no output) → allows the stop
#
# Also supports exit code 2 → stderr is fed back as feedback

set -euo pipefail

INPUT=$(cat)

# ── Extract fields from JSON stdin ──────────────────────────────────────
extract() {
    local field="$1"
    if command -v jq &>/dev/null; then
        echo "$INPUT" | jq -r "$field // \"\""
    elif command -v python3 &>/dev/null; then
        echo "$INPUT" | python3 -c "
import sys, json, functools
data = json.load(sys.stdin)
keys = '''$field'''.strip('.').split('.')
val = functools.reduce(lambda d,k: d.get(k,'') if isinstance(d,dict) else '', keys, data)
print(val if val else '')
"
    elif command -v python &>/dev/null; then
        echo "$INPUT" | python -c "
import sys, json, functools
data = json.load(sys.stdin)
keys = '''$field'''.strip('.').split('.')
val = functools.reduce(lambda d,k: d.get(k,'') if isinstance(d,dict) else '', keys, data)
print(val if val else '')
"
    else
        echo ""
    fi
}

AGENT_TYPE=$(extract '.agent_type')
CWD=$(extract '.cwd')

# Normalize: agent_type comes from frontmatter "name" field
AGENT_LOWER=$(echo "$AGENT_TYPE" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')

# ── Report directories ──────────────────────────────────────────────────
QA_DIR="$CWD/.claude/agents/coding_line/sprint-active/reports"
SPRINT_DIR="$CWD/.claude/agents/coding_line/sprint-active"

# ── Helper: check if file exists and is non-empty ───────────────────────
check_report() {
    local pattern="$1"
    local search_dir="$2"

    if [ ! -d "$search_dir" ]; then
        echo "MISSING"
        return
    fi

    local found
    found=$(find "$search_dir" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | head -1)

    if [ -z "$found" ]; then
        echo "MISSING"
        return
    fi

    local size
    size=$(wc -c < "$found" 2>/dev/null || echo "0")
    size=$(echo "$size" | tr -d ' ')

    if [ "$size" -lt 100 ]; then
        echo "EMPTY"
        return
    fi

    echo "OK"
}

# ── Helper: block the agent from stopping ───────────────────────────────
# Uses the Stop/SubagentStop decision control format
block() {
    local reason="$1"
    echo "{\"decision\":\"block\",\"reason\":\"DELIVERABLE NOT MET: $reason. Re-read your <deliverables> section and complete ALL required outputs before stopping.\"}"
    exit 0
}

# ── Helper: allow the stop ──────────────────────────────────────────────
pass() {
    exit 0
}

# ── Agent-specific verification ─────────────────────────────────────────

case "$AGENT_LOWER" in

    # ── QA White Hats: must produce their report ──────────────────────
    *security*white*|*sec*white*)
        result=$(check_report "SEC_WHITE_HAT_REPORT.md" "$QA_DIR")
        case "$result" in
            MISSING) block "SEC_WHITE_HAT_REPORT.md not found in reports directory" ;;
            EMPTY)   block "SEC_WHITE_HAT_REPORT.md exists but is nearly empty (< 100 bytes)" ;;
            OK)      pass ;;
        esac
        ;;

    *security*black*|*sec*black*)
        result=$(check_report "SEC_BLACK_HAT_REPORT.md" "$QA_DIR")
        case "$result" in
            MISSING) block "SEC_BLACK_HAT_REPORT.md not found in reports directory" ;;
            EMPTY)   block "SEC_BLACK_HAT_REPORT.md exists but is nearly empty (< 100 bytes)" ;;
            OK)      pass ;;
        esac
        ;;

    *performance*white*|*perf*white*)
        result=$(check_report "PERF_WHITE_HAT_REPORT.md" "$QA_DIR")
        case "$result" in
            MISSING) block "PERF_WHITE_HAT_REPORT.md not found in reports directory" ;;
            EMPTY)   block "PERF_WHITE_HAT_REPORT.md exists but is nearly empty (< 100 bytes)" ;;
            OK)      pass ;;
        esac
        ;;

    *performance*black*|*perf*black*)
        result=$(check_report "PERF_BLACK_HAT_REPORT.md" "$QA_DIR")
        case "$result" in
            MISSING) block "PERF_BLACK_HAT_REPORT.md not found in reports directory" ;;
            EMPTY)   block "PERF_BLACK_HAT_REPORT.md exists but is nearly empty (< 100 bytes)" ;;
            OK)      pass ;;
        esac
        ;;

    *ux*white*)
        result=$(check_report "UX_WHITE_HAT_REPORT.md" "$QA_DIR")
        case "$result" in
            MISSING) block "UX_WHITE_HAT_REPORT.md not found in reports directory" ;;
            EMPTY)   block "UX_WHITE_HAT_REPORT.md exists but is nearly empty (< 100 bytes)" ;;
            OK)      pass ;;
        esac
        ;;

    *ux*black*)
        result=$(check_report "UX_BLACK_HAT_REPORT.md" "$QA_DIR")
        case "$result" in
            MISSING) block "UX_BLACK_HAT_REPORT.md not found in reports directory" ;;
            EMPTY)   block "UX_BLACK_HAT_REPORT.md exists but is nearly empty (< 100 bytes)" ;;
            OK)      pass ;;
        esac
        ;;

    # ── Test Designer: must produce test plan ─────────────────────────
    *test*designer*|*test_designer*)
        r1=$(check_report "TEST_PLAN-*.md" "$QA_DIR")
        r2=$(check_report "TEST_PLAN-*.md" "$SPRINT_DIR")
        if [ "$r1" = "OK" ] || [ "$r2" = "OK" ]; then
            pass
        elif [ "$r1" = "EMPTY" ] || [ "$r2" = "EMPTY" ]; then
            block "TEST_PLAN file exists but is nearly empty. Complete the test plan"
        else
            block "TEST_PLAN-[task-id].md not found. Write the test plan report before stopping"
        fi
        ;;

    # ── Coding agents: must produce a task report ─────────────────────
    *backend*|*frontend*|*mobile*)
        r1=$(check_report "TASK_REPORT-*.md" "$QA_DIR")
        r2=$(check_report "TASK_REPORT-*.md" "$SPRINT_DIR")
        r3=$(check_report "TASK_REPORT-*.md" "$SPRINT_DIR/reports")
        if [ "$r1" = "OK" ] || [ "$r2" = "OK" ] || [ "$r3" = "OK" ]; then
            pass
        elif [ "$r1" = "EMPTY" ] || [ "$r2" = "EMPTY" ] || [ "$r3" = "EMPTY" ]; then
            block "TASK_REPORT file exists but is nearly empty. Complete the report"
        else
            block "TASK_REPORT-[task-id].md not found. Write your task report before stopping"
        fi
        ;;

    # ── Documenter: must produce docs task report ─────────────────────
    *technical*writer*|*documenter*)
        r1=$(check_report "TASK_REPORT-*-docs.md" "$QA_DIR")
        r2=$(check_report "TASK_REPORT-*-docs.md" "$SPRINT_DIR")
        # Fallback: any TASK_REPORT
        r3=$(check_report "TASK_REPORT-*.md" "$QA_DIR")
        if [ "$r1" = "OK" ] || [ "$r2" = "OK" ] || [ "$r3" = "OK" ]; then
            pass
        elif [ "$r1" = "EMPTY" ] || [ "$r2" = "EMPTY" ] || [ "$r3" = "EMPTY" ]; then
            block "Documentation task report exists but is nearly empty"
        else
            block "TASK_REPORT-[task-id]-docs.md not found. Write it before stopping"
        fi
        ;;

    # ── Scheduler: must produce SPRINT_PLAN.md ────────────────────────
    *sprint*prioritizer*|*scheduler*)
        result=$(check_report "SPRINT_PLAN.md" "$SPRINT_DIR")
        case "$result" in
            MISSING) block "SPRINT_PLAN.md not found in sprint-active directory" ;;
            EMPTY)   block "SPRINT_PLAN.md exists but is nearly empty" ;;
            OK)      pass ;;
        esac
        ;;

    # ── Git Specialist: verify clean git state ────────────────────────
    *git*workflow*|*git*specialist*)
        if command -v git &>/dev/null; then
            staged=$(cd "$CWD" && git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
            if [ "$staged" -gt 0 ]; then
                block "You have $staged staged but uncommitted files. Commit them before stopping"
            fi
        fi
        pass
        ;;

    # ── Unknown agent type: allow through ─────────────────────────────
    *)
        pass
        ;;
esac
