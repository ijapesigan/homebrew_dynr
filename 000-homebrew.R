# ===== macOS user-local Homebrew + R toolchain bootstrap (R script) =====
# Policy #1: If a Homebrew is already present on PATH, reuse it.
# Otherwise, install a user-local Homebrew into ~/homebrew (no sudo).
#
# Installs: llvm, gcc (incl. gfortran), pkg-config, gsl
# Wires PATH/CC/CXX/FC/F77 and PKG_CONFIG/PKG_CONFIG_PATH in ~/.Renviron.
# Idempotent: safe to re-run.

message_section <- function(title) {
  cat("\n", paste0(strrep("=", nchar(title)+4), "\n= ", title, " =\n", strrep("=", nchar(title)+4), "\n"), sep = "")
}

stop_if_not_macos <- function() {
  if (!identical(Sys.info()[["sysname"]], "Darwin")) {
    stop("This script is for macOS only.", call. = FALSE)
  }
}

append_unique_line <- function(file, line) {
  dir.create(dirname(file), showWarnings = FALSE, recursive = TRUE)
  key <- sub("^([^=]+)=.*$", "\\1=", line)           # e.g., PATH=, CC=, etc.
  if (file.exists(file)) {
    txt <- readLines(file, warn = FALSE)
    if (any(startsWith(trimws(txt), key))) return(invisible(FALSE))
  }
  cat(line, "\n", file = file, append = TRUE)
  invisible(TRUE)
}

run_sh <- function(cmd, env = character()) {
  # Run in login shell so brew shellenv behaves consistently
  full <- paste("-lc", shQuote(cmd))
  out  <- tryCatch(system2("/bin/bash", args = full, env = env, stdout = TRUE, stderr = TRUE),
                   error = function(e) structure(character(), status = 1L))
  attr(out, "status") <- if (is.null(attr(out, "status"))) 0L else attr(out, "status")
  out
}

detect_existing_brew <- function() {
  # Returns absolute path to brew binary on PATH, or "" if none
  out <- suppressWarnings(run_sh("command -v brew"))
  if (attr(out, "status") == 0L && length(out) && nzchar(out[1])) {
    normalizePath(out[1], mustWork = FALSE)
  } else ""
}

# ---------------------- Bootstrap --------------------------------------------
stop_if_not_macos()
message_section("User-local/Homebrew reuse + R toolchain (no sudo)")

home      <- Sys.getenv("HOME", unset = path.expand("~"))
brew_home <- NULL
zprofile  <- file.path(home, ".zprofile")
renviron  <- file.path(home, ".Renviron")

arch <- R.version$arch
cat("Home directory: ", home, "\n", sep = "")
cat("CPU arch: ", arch, "\n", sep = "")

# 1) Choose Homebrew per Policy #1
message_section("Selecting Homebrew (reuse if present, else install user-local)")
existing_brew_bin <- detect_existing_brew()
use_existing      <- nzchar(existing_brew_bin)

if (use_existing) {
  # Reuse system/managed brew e.g., /opt/homebrew/bin/brew or /usr/local/bin/brew
  shellenv <- run_sh("brew shellenv")
  if (attr(shellenv, "status") != 0L || length(shellenv) == 0) {
    stop("Found an existing brew at ", existing_brew_bin, " but failed to get shellenv:\n", paste(shellenv, collapse = "\n"))
  }
  brew_home <- sub("/bin/brew$", "", existing_brew_bin)  # brew prefix dir
  cat("Using existing Homebrew at: ", brew_home, "\n", sep = "")
} else {
  # Create/refresh user-local brew in ~/homebrew
  brew_home <- file.path(home, "homebrew")
  if (!dir.exists(brew_home)) {
    out <- run_sh(sprintf("git clone https://github.com/Homebrew/brew %s", shQuote(brew_home)))
    if (attr(out, "status") != 0L) {
      stop("Failed to clone Homebrew:\n", paste(out, collapse = "\n"))
    }
    cat("Cloned user-local Homebrew into: ", brew_home, "\n", sep = "")
  } else {
    # Refresh the brew repo safely
    run_sh(sprintf("git -C %s fetch --quiet || true", shQuote(brew_home)))
    run_sh(sprintf("git -C %s reset --hard origin/master --quiet || true", shQuote(brew_home)))
    cat("Refreshed existing user-local Homebrew at: ", brew_home, "\n", sep = "")
  }
  # Obtain shellenv from user-local brew
  shellenv <- run_sh(sprintf("%s/bin/brew shellenv", shQuote(brew_home)))
  if (attr(shellenv, "status") != 0L || length(shellenv) == 0) {
    stop("Failed to obtain brew shellenv from ", brew_home, ":\n", paste(shellenv, collapse = "\n"))
  }
}

# 2) Apply brew shellenv now; persist into ~/.zprofile only for user-local brew
message_section("Activating brew shellenv")
for (line in shellenv) {
  m <- regexec('^export ([A-Za-z_][A-Za-z0-9_]*)="?(.*?)"?$', line)
  r <- regmatches(line, m)[[1]]
  if (length(r) == 3) Sys.setenv(structure(r[3], names = r[2]))
}
if (!use_existing) {
  zline <- 'eval "$($HOME/homebrew/bin/brew shellenv)"'
  if (!file.exists(zprofile) || !any(grepl("homebrew/bin/brew shellenv", readLines(zprofile, warn = FALSE), fixed = TRUE))) {
    cat(zline, "\n", file = zprofile, append = TRUE)
  }
  cat("~/.zprofile updated to source user-local brew shellenv.\n", sep = "")
} else {
  cat("Not modifying ~/.zprofile (reusing existing brew on PATH).\n", sep = "")
}

# 3) Show brew version, update, install toolchain
message_section("brew update & install toolchain")
ver <- run_sh("brew --version")
cat(paste(ver, collapse = "\n"), "\n", sep = "")

upd <- run_sh("brew update")
if (attr(upd, "status") != 0L) {
  warning("brew update reported issues (continuing):\n", paste(upd, collapse = "\n"))
}

# Install formulae (idempotent; brew will skip if satisfied)
pkgs <- c("llvm", "gcc", "pkg-config", "gsl")
inst <- run_sh(sprintf("brew install %s", paste(shQuote(pkgs), collapse = " ")))
if (attr(inst, "status") != 0L) {
  message("brew install output (non-fatal):\n", paste(inst, collapse = "\n"))
}

# 4) Resolve prefixes for wiring ~/.Renviron
message_section("Configuring ~/.Renviron for R builds")
brew_prefix <- paste(run_sh("brew --prefix"), collapse = "")
llvm_prefix <- paste(run_sh("brew --prefix llvm"), collapse = "")
gsl_prefix  <- paste(run_sh("brew --prefix gsl"),  collapse = "")

# Use tilde-based paths for portability in R; these point to user-local locations
# when we installed user-local brew, and to system locations if reusing system brew.
# For PATH we *prepend* LLVM and brew bin, but we do not hardcode absolute CC paths.
LLVM_BIN_TILDE <- if (!use_existing) "~/homebrew/opt/llvm/bin" else file.path("~", substring(llvm_prefix, nchar(path.expand("~"))+2), "bin")
BREW_BIN_TILDE <- if (!use_existing) "~/homebrew/bin"           else file.path("~", substring(file.path(brew_prefix, "bin"), nchar(path.expand("~"))+2))
BREW_PKG_TILDE <- if (!use_existing) "~/homebrew/lib/pkgconfig" else file.path("~", substring(file.path(brew_prefix, "lib", "pkgconfig"), nchar(path.expand("~"))+2))
GSL_PKG_TILDE  <- if (!use_existing) "~/homebrew/opt/gsl/lib/pkgconfig" else file.path("~", substring(file.path(gsl_prefix, "lib", "pkgconfig"), nchar(path.expand("~"))+2))
PKGCONF_TILDE  <- if (!use_existing) "~/homebrew/bin/pkg-config" else file.path("~", substring(file.path(brew_prefix, "bin", "pkg-config"), nchar(path.expand("~"))+2))

# Guard: if prefixes couldn't be resolved yet (e.g., llvm not installed), fall back to common tilde paths
fallback_if_empty <- function(x, fb) if (!nzchar(x) || grepl("^~/$", x)) fb else x
LLVM_BIN_TILDE <- fallback_if_empty(LLVM_BIN_TILDE, "~/homebrew/opt/llvm/bin")
BREW_BIN_TILDE <- fallback_if_empty(BREW_BIN_TILDE, "~/homebrew/bin")
BREW_PKG_TILDE <- fallback_if_empty(BREW_PKG_TILDE, "~/homebrew/lib/pkgconfig")
GSL_PKG_TILDE  <- fallback_if_empty(GSL_PKG_TILDE,  "~/homebrew/opt/gsl/lib/pkgconfig")
PKGCONF_TILDE  <- fallback_if_empty(PKGCONF_TILDE,  "~/homebrew/bin/pkg-config")

# Idempotently append env lines
append_unique_line(renviron, sprintf('PATH="%s:%s:${PATH}"', LLVM_BIN_TILDE, BREW_BIN_TILDE))
append_unique_line(renviron, 'CC="clang"')
append_unique_line(renviron, 'CXX="clang++"')
append_unique_line(renviron, 'FC="gfortran"')
append_unique_line(renviron, 'F77="gfortran"')
append_unique_line(renviron, sprintf('PKG_CONFIG="%s"', PKGCONF_TILDE))
append_unique_line(renviron, sprintf('PKG_CONFIG_PATH="%s:%s:${PKG_CONFIG_PATH}"', BREW_PKG_TILDE, GSL_PKG_TILDE))

cat("Wrote/ensured entries in: ", renviron, "\n", sep = "")
cat("  - PATH prepended with ", LLVM_BIN_TILDE, " and ", BREW_BIN_TILDE, "\n", sep = "")
cat("  - CC/CXX/FC/F77 set to clang/clang++/gfortran\n", sep = "")
cat("  - PKG_CONFIG and PKG_CONFIG_PATH set (incl. GSL)\n", sep = "")

# 5) Prime current R session PATH so you can use compilers immediately
Sys.setenv(PATH = paste(file.path(llvm_prefix, "bin"),
                        file.path(brew_prefix, "bin"),
                        Sys.getenv("PATH"),
                        sep = .Platform$path.sep))

# 6) Optional: notify about Apple CLTs
message_section("Checking Apple Command Line Tools")
clt <- run_sh("xcode-select -p")
if (attr(clt, "status") == 0L) {
  cat("Apple Command Line Tools found at: ", paste(clt, collapse = ""), "\n", sep = "")
} else {
  cat("Tip: Running 'xcode-select --install' can improve SDK-based builds (no sudo to initiate).\n", sep = "")
}

# 7) Verify compilers and GSL discovery
message_section("Verifying compilers and GSL via pkg-config")
cmd_ok <- function(x) nzchar(Sys.which(x))
cat("clang:     ", Sys.which("clang"), "\n", sep = "")
cat("gfortran:  ", Sys.which("gfortran"), "\n", sep = "")
cat("pkg-config:", Sys.which("pkg-config"), "\n", sep = "")

pc_ver <- run_sh("pkg-config --version")
cat("pkg-config version: ", if (attr(pc_ver, "status")==0L) paste(pc_ver, collapse=" ") else "not found", "\n", sep = "")

gsl_ver <- run_sh("pkg-config --modversion gsl")
if (attr(gsl_ver, "status") == 0L) {
  cat("GSL version: ", paste(gsl_ver, collapse = " "), "\n", sep = "")
} else {
  cat("WARNING: pkg-config did not find GSL. Check PKG_CONFIG_PATH in ~/.Renviron\nExpected to include: ", GSL_PKG_TILDE, "\n", sep = "")
}

cat("\nAll set!\n- Restart R so it reads ~/.Renviron automatically.\n- You can now build R packages from source with clang/gfortran and link GSL.\n", sep = "")
