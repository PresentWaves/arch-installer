#!/bin/bash
# common.sh — shared helpers sourced by every phase script
# Do not run directly.

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${YELLOW}[*] $1${NC}"; }
ok()      { echo -e "${GREEN}[+] $1${NC}"; }
error()   { echo -e "${RED}[!] $1${NC}"; exit 1; }
warn()    { echo -e "${YELLOW}[!] $1${NC}"; }
skip()    { echo -e "${BLUE}[-] $1 — skipping${NC}"; }

readonly PHASE_SKIPPED=42

phase_skipped() {
    skip "$1"
    exit $PHASE_SKIPPED
}

# shellcheck disable=SC2034 # used downstream via source
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
# shellcheck disable=SC2034
CONFIG_ENV="$BOOTSTRAP_DIR/config.env"

# Source config.env if present (optional — interactive prompts fill missing vars)
# shellcheck disable=SC1090
[[ -f "$CONFIG_ENV" ]] && source "$CONFIG_ENV"

# Derive SCRIPT_DIR for the calling script (not common.sh itself)
# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

# ── Package install ─────────────────────────────────────────────────────────

# Install any of the given packages that are missing. Each phase declares its
# own dependencies so phases stay decoupled — overlap with the Phase 00
# pacstrap list is intentional and free (pacman -Q makes re-checks a no-op).
ensure_packages() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        pacman -Q "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing: ${missing[*]}"
        sudo pacman -S --noconfirm --needed "${missing[@]}"
        ok "Installed: ${missing[*]}"
    fi
}

# ── SSH auth check ──────────────────────────────────────────────────────────

# Returns 0 if SSH agent has at least one key (YubiKey or otherwise).
# Used by phases that clone over SSH to fail gracefully.
ssh_has_key() {
    ssh-add -L &>/dev/null
}

setup_ssh_auth() {
    info "Setting up SSH auth agent..."
    export SSH_AUTH_SOCK
    SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
    ok "SSH auth agent ready"
}

# ── Git clone ────────────────────────────────────────────────────────────────

# Clone a repo using the configured protocol (GIT_PROTOCOL=ssh|https).
# Also manages the insteadOf rule so it matches the chosen protocol.
# Usage: git_clone owner/repo /path/to/dest
git_clone() {
    local repo="$1"
    local dest="$2"
    local config_file="$HOME/.gitconfig"

    rm -rf "$dest"

    if [[ "${GIT_PROTOCOL:-https}" == "ssh" ]]; then
        git config --file "$config_file" url."git@github.com:".insteadof "https://github.com/"
        info "Cloning ${repo} via SSH..."
        git clone "git@github.com:${repo}.git" "$dest"
    else
        git config --file "$config_file" --unset url."git@github.com:".insteadof 2>/dev/null || true
        info "Cloning ${repo} via HTTPS..."
        git clone "https://github.com/${repo}.git" "$dest"
    fi
}
