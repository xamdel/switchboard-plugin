#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Sixerr OpenClaw Patch
#
# Applies three surgical fixes to a standard OpenClaw npm install:
#   1. Streaming tool call interception (gateway)
#   2. clientTools parameter passthrough (embedded runner)
#   3. before_agent_start systemPrompt + promptOverride hooks (embedded runner)
#
# Usage:
#   curl -fsSL https://sixerr.ai/patch.sh | bash
#
# Reversible:
#   Backups are saved as *.sixerr-backup. To restore:
#     cp file.sixerr-backup file
# =============================================================================

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
RESET='\033[0m'

ok()   { printf "${GREEN}✔${RESET}  %s\n" "$1"; }
fail() { printf "${RED}✖${RESET}  %s\n" "$1" >&2; exit 1; }
info() { printf "${CYAN}ℹ${RESET}  %s\n" "$1"; }
warn() { printf "${YELLOW}⚠${RESET}  %s\n" "$1"; }

# ---------------------------------------------------------------------------
# Tested OpenClaw versions
# ---------------------------------------------------------------------------

TESTED_VERSIONS=("2026.2.10")

# ---------------------------------------------------------------------------
# Find OpenClaw dist directory
# ---------------------------------------------------------------------------

find_openclaw_dist() {
  local candidates=(
    "$(npm root -g 2>/dev/null)/openclaw/dist"
    "$HOME/.npm-global/lib/node_modules/openclaw/dist"
    "/usr/lib/node_modules/openclaw/dist"
    "/usr/local/lib/node_modules/openclaw/dist"
  )
  for dir in "${candidates[@]}"; do
    if [ -d "$dir" ]; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}

printf "\n"
printf "${BOLD}${CYAN}  ╔═══════════════════════════════════════╗${RESET}\n"
printf "${BOLD}${CYAN}  ║      Sixerr Patcher                   ║${RESET}\n"
printf "${BOLD}${CYAN}  ║      Patch OpenClaw for Sixerr relay   ║${RESET}\n"
printf "${BOLD}${CYAN}  ╚═══════════════════════════════════════╝${RESET}\n"
printf "\n"

DIST_DIR=$(find_openclaw_dist) || fail "Could not find OpenClaw dist directory. Is OpenClaw installed globally?"
info "Found OpenClaw at: $DIST_DIR"

# ---------------------------------------------------------------------------
# Version check
# ---------------------------------------------------------------------------

PKG_JSON="$DIST_DIR/../package.json"
if [ -f "$PKG_JSON" ]; then
  OC_VERSION=$(node -e "console.log(require('$PKG_JSON').version)" 2>/dev/null || echo "unknown")
  info "OpenClaw version: $OC_VERSION"

  version_tested=false
  for v in "${TESTED_VERSIONS[@]}"; do
    if [[ "$OC_VERSION" == "$v" ]]; then
      version_tested=true
      break
    fi
  done

  if [ "$version_tested" = false ]; then
    warn "This patch was tested against OpenClaw ${TESTED_VERSIONS[*]}"
    warn "You have $OC_VERSION — patches may not apply cleanly"
    printf "\n"
    if [ -t 0 ]; then
      read -rp "  Continue anyway? [y/N] " confirm
      if [[ ! "$confirm" =~ ^[Yy] ]]; then
        info "Aborted."
        exit 0
      fi
    else
      warn "Non-interactive mode — continuing anyway"
    fi
  else
    ok "Version $OC_VERSION is tested"
  fi
else
  warn "Could not read OpenClaw version — proceeding with caution"
fi

# ---------------------------------------------------------------------------
# Find target files dynamically (handles hashed filenames)
# ---------------------------------------------------------------------------

GW_FILE=$(grep -rl "maybeFinalize" "$DIST_DIR"/gateway-cli-*.js 2>/dev/null | head -1) \
  || fail "Could not find gateway CLI bundle (looked for maybeFinalize in gateway-cli-*.js)"

EMB_FILE=$(grep -rl "clientTools: params.clientTools\|disableTools: params.disableTools" "$DIST_DIR"/pi-embedded-*.js 2>/dev/null \
  | xargs grep -l "hookRunner.*hasHooks.*before_agent_start" 2>/dev/null | head -1) \
  || fail "Could not find embedded runner bundle"

info "Gateway file:  $(basename "$GW_FILE")"
info "Embedded file: $(basename "$EMB_FILE")"

# ---------------------------------------------------------------------------
# Check if already patched
# ---------------------------------------------------------------------------

if grep -q "SIXERR_PATCHED" "$GW_FILE" 2>/dev/null; then
  ok "Already patched — nothing to do"
  exit 0
fi

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

cp "$GW_FILE" "${GW_FILE}.sixerr-backup"
cp "$EMB_FILE" "${EMB_FILE}.sixerr-backup"
ok "Backups created"

# ---------------------------------------------------------------------------
# Patch 1: Gateway streaming tool call fix
#
# Problem: maybeFinalize() runs before tool call check in streaming mode,
#          closing the stream as text-only and skipping the tool call.
# Fix:     Move tool call check before maybeFinalize(), handle accumulated
#          text from streaming deltas.
# ---------------------------------------------------------------------------

info "Applying patch 1/3: Gateway streaming tool call fix"

node -e "
const fs = require('fs');
const file = process.argv[1];
let code = fs.readFileSync(file, 'utf8');

const oldPattern = [
  'finalUsage = extractUsageFromResult(result);',
  '\t\t\tmaybeFinalize();',
  '\t\t\tif (closed) return;',
  '\t\t\tif (!sawAssistantDelta) {',
  '\t\t\t\tconst resultAny = result;',
  '\t\t\t\tconst payloads = resultAny.payloads;',
  '\t\t\t\tconst meta = resultAny.meta;',
  '\t\t\t\tconst stopReason = meta && typeof meta === \"object\" ? meta.stopReason : void 0;',
  '\t\t\t\tconst pendingToolCalls = meta && typeof meta === \"object\" ? meta.pendingToolCalls : void 0;',
  '\t\t\t\tif (stopReason === \"tool_calls\" && pendingToolCalls && pendingToolCalls.length > 0) {',
  '\t\t\t\t\tconst functionCall = pendingToolCalls[0];',
  '\t\t\t\t\tconst usage = finalUsage ?? createEmptyUsage();',
].join('\n');

const newPattern = [
  'finalUsage = extractUsageFromResult(result);',
  '\t\t\tif (closed) return; // SIXERR_PATCHED',
  '\t\t\tconst resultAny = result;',
  '\t\t\tconst payloads = resultAny.payloads;',
  '\t\t\tconst meta = resultAny.meta;',
  '\t\t\tconst stopReason = meta && typeof meta === \"object\" ? meta.stopReason : void 0;',
  '\t\t\tconst pendingToolCalls = meta && typeof meta === \"object\" ? meta.pendingToolCalls : void 0;',
  '\t\t\tif (stopReason === \"tool_calls\" && pendingToolCalls && pendingToolCalls.length > 0) {',
  '\t\t\t\tconst functionCall = pendingToolCalls[0];',
  '\t\t\t\tconst usage = finalUsage ?? createEmptyUsage();',
  '\t\t\t\tconst textSoFar = sawAssistantDelta ? accumulatedText : \"\";',
].join('\n');

if (!code.includes(oldPattern)) {
  console.error('PATCH1_MATCH_FAILED');
  process.exit(1);
}

code = code.replace(oldPattern, newPattern);

// Fix output_text.done text
code = code.replace(
  /(\t\t\t\t\tconst textSoFar = sawAssistantDelta \? accumulatedText : \"\";[\s\S]*?type: \"response\.output_text\.done\",[\s\S]*?)text: \"\"/,
  '\$1text: textSoFar'
);

// Fix content_part.done text
code = code.replace(
  /(type: \"response\.content_part\.done\",[\s\S]*?type: \"output_text\",[\s\S]*?)text: \"\"/,
  '\$1text: textSoFar'
);

// Fix createAssistantOutputItem text
code = code.replace(
  /(const completedItem = createAssistantOutputItem\(\{[\s\S]*?id: outputItemId,[\s\S]*?)text: \"\",/,
  '\$1text: textSoFar,'
);

// Add maybeFinalize after the tool call return block
code = code.replace(
  /\t\t\t\treturn;\n\t\t\t\t}\n\t\t\t\tconst content = /,
  '\t\t\t\treturn;\n\t\t\t\t}\n\t\t\t\tmaybeFinalize();\n\t\t\t\tif (closed) return;\n\t\t\t\tif (!sawAssistantDelta) {\n\t\t\t\tconst content = '
);

fs.writeFileSync(file, code);
console.log('OK');
" "$GW_FILE" || fail "Patch 1 failed — gateway code structure may have changed"

ok "Patch 1 applied"

# ---------------------------------------------------------------------------
# Patch 2: clientTools parameter passthrough
#
# Problem: clientTools not passed through to runEmbeddedAttempt call
# Fix:     Add clientTools: params.clientTools to the call object
# ---------------------------------------------------------------------------

info "Applying patch 2/3: clientTools passthrough"

node -e "
const fs = require('fs');
const file = process.argv[1];
let code = fs.readFileSync(file, 'utf8');

const marker = 'images: params.images,';
const idx = code.indexOf(marker);
if (idx === -1) { console.error('PATCH2_MATCH_FAILED'); process.exit(1); }
const lineStart = code.lastIndexOf('\\n', idx) + 1;
const indent = code.slice(lineStart, idx);
const oldPattern = indent + 'images: params.images,\\n' + indent + 'disableTools: params.disableTools,';
const newPattern = indent + 'images: params.images,\\n' + indent + 'clientTools: params.clientTools,\\n' + indent + 'disableTools: params.disableTools,';

if (!code.includes(oldPattern)) {
  console.error('PATCH2_MATCH_FAILED');
  process.exit(1);
}

code = code.replace(oldPattern, newPattern);
fs.writeFileSync(file, code);
console.log('OK');
" "$EMB_FILE" || fail "Patch 2 failed — embedded runner structure may have changed"

ok "Patch 2 applied"

# ---------------------------------------------------------------------------
# Patch 3: before_agent_start hook - systemPrompt + promptOverride
#
# Problem: Hook result systemPrompt and promptOverride not handled
# Fix:     Add handling after prependContext check
# ---------------------------------------------------------------------------

info "Applying patch 3/3: before_agent_start hook enhancements"

node -e "
const fs = require('fs');
const file = process.argv[1];
let code = fs.readFileSync(file, 'utf8');

// Find the prependContext log marker and insert after its closing brace
const marker = 'hooks: prepended context to prompt';
if (!code.includes(marker)) {
  console.error('PATCH3_MATCH_FAILED');
  process.exit(1);
}

const idx = code.indexOf(marker);
const afterLog = code.indexOf('}', idx);
const insertPoint = afterLog + 1;

const addition = '\\n\\t\\t\\t\\t\\t\\tif (hookResult?.promptOverride) {\\n\\t\\t\\t\\t\\t\\t\\teffectivePrompt = hookResult.promptOverride;\\n\\t\\t\\t\\t\\t\\t}\\n\\t\\t\\t\\t\\t\\tif (hookResult?.systemPrompt) {\\n\\t\\t\\t\\t\\t\\t\\tapplySystemPromptOverrideToSession(activeSession, hookResult.systemPrompt);\\n\\t\\t\\t\\t\\t\\t}';

code = code.slice(0, insertPoint) + addition + code.slice(insertPoint);
fs.writeFileSync(file, code);
console.log('OK');
" "$EMB_FILE" || fail "Patch 3 failed — hook runner structure may have changed"

ok "Patch 3 applied"

# ---------------------------------------------------------------------------
# Post-patch verification
# ---------------------------------------------------------------------------

printf "\n"
info "Verifying patches..."

errors=0

# Verify patch 1: SIXERR_PATCHED marker + textSoFar in gateway
if grep -q "SIXERR_PATCHED" "$GW_FILE"; then
  ok "Patch 1 verified: streaming tool call marker present"
else
  fail "Patch 1 verification failed: SIXERR_PATCHED marker not found"
  errors=$((errors + 1))
fi

if grep -q "textSoFar" "$GW_FILE"; then
  ok "Patch 1 verified: textSoFar variable present"
else
  warn "Patch 1 partial: textSoFar not found — text accumulation may not work"
  errors=$((errors + 1))
fi

# Verify patch 2: clientTools passthrough
if grep -q "clientTools: params.clientTools" "$EMB_FILE"; then
  ok "Patch 2 verified: clientTools passthrough present"
else
  warn "Patch 2 verification failed: clientTools passthrough not found"
  errors=$((errors + 1))
fi

# Verify patch 3: promptOverride + systemPrompt
if grep -q "hookResult?.promptOverride" "$EMB_FILE"; then
  ok "Patch 3 verified: promptOverride handler present"
else
  warn "Patch 3 verification failed: promptOverride not found"
  errors=$((errors + 1))
fi

if grep -q "hookResult?.systemPrompt" "$EMB_FILE"; then
  ok "Patch 3 verified: systemPrompt handler present"
else
  warn "Patch 3 verification failed: systemPrompt not found"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  printf "\n"
  warn "$errors verification(s) failed — patches may not work correctly"
  warn "To revert: cp *.sixerr-backup to restore originals"
  exit 1
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf "\n${BOLD}${GREEN}All patches applied and verified!${RESET}\n\n"
info "Restart your OpenClaw gateway to activate:"
printf "  ${BOLD}openclaw gateway restart${RESET}\n\n"
printf "${DIM}To revert all patches:${RESET}\n"
printf "  ${DIM}cp ${GW_FILE}.sixerr-backup ${GW_FILE}${RESET}\n"
printf "  ${DIM}cp ${EMB_FILE}.sixerr-backup ${EMB_FILE}${RESET}\n"
printf "  ${DIM}openclaw gateway restart${RESET}\n\n"
