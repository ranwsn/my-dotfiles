#!/usr/bin/env bash
# install-binaries.sh - Linux-only fixups and tools not packaged in apt.
#   - fzf:       git clone per https://github.com/junegunn/fzf#using-git
#                (apt's version on some distros lacks `fzf --zsh` key bindings,
#                 added in fzf 0.48.0)
#   - gdu:       GitHub release (not in default Debian/Ubuntu repos)
#   - uv:        Astral's official install script
#                (not in default Debian/Ubuntu repos)
#   - bat shim:  symlink batcat → ~/.local/bin/bat on older Debian/Ubuntu
#                where the apt `bat` package installs as `batcat`.
#                (Modern Debian 11+/Ubuntu 20.04+ install as `bat` natively
#                 and this function is a no-op.)
set -euo pipefail

log_info() { echo "ℹ️  $*"; }
log_ok()   { echo "✅ $*"; }
log_skip() { echo "⏭️  $*"; }
log_warn() { echo "⚠️  $*"; }

command_exists() { command -v "$1" &>/dev/null; }

get_arch() {
  case "$(uname -m)" in
    x86_64)         echo "x86_64" ;;
    aarch64|arm64)  echo "aarch64" ;;
    *)              uname -m ;;
  esac
}

get_github_release_version() {
  local repo="$1"
  local response version
  response=$(curl -sSf "https://api.github.com/repos/${repo}/releases/latest" 2>&1) || {
    if echo "$response" | grep -qi "rate limit"; then
      log_warn "GitHub API rate limit exceeded. Set GITHUB_TOKEN for higher limits."
    else
      log_warn "Failed to fetch release info for $repo: $response"
    fi
    return 1
  }
  version=$(echo "$response" | grep -Po '"tag_name": "v?\K[^"]+' | head -1)
  [[ -n "$version" ]] || { log_warn "Could not parse version for $repo"; return 1; }
  echo "$version"
}

install_fzf() {
  local fzf_dir="$HOME/.fzf"
  if [[ -d "$fzf_dir" ]]; then
    log_info "Updating fzf..."
    git -C "$fzf_dir" pull --quiet
    "$fzf_dir/install" --bin --no-bash --no-fish --no-update-rc
    log_ok "fzf updated"
    return 0
  fi
  log_info "Installing fzf from git..."
  git clone --depth 1 https://github.com/junegunn/fzf.git "$fzf_dir"
  # install.sh runs backup_user_dotfiles BEFORE this script, so ~/.zshrc is
  # already moved aside. fzf's installer sees no pre-existing rcfile and so
  # no "Continue modifying ~/.zshrc?" prompt fires.
  # (Do NOT pipe `yes n` here: under set -euo pipefail, `yes` gets SIGPIPE
  # when fzf exits, and the resulting 141 kills the whole script.)
  "$fzf_dir/install" --key-bindings --completion --no-update-rc --no-bash --no-fish
  log_ok "fzf installed to $fzf_dir"
}

install_gdu() {
  if command_exists gdu; then
    log_skip "gdu already installed ($(gdu --version 2>&1 | head -1))"
    return 0
  fi
  local version arch arch_name
  version=$(get_github_release_version "dundee/gdu") || return 1
  arch=$(get_arch)
  case "$arch" in
    x86_64)  arch_name="amd64" ;;
    aarch64) arch_name="arm64" ;;
    *) log_warn "Unsupported architecture for gdu: $arch"; return 1 ;;
  esac

  log_info "Installing gdu $version..."
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN
  curl -LSsf "https://github.com/dundee/gdu/releases/download/v${version}/gdu_linux_${arch_name}.tgz" \
    -o "$tmpdir/gdu.tgz"
  tar -xzf "$tmpdir/gdu.tgz" -C "$tmpdir"

  local bindir="$HOME/.local/bin"
  mkdir -p "$bindir"
  mv "$tmpdir/gdu_linux_${arch_name}" "$bindir/gdu"
  chmod +x "$bindir/gdu"
  log_ok "gdu installed to $bindir/gdu"
}

install_uv() {
  if command_exists uv; then
    log_skip "uv already installed ($(uv --version))"
    return 0
  fi
  log_info "Installing uv via Astral's install script..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  log_ok "uv installed (will be on PATH after sourcing ~/.local/bin)"
}

# Older Debian/Ubuntu install the `bat` apt package as `/usr/bin/batcat`
# (name clash with another package). Newer releases (Debian 11+/Ubuntu 20.04+)
# install as `bat` natively, in which case this function is a no-op.
# See https://github.com/sharkdp/bat#on-ubuntu-using-apt
symlink_batcat() {
  local bin="$HOME/.local/bin/bat"
  if [[ -x "$bin" ]]; then
    log_skip "bat symlink already present at $bin"
    return 0
  fi
  if command_exists batcat; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v batcat)" "$bin"
    log_ok "Symlinked batcat → $bin (older-distro bat→batcat workaround)"
  elif command_exists bat; then
    log_skip "bat installed natively as 'bat'; no symlink needed"
  else
    log_warn "Neither bat nor batcat found (apt install bat may have failed)"
  fi
}

main() {
  echo "========================================"
  echo "  Linux extras: fzf, gdu, bat symlink"
  echo "========================================"
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"

  install_fzf
  install_gdu
  install_uv
  symlink_batcat

  echo ""
  echo "Done. Ensure ~/.local/bin is on your PATH."
}

main "$@"
