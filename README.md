# dotfiles

Personal dotfiles for macOS and Linux (Debian/Ubuntu).

## Architecture

There are two physical locations once installed:

| Location | Tracked by git? | Purpose |
|---|---|---|
| **Source repo** (e.g., `~/code/dotfiles-source`) | yes | What you clone and edit |
| **`~/dotfiles/`** | no | Staging copy of the live config; symlinks from `$HOME` point here |

`install.sh` copies the relevant packages (`zsh/`, `git/`, `vim/`) from the
source repo into a fresh `~/dotfiles/` directory, then uses GNU stow to
symlink `$HOME` entries (`~/.zshrc`, `~/.p10k.zsh`, `~/.gitconfig`, `~/.vimrc`)
into `~/dotfiles/`. Editing the staging copies is safe — they're not in the
source repo, so changes don't dirty your git working tree.

The script aborts immediately if `~/dotfiles/` already exists. To reinstall,
move it aside first:

```bash
mv ~/dotfiles ~/dotfiles.old
./install.sh
```

## What it installs

- **Shell**: zsh + oh-my-zsh + powerlevel10k + plugins (autosuggestions,
  syntax-highlighting, completions)
- **CLI tools**: fzf, eza, glow, bat, htop, gdu, tmux, vim, git, git-delta,
  gh, uv, stow
- **Dotfiles** (stowed from `~/dotfiles/` into `$HOME`): `.zshrc`, `.p10k.zsh`,
  `.gitconfig`, `.vimrc`

See [`Brewfile`](Brewfile) and [`Aptfile`](Aptfile) for the exact package
lists.

## Prerequisites

- **macOS**: [Homebrew](https://brew.sh/) installed (the script verifies it
  and aborts with a link if missing).
- **Linux**: Debian/Ubuntu with `apt` and `sudo`.

## Install

```bash
git clone <this-repo-url> ~/code/dotfiles-source
cd ~/code/dotfiles-source
./install.sh
```

The path you clone to doesn't matter — the script uses `$SCRIPT_DIR`. Just
avoid cloning to `~/dotfiles/`, since that name is reserved for the staging
dir the script creates.

If `./install.sh` reports "Permission denied", `chmod +x install.sh` first.
(`git clone` should preserve the execute bit; this is a fallback.)

## What happens when you run it

`install.sh` runs in two phases — all validation first, then side effects.
If any validation fails, nothing is installed and `~/dotfiles/` is not
created.

### Validation phase (no side effects)
1. OS detection — aborts if not macOS or Debian/Ubuntu
2. `~/dotfiles/` must not exist — aborts otherwise
3. Source repo integrity — required files (zsh/.zshrc, etc.) must exist
4. OS prereqs — `brew` on macOS, `apt-get` on Linux
5. Git identity — prompts for `user.name` and `user.email` unless
   `GIT_USER_NAME` and `GIT_USER_EMAIL` are set in env
6. Backup consent — if any of `~/.zshrc`, `~/.p10k.zsh`, `~/.gitconfig`,
   `~/.vimrc` already exist, prompts for permission to move them aside as
   `<file>.bak.<timestamp>`

### Side-effect phase
1. Installs packages (`brew bundle` on mac, `apt-get install` on linux)
2. On linux: installs extras not in apt (`fzf`, `gdu`, `uv`) and configures
   the `batcat → bat` symlink
3. Installs oh-my-zsh, powerlevel10k, and zsh plugins via their official
   methods (curl-script for omz, git-clone for the rest)
4. Creates `~/dotfiles/` and copies the `zsh/`, `git/`, `vim/` packages into
   it
5. Writes your git identity (from the prompt or env) into
   `~/dotfiles/git/.gitconfig`
6. Backs up any conflicting `$HOME` files (the ones you consented to)
7. Stows `zsh`, `git`, `vim` from `~/dotfiles/` to `$HOME`
8. On linux: sets zsh as your default shell via `chsh`

Open a new shell to apply.

### Headless / automated installs

To skip prompts, set the env vars and pipe `y` to stdin:

```bash
GIT_USER_NAME="Your Name" GIT_USER_EMAIL=you@example.com \
  yes y | ./install.sh
```

If `~/dotfiles/` exists or any conflicting file exists without an
interactive TTY and no env-based consent, the script aborts with a clear
error.

## Re-installing

A successful install leaves `~/dotfiles/` in place. Re-running aborts on
the existence check. To do a clean reinstall:

```bash
mv ~/dotfiles ~/dotfiles.old
./install.sh
```

The new install's backup step will move your existing `~/.zshrc` etc.
(which are now symlinks into `~/dotfiles.old/`) to `.bak.<timestamp>`. You
can then remove `~/dotfiles.old` once you've confirmed the new install
works.

## Migrating from an older stow-based layout

If you previously ran a version of this repo that stowed directly from the
source repo (so `~/.zshrc` was a symlink into wherever you cloned), those
symlinks won't be recognized as belonging to the new `~/dotfiles/` staging
dir — they'll be treated as conflicts. The script will list them, prompt for
consent, and back them up as `.bak.<timestamp>`. Confirm, and the new
install creates fresh symlinks pointing into `~/dotfiles/`.

## Backup notice

At the end of every install that backed up any files, the script prints an
emphasized banner listing each `.bak.<timestamp>` file. Review those — they
contain your prior content. Copy anything you want into the new (now stowed)
files in `$HOME`, then delete the `.bak` files.
