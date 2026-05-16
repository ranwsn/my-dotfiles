#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
DOTFILES_DIR="$HOME/dotfiles"   # staging dir created at install time (must not pre-exist)

log_info() { echo "ℹ️  $*"; }
log_ok()   { echo "✅ $*"; }
log_warn() { echo "⚠️  $*"; }
log_skip() { echo "⏭️  $*"; }
log_err()  { echo "❌ $*" >&2; }

# Files this script will deploy to $HOME (as stow-managed symlinks pointing
# into $DOTFILES_DIR after install).
HOME_DOTFILES=(
  "$HOME/.zshrc"
  "$HOME/.p10k.zsh"
  "$HOME/.gitconfig"
  "$HOME/.vimrc"
)

# Source files that must exist in the repo (validated before any side effects).
REQUIRED_SOURCES=(
  "$SCRIPT_DIR/zsh/.zshrc"
  "$SCRIPT_DIR/zsh/.p10k.zsh"
  "$SCRIPT_DIR/git/.gitconfig"
  "$SCRIPT_DIR/vim/.vimrc"
  "$SCRIPT_DIR/Brewfile"
  "$SCRIPT_DIR/Aptfile"
  "$SCRIPT_DIR/scripts/linux/install-binaries.sh"
)

# Side-effect tracking.
BACKUPS=()
CONFLICTS_AT_VALIDATION=()   # files user explicitly consented to back up
GIT_NAME=""
GIT_EMAIL=""

# Acquired during validation, used during side-effect phase.
OS=""

usage() {
  cat <<'EOF'
Usage: ./install.sh

Environment overrides (skip interactive prompts):
  GIT_USER_NAME    Set git user.name without prompting
  GIT_USER_EMAIL   Set git user.email without prompting

Aborts immediately if ~/dotfiles/ already exists (move it aside and re-run).
EOF
}

run_privileged() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "mac"   ;;
    Linux)  echo "linux" ;;
    *)      echo "other" ;;
  esac
}

# ============================================================================
# === validation phase (no side effects) =====================================
# ============================================================================

validate_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) log_err "Unknown argument: $1"; usage; exit 2 ;;
    esac
  fi
}

validate_os() {
  OS="$(detect_os)"
  if [[ "$OS" != "mac" && "$OS" != "linux" ]]; then
    log_err "Unsupported OS: $(uname -s). This script supports macOS and Linux only."
    exit 1
  fi
  log_ok "Detected OS: $OS"
}

validate_dotfiles_dir_absent() {
  if [[ -e "$DOTFILES_DIR" || -L "$DOTFILES_DIR" ]]; then
    log_err "$DOTFILES_DIR already exists. Aborting to avoid clobbering it."
    log_err "If you want a clean reinstall, move it aside first:"
    log_err "  mv $DOTFILES_DIR ${DOTFILES_DIR}.old"
    log_err "Then re-run ./install.sh"
    exit 1
  fi
  log_ok "$DOTFILES_DIR is clear"
}

validate_source_repo() {
  local missing=()
  local f
  for f in "${REQUIRED_SOURCES[@]}"; do
    [[ -e "$f" ]] || missing+=("$f")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_err "Source repo is missing required files:"
    local m
    for m in "${missing[@]}"; do log_err "  $m"; done
    exit 1
  fi
  log_ok "Source repo files present"
}

validate_os_prereqs() {
  if [[ "$OS" == "mac" ]]; then
    if ! command -v brew &>/dev/null; then
      log_err "Homebrew is required but not installed."
      log_err "Install it from https://brew.sh/ then re-run this script."
      exit 1
    fi
    log_ok "Homebrew detected: $(command -v brew)"
  elif [[ "$OS" == "linux" ]]; then
    if ! command -v apt-get &>/dev/null; then
      log_err "apt-get is required but not found. This script supports Debian/Ubuntu only."
      exit 1
    fi
    log_ok "apt-get detected"
    # Cache sudo credentials NOW so the install doesn't pause mid-progress
    # when the first sudo call fires (e.g., setup_charm_apt_repo).
    # `sudo -n true` is a non-prompting probe — succeeds silently if cache
    # is warm or if all sudo calls we'll make are NOPASSWD-allowed. Only
    # fall back to interactive `sudo -v` if the probe says we'd otherwise
    # prompt mid-install. `sudo -v` itself can spuriously prompt when the
    # user has partial-NOPASSWD sudoers (e.g., NOPASSWD: /usr/bin/apt-get
    # specifically) — so we demote its failure to a warning and let the
    # actual sudo calls handle authentication on their own.
    if [[ $EUID -ne 0 ]]; then
      if sudo -n true 2>/dev/null; then
        log_ok "sudo cache is warm (no prompt expected during install)"
      else
        log_info "sudo may prompt for your password during install."
        log_info "Pre-authenticating now to avoid pausing mid-progress..."
        if ! sudo -v; then
          log_warn "Could not pre-validate sudo. Will prompt as needed."
        fi
      fi
    fi
  fi
}

# Print which HOME_DOTFILES already exist (and aren't already symlinked into
# our soon-to-exist staging dir). One absolute path per line.
list_conflicting_dotfiles() {
  local f target
  for f in "${HOME_DOTFILES[@]}"; do
    if [[ -L "$f" ]]; then
      # readlink -f resolves stow's relative symlinks to absolute path.
      target="$(readlink -f "$f" 2>/dev/null || true)"
      [[ "$target" == "$DOTFILES_DIR"/* ]] && continue
    fi
    if [[ -e "$f" || -L "$f" ]]; then
      echo "$f"
    fi
  done
  return 0
}

validate_backup_consent() {
  local existing
  existing="$(list_conflicting_dotfiles)"
  if [[ -z "$existing" ]]; then
    log_ok "No existing home dotfiles conflict with the install"
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    log_err "Existing home dotfiles would conflict with install, but no TTY is available"
    log_err "to confirm the backup. Run interactively, or move these files aside first:"
    while IFS= read -r f; do log_err "  $f"; done <<<"$existing"
    exit 1
  fi

  echo
  echo "The following files (or symlinks from a previous install) already exist"
  echo "in your home directory. They will be renamed to <file>.bak.<timestamp>"
  echo "before the new install runs:"
  echo
  while IFS= read -r f; do echo "  $f"; done <<<"$existing"
  echo
  local reply=""
  read -r -p "Proceed with install and backup? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) log_ok "Backup consent given" ;;
    *) log_warn "Aborted by user. Nothing was changed."; exit 1 ;;
  esac

  # Snapshot the consented list — only these get emphasized backups later.
  # Anything that appears later (e.g., oh-my-zsh template ~/.zshrc) was
  # created by an installer and is not user content.
  while IFS= read -r f; do CONFLICTS_AT_VALIDATION+=("$f"); done <<<"$existing"
}

validate_git_identity() {
  GIT_NAME="${GIT_USER_NAME:-}"
  GIT_EMAIL="${GIT_USER_EMAIL:-}"

  if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
    log_ok "Git identity from env: $GIT_NAME <$GIT_EMAIL>"
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    log_err "Git user.name/user.email not in env (GIT_USER_NAME, GIT_USER_EMAIL)"
    log_err "and no TTY available to prompt. Set the env vars or run interactively."
    exit 1
  fi

  echo
  echo "Git user identity (used in commit author):"
  [[ -z "$GIT_NAME"  ]] && read -r -p "  user.name:  " GIT_NAME
  [[ -z "$GIT_EMAIL" ]] && read -r -p "  user.email: " GIT_EMAIL
  if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
    log_err "Both name and email are required."
    exit 1
  fi
  log_ok "Git identity: $GIT_NAME <$GIT_EMAIL>"
}

# ============================================================================
# === side-effect phase ======================================================
# ============================================================================

# --- packages ---------------------------------------------------------------

install_mac_packages() {
  log_info "Installing Homebrew packages..."
  brew bundle --file="$SCRIPT_DIR/Brewfile" --verbose
}

install_linux_prerequisites() {
  local missing=()
  command -v curl &>/dev/null || missing+=(curl)
  command -v git  &>/dev/null || missing+=(git)
  command -v gpg  &>/dev/null || missing+=(gnupg)
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Installing prerequisites (${missing[*]})..."
    run_privileged apt-get update
    run_privileged apt-get install -y "${missing[@]}" ca-certificates
  fi
}

# Charm's official apt repo for glow. Per
# https://github.com/charmbracelet/glow#installation
setup_charm_apt_repo() {
  local source_list="/etc/apt/sources.list.d/charm.list"
  if [[ -f "$source_list" ]]; then
    log_skip "Charm apt repo already configured"
    return 0
  fi
  log_info "Configuring Charm apt repo for glow..."
  run_privileged mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.charm.sh/apt/gpg.key \
    | run_privileged gpg --dearmor -o /etc/apt/keyrings/charm.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
    | run_privileged tee "$source_list" >/dev/null
  log_ok "Charm apt repo configured"
}

# GitHub's official apt repo for gh. Per
# https://github.com/cli/cli/blob/trunk/docs/install_linux.md
setup_github_apt_repo() {
  local source_list="/etc/apt/sources.list.d/github-cli.list"
  if [[ -f "$source_list" ]]; then
    log_skip "GitHub CLI apt repo already configured"
    return 0
  fi
  log_info "Configuring GitHub CLI apt repo for gh..."
  run_privileged mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | run_privileged tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  run_privileged chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | run_privileged tee "$source_list" >/dev/null
  log_ok "GitHub CLI apt repo configured"
}

install_linux_packages() {
  local aptfile="$SCRIPT_DIR/Aptfile"
  log_info "Installing apt packages from Aptfile..."
  run_privileged apt-get update
  local packages=()
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [[ -n "$line" ]] && packages+=("$line")
  done <"$aptfile"
  # See backup_user_dotfiles for why this expansion is written this way.
  run_privileged apt-get install -y ${packages[@]+"${packages[@]}"}
}

set_zsh_as_default_shell() {
  local target_user="${SUDO_USER:-${USER:-$(whoami)}}"
  local current_shell
  current_shell="$(getent passwd "$target_user" 2>/dev/null | cut -d: -f7)"
  if [[ "$(basename "$current_shell")" == "zsh" ]]; then
    log_skip "Default shell is already zsh for $target_user"
    return 0
  fi
  local zsh_path
  zsh_path="$(command -v zsh)" || { log_warn "zsh not found; skipping chsh"; return 0; }
  log_info "Setting default shell to $zsh_path for $target_user..."
  if run_privileged chsh -s "$zsh_path" "$target_user"; then
    log_ok "Default shell set to zsh (open a new login session to apply)"
  else
    log_warn "chsh failed — set manually with: sudo chsh -s $zsh_path $target_user"
  fi
}

# --- oh-my-zsh + p10k + plugins ---------------------------------------------

setup_ohmyzsh() {
  local omz="$HOME/.oh-my-zsh"
  if [[ -d "$omz" ]]; then
    log_skip "oh-my-zsh already present"
    return 0
  fi
  log_info "Installing oh-my-zsh (unattended)..."
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  mkdir -p "$omz/custom"
}

clone_or_skip() {
  local url="$1" dest="$2" name="$3"
  if [[ -d "$dest/.git" ]]; then
    log_skip "$name already installed"
    return 0
  fi
  rm -rf "$dest"
  log_info "Installing $name..."
  git clone --depth=1 "$url" "$dest"
}

setup_p10k() {
  local custom="$HOME/.oh-my-zsh/custom"
  clone_or_skip "https://github.com/romkatv/powerlevel10k.git" \
    "$custom/themes/powerlevel10k" "powerlevel10k"
}

setup_zsh_plugins() {
  local custom="$HOME/.oh-my-zsh/custom"
  clone_or_skip "https://github.com/zsh-users/zsh-autosuggestions" \
    "$custom/plugins/zsh-autosuggestions" "zsh-autosuggestions"
  clone_or_skip "https://github.com/zsh-users/zsh-syntax-highlighting.git" \
    "$custom/plugins/zsh-syntax-highlighting" "zsh-syntax-highlighting"
  clone_or_skip "https://github.com/zsh-users/zsh-completions" \
    "$custom/plugins/zsh-completions" "zsh-completions"
}

# --- staging dir + git identity ---------------------------------------------

create_staging_dir() {
  log_info "Creating staging dir $DOTFILES_DIR..."
  mkdir -p "$DOTFILES_DIR"
  cp -R "$SCRIPT_DIR/zsh" "$DOTFILES_DIR/zsh"
  cp -R "$SCRIPT_DIR/git" "$DOTFILES_DIR/git"
  cp -R "$SCRIPT_DIR/vim" "$DOTFILES_DIR/vim"
  log_ok "Copied zsh, git, vim packages to $DOTFILES_DIR"
}

write_git_identity() {
  local cfg="$DOTFILES_DIR/git/.gitconfig"
  git config --file "$cfg" user.name  "$GIT_NAME"
  git config --file "$cfg" user.email "$GIT_EMAIL"
  log_ok "Wrote git identity to $cfg"
}

# --- backup + stow ----------------------------------------------------------

# Move a single home dotfile to <path>.bak.<ts> if it exists and isn't already
# a symlink into our staging dir. Records the new path in $BACKUPS.
backup_home_dotfile() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  if [[ -L "$path" ]]; then
    local target
    target="$(readlink -f "$path" 2>/dev/null || true)"
    if [[ "$target" == "$DOTFILES_DIR"/* ]]; then
      log_skip "$path already symlinked into $DOTFILES_DIR"
      return 0
    fi
  fi
  local ts backup
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="${path}.bak.${ts}"
  mv "$path" "$backup"
  BACKUPS+=("$backup")
  log_warn "Backed up $path → $backup"
}

# Phase 1 — runs BEFORE installers. Moves user-consented files to
# .bak.<ts>. Critical timing: must happen before any third-party installer
# that reads or modifies $HOME rcfiles (fzf-installer, oh-my-zsh installer,
# Astral's uv installer all do this).
backup_user_dotfiles() {
  local f
  # ${ARR[@]+"${ARR[@]}"}: macOS bash 3.2 errors on "${EMPTY_ARRAY[@]}" under
  # `set -u`. This portable expansion is a no-op when the array is empty
  # (no consented conflicts) and yields all elements otherwise.
  for f in ${CONFLICTS_AT_VALIDATION[@]+"${CONFLICTS_AT_VALIDATION[@]}"}; do
    backup_home_dotfile "$f"
  done
}

# Phase 2 — runs AFTER installers, before stow. Silently removes any
# HOME_DOTFILES that installers left behind (e.g., oh-my-zsh template).
# Skips files already symlinked into our staging dir (idempotent re-runs).
clear_installer_dotfiles() {
  local f target c in_consent
  for f in "${HOME_DOTFILES[@]}"; do
    [[ -e "$f" || -L "$f" ]] || continue
    if [[ -L "$f" ]]; then
      target="$(readlink -f "$f" 2>/dev/null || true)"
      if [[ "$target" == "$DOTFILES_DIR"/* ]]; then
        log_skip "$f already symlinked into $DOTFILES_DIR"
        continue
      fi
    fi
    # Belt-and-suspenders: if a consented file somehow re-appeared, back up
    # rather than silently nuke.
    in_consent=false
    # See backup_user_dotfiles for why this expansion is written this way.
    for c in ${CONFLICTS_AT_VALIDATION[@]+"${CONFLICTS_AT_VALIDATION[@]}"}; do
      [[ "$c" == "$f" ]] && in_consent=true && break
    done
    if $in_consent; then
      backup_home_dotfile "$f"
    else
      log_skip "Removing installer-created $f"
      rm -f "$f"
    fi
  done
}

run_stow() {
  (cd "$DOTFILES_DIR" && stow -t "$HOME" zsh git vim)
}

# --- final notice -----------------------------------------------------------

print_backup_notice() {
  [[ ${#BACKUPS[@]} -eq 0 ]] && return 0
  echo
  echo "============================================================"
  echo "⚠️  IMPORTANT: pre-existing dotfiles were moved aside"
  echo "============================================================"
  echo "Review the following backup files — they contain content"
  echo "that was in \$HOME before install ran. Copy anything you"
  echo "want to keep into the new (live) files at ~/."
  echo
  local b
  for b in "${BACKUPS[@]}"; do
    echo "  • $b"
  done
  echo
  echo "Once you're done, you can delete the .bak files."
  echo "============================================================"
}

# ============================================================================
# === main ===================================================================
# ============================================================================

main() {
  # ----- validation phase (no side effects) -----
  validate_args "$@"
  validate_os
  validate_dotfiles_dir_absent
  validate_source_repo
  validate_os_prereqs
  validate_git_identity
  validate_backup_consent

  echo
  log_info "All validations passed. Starting install..."
  echo

  # ----- side-effect phase -----

  # CRITICAL ORDERING: backup user-consented files BEFORE running any
  # installer that reads/modifies $HOME rcfiles. fzf-install prompts on a
  # pre-existing ~/.zshrc with fzf mentions; Astral's uv installer
  # silently appends to ~/.zshrc; oh-my-zsh's installer skips template
  # creation when ~/.zshrc exists. Running backup first means all those
  # installers see a clean $HOME and behave predictably.
  backup_user_dotfiles
  # If interrupted between here and the end of stow, print the recovery
  # list so the user knows where their files went.
  trap 'print_backup_notice' EXIT

  case "$OS" in
    mac)
      install_mac_packages
      ;;
    linux)
      install_linux_prerequisites
      setup_charm_apt_repo
      setup_github_apt_repo
      install_linux_packages
      log_info "Installing extra binary tools..."
      bash "$SCRIPT_DIR/scripts/linux/install-binaries.sh"
      ;;
  esac

  setup_ohmyzsh
  setup_p10k
  setup_zsh_plugins

  create_staging_dir
  write_git_identity

  # Remove anything installers left behind (e.g., oh-my-zsh template)
  # before stow tries to create our symlinks.
  clear_installer_dotfiles
  log_info "Stowing zsh, git, vim from $DOTFILES_DIR..."
  run_stow

  if [[ "$OS" == "linux" ]]; then
    set_zsh_as_default_shell
  fi

  log_ok "Bootstrap complete! Open a new shell to apply changes."
  # EXIT trap will print the backup notice. Disable it now since we ran
  # to completion (otherwise it'd print twice on normal exit).
  trap - EXIT
  print_backup_notice
}

main "$@"
