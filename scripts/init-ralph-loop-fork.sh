#!/bin/bash

# Ralph Loop Fork — Dependency Initialiser
#
# Checks all required and optional dependencies, attempts auto-install where
# possible, and prints a clear summary. Safe to re-run at any time.
#
# Usage:
#   scripts/init-ralph-loop-fork.sh [--check-only]
#
# Flags:
#   --check-only   Report status without attempting any installation.

set -uo pipefail

CHECK_ONLY=false
for arg in "$@"; do
  [[ "$arg" == "--check-only" ]] && CHECK_ONLY=true
done

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}~${NC} $1"; WARN=$((WARN+1)); }
info() { echo -e "  ${CYAN}→${NC} $1"; }

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
OS="$(uname -s 2>/dev/null || echo unknown)"
IS_MAC=false
IS_APT=false
IS_PACMAN=false
IS_BREW=false

[[ "$OS" == "Darwin" ]] && IS_MAC=true
command -v brew    >/dev/null 2>&1 && IS_BREW=true
command -v apt-get >/dev/null 2>&1 && IS_APT=true
command -v pacman  >/dev/null 2>&1 && IS_PACMAN=true

IS_WINDOWS=false
if [[ -n "${MSYSTEM:-}" ]] || [[ "$OS" == MINGW* ]] || [[ "$OS" == MSYS* ]]; then
  IS_WINDOWS=true
fi

# ---------------------------------------------------------------------------
# Install helper — tries the right package manager for this platform
# ---------------------------------------------------------------------------
try_install() {
  local pkg="$1"      # package name (may differ from binary name)
  local binary="$2"   # binary to re-check after install

  if [[ "$CHECK_ONLY" == "true" ]]; then
    return 1  # never install in check-only mode
  fi

  if $IS_WINDOWS; then
    info "Cannot auto-install on Windows — install $pkg manually."
    return 1
  fi

  if $IS_BREW; then
    info "Running: brew install $pkg"
    brew install "$pkg" >/dev/null 2>&1 && command -v "$binary" >/dev/null 2>&1 && return 0
  fi

  if $IS_APT; then
    info "Running: sudo apt-get install -y $pkg"
    sudo apt-get install -y "$pkg" >/dev/null 2>&1 && command -v "$binary" >/dev/null 2>&1 && return 0
  fi

  if $IS_PACMAN; then
    info "Running: sudo pacman -S --noconfirm $pkg"
    sudo pacman -S --noconfirm "$pkg" >/dev/null 2>&1 && command -v "$binary" >/dev/null 2>&1 && return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Check one binary dep: auto-install if missing, report outcome
# ---------------------------------------------------------------------------
check_dep() {
  local binary="$1"
  local pkg="${2:-$1}"      # package name if different from binary
  local label="${3:-$pkg}"  # human label for output
  local required="${4:-true}"

  if command -v "$binary" >/dev/null 2>&1; then
    ok "$label"
    return 0
  fi

  if [[ "$required" == "false" ]]; then
    warn "$label — not found (optional, has fallback)"
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    fail "$label — not found (run without --check-only to auto-install)"
    return 1
  fi

  info "$label not found — attempting install..."
  if try_install "$pkg" "$binary"; then
    ok "$label (just installed)"
  else
    fail "$label — install failed or no package manager available"
    info "Install manually: $label — $(install_hint "$binary")"
    return 1
  fi
}

install_hint() {
  case "$1" in
    jq)    echo "brew install jq  |  apt-get install jq  |  https://jqlang.github.io/jq/" ;;
    tmux)  echo "brew install tmux  |  apt-get install tmux  |  https://github.com/tmux/tmux" ;;
    xxd)   echo "brew install vim  |  apt-get install xxd  (part of vim-common on some distros)" ;;
    git)   echo "brew install git  |  apt-get install git  |  https://git-scm.com/downloads" ;;
    claude) echo "Install Claude Code CLI — https://claude.ai/code" ;;
    *)     echo "see your package manager" ;;
  esac
}

# ---------------------------------------------------------------------------
# Git version check (worktree requires ≥ 2.5)
# ---------------------------------------------------------------------------
check_git_version() {
  if ! command -v git >/dev/null 2>&1; then
    if [[ "$CHECK_ONLY" == "true" ]]; then
      fail "git — not found"
    else
      info "git not found — attempting install..."
      if try_install git git; then
        ok "git (just installed)"
      else
        fail "git — install failed"
        info "Install: $(install_hint git)"
      fi
    fi
    return
  fi

  local ver
  ver=$(git --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
  local major minor
  major=$(echo "$ver" | cut -d. -f1)
  minor=$(echo "$ver" | cut -d. -f2)

  if [[ "$major" -gt 2 ]] || { [[ "$major" -eq 2 ]] && [[ "$minor" -ge 5 ]]; }; then
    ok "git $ver (worktree support confirmed)"
  else
    fail "git $ver — worktree mode requires git ≥ 2.5 (upgrade git)"
  fi
}

# ---------------------------------------------------------------------------
# claude CLI check (only needed for --worktree mode)
# ---------------------------------------------------------------------------
check_claude() {
  if command -v claude >/dev/null 2>&1; then
    ok "claude CLI (needed for --worktree mode)"
  else
    warn "claude CLI — not found"
    info "Required only for --worktree mode."
    info "Install: https://claude.ai/code"
    WARN=$((WARN+1))
    PASS=$((PASS-1))  # undo the warn() increment duplication
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}=================================================================${NC}"
echo -e "${BOLD} Ralph Loop Fork — Dependency Check${NC}"
if $CHECK_ONLY; then
  echo -e "${BOLD} Mode: check only (no installation)${NC}"
fi
echo -e "${BOLD}=================================================================${NC}"
echo ""
echo -e "${BOLD}Required (always):${NC}"
check_dep jq  jq  "jq"
check_dep tmux tmux "tmux"
check_dep xxd xxd "xxd"

echo ""
echo -e "${BOLD}Required for worktree mode (--worktree):${NC}"
check_git_version
check_claude

echo ""
echo -e "${BOLD}Optional (have fallbacks):${NC}"
check_dep uuidgen uuidgen "uuidgen" false
if command -v md5sum >/dev/null 2>&1 || command -v md5 >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
  ok "checksum tool (md5sum / md5 / shasum)"
else
  warn "No checksum tool found — checklist progress detection disabled"
fi

echo ""
echo -e "${BOLD}=================================================================${NC}"
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}  All required dependencies satisfied.${NC}"
  if [[ $WARN -gt 0 ]]; then
    echo -e "${YELLOW}  $WARN optional item(s) missing — see warnings above.${NC}"
  fi
  echo -e "${BOLD}=================================================================${NC}"
  echo ""
  exit 0
else
  echo -e "${RED}  $FAIL required dependency/dependencies MISSING.${NC}"
  echo -e "  Fix the issues above, then re-run:"
  echo -e "  ${CYAN}/ralph-loop-fork:init-ralph-fork${NC}"
  echo -e "${BOLD}=================================================================${NC}"
  echo ""
  exit 1
fi
