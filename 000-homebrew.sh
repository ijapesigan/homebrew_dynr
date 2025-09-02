#!/usr/bin/env bash
# ===== macOS user-local Homebrew + R toolchain bootstrap (bash) =====
# Policy #1: If a Homebrew is already present on PATH, reuse it.
# Otherwise, install a user-local Homebrew into ~/homebrew (no sudo).
#
# Installs: llvm, gcc (incl. gfortran), pkg-config, gsl
# Wires PATH/CC/CXX/FC/F77 and PKG_CONFIG/PKG_CONFIG_PATH into ~/.Renviron.
# Idempotent: safe to re-run.

set -uo pipefail

message_section() {
  local title="$1"
  local bar
  bar="$(printf '%*s' $(( ${#title} + 4 )) '' | tr ' ' '=')"
  printf "\n%s\n= %s =\n%s\n" "$bar" "$title" "$bar"
}

die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

append_unique_line() {
  # Append a KEY=... style line only if KEY= doesn't already exist in the file.
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  local key="${line%%=*}="
  if [[ -f "$file" ]] && grep -q -E "^[[:space:]]*${key//\//\\/}" "$file"; then
    return 0
  fi
  printf "%s\n" "$line" >> "$file"
}

# ---------------------- Guards -----------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS only."
if command -v sudo >/dev/null 2>&1; then :; fi  # Not used; guaranteed no 'sudo' calls below.

# ---------------------- Bootstrap --------------------------------------------
message_section "User-local/Homebrew reuse + R toolchain (no sudo)"

HOME_DIR="${HOME}"
ZPROFILE="${HOME_DIR}/.zprofile"
RENVRON="${HOME_DIR}/.Renviron"

printf "Home directory: %s\n" "${HOME_DIR}"
printf "CPU arch: %s\n" "$(uname -m)"

# 1) Choose Homebrew per Policy #1
message_section "Selecting Homebrew (reuse if present, else install user-local)"

USE_EXISTING=false
if command -v brew >/dev/null 2>&1; then
  USE_EXISTING=true
  EXISTING_BREW_BIN="$(command -v brew)"
  BREW_HOME="${EXISTING_BREW_BIN%/bin/brew}"
  printf "Using existing Homebrew at: %s\n" "${BREW_HOME}"
else
  BREW_HOME="${HOME_DIR}/homebrew"
  if [[ ! -d "${BREW_HOME}" ]]; then
    command -v git >/dev/null 2>&1 || die "git is required. Tip: install Apple Command Line Tools with 'xcode-select --install'."
    git clone https://github.com/Homebrew/brew "${BREW_HOME}" || die "Failed to clone Homebrew into ${BREW_HOME}"
    printf "Cloned user-local Homebrew into: %s\n" "${BREW_HOME}"
  else
    ( git -C "${BREW_HOME}" fetch --quiet || true
      git -C "${BREW_HOME}" reset --hard origin/master --quiet || true ) || true
    printf "Refreshed existing user-local Homebrew at: %s\n" "${BREW_HOME}"
  fi
fi

# 2) Activate brew shellenv now; persist into ~/.zprofile only for user-local brew
message_section "Activating brew shellenv"

if $USE_EXISTING; then
  # Reuse existing brew
  eval "$(brew shellenv)" || die "Failed to eval 'brew shellenv' from existing brew."
  printf "Not modifying ~/.zprofile (reusing existing brew on PATH).\n"
else
  # User-local brew
  eval "$("${BREW_HOME}/bin/brew" shellenv)" || die "Failed to eval shellenv from ${BREW_HOME}"
  if [[ ! -f "${ZPROFILE}" ]] || ! grep -q 'homebrew/bin/brew shellenv' "${ZPROFILE}" 2>/dev/null; then
    printf 'eval "$($HOME/homebrew/bin/brew shellenv)"\n' >> "${ZPROFILE}"
  fi
  printf "~/.zprofile updated to source user-local brew shellenv.\n"
fi

# 3) Show brew version, update, install toolchain
message_section "brew update & install toolchain"

brew --version || die "brew not functional on PATH."
# Don't fail the whole script if 'brew update' warns.
if ! brew update; then
  printf "WARNING: 'brew update' reported issues (continuing).\n"
fi

# Install formulae (idempotent; brew will skip if satisfied)
PKGS=( llvm gcc pkg-config gsl r )
if ! brew install "${PKGS[@]}"; then
  printf "NOTE: 'brew install' returned non-zero. This may be benign if packages already installed.\n"
fi

# 4) Resolve prefixes for wiring ~/.Renviron
message_section "Configuring ~/.Renviron for R builds"

BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null || true)"
GSL_PREFIX="$(brew --prefix gsl  2>/dev/null || true)"

# Decide path strings to write:
# - If using user-local brew (~/homebrew), write tilde-based paths.
# - If reusing system brew, write absolute paths (portable across shells).
if $USE_EXISTING; then
  LLVM_BIN_PATH="${LLVM_PREFIX:+${LLVM_PREFIX}/bin}"
  BREW_BIN_PATH="${BREW_PREFIX:+${BREW_PREFIX}/bin}"
  BREW_PKG_PATH="${BREW_PREFIX:+${BREW_PREFIX}/lib/pkgconfig}"
  GSL_PKG_PATH="${GSL_PREFIX:+${GSL_PREFIX}/lib/pkgconfig}"
  PKGCONF_BIN_PATH="${BREW_PREFIX:+${BREW_PREFIX}/bin/pkg-config}"
else
  LLVM_BIN_PATH="~/homebrew/opt/llvm/bin"
  BREW_BIN_PATH="~/homebrew/bin"
  BREW_PKG_PATH="~/homebrew/lib/pkgconfig"
  GSL_PKG_PATH="~/homebrew/opt/gsl/lib/pkgconfig"
  PKGCONF_BIN_PATH="~/homebrew/bin/pkg-config"
fi

# Idempotently append env lines
append_unique_line "${RENVRON}" "PATH=\"${LLVM_BIN_PATH}:${BREW_BIN_PATH}:\${PATH}\""
append_unique_line "${RENVRON}" "CC=\"clang\""
append_unique_line "${RENVRON}" "CXX=\"clang++\""
append_unique_line "${RENVRON}" "FC=\"gfortran\""
append_unique_line "${RENVRON}" "F77=\"gfortran\""
append_unique_line "${RENVRON}" "PKG_CONFIG=\"${PKGCONF_BIN_PATH}\""
append_unique_line "${RENVRON}" "PKG_CONFIG_PATH=\"${BREW_PKG_PATH}:${GSL_PKG_PATH}:\${PKG_CONFIG_PATH}\""

printf "Wrote/ensured entries in: %s\n" "${RENVRON}"
printf "  - PATH prepended with %s and %s\n" "${LLVM_BIN_PATH}" "${BREW_BIN_PATH}"
printf "  - CC/CXX/FC/F77 set to clang/clang++/gfortran\n"
printf "  - PKG_CONFIG and PKG_CONFIG_PATH set (incl. GSL)\n"

# 5) (Current shell) Prime PATH so compilers work immediately
if [[ -n "${LLVM_PREFIX}" && -d "${LLVM_PREFIX}/bin" ]]; then
  export PATH="${LLVM_PREFIX}/bin:${PATH}"
fi
if [[ -n "${BREW_PREFIX}" && -d "${BREW_PREFIX}/bin" ]]; then
  export PATH="${BREW_PREFIX}/bin:${PATH}"
fi

# 6) Optional: notify about Apple CLTs
message_section "Checking Apple Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  printf "Apple Command Line Tools found at: %s\n" "$(xcode-select -p)"
else
  printf "Tip: Running 'xcode-select --install' can improve SDK-based builds (no sudo to initiate).\n"
fi

# 7) Verify compilers and GSL discovery
message_section "Verifying compilers and GSL via pkg-config"

printf "clang:      %s\n" "$(command -v clang || true)"
printf "gfortran:   %s\n" "$(command -v gfortran || true)"
printf "pkg-config: %s\n" "$(command -v pkg-config || true)"

if pkg-config --version >/dev/null 2>&1; then
  printf "pkg-config version: %s\n" "$(pkg-config --version)"
else
  printf "pkg-config version: not found\n"
fi

if pkg-config --modversion gsl >/dev/null 2>&1; then
  printf "GSL version: %s\n" "$(pkg-config --modversion gsl)"
else
  printf "WARNING: pkg-config did not find GSL.\n"
  printf "Check PKG_CONFIG_PATH in ~/.Renviron. Expected to include: %s\n" "${GSL_PKG_PATH}"
fi

printf "\nAll set!\n- Restart R so it reads ~/.Renviron automatically.\n- You can now build R packages from source with clang/gfortran and link GSL.\n"
