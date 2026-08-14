#!/usr/bin/env bash
# Installer for neoansible-vault.
#
# Usage:
#   ./install.sh              auto-detect: lazy.nvim spec if lazy is used, else pack dir
#   ./install.sh --lazy       force lazy.nvim spec install
#   ./install.sh --pack       force Vim package install (:help packages)
#   ./install.sh uninstall    remove the plugin (lazy spec and/or pack dir)
#   ./install.sh --dir PATH   custom pack target directory
#   ./install.sh --config PATH  custom nvim config dir (default: ${XDG_CONFIG_HOME:-~/.config}/nvim)
#
# lazy.nvim detection: lazy-lock.json, a lazy.nvim checkout under stdpath("data"),
# or require("lazy") in the config. The spec is written into the user's plugin
# import directory (e.g. lua/plugins/, see { import = "plugins" }).
set -euo pipefail

PLUGIN_NAME="neoansible-vault"
MARKER="plugin/neoansible-vault.lua"
LAZY_MARKER="neoansible-vault-installer"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
NVIM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
DEFAULT_TARGET="$DATA_HOME/nvim/site/pack/$PLUGIN_NAME/start/$PLUGIN_NAME"

MODE="install"
FORCE="" # "", "lazy" or "pack"
LINK=0
TARGET="$DEFAULT_TARGET"

log() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; }

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    install) MODE="install" ;;
    uninstall | remove) MODE="uninstall" ;;
    --lazy) FORCE="lazy" ;;
    --pack) FORCE="pack" ;;
    --link | -l) LINK=1 ;;
    --dir)
      shift
      [ $# -gt 0 ] || { err "--dir requires a path"; exit 1; }
      TARGET="$1"
      FORCE="pack"
      ;;
    --dir=*)
      TARGET="${1#--dir=}"
      FORCE="pack"
      ;;
    --config)
      shift
      [ $# -gt 0 ] || { err "--config requires a path"; exit 1; }
      NVIM_CONFIG="$1"
      ;;
    --config=*) NVIM_CONFIG="${1#--config=}" ;;
    -h | --help) usage 0 ;;
    *)
      err "unknown argument: $1"
      usage 1
      ;;
  esac
  shift
done

# --- generic helpers ----------------------------------------------------------

nvim_version_ok() {
  command -v nvim >/dev/null 2>&1 || return 1
  local version major minor
  version="$(nvim --version | head -n1)" # "NVIM v0.12.4"
  major="$(printf '%s' "$version" | sed -n 's/^NVIM v\([0-9]\+\)\..*/\1/p')"
  minor="$(printf '%s' "$version" | sed -n 's/^NVIM v[0-9]\+\.\([0-9]\+\).*/\1/p')"
  [ -n "$major" ] && [ -n "$minor" ] || return 1
  [ "$major" -gt 0 ] || [ "$minor" -ge 12 ]
}

check_deps() {
  local failed=0
  if nvim_version_ok; then
    log "ok: $(nvim --version | head -n1)"
  else
    err "Neovim >= 0.12 is required but was not found"
    failed=1
  fi
  if command -v ansible-vault >/dev/null 2>&1; then
    log "ok: $(ansible-vault --version | head -n1)"
  else
    log "warning: ansible-vault not found on PATH (install ansible-core)"
  fi
  return "$failed"
}

# --- lazy.nvim ----------------------------------------------------------------

detect_lazy() {
  [ -f "$NVIM_CONFIG/lazy-lock.json" ] && return 0
  [ -d "$DATA_HOME/nvim/lazy/lazy.nvim" ] && return 0
  grep -rqsE "require\(['\"]lazy['\"]\)" "$NVIM_CONFIG" --include="*.lua" 2>/dev/null && return 0
  return 1
}

# find_spec_dir — locate the user's plugin import directory (e.g. lua/plugins).
find_spec_dir() {
  local imports mod dir
  imports="$(grep -rhoE 'import\s*=\s*"[[:alnum:]_.]+"' "$NVIM_CONFIG" --include="*.lua" 2>/dev/null |
    sed -E 's/.*"([^"]+)".*/\1/' | sort -u)"
  # prefer the conventional "plugins" module
  for mod in $imports; do
    if [ "$mod" = "plugins" ] && [ -d "$NVIM_CONFIG/lua/plugins" ]; then
      printf '%s\n' "$NVIM_CONFIG/lua/plugins"
      return 0
    fi
  done
  # otherwise first import that maps to a real dir inside the config
  for mod in $imports; do
    case "$mod" in
      lazyvim.*) continue ;;
    esac
    dir="$NVIM_CONFIG/lua/$(printf '%s' "$mod" | tr '.' '/')"
    if [ -d "$dir" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

lazy_spec_file() {
  local spec_dir="$1"
  printf '%s/%s.lua' "$spec_dir" "$PLUGIN_NAME"
}

is_our_lazy_spec() {
  [ -f "$1" ] && grep -qs "$LAZY_MARKER" "$1"
}

lazy_snippet() {
  cat <<EOF
    {
      dir = "$REPO_ROOT",
      event = "BufReadPre", -- load before file reads so vault files decrypt transparently
      opts = {},
    },
EOF
}

do_install_lazy() {
  local spec_dir spec_file
  if ! spec_dir="$(find_spec_dir)"; then
    err "lazy.nvim detected but no plugin import directory found in $NVIM_CONFIG"
    err "add this to your lazy.nvim specs manually:"
    lazy_snippet >&2
    exit 1
  fi
  spec_file="$(lazy_spec_file "$spec_dir")"

  if [ -e "$spec_file" ] && ! is_our_lazy_spec "$spec_file"; then
    err "$spec_file exists and was not created by this installer; refusing to overwrite"
    exit 1
  fi

  cat >"$spec_file" <<EOF
-- $LAZY_MARKER: managed by $PLUGIN_NAME install.sh, safe to delete
return {
  dir = "$REPO_ROOT",
  -- once published, replace \`dir\` with the git URL, e.g. "you/$PLUGIN_NAME",
  -- load before any file read so vault files decrypt transparently on open
  event = "BufReadPre",
  keys = {
    { "<leader>ve", desc = "Ansible vault: encrypt/decrypt under cursor" },
    { "<leader>vf", desc = "Ansible vault: find secrets in buffer" },
    { "<leader>vF", desc = "Ansible vault: find secrets in project" },
    { "<leader>vr", desc = "Ansible vault: reveal/edit secret under cursor" },
    { "<leader>vR", desc = "Ansible vault: reveal/edit all secrets in buffer" },
  },
  opts = {},
}
EOF
  log "wrote lazy.nvim spec: $spec_file"
  log ""
  log "$PLUGIN_NAME installed. Restart nvim (or run :Lazy sync) to load it."
  log "Try:  nvim some-vault-file.yml   (or :checkhealth $PLUGIN_NAME)"
}

do_uninstall_lazy() {
  local spec_dir spec_file found=1
  if spec_dir="$(find_spec_dir)"; then
    spec_file="$(lazy_spec_file "$spec_dir")"
    if [ -e "$spec_file" ]; then
      if is_our_lazy_spec "$spec_file"; then
        rm "$spec_file"
        log "removed lazy.nvim spec: $spec_file"
        found=0
      else
        err "$spec_file was not created by this installer; refusing to remove it"
        found=0
      fi
    fi
  fi
  return "$found"
}

# --- pack (vim packages) --------------------------------------------------------

# is_ours PATH — true if PATH looks like a neoansible-vault install we made.
is_ours() {
  local path="$1"
  if [ -L "$path" ]; then
    [ "$(readlink -f "$path")" = "$REPO_ROOT" ] && return 0
    [ -e "$path/$MARKER" ] && return 0
    return 1
  fi
  [ -f "$path/$MARKER" ]
}

remove_target() {
  if [ -L "$TARGET" ]; then
    rm "$TARGET"
  else
    rm -rf "$TARGET"
  fi
  # prune now-empty pack directories, ignore failures if non-empty
  rmdir -p --ignore-fail-on-non-empty "$(dirname "$TARGET")" 2>/dev/null || true
}

# probe_autoload — returns 0 if a fresh nvim would auto-load the pack install.
probe_autoload() {
  local result
  result="$(nvim --headless -c "lua io.write(tostring(vim.go.loadplugins and vim.tbl_contains(vim.opt.packpath:get(), vim.fn.stdpath('data') .. '/site')))" -c "qa!" 2>/dev/null)" || true
  [ "$result" = "true" ]
}

do_install_pack() {
  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    if is_ours "$TARGET"; then
      log "replacing existing installation at $TARGET"
      remove_target
    else
      err "$TARGET exists and does not look like a $PLUGIN_NAME install; refusing to remove it"
      exit 1
    fi
  fi

  mkdir -p "$(dirname "$TARGET")"

  if [ "$LINK" -eq 1 ]; then
    ln -s "$REPO_ROOT" "$TARGET"
    log "linked $TARGET -> $REPO_ROOT"
  else
    mkdir -p "$TARGET"
    cp -r "$REPO_ROOT/lua" "$REPO_ROOT/plugin" "$REPO_ROOT/doc" "$TARGET/"
    cp "$REPO_ROOT/README.md" "$TARGET/" 2>/dev/null || true
    log "copied plugin files to $TARGET"
  fi

  # generate helptags so :help neoansible-vault works
  if [ -d "$TARGET/doc" ]; then
    nvim --headless -u NONE -c "silent helptags $TARGET/doc" -c "qa!" 2>/dev/null || true
  fi

  log ""
  if [ "$TARGET" = "$DEFAULT_TARGET" ] && ! probe_autoload; then
    log "note: your Neovim config disables package auto-loading (loadplugins=false),"
    log "so the plugin will NOT load from the pack directory with your config."
    log "Use your plugin manager instead, e.g. with lazy.nvim:"
    log ""
    lazy_snippet
    log ""
    log "(the files were still installed to $TARGET and will load on"
    log " configs that use :help packages)"
  else
    log "$PLUGIN_NAME installed. It loads automatically on the next nvim start."
    log "Try:  nvim some-vault-file.yml   (or :checkhealth $PLUGIN_NAME)"
  fi
}

do_uninstall_pack() {
  if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
    return 1
  fi
  if ! is_ours "$TARGET"; then
    err "$TARGET does not look like a $PLUGIN_NAME install; refusing to remove it"
    return 0
  fi
  remove_target
  log "removed pack install: $TARGET"
  return 0
}

# --- dispatch -------------------------------------------------------------------

do_install() {
  check_deps || exit 1

  local method="$FORCE"
  if [ -z "$method" ]; then
    if detect_lazy; then
      method="lazy"
    else
      method="pack"
    fi
  fi

  if [ "$method" = "lazy" ]; then
    [ "$LINK" -eq 1 ] && log "note: --link is ignored for lazy.nvim installs (dir= specs are already live)"
    do_install_lazy
  else
    do_install_pack
  fi
}

do_uninstall() {
  local removed=1
  do_uninstall_lazy && removed=0
  do_uninstall_pack && removed=0
  if [ "$removed" -ne 0 ]; then
    log "nothing to uninstall"
  else
    log ""
    log "$PLUGIN_NAME uninstalled. Restart nvim (or run :Lazy sync) to apply."
  fi
}

case "$MODE" in
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
