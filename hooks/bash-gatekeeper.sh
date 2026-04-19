#!/usr/bin/env bash
# bash-gatekeeper.sh
# "Factory Droid Medium Autonomy" — auto-allow reversible Bash commands,
# block irreversible/destructive ones, let the user decide on everything else.
#
# Works on Linux (native bash) and Windows (Git Bash).

set -euo pipefail

INPUT=$(cat)

# ── Extract the command from JSON stdin ─────────────────────────────────
if command -v jq &>/dev/null; then
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
elif command -v python3 &>/dev/null; then
    COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))")
elif command -v python &>/dev/null; then
    COMMAND=$(echo "$INPUT" | python -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))")
else
    # Last resort: grep-based extraction (fragile with escaped quotes)
    COMMAND=$(echo "$INPUT" | grep -oP '"command"\s*:\s*"\K[^"]*' 2>/dev/null || echo "")
fi

# ── Helper: emit JSON decision ──────────────────────────────────────────
allow() {
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
    exit 0
}

ask() {
    local reason="$1"
    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"$reason\"}}"
    exit 0
}

# ── IRREVERSIBLE / DESTRUCTIVE patterns (ASK) ──────────────────────────
# These cannot be undone. Claude MUST ask the user.
DESTRUCTIVE_PATTERNS=(
    '^\s*rm\s+-[^ ]*r'             # rm -r, rm -rf, rm -ri (recursive delete)
    '^\s*rm\s+-[^ ]*f'             # rm -f (forced delete, no confirmation)
    '^\s*rmdir\s+/s'               # rmdir /s (Windows recursive)
    '^\s*del\s+/s'                  # del /s  (Windows recursive)
    '\|\s*rm\b'                     # piped into rm
    'format\s+[a-zA-Z]:'           # format drive
    '^\s*dd\s+'                     # dd (disk destroyer)
    'mkfs\.'                        # mkfs (make filesystem)
    '^\s*shutdown'                  # shutdown
    '^\s*reboot'                    # reboot
    '^\s*init\s+[0-6]'             # init level change
    '^\s*kill\s+-9'                # force kill
    '^\s*pkill\s+-9'               # force pkill
    '>\s+/etc/'                     # overwrite system config
    '^\s*chmod\s+000'              # remove all permissions
    '^\s*chown\s+root'             # change ownership to root
    'curl\s+.*\|\s*(ba)?sh'        # pipe curl to shell
    'wget\s+.*\|\s*(ba)?sh'        # pipe wget to shell
    '^\s*git\s+push\s+.*--force'   # force push (rewrites history)
    '^\s*git\s+push\s+-f\b'       # force push shorthand
    '^\s*git\s+reset\s+--hard'     # hard reset (loses uncommitted work)
    '^\s*git\s+clean\s+-fd'        # git clean force (deletes untracked)
    '^\s*npm\s+publish'            # publish package
    '^\s*npx\s+.*publish'          # publish via npx
    '^\s*docker\s+system\s+prune'  # docker system prune
    '^\s*docker\s+rm\s+-f'         # force remove containers
    '^\s*docker\s+rmi\s+-f'        # force remove images
    'DROP\s+DATABASE'               # SQL drop database
    'DROP\s+TABLE'                  # SQL drop table
    'TRUNCATE\s+'                   # SQL truncate
    ':\s*>\s+'                      # truncate file with : >
    '^\s*mv\s+/\s'                  # move root
    'sudo\s+rm'                     # sudo rm
    'sudo\s+dd'                     # sudo dd
    '^\s*Remove-Item\s+.*-Recurse' # PowerShell recursive delete
    '^\s*Remove-Item\s+.*-Force'   # PowerShell force delete
)

for pattern in "${DESTRUCTIVE_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
        ask "IRREVERSIBLE command detected — requires human approval"
    fi
done

# ── REVERSIBLE / READ-ONLY patterns (ALLOW) ────────────────────────────
# These are safe or easily undoable. Let Claude run them freely.
SAFE_PATTERNS=(
    # ── Read-only / informational ───────────────────────────────────────
    '^\s*ls\b'
    '^\s*dir\b'
    '^\s*cat\b'
    '^\s*echo\b'
    '^\s*printf\b'
    '^\s*head\b'
    '^\s*tail\b'
    '^\s*wc\b'
    '^\s*sort\b'
    '^\s*uniq\b'
    '^\s*grep\b'
    '^\s*rg\b'
    '^\s*find\b'
    '^\s*fd\b'
    '^\s*which\b'
    '^\s*where\b'
    '^\s*type\b'
    '^\s*file\b'
    '^\s*stat\b'
    '^\s*pwd\b'
    '^\s*env\b'
    '^\s*printenv\b'
    '^\s*set\b'
    '^\s*tree\b'
    '^\s*du\b'
    '^\s*df\b'
    '^\s*diff\b'
    '^\s*less\b'
    '^\s*more\b'
    '^\s*true\b'
    '^\s*false\b'
    '^\s*test\b'
    '^\s*\[\s'
    '^\s*basename\b'
    '^\s*dirname\b'
    '^\s*realpath\b'
    '^\s*readlink\b'
    '^\s*date\b'
    '^\s*whoami\b'
    '^\s*hostname\b'
    '^\s*uname\b'
    '^\s*id\b'
    '^\s*uptime\b'
    '^\s*free\b'
    '^\s*ps\b'
    '^\s*top\b'
    '^\s*htop\b'
    '^\s*seq\b'
    '^\s*tr\b'
    '^\s*cut\b'
    '^\s*awk\b'
    '^\s*sed\b'
    '^\s*jq\b'
    '^\s*xargs\b'
    '^\s*tee\b'
    '^\s*yes\b'

    # ── Reversible filesystem operations ────────────────────────────────
    '^\s*mkdir\b'                   # reversible: rmdir undoes it
    '^\s*touch\b'                   # reversible: rm the file
    '^\s*cp\b'                      # reversible: delete the copy
    '^\s*mv\b'                      # reversible: mv back (non-root caught above)
    '^\s*ln\b'                      # reversible: unlink
    '^\s*chmod\s+[1-7]'            # reversible: chmod back (non-000)

    # ── Git (safe operations) ──────────────────────────────────────────
    '^\s*git\s+status'
    '^\s*git\s+log'
    '^\s*git\s+diff'
    '^\s*git\s+show'
    '^\s*git\s+branch'
    '^\s*git\s+tag'
    '^\s*git\s+stash'
    '^\s*git\s+remote'
    '^\s*git\s+fetch'
    '^\s*git\s+pull'                # reversible: git reset
    '^\s*git\s+add\b'              # reversible: git reset HEAD
    '^\s*git\s+commit\b'           # reversible: git reset --soft
    '^\s*git\s+checkout\b'         # reversible: checkout back
    '^\s*git\s+switch\b'           # reversible: switch back
    '^\s*git\s+merge\b'            # reversible: git merge --abort or reset
    '^\s*git\s+rebase\b'           # reversible: git rebase --abort
    '^\s*git\s+cherry-pick\b'      # reversible: git cherry-pick --abort
    '^\s*git\s+restore\b'
    '^\s*git\s+rev-parse\b'
    '^\s*git\s+config\b'
    '^\s*git\s+ls-files\b'
    '^\s*git\s+worktree\b'
    '^\s*git\s+push\b'             # normal push (no --force) is reversible

    # ── Node.js / npm / package managers ───────────────────────────────
    '^\s*npm\s+install\b'
    '^\s*npm\s+ci\b'
    '^\s*npm\s+run\b'
    '^\s*npm\s+test\b'
    '^\s*npm\s+start\b'
    '^\s*npm\s+build\b'
    '^\s*npm\s+exec\b'
    '^\s*npm\s+init\b'
    '^\s*npm\s+ls\b'
    '^\s*npm\s+list\b'
    '^\s*npm\s+outdated\b'
    '^\s*npm\s+info\b'
    '^\s*npm\s+view\b'
    '^\s*npm\s+pack\b'
    '^\s*npm\s+audit\b'
    '^\s*npm\s+explain\b'
    '^\s*npm\s+why\b'
    '^\s*npx\b'
    '^\s*node\b'
    '^\s*tsx\b'
    '^\s*ts-node\b'
    '^\s*tsc\b'

    # ── Linters / formatters / test runners ────────────────────────────
    '^\s*eslint\b'
    '^\s*prettier\b'
    '^\s*vitest\b'
    '^\s*jest\b'
    '^\s*mocha\b'
    '^\s*playwright\b'
    '^\s*cypress\b'

    # ── Build tools / bundlers ─────────────────────────────────────────
    '^\s*next\b'
    '^\s*vite\b'
    '^\s*webpack\b'
    '^\s*rollup\b'
    '^\s*esbuild\b'
    '^\s*turbo\b'

    # ── Other package managers ─────────────────────────────────────────
    '^\s*pnpm\b'
    '^\s*yarn\b'
    '^\s*bun\b'
    '^\s*deno\b'

    # ── Other languages / runtimes ─────────────────────────────────────
    '^\s*python\b'
    '^\s*python3\b'
    '^\s*pip\b'
    '^\s*pip3\b'
    '^\s*cargo\b'
    '^\s*rustc\b'
    '^\s*go\s+(build|run|test|vet|fmt|mod|get|version)\b'
    '^\s*dotnet\b'
    '^\s*docker\s+(build|run|ps|images|logs|inspect|exec|compose)\b'

    # ── Networking (read-only, pipe-to-sh caught above) ────────────────
    '^\s*curl\b'
    '^\s*wget\b'
    '^\s*ssh\b'
    '^\s*scp\b'
    '^\s*rsync\b'

    # ── Archives ───────────────────────────────────────────────────────
    '^\s*tar\b'
    '^\s*zip\b'
    '^\s*unzip\b'
    '^\s*gzip\b'
    '^\s*gunzip\b'
    '^\s*7z\b'

    # ── PowerShell cmdlets (Windows cross-compat) ──────────────────────
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
    '^\s*\$\w'                      # variable assignments
    '^\s*export\b'
    '^\s*alias\b'
    '^\s*source\b'
    '^\s*\.\s+'                     # source shorthand
    '^\s*cd\b'
    '^\s*pushd\b'
    '^\s*popd\b'
    '^\s*rm\s+[^-]'                # rm single file (no flags) — reversible via git
    '^\s*rm\s+-i\b'                # rm interactive (asks first)
)

for pattern in "${SAFE_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
        allow
    fi
done

# ── UNKNOWN commands → ask the user ─────────────────────────────────────
# If we can't classify it, ask for approval (safe default).
ask "Unclassified command — needs human review"
