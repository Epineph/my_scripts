#!/usr/bin/env bash
# secure-archive — create an encrypted backup archive (7z AES-256 or tar.gz.gpg)
# - Default sources: ~/.zshrc ~/.zsh_profile ~/.config/zsh
# - Default output dir: $HOME/dotfile_backups
# - Default format: 7z (AES-256, header-encrypted)
# - Creates missing default directories; validates sources; flexible list parsing.

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# Defaults
# ────────────────────────────────────────────────────────────────────────────────
DEFAULT_OUTDIR="${HOME}/dotfile_backups"
DEFAULT_SOURCES=( "${HOME}/.zshrc" "${HOME}/.zsh_profile" "${HOME}/.config/zsh" )
DEFAULT_FORMAT="7z"   # alternatives: "gpg"
OUTDIR="${DEFAULT_OUTDIR}"
OUTFILE=""
FORMAT="${DEFAULT_FORMAT}"
DRY_RUN=0
SOURCES_RAW=()        # raw tokens from -s/--sources (may include comma/space separated lists)
SOURCES_FILE=""

# ────────────────────────────────────────────────────────────────────────────────
# Viewer for help text (helpout > batwrap > bat > cat)
# ────────────────────────────────────────────────────────────────────────────────
function _help_viewer() {
  if command -v helpout >/dev/null 2>&1; then
    helpout
  elif command -v batwrap >/dev/null 2>&1; then
    batwrap
  elif command -v bat >/dev/null 2>&1; then
    bat --style="grid,header,snip" --italic-text="always" --theme="gruvbox-dark" \
        --squeeze-blank --squeeze-limit="2" --force-colorization --terminal-width="auto" \
        --tabs="2" --paging="never" --chop-long-lines
  else
    cat
  fi
}

# ────────────────────────────────────────────────────────────────────────────────
# Help
# ────────────────────────────────────────────────────────────────────────────────
function show_help() {
  cat <<'EOF' | _help_viewer
# `secure-archive` — create an encrypted backup of selected files/dirs

**Synopsis**
- `secure-archive` \\
  `[-s "<paths>"]...` `[--sources-file <file>]` \\
  `[-d <out-dir>]` `[-o <outfile>]` `[--format 7z|gpg]` `[--dry-run]` \\
  `[--help]`

**Description**
Creates an encrypted backup archive of chosen sources. By default:
- **Format:** 7z with AES-256 and header encryption (filenames hidden)
- **Output:** `~/dotfile_backups/dotfiles-YYYYMMDD-HHMMSS.7z`
- **Sources:** `~/.zshrc`, `~/.zsh_profile`, `~/.config/zsh`
- **Behavior:** Missing *default directories* are created; missing files are warned and skipped.

**Options**
- `-s, --sources "<list>"`  
  One or more source lists. A list may contain comma and/or space separators:  
  `-s "~/.zshrc, ~/.zsh_profile ~/.config/zsh"`  
  You may pass `-s` multiple times.  
  *Note:* If your paths contain spaces, prefer separate `-s` flags or use `--sources-file`.

- `--sources-file <file>`  
  Read sources from a newline-delimited file (supports spaces in paths).

- `-d, --out-dir <dir>`  
  Output directory. Created if missing. Default: `~/dotfile_backups`.

- `-o, --out-file <path>`  
  Explicit output file path. Parent directory is created if missing.
  The extension determines format if `--format` is not set:
  - `*.7z` → 7z (AES-256, header-encrypted)
  - `*.tar.gz.gpg` → tar.gz piped to GPG (AES-256)

- `-f, --format 7z|gpg`  
  Force archive format (overrides extension inference).

- `-n, --dry-run`  
  Show what would happen (sources resolved, output path/format) and exit.

- `-h, --help`  
  Show this help.

**Examples**
- Default backup (7z) of default sources:  
  `secure-archive`

- Custom sources via mixed separators:  
  `secure-archive -s "~/.zshrc, ~/.zsh_profile ~/.config/zsh"`

- Multiple -s flags:  
  `secure-archive -s "~/.zshrc, ~/.zsh_profile" -s "~/.config/zsh"`

- Sources with spaces (use a file):  
  `printf "%s\n" "$HOME/.config/Some Dir" "$HOME/.zshrc" > /tmp/list.txt`  
  `secure-archive --sources-file /tmp/list.txt`

- Explicit output file (format inferred):  
  `secure-archive -o "$HOME/backups/dotfiles.7z"`  
  `secure-archive -o "$HOME/backups/dotfiles.tar.gz.gpg"`

**Security notes**
- 7z uses AES-256 with header encryption; GPG symmetric encryption also uses AES-256.  
- Choose a high-entropy passphrase. Losing it means permanent data loss.

EOF
}

# ────────────────────────────────────────────────────────────────────────────────
# Utilities
# ────────────────────────────────────────────────────────────────────────────────
function die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
function msg()  { printf '%s\n' "$*"; }
function ts()   { date +%Y%m%d-%H%M%S; }

# Split a user-provided list string on commas and spaces, trimming empties.
# Note: This intentionally *does not* preserve spaces within a single path.
# For paths with spaces, use --sources-file or multiple -s flags.
function parse_list_string() {
  local s expanded tok
  s="$1"
  # Replace commas with spaces, then split on IFS (space, tab, newline)
  expanded="${s//,/ }"
  # shellcheck disable=SC2086
  for tok in $expanded; do
    [[ -n "$tok" ]] && printf '%s\0' "$tok"
  done
}

# Read newline-delimited file of sources (supports spaces)
function read_sources_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Sources file not found: $file"
  # print NUL-delimited entries
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && printf '%s\0' "$line"
  done <"$file"
}

# Resolve sources: combine defaults/flags, create default dirs if missing, validate.
function resolve_sources() {
  local -a resolved=()
  local -a defaults=( "${DEFAULT_SOURCES[@]}" )
  local had_any_flag=0

  # Collect from -s flags
  if ((${#SOURCES_RAW[@]} > 0)); then
    had_any_flag=1
    local raw
    for raw in "${SOURCES_RAW[@]}"; do
      while IFS= read -r -d '' item; do
        resolved+=( "$item" )
      done < <(parse_list_string "$raw")
    done
  fi

  # Collect from --sources-file
  if [[ -n "$SOURCES_FILE" ]]; then
    had_any_flag=1
    while IFS= read -r -d '' item; do
      resolved+=( "$item" )
    done < <(read_sources_file "$SOURCES_FILE")
  fi

  # If nothing provided, use defaults (and ensure default dirs exist)
  if (( had_any_flag == 0 )); then
    local p
    for p in "${defaults[@]}"; do
      # If a default is a directory path and missing, create it.
      if [[ "$p" == */ && ! -d "$p" ]]; then
        mkdir -p "$p"
      elif [[ -d "$p" ]]; then
        : # exists
      elif [[ -f "$p" ]]; then
        : # exists
      else
        # If it's a directory-like default (we only assume ~/.config/zsh), create it.
        if [[ "$p" == *"/.config/"* || "$p" == *"/.config/zsh" ]]; then
          mkdir -p "$p"
        fi
      fi
      resolved+=( "$p" )
    done
  fi

  # Filter and normalize existing entries; warn on non-existent files.
  local -a include=()
  local entry
  for entry in "${resolved[@]}"; do
    # tilde expansion
    entry="${entry/#\~/$HOME}"
    if [[ -d "$entry" ]]; then
      include+=( "$entry" )
    elif [[ -f "$entry" ]]; then
      include+=( "$entry" )
    else
      msg "WARN: Skipping missing path: $entry" >&2
    fi
  done

  if ((${#include[@]} == 0)); then
    die "No valid sources to archive after validation."
  fi

  # Emit NUL-delimited results
  local inc
  for inc in "${include[@]}"; do
    printf '%s\0' "$inc"
  done
}

# Determine output file path given OUTFILE/OUTDIR/FORMAT
function resolve_outfile() {
  local outfile="$OUTFILE"
  if [[ -z "$outfile" ]]; then
    mkdir -p "$OUTDIR"
    case "$FORMAT" in
      7z)  outfile="${OUTDIR}/dotfiles-$(ts).7z" ;;
      gpg) outfile="${OUTDIR}/dotfiles-$(ts).tar.gz.gpg" ;;
      *)   die "Unknown format: $FORMAT" ;;
    esac
  else
    mkdir -p "$(dirname -- "$outfile")"
    # If FORMAT not explicitly set, infer from extension
    if [[ "$FORMAT" == "$DEFAULT_FORMAT" && -n "$OUTFILE" ]]; then
      if [[ "$outfile" == *.tar.gz.gpg ]]; then
        FORMAT="gpg"
      elif [[ "$outfile" == *.7z ]]; then
        FORMAT="7z"
      fi
    fi
  fi
  printf '%s' "$outfile"
}

# ────────────────────────────────────────────────────────────────────────────────
# Archivers
# ────────────────────────────────────────────────────────────────────────────────
function do_7z() {
  command -v 7z >/dev/null 2>&1 || die "7z not found. Install 'p7zip' (Arch: pacman -S p7zip)."
  local outfile="$1"; shift
  msg "Creating encrypted 7z (AES-256, header-encrypted): $outfile"
  # -p → prompt for passphrase; -mhe=on → encrypt headers (hide filenames)
  7z a -p -mhe=on -- "$outfile" "$@"
  msg "Done."
}

function do_gpg() {
  command -v gpg >/dev/null 2>&1 || die "gpg not found. Install 'gnupg'."
  local outfile="$1"; shift
  msg "Creating tar.gz.gpg (GPG symmetric AES-256): $outfile"
  tar -czf - --absolute-names -- "$@" | gpg -c -o "$outfile"
  msg "Done."
}

# ────────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ────────────────────────────────────────────────────────────────────────────────
function parse_args() {
  while (( $# )); do
    case "$1" in
      -s|--sources)
        shift
        [[ $# -gt 0 ]] || die "Missing argument to --sources"
        SOURCES_RAW+=( "$1" )
        ;;
      --sources-file)
        shift
        [[ $# -gt 0 ]] || die "Missing argument to --sources-file"
        SOURCES_FILE="$1"
        ;;
      -d|--out-dir)
        shift
        [[ $# -gt 0 ]] || die "Missing argument to --out-dir"
        OUTDIR="$1"
        ;;
      -o|--out-file)
        shift
        [[ $# -gt 0 ]] || die "Missing argument to --out-file"
        OUTFILE="$1"
        ;;
      -f|--format)
        shift
        [[ $# -gt 0 ]] || die "Missing argument to --format"
        case "$1" in
          7z|gpg) FORMAT="$1" ;;
          *) die "Invalid format: $1 (use 7z|gpg)";;
        esac
        ;;
      -n|--dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        show_help; exit 0 ;;
      --)
        shift; break ;;
      -*)
        die "Unknown option: $1" ;;
      *)
        # Allow trailing positional tokens as sources as a convenience
        SOURCES_RAW+=( "$1" )
        ;;
    esac
    shift || true
  done
}

# ────────────────────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────────────────────
function main() {
  parse_args "$@"

  # Resolve source list
  local -a SOURCES=()
  while IFS= read -r -d '' inc; do
    SOURCES+=( "$inc" )
  done < <(resolve_sources)

  # Resolve outfile
  local OUT
  OUT="$(resolve_outfile)"

  # Dry-run summary
  if (( DRY_RUN )); then
    msg "DRY-RUN:"
    msg "  Format : $FORMAT"
    msg "  Outfile: $OUT"
    msg "  Sources:"
    local s
    for s in "${SOURCES[@]}"; do
      msg "    - $s"
    done
    exit 0
  fi

  # Dispatch
  case "$FORMAT" in
    7z)  do_7z  "$OUT" "${SOURCES[@]}" ;;
    gpg) do_gpg "$OUT" "${SOURCES[@]}" ;;
    *)   die "Unknown format: $FORMAT" ;;
  esac
}

main "$@"

