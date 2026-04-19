#!/usr/bin/env bash
# bash-gatekeeper.sh
# "Factory Droid Medium Autonomy" — auto-allow reversible Bash commands,
# block irreversible/destructive ones, let the user decide on everything else.
# Automatically rewrites supported commands to their RustTokenKiller (rtk) equivalents.
#
# Works on Linux (native bash) and Windows (Git Bash).

set -euo pipefail

INPUT=$(cat)

# ── Extract the command from JSON stdin ─────────────────────────────────
if command -v jq &>/dev/null; then
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
elif command -v python3 &>/dev/null && python3 -c "pass" &>/dev/null; then
    COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))")
elif command -v python &>/dev/null && python -c "pass" &>/dev/null; then
    COMMAND=$(echo "$INPUT" | python -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))")
else
    # Last resort grep fallback
    COMMAND=$(echo "$INPUT" | grep -oP '"command"\s*:\s*"\K[^"]*' 2>/dev/null || echo "")
fi

# Clean escaped newlines and carriage returns if any
COMMAND="${COMMAND//\\n/
}"
COMMAND="${COMMAND//$'\r'/}"

# ── Resolve RTK executable (cross-platform / bash-windows compat) ───────
RTK_BIN=""
if command -v rtk &>/dev/null; then
    RTK_BIN="rtk"
elif command -v rtk.exe &>/dev/null; then
    RTK_BIN="rtk.exe"
elif [ -f "$USERPROFILE/.cargo/bin/rtk.exe" ]; then
    RTK_BIN="$USERPROFILE/.cargo/bin/rtk.exe"
elif [ -f "$HOME/.cargo/bin/rtk" ]; then
    RTK_BIN="$HOME/.cargo/bin/rtk"
fi

# ── Auto-rewrite to RTK (RustTokenKiller) if available ──────────────────
REWRITTEN=""
if [ -n "$RTK_BIN" ]; then
    # rtk rewrite prints to stdout and exits with 0 on success, or exits 1 if not supported
    # Some versions output to stderr, so we redirect 2>&1
    RTK_CANDIDATE=$("$RTK_BIN" rewrite "$COMMAND" 2>&1 || true)
    RTK_CANDIDATE="${RTK_CANDIDATE//$'\r'/}"
    
    # We only accept the rewrite if it starts with "rtk " or "rtk.exe "
    if [[ "$RTK_CANDIDATE" == "rtk "* ]] || [[ "$RTK_CANDIDATE" == "rtk.exe "* ]]; then
        # Check if the command was ACTUALLY rewritten and differs from the original
        if [ "$RTK_CANDIDATE" != "$COMMAND" ]; then
            COMMAND="$RTK_CANDIDATE"
            REWRITTEN=$(echo "$COMMAND" | sed -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g')
        fi
    fi
fi

# ── Helper: emit JSON decision ──────────────────────────────────────────
allow() {
    if [ -n "$REWRITTEN" ]; then
        echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"$REWRITTEN\"},\"additionalContext\":\"Command was automatically rewritten to use rtk (RustTokenKiller) to save LLM tokens. Rewritten to: $REWRITTEN\"}}"
    else
        echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    fi
    exit 0
}

ask() {
    local reason="$1"
    if [ -n "$REWRITTEN" ]; then
        echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"$reason\",\"updatedInput\":{\"command\":\"$REWRITTEN\"},\"additionalContext\":\"Command was automatically rewritten to use rtk (RustTokenKiller) to save LLM tokens.\"}}"
    else
        echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"$reason\"}}"
    fi
    exit 0
}

# ── IRREVERSIBLE / DESTRUCTIVE patterns (ASK) ──────────────────────────
DESTRUCTIVE_PATTERNS=(
    '^\s*(rtk(\.exe)?\s+)?rm\s+-[^ ]*r'             # rm -r, rm -rf, rm -ri
    '^\s*(rtk(\.exe)?\s+)?rm\s+-[^ ]*f'             # rm -f
    '^\s*(rtk(\.exe)?\s+)?rmdir\s+/s'               # rmdir /s (Windows recursive)
    '^\s*(rtk(\.exe)?\s+)?del\s+/s'                 # del /s  (Windows recursive)
    '\|\s*(rtk(\.exe)?\s+)?rm\b'                    # piped into rm
    'format\s+[a-zA-Z]:'                            # format drive
    '^\s*(rtk(\.exe)?\s+)?dd\s+'                    # dd (disk destroyer)
    'mkfs\.'                                        # mkfs (make filesystem)
    '^\s*(rtk(\.exe)?\s+)?shutdown'                 # shutdown
    '^\s*(rtk(\.exe)?\s+)?reboot'                   # reboot
    '^\s*(rtk(\.exe)?\s+)?init\s+[0-6]'             # init level change
    '^\s*(rtk(\.exe)?\s+)?kill\s+-9'                # force kill
    '^\s*(rtk(\.exe)?\s+)?pkill\s+-9'               # force pkill
    '>\s+/etc/'                                     # overwrite system config
    '^\s*(rtk(\.exe)?\s+)?chmod\s+000'              # remove all permissions
    '^\s*(rtk(\.exe)?\s+)?chown\s+root'             # change ownership to root
    '(rtk(\.exe)?\s+)?curl\s+.*\|\s*(ba)?sh'        # pipe curl to shell
    '(rtk(\.exe)?\s+)?wget\s+.*\|\s*(ba)?sh'        # pipe wget to shell
    '^\s*(rtk(\.exe)?\s+)?git\s+push\s+.*--force'   # force push
    '^\s*(rtk(\.exe)?\s+)?git\s+push\s+-f\b'        # force push shorthand
    '^\s*(rtk(\.exe)?\s+)?git\s+reset\s+--hard'     # hard reset
    '^\s*(rtk(\.exe)?\s+)?git\s+clean\s+-fd'        # git clean force
    '^\s*(rtk(\.exe)?\s+)?npm\s+publish'            # publish package
    '^\s*(rtk(\.exe)?\s+)?npx\s+.*publish'          # publish via npx
    '^\s*(rtk(\.exe)?\s+)?docker\s+system\s+prune'  # docker system prune
    '^\s*(rtk(\.exe)?\s+)?docker\s+rm\s+-f'         # force remove containers
    '^\s*(rtk(\.exe)?\s+)?docker\s+rmi\s+-f'        # force remove images
    'DROP\s+DATABASE'                               # SQL drop database
    'DROP\s+TABLE'                                  # SQL drop table
    'TRUNCATE\s+'                                   # SQL truncate
    ':\s*>\s+'                                      # truncate file with : >
    '^\s*(rtk(\.exe)?\s+)?mv\s+/\s'                 # move root
    'sudo\s+(rtk(\.exe)?\s+)?rm'                    # sudo rm
    'sudo\s+(rtk(\.exe)?\s+)?dd'                    # sudo dd
    '^\s*Remove-Item\s+.*-Recurse'                  # PowerShell recursive delete
    '^\s*Remove-Item\s+.*-Force'                    # PowerShell force delete
)

for pattern in "${DESTRUCTIVE_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
        ask "IRREVERSIBLE command detected — requires human approval"
    fi
done

# ── REVERSIBLE / READ-ONLY patterns (ALLOW) ────────────────────────────
SAFE_PATTERNS=(
    # ── Read-only / informational ───────────────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?ls\b'
    '^\s*(rtk(\.exe)?\s+)?dir\b'
    '^\s*(rtk(\.exe)?\s+)?cat\b'
    '^\s*(rtk(\.exe)?\s+)?echo\b'
    '^\s*(rtk(\.exe)?\s+)?printf\b'
    '^\s*(rtk(\.exe)?\s+)?head\b'
    '^\s*(rtk(\.exe)?\s+)?tail\b'
    '^\s*(rtk(\.exe)?\s+)?wc\b'
    '^\s*(rtk(\.exe)?\s+)?sort\b'
    '^\s*(rtk(\.exe)?\s+)?uniq\b'
    '^\s*(rtk(\.exe)?\s+)?grep\b'
    '^\s*(rtk(\.exe)?\s+)?rg\b'
    '^\s*(rtk(\.exe)?\s+)?find\b'
    '^\s*(rtk(\.exe)?\s+)?fd\b'
    '^\s*(rtk(\.exe)?\s+)?which\b'
    '^\s*(rtk(\.exe)?\s+)?where\b'
    '^\s*(rtk(\.exe)?\s+)?type\b'
    '^\s*(rtk(\.exe)?\s+)?file\b'
    '^\s*(rtk(\.exe)?\s+)?stat\b'
    '^\s*(rtk(\.exe)?\s+)?pwd\b'
    '^\s*(rtk(\.exe)?\s+)?env\b'
    '^\s*(rtk(\.exe)?\s+)?printenv\b'
    '^\s*(rtk(\.exe)?\s+)?set\b'
    '^\s*(rtk(\.exe)?\s+)?tree\b'
    '^\s*(rtk(\.exe)?\s+)?du\b'
    '^\s*(rtk(\.exe)?\s+)?df\b'
    '^\s*(rtk(\.exe)?\s+)?diff\b'
    '^\s*(rtk(\.exe)?\s+)?less\b'
    '^\s*(rtk(\.exe)?\s+)?more\b'
    '^\s*(rtk(\.exe)?\s+)?true\b'
    '^\s*(rtk(\.exe)?\s+)?false\b'
    '^\s*(rtk(\.exe)?\s+)?test\b'
    '^\s*(rtk(\.exe)?\s+)?\[\s'
    '^\s*(rtk(\.exe)?\s+)?basename\b'
    '^\s*(rtk(\.exe)?\s+)?dirname\b'
    '^\s*(rtk(\.exe)?\s+)?realpath\b'
    '^\s*(rtk(\.exe)?\s+)?readlink\b'
    '^\s*(rtk(\.exe)?\s+)?date\b'
    '^\s*(rtk(\.exe)?\s+)?whoami\b'
    '^\s*(rtk(\.exe)?\s+)?hostname\b'
    '^\s*(rtk(\.exe)?\s+)?uname\b'
    '^\s*(rtk(\.exe)?\s+)?id\b'
    '^\s*(rtk(\.exe)?\s+)?uptime\b'
    '^\s*(rtk(\.exe)?\s+)?free\b'
    '^\s*(rtk(\.exe)?\s+)?ps\b'
    '^\s*(rtk(\.exe)?\s+)?top\b'
    '^\s*(rtk(\.exe)?\s+)?htop\b'
    '^\s*(rtk(\.exe)?\s+)?seq\b'
    '^\s*(rtk(\.exe)?\s+)?tr\b'
    '^\s*(rtk(\.exe)?\s+)?cut\b'
    '^\s*(rtk(\.exe)?\s+)?awk\b'
    '^\s*(rtk(\.exe)?\s+)?sed\b'
    '^\s*(rtk(\.exe)?\s+)?jq\b'
    '^\s*(rtk(\.exe)?\s+)?json\b'
    '^\s*(rtk(\.exe)?\s+)?xargs\b'
    '^\s*(rtk(\.exe)?\s+)?tee\b'
    '^\s*(rtk(\.exe)?\s+)?yes\b'

    # ── Reversible filesystem operations ────────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?mkdir\b'
    '^\s*(rtk(\.exe)?\s+)?touch\b'
    '^\s*(rtk(\.exe)?\s+)?cp\b'
    '^\s*(rtk(\.exe)?\s+)?mv\b'
    '^\s*(rtk(\.exe)?\s+)?ln\b'
    '^\s*(rtk(\.exe)?\s+)?chmod\s+[1-7]'

    # ── Git (safe operations) ──────────────────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?git\s+status'
    '^\s*(rtk(\.exe)?\s+)?git\s+log'
    '^\s*(rtk(\.exe)?\s+)?git\s+diff'
    '^\s*(rtk(\.exe)?\s+)?git\s+show'
    '^\s*(rtk(\.exe)?\s+)?git\s+branch'
    '^\s*(rtk(\.exe)?\s+)?git\s+tag'
    '^\s*(rtk(\.exe)?\s+)?git\s+stash'
    '^\s*(rtk(\.exe)?\s+)?git\s+remote'
    '^\s*(rtk(\.exe)?\s+)?git\s+fetch'
    '^\s*(rtk(\.exe)?\s+)?git\s+pull'
    '^\s*(rtk(\.exe)?\s+)?git\s+add\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+commit\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+checkout\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+switch\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+merge\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+rebase\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+cherry-pick\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+restore\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+rev-parse\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+config\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+ls-files\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+worktree\b'
    '^\s*(rtk(\.exe)?\s+)?git\s+push\b'             # normal push (no --force) is reversible

    # ── Node.js / npm / package managers ───────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?npm\s+install\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+ci\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+run\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+test\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+start\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+build\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+exec\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+init\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+ls\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+list\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+outdated\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+info\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+view\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+pack\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+audit\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+explain\b'
    '^\s*(rtk(\.exe)?\s+)?npm\s+why\b'
    '^\s*(rtk(\.exe)?\s+)?npx\b'
    '^\s*(rtk(\.exe)?\s+)?node\b'
    '^\s*(rtk(\.exe)?\s+)?tsx\b'
    '^\s*(rtk(\.exe)?\s+)?ts-node\b'
    '^\s*(rtk(\.exe)?\s+)?tsc\b'

    # ── Linters / formatters / test runners ────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?eslint\b'
    '^\s*(rtk(\.exe)?\s+)?prettier\b'
    '^\s*(rtk(\.exe)?\s+)?vitest\b'
    '^\s*(rtk(\.exe)?\s+)?jest\b'
    '^\s*(rtk(\.exe)?\s+)?mocha\b'
    '^\s*(rtk(\.exe)?\s+)?playwright\b'
    '^\s*(rtk(\.exe)?\s+)?cypress\b'

    # ── Build tools / bundlers ─────────────────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?next\b'
    '^\s*(rtk(\.exe)?\s+)?vite\b'
    '^\s*(rtk(\.exe)?\s+)?webpack\b'
    '^\s*(rtk(\.exe)?\s+)?rollup\b'
    '^\s*(rtk(\.exe)?\s+)?esbuild\b'
    '^\s*(rtk(\.exe)?\s+)?turbo\b'

    # ── Other package managers ─────────────────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?pnpm\b'
    '^\s*(rtk(\.exe)?\s+)?yarn\b'
    '^\s*(rtk(\.exe)?\s+)?bun\b'
    '^\s*(rtk(\.exe)?\s+)?deno\b'

    # ── Other languages / runtimes ─────────────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?python\b'
    '^\s*(rtk(\.exe)?\s+)?python3\b'
    '^\s*(rtk(\.exe)?\s+)?pip\b'
    '^\s*(rtk(\.exe)?\s+)?pip3\b'
    '^\s*(rtk(\.exe)?\s+)?cargo\b'
    '^\s*(rtk(\.exe)?\s+)?rustc\b'
    '^\s*(rtk(\.exe)?\s+)?go\s+(build|run|test|vet|fmt|mod|get|version)\b'
    '^\s*(rtk(\.exe)?\s+)?dotnet\b'
    '^\s*(rtk(\.exe)?\s+)?docker\s+(build|run|ps|images|logs|inspect|exec|compose)\b'

    # ── Networking ─────────────────────────────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?curl\b'
    '^\s*(rtk(\.exe)?\s+)?wget\b'
    '^\s*(rtk(\.exe)?\s+)?ssh\b'
    '^\s*(rtk(\.exe)?\s+)?scp\b'
    '^\s*(rtk(\.exe)?\s+)?rsync\b'

    # ── Archives ───────────────────────────────────────────────────────
    '^\s*(rtk(\.exe)?\s+)?tar\b'
    '^\s*(rtk(\.exe)?\s+)?zip\b'
    '^\s*(rtk(\.exe)?\s+)?unzip\b'
    '^\s*(rtk(\.exe)?\s+)?gzip\b'
    '^\s*(rtk(\.exe)?\s+)?gunzip\b'
    '^\s*(rtk(\.exe)?\s+)?7z\b'

    # ── PowerShell cmdlets ─────────────────────────────────────────────
    '^\s*Get-Content\b'
    '^\s*Get-ChildItem\b'
    '^\s*Get-Item\b'
    '^\s*Get-Location\b'
    '^\s*Set-Location\b'
    '^\s*Test-Path\b'
    '^\s*New-Item\b'
    '^\s*Copy-Item\b'
    '^\s*Move-Item\b'
    '^\s*Select-String\b'
    '^\s*Write-Output\b'
    '^\s*Write-Host\b'
    '^\s*Get-Process\b'
    '^\s*ConvertFrom-Json\b'
    '^\s*ConvertTo-Json\b'
    '^\s*Invoke-WebRequest\b'
    '^\s*Resolve-Path\b'
    '^\s*Split-Path\b'
    '^\s*Join-Path\b'

    # ── Shell builtins / misc ──────────────────────────────────────────
    '^\s*\$\w'
    '^\s*export\b'
    '^\s*alias\b'
    '^\s*source\b'
    '^\s*\.\s+'
    '^\s*cd\b'
    '^\s*pushd\b'
    '^\s*popd\b'
    '^\s*(rtk(\.exe)?\s+)?rm\s+[^-]'
    '^\s*(rtk(\.exe)?\s+)?rm\s+-i\b'
)

for pattern in "${SAFE_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
        allow
    fi
done

# ── UNKNOWN commands → ask the user ─────────────────────────────────────
ask "Unclassified command — needs human review"
