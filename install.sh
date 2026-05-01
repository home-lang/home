#!/usr/bin/env bash
#
# Home language installer.
#
# Usage:
#   curl -fsSL https://home-lang.org/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/home-lang/home/main/install.sh | bash
#
# Environment variables:
#   HOME_VERSION       Pin a specific release tag (e.g. v0.1.0). Defaults to "latest".
#   HOME_INSTALL_DIR   Where to install Home. Defaults to "$HOME/.home".
#   HOME_BIN_DIR       Where to place the `home` binary. Defaults to "$HOME_INSTALL_DIR/bin".
#   HOME_SKIP_CHECKSUM Set to "1" to skip checksum verification (not recommended).
#
# Exit codes:
#   1  General failure (download, extraction, etc.)
#   2  Unsupported platform
#   3  Missing required tool (curl/tar/etc.)
#   4  Checksum verification failed

set -euo pipefail

# ---------- pretty output ---------------------------------------------------

# Detect whether stdout is a TTY so we don't dump escape codes into log files.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  bold=$(printf '\033[1m')
  dim=$(printf '\033[2m')
  red=$(printf '\033[31m')
  green=$(printf '\033[32m')
  yellow=$(printf '\033[33m')
  blue=$(printf '\033[34m')
  reset=$(printf '\033[0m')
else
  bold=''; dim=''; red=''; green=''; yellow=''; blue=''; reset=''
fi

info()  { printf '%s==>%s %s\n' "${blue}${bold}" "${reset}" "$*"; }
warn()  { printf '%swarning:%s %s\n' "${yellow}${bold}" "${reset}" "$*" >&2; }
error() { printf '%serror:%s %s\n' "${red}${bold}" "${reset}" "$*" >&2; }
ok()    { printf '%s%s%s\n' "${green}" "$*" "${reset}"; }

die() {
  error "$1"
  exit "${2:-1}"
}

# ---------- prerequisites ---------------------------------------------------

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "required command not found: $1" 3
  fi
}

require_cmd uname
require_cmd curl
require_cmd tar
require_cmd mkdir
require_cmd mktemp
require_cmd rm

# We need at least one of `shasum` or `sha256sum` for checksum verification.
checksum_cmd=""
if command -v sha256sum >/dev/null 2>&1; then
  checksum_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  checksum_cmd="shasum -a 256"
fi

# ---------- platform detection ---------------------------------------------

# Maps `uname -s`/`uname -m` output to the artifact basename produced by the
# release workflow at .github/workflows/release.yml. Keep these aligned!
detect_target() {
  local os arch

  case "$(uname -s)" in
    Linux)         os="linux"  ;;
    Darwin)        os="darwin" ;;
    MINGW*|MSYS*|CYGWIN*) os="windows" ;;
    *) die "unsupported operating system: $(uname -s)" 2 ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)  arch="x64"   ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported architecture: $(uname -m)" 2 ;;
  esac

  printf '%s-%s' "$os" "$arch"
}

artifact_extension() {
  case "$1" in
    windows-*) printf 'zip' ;;
    *)         printf 'tar.gz' ;;
  esac
}

# ---------- main ------------------------------------------------------------

main() {
  local version install_dir bin_dir target ext
  version="${HOME_VERSION:-latest}"
  install_dir="${HOME_INSTALL_DIR:-$HOME/.home}"
  bin_dir="${HOME_BIN_DIR:-$install_dir/bin}"

  target="$(detect_target)"
  ext="$(artifact_extension "$target")"

  if [ "$target" = "windows-x64" ] || [ "$target" = "windows-arm64" ]; then
    warn "Windows detected. This script targets POSIX shells (Git Bash, WSL, MSYS)."
    warn "For native PowerShell, use the .zip artifact directly from GitHub Releases."
  fi

  local artifact_name="home-${target}.${ext}"
  local base_url
  if [ "$version" = "latest" ]; then
    base_url="https://github.com/home-lang/home/releases/latest/download"
  else
    base_url="https://github.com/home-lang/home/releases/download/${version}"
  fi

  local artifact_url="${base_url}/${artifact_name}"
  local checksum_url="${artifact_url}.sha256"

  info "Installing Home (${bold}${version}${reset}${dim}) for ${target}${reset}"
  info "Artifact: ${dim}${artifact_url}${reset}"

  local tmp_dir
  tmp_dir="$(mktemp -d 2>/dev/null || mktemp -d -t 'home-install')"
  trap 'rm -rf "$tmp_dir"' EXIT

  local artifact_path="${tmp_dir}/${artifact_name}"
  local checksum_path="${artifact_path}.sha256"

  info "Downloading ${artifact_name}..."
  if ! curl --fail --location --progress-bar --output "$artifact_path" "$artifact_url"; then
    error "failed to download $artifact_url"
    error "is ${version} a published release? See https://github.com/home-lang/home/releases"
    exit 1
  fi

  # Checksum verification. We treat a missing .sha256 as a soft failure for now
  # because the existing release workflow does not yet emit them — it's tracked
  # as part of the release-build hardening work. Set HOME_SKIP_CHECKSUM=1 to
  # silence the warning entirely.
  if [ "${HOME_SKIP_CHECKSUM:-0}" = "1" ]; then
    warn "skipping checksum verification (HOME_SKIP_CHECKSUM=1)"
  elif [ -z "$checksum_cmd" ]; then
    warn "no sha256sum/shasum found; skipping checksum verification"
  else
    info "Downloading checksum..."
    if curl --fail --silent --location --output "$checksum_path" "$checksum_url"; then
      info "Verifying checksum..."
      # The .sha256 file is expected to contain "<hex>  <filename>". We only
      # care about the hex; recompute over the downloaded artifact and compare.
      local expected actual
      expected="$(awk '{print $1}' "$checksum_path")"
      actual="$(cd "$tmp_dir" && $checksum_cmd "$artifact_name" | awk '{print $1}')"
      if [ "$expected" != "$actual" ]; then
        error "checksum mismatch for $artifact_name"
        error "  expected: $expected"
        error "  actual:   $actual"
        exit 4
      fi
      ok "checksum OK"
    else
      warn "no checksum file at $checksum_url; skipping verification"
      warn "(release-build CI does not yet emit .sha256 files — tracked separately)"
    fi
  fi

  info "Extracting to ${install_dir}..."
  mkdir -p "$install_dir" "$bin_dir"

  case "$ext" in
    tar.gz)
      tar -xzf "$artifact_path" -C "$install_dir"
      ;;
    zip)
      require_cmd unzip
      unzip -oq "$artifact_path" -d "$install_dir"
      ;;
    *)
      die "unknown artifact extension: $ext"
      ;;
  esac

  # The artifacts pack the binary at the archive root (see release.yml).
  local binary_name="home"
  if [ "$ext" = "zip" ]; then
    binary_name="home.exe"
  fi

  local binary_src="${install_dir}/${binary_name}"
  if [ ! -f "$binary_src" ]; then
    die "binary not found at $binary_src after extraction (corrupt archive?)"
  fi

  chmod +x "$binary_src"

  # Copy (rather than symlink) into bin_dir so users who set HOME_BIN_DIR to
  # something outside HOME_INSTALL_DIR get a self-contained binary.
  if [ "$binary_src" != "${bin_dir}/${binary_name}" ]; then
    cp "$binary_src" "${bin_dir}/${binary_name}"
    chmod +x "${bin_dir}/${binary_name}"
  fi

  ok ""
  ok "Home installed to ${install_dir}"
  ok "Binary at        ${bin_dir}/${binary_name}"
  ok ""

  print_path_instructions "$bin_dir"
}

print_path_instructions() {
  local bin_dir="$1"

  # If bin_dir is already on PATH, no setup is needed.
  case ":${PATH}:" in
    *":${bin_dir}:"*)
      info "${bin_dir} is already on your PATH. Run ${bold}home --version${reset} to verify."
      return
      ;;
  esac

  printf '%sNext step:%s add %s%s%s to your PATH.\n\n' \
    "${bold}" "${reset}" "${bold}" "${bin_dir}" "${reset}"

  printf '  %s# bash (~/.bashrc)%s\n' "${dim}" "${reset}"
  printf '  echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc\n\n' "$bin_dir"

  printf '  %s# zsh (~/.zshrc)%s\n' "${dim}" "${reset}"
  printf '  echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc\n\n' "$bin_dir"

  printf '  %s# fish (~/.config/fish/config.fish)%s\n' "${dim}" "${reset}"
  printf '  fish_add_path %s\n\n' "$bin_dir"

  printf 'Then restart your shell (or source the file) and run %shome --version%s.\n' \
    "${bold}" "${reset}"
}

main "$@"
