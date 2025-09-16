#!/usr/bin/env bash
#
# A wrapper script to call 'bat' with custom flags and optional fd-based filtering.

###############################################################################
# Default Configuration
###############################################################################
PAGING="never"            # --paging
THEME="TwoDark"           # --theme
STYLE="grid,header"       # --style
DECORATIONS="always"      # --decorations
COLOR="always"            # --color
WRAP="auto"               # --wrap
LANGUAGE=""               # --language (empty => let bat auto-detect)
EXTENSIONS=""             # Default: no extension filtering
RECURSIVE="false"         # Recursive search
MAX_DEPTH=3               # Default max-depth for recursive searches

# Will hold our target paths
TARGETS=()

###############################################################################
# Helper Functions
###############################################################################



# Check if fd is installed
check_fd_installed() {
  if ! command -v fd >/dev/null 2>&1; then
    echo "Warning: 'fd' is not installed. Falling back to basic file listing." >&2
    echo "To enable optimized searching with 'fd', install it using your package manager." >&2
    return 1
  fi
  return 0
}

# Display usage instructions
usage() {
  bat --style="grid,header" --paging="never" --color="always" --language="LESS" --theme-light="Dracula" <<EOF
Usage: $(basename "$0") [OPTIONS] -t <TARGETS...>

A wrapper script for 'bat' with optional fd-based file filtering.

Options:
  -t, --target <TARGETS...>          Target paths (comma- or space-separated).
  -r, --recursive [MAX_DEPTH]        Recursively display files (default depth: $MAX_DEPTH).
  -x, --extensions <EXTS...>         Comma- or space-separated list of extensions to include.
                                     e.g., -x "py,sh,md" or -x py sh
                                     Defaults to all files if not specified.
  -p, --paging [never|auto|always]   Set paging mode (default: $PAGING).
  --theme <THEME>                    Set the theme (default: $THEME).
  -s, --style <STYLE>                Style (default: $STYLE).
  -d, --decorations <WHEN>           Decorations (default: $DECORATIONS).
  -c, --color <WHEN>                 Color mode (default: $COLOR).
  -w, --wrap <MODE>                  Wrapping mode (default: $WRAP).
  -l, --language <LANG>              Force a language (if not set, let bat auto-detect).
  -h, --help                         Show this help message and exit.

Examples:
  # Default: Display all files in ~/repos
  $(basename "$0") -t ~/repos

  # Recursive, limit depth, and filter extensions
  $(basename "$0") -t ~/repos -r 3 -x "py,md,sh"

  # Target a single file
  $(basename "$0") -t ~/repos/my_script.sh

  # Force language for highlighting
  $(basename "$0") -t ~/repos -l bash
EOF
}

# Log binary file detection
is_binary() {
  file --mime-encoding "$1" 2>/dev/null | grep -q "binary"
}

###############################################################################
# Parse Command-Line Arguments
###############################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      ARG_VALUE=$(echo "$2" | sed 's/,/ /g')
      for entry in $ARG_VALUE; do
        TARGETS+=("$entry")
      done
      shift 2
      ;;
    -r|--recursive)
      RECURSIVE="true"
      if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then
        MAX_DEPTH="$2"
        shift 2
      else
        shift
      fi
      ;;
    -x|--extensions)
      EXTENSIONS=$(echo "$2" | sed 's/,/ /g')
      shift 2
      ;;
    -p|--paging)
      PAGING="$2"
      shift 2
      ;;
    --theme)
      THEME="$2"
      shift 2
      ;;
    -s|--style)
      STYLE="$2"
      shift 2
      ;;
    -d|--decorations)
      DECORATIONS="$2"
      shift 2
      ;;
    -c|--color)
      COLOR="$2"
      shift 2
      ;;
    -w|--wrap)
      WRAP="$2"
      shift 2
      ;;
    -l|--language)
      LANGUAGE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Ensure at least one target is provided
if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "No targets specified."
  # Prompt user, reading exactly one character (without needing Enter).
  read -n 1 -r -p "Show help? [Y/n] " ans
  # Print a newline after the user presses the key.
  echo
  # Convert answer to lowercase for case-insensitive comparison.
  ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
  if [[ "$ans" == "y" ]]; then
    usage
  fi
  # If user pressed anything else (or nothing), just exit.
  exit 1
fi


###############################################################################
# Build Bat Command
###############################################################################
BAT_CMD=("bat")
BAT_CMD+=( "--paging=$PAGING" )
BAT_CMD+=( "--style=$STYLE" )
BAT_CMD+=( "--decorations=$DECORATIONS" )
BAT_CMD+=( "--color=$COLOR" )
BAT_CMD+=( "--wrap=$WRAP" )
[[ -n "$THEME" ]] && BAT_CMD+=( "--theme=$THEME" )
[[ -n "$LANGUAGE" ]] && BAT_CMD+=( "--language=$LANGUAGE" )

###############################################################################
# Process Targets
###############################################################################
process_target() {
  local TGT="$1"

  if [[ -f "$TGT" ]]; then
    # If the target is a single file, process it directly
    if is_binary "$TGT"; then
      echo "Skipping binary file: $TGT" >&2
    else
      "${BAT_CMD[@]}" "$TGT"
    fi
  elif [[ -d "$TGT" ]]; then
    # If the target is a directory, use fd or fallback to find
    if check_fd_installed; then
      FD_CMD=("fd" "--type" "f" "--search-path" "$TGT")
      [[ "$RECURSIVE" == "true" ]] && FD_CMD+=( "--max-depth" "$MAX_DEPTH" )
      [[ -n "$EXTENSIONS" ]] && for ext in $EXTENSIONS; do FD_CMD+=( "-e" "$ext" ); done

      "${FD_CMD[@]}" --print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        if is_binary "$file"; then
          echo "Skipping binary file: $file" >&2
        else
          "${BAT_CMD[@]}" "$file"
        fi
      done
    else
      # Fallback to find if fd is not available
      if [[ "$RECURSIVE" == "true" ]]; then
        find "$TGT" -maxdepth "$MAX_DEPTH" -type f -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
          if is_binary "$file"; then
            echo "Skipping binary file: $file" >&2
          else
            "${BAT_CMD[@]}" "$file"
          fi
        done
      else
        for file in "$TGT"/*; do
          if [[ -f "$file" ]] && ! is_binary "$file"; then
            "${BAT_CMD[@]}" "$file"
          fi
        done
      fi
    fi
  else
    echo "Warning: '$TGT' is not a valid file or directory." >&2
  fi
}

for TGT in "${TARGETS[@]}"; do
  process_target "$TGT"
done
