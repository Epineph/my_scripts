#!/usr/bin/env bash
# recv-sign-key — Fetch GPG keys into pacman’s keyring and locally sign them.
# Arch-focused helper wrapping `pacman-key -r` and `pacman-key --lsign-key`.
#
# Exit codes:
#   0  success
#   1  usage / input error
#   2  missing dependency
#   3  runtime failure (network, pacman-key, etc.)

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.3.0"
SCRIPT_NAME="$(basename "$0")"

# ─────────────────────────────── Defaults ───────────────────────────────
ASSUME_YES=false
DRY_RUN=false
QUIET=false
KEYSERVER=""          # e.g. hkps://keys.openpgp.org (leave empty to use system default)
KEY_FILE=""
KEYS=()

# ──────────────────────────── Mini logging API ──────────────────────────
_color() { [[ -t 2 ]] && [[ "${NO_COLOR:-0}" != "1" ]] && printf '%b' "$1" || true; }
BOLD=$(_color $'\033[1m'); DIM=$(_color $'\033[2m'); GREEN=$(_color $'\033[32m')
YELLOW=$(_color $'\033[33m'); RED=$(_color $'\033[31m'); RESET=$(_color $'\033[0m')

log()  { $QUIET || printf '%s\n' "$*"; }
inf()  { $QUIET || printf '%s%s%s\n' "${DIM}" "$*" "${RESET}"; }
ok()   { $QUIET || printf '%s%s%s\n' "${GREEN}" "$*" "${RESET}"; }
warn() { printf '%s%s%s\n' "${YELLOW}" "$*" "${RESET}" >&2; }
err()  { printf '%s%s%s\n' "${RED}" "$*" "${RESET}" >&2; }

die()  { err "$*"; exit 1; }

# ──────────────────────────────── Help ──────────────────────────────────
show_help() {
  cat <<'EOF'
Usage:
  recv-sign-key [OPTIONS] [KEY_ID ...]
  recv-sign-key -k KEY_ID [KEY_ID ...]
  recv-sign-key -f FILE_WITH_KEY_IDS

Fetch one or more public keys into pacman's keyring and locally sign them
(after fingerprint review unless --yes/--noconfirm/--force is supplied).

Options:
  -k, --keyid <ID ...>     One or more key IDs (8/16/40 hex, with or without 0x).
                           You may also pass KEY_IDs positionally without -k.
  -f, --file  <PATH>       Read key IDs from file (whitespace or newline separated;
                           lines starting with # are ignored).
  -s, --server <URL>       Override keyserver for retrieval (e.g., hkps://keys.openpgp.org).
                           Defaults to whatever /etc/pacman.d/gnupg/gpg.conf specifies.
  -y, --yes, --noconfirm, --force
                           Non-interactive: skip fingerprint confirmation and sign.
      --dry-run            Print planned actions; do not modify the system.
  -q, --quiet              Reduce output.
      --version            Print version and exit.
  -h, --help               Show this help and exit.

Examples:
  # Single key (andontie-aur)
  recv-sign-key -k 72BF227DD76AE5BF

  # Multiple keys, mixed formats
  recv-sign-key -k 72BF227DD76AE5BF 0xBD2AC8C5E989490C

  # Positional args without -k
  recv-sign-key 72BF227DD76AE5BF BD2AC8C5E989490C

  # From a file
  recv-sign-key -f ~/.config/aur-keyids.txt

Security note:
  ALWAYS verify fingerprints from a trusted, out-of-band source before signing.
  Local signatures mark keys as trusted for your system.

EOF
}

# ─────────────────────────── Dependency checks ──────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1 (exit 2)"; }
check_deps() {
  need pacman-key || { err "pacman-key is required."; exit 2; }
  if [[ $EUID -ne 0 ]]; then
    need sudo || { err "sudo is required when not root."; exit 2; }
  fi
}

# Run a command with root privileges (sudo if needed)
as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# ────────────────────────────── Utilities ───────────────────────────────
normalize_key() {
  # Upper-case, strip leading 0x, keep only hex (let pacman-key accept short/long).
  local k="${1^^}"
  k="${k#0X}"
  printf '%s' "$k"
}

add_keys_from_file() {
  local f="$1"
  [[ -r "$f" ]] || die "Cannot read key file: $f"
  # shellcheck disable=SC2207
  local lines=($(grep -vE '^\s*(#|$)' "$f" | tr -s '[:space:]' '\n'))
  for k in "${lines[@]}"; do
    KEYS+=("$(normalize_key "$k")")
  done
}

# ────────────────────────────── Arg parsing ─────────────────────────────
parse_args() {
  if [[ $# -eq 0 ]]; then
    show_help; exit 1
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -k|--keyid)
        shift
        [[ $# -gt 0 ]] || die "Missing argument(s) to --keyid"
        # Gather subsequent non-option tokens as key IDs
        while [[ $# -gt 0 && "${1:0:1}" != "-" ]]; do
          KEYS+=("$(normalize_key "$1")")
          shift
        done
        ;;
      -f|--file)
        shift; [[ $# -gt 0 ]] || die "Missing path for --file"
        KEY_FILE="$1"; shift
        ;;
      -s|--server)
        shift; [[ $# -gt 0 ]] || die "Missing URL for --server"
        KEYSERVER="$1"; shift
        ;;
      -y|--yes|--noconfirm|--force)
        ASSUME_YES=true; shift ;;
      --dry-run)    DRY_RUN=true;   shift ;;
      -q|--quiet)   QUIET=true;     shift ;;
      --version)    printf '%s\n' "$VERSION"; exit 0 ;;
      -h|--help)    show_help; exit 0 ;;
      --)           shift; while [[ $# -gt 0 ]]; do KEYS+=("$(normalize_key "$1")"); shift; done ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        KEYS+=("$(normalize_key "$1")"); shift
        ;;
    esac
  done

  if [[ -n "$KEY_FILE" ]]; then
    add_keys_from_file "$KEY_FILE"
  fi
  # Deduplicate while preserving order (associative to allow string keys)
  if [[ ${#KEYS[@]} -eq 0 ]]; then
    die "No key IDs provided."
  fi
  local -A seen=()
  local -a uniq=()
  local k
  for k in "${KEYS[@]}"; do
    if [[ -z "${seen["$k"]+x}" ]]; then
      uniq+=("$k"); seen["$k"]=1
    fi
  done
  KEYS=("${uniq[@]}")
}

# ───────────────────── Fingerprint + confirmation ───────────────────────
show_fingerprint() {
  local key="$1"
  as_root pacman-key --finger "$key" || return 1
}

confirm_sign() {
  local key="$1"
  $ASSUME_YES && return 0
  printf "%sReview fingerprint above for key [%s].%s\n" "${BOLD}" "$key" "${RESET}"
  read -r -p "Locally sign this key? [y/N] " ans || true
  case "${ans:-}" in
    y|Y) return 0 ;;
    *)   return 1 ;;
  esac
}

# ─────────────────────────────── Main flow ──────────────────────────────
main() {
  parse_args "$@"
  check_deps

  inf "${SCRIPT_NAME} v${VERSION}"
  inf "Keys: ${KEYS[*]}"
  [[ -n "$KEYSERVER" ]] && inf "Keyserver override: $KEYSERVER" || inf "Keyserver: system default"
  $ASSUME_YES && warn "Non-interactive mode: skipping fingerprint review (trust boundary is yours)."

  # Fetch public keys
  if $DRY_RUN; then
    log "[DRY-RUN] pacman-key -r ${KEYS[*]} ${KEYSERVER:+--keyserver $KEYSERVER}"
  else
    if [[ -n "$KEYSERVER" ]]; then
      as_root pacman-key -r "${KEYS[@]}" --keyserver "$KEYSERVER" \
        || die "Failed to retrieve one or more keys."
    else
      as_root pacman-key -r "${KEYS[@]}" \
        || die "Failed to retrieve one or more keys (check network/keyserver)."
    fi
  fi

  # For each key: (optionally show fingerprint), then sign
  local key
  for key in "${KEYS[@]}"; do
    $DRY_RUN && {
      $ASSUME_YES || log "[DRY-RUN] Show fingerprint: $key"
      log "[DRY-RUN] Local-sign: $key"
      continue
    }

    if ! $ASSUME_YES; then
      inf "────────────────────────────────────────────────────────"
      if ! show_fingerprint "$key"; then
        warn "Could not display fingerprint for $key (does the key exist?). Skipping."
        continue
      fi
    fi

    if confirm_sign "$key"; then
      if as_root pacman-key --lsign-key "$key"; then
        ok "Locally signed: $key"
      else
        warn "Signing failed for: $key"
      fi
    else
      warn "Skipped signing: $key"
    fi
  done

  ok "Done."
}

main "$@"

