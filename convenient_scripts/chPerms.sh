#!/usr/bin/env bash

##############################################################################
# changePermissions: A script to view and modify ownership & permissions of files/
#           directories, supporting multiple targets, dry-run, and now a
#           "--refresh-rc" option to source the user's shell RC file.
#
# Version: 1.4.0
# Author:  Heini Winther Johnsen
# License: MIT
##############################################################################

show_help() {
    cat <<EOF
Usage: $(basename "$0") [PATH(S)...] [OPTIONS]...

Change ownership and/or permissions of one or more files/directories.

Arguments:
  PATH(S)             One or more paths (space-separated). You can also use
                      -t/--target <LIST>, where <LIST> is comma-separated.

Options:
  -t, --target <LIST> Comma-separated list of paths (e.g. dir1,dir2,dir3).
                      This can be combined with or instead of positional paths.

  -R, --recursive
      --recursively-apply
      --recurse-action
      --force-recursively
      --recursively-force
                      Apply changes recursively. Prompts for confirmation unless
                      --noconfirm or --force is used.

  -o, --owner <USER>  Change the owner to <USER>. "user:group" also works, e.g. "root:staff".
                      If <USER> is "activeuser", we use the current user (id -un).

  -g, --group <GROUP> Change only the group to <GROUP>.

  -p, --perm <PERMS>
      --permission, permissions, etc.
                      Set permissions in numeric (e.g. 755), 9-char symbolic
                      (e.g. rwxr-xr-x), or extended symbolic (u=rwx,g=rx,o=rx).
                      (Don't include leading '-' or 'd' from ls -l output.)

  -c, --current-owner 
      currentowner, currentownership
                      Show current owner/group of each target.

  -a, --active-perms
      --active-permissions
      currentperms
                      Show current permissions (symbolic + numeric) of each target.

  --noconfirm         Bypass confirmation for recursive operations.
  --dry-run, -n       Preview changes without actually applying them.

  --refresh, --refresh-rc
                      Attempt to source the current user's RC file (~/.bashrc or ~/.zshrc)
                      after all operations. (Note: This won't affect your
                      already-running shell session.)

  --version           Show version information and exit.
  --help              Display this help text and exit.

Examples:
  # Apply perms & ownership to multiple directories at once:
    sudo $(basename "$0") dirA dirB -o heini -p 755 -R

  # Specify multiple targets via -t:
    sudo $(basename "$0") -t dirA,dirB -o root -g staff -p u=rwx,g=r-x,o=r-x

  # Combine both (positional + -t):
    sudo $(basename "$0") dirA -t dirB,dirC -p 755 -R

  # Dry-run:
    $(basename "$0") dirA dirB --perm 755 --dry-run

  # Attempt refresh RC after changes:
    $(basename "$0") dirA -p 755 --refresh-rc
EOF
}

##############################################################################
#  GLOBALS
##############################################################################
RECURSIVE=false
FORCE=false
NOCONFIRM=false
DRY_RUN=false
REFRESH_RC=false  # <-- new

TARGETS=()
OPERATIONS=()

##############################################################################
#  HELPER FUNCTIONS
##############################################################################

confirm_recursive() {
    if ! $NOCONFIRM && ! $FORCE; then
        echo "You have requested a recursive operation. This may affect many files"
        echo "and can break your system if used improperly."
        read -rp "Are you sure you want to continue? [y/N]: " response
        if [[ "$response" != [Yy] ]]; then
            echo "Recursive operation cancelled."
            exit 1
        fi
    fi
}

display_ownership() {
    local path="$1"
    local owner group
    owner=$(stat -c %U "$path" 2>/dev/null)
    group=$(stat -c %G "$path" 2>/dev/null)
    echo "Current ownership of '$path':"
    echo "  Owner: $owner"
    echo "  Group: $group"
}

display_permissions() {
    local path="$1"
    local symbolic numeric user_perms group_perms others_perms
    symbolic=$(stat -c %A "$path" 2>/dev/null)
    numeric=$(stat -c %a "$path" 2>/dev/null)
    echo "Current permissions of '$path':"
    echo "  Symbolic: $symbolic"
    echo "  Numeric: $numeric"
    user_perms=$(echo "$symbolic" | cut -c2-4)
    group_perms=$(echo "$symbolic" | cut -c5-7)
    others_perms=$(echo "$symbolic" | cut -c8-10)
    echo "  Detailed: u=$user_perms, g=$group_perms, o=$others_perms"
}

calculate_numeric_perm() {
    local perm_str="$1"
    local -n out_ref="$2"
    local -i value=0

    [[ "$perm_str" == *r* ]] && ((value += 4))
    [[ "$perm_str" == *w* ]] && ((value += 2))
    [[ "$perm_str" == *x* ]] && ((value += 1))

    out_ref=$value
}

apply_permissions() {
    local path="$1"
    local perms="$2"
    local rec_option="$3"

    # Numeric (e.g. 755)
    if [[ "$perms" =~ ^[0-7]{3}$ ]]; then
        if ! $DRY_RUN; then
            echo "Setting permissions of '$path' to '$perms'..."
            chmod "$rec_option" "$perms" "$path"
            echo "Permissions change applied."
        else
            echo "[DRY RUN] Would set permissions of '$path' to '$perms' $rec_option."
        fi

    # 9-char symbolic
    elif [[ "$perms" =~ ^[rwx-]{9}$ ]]; then
        local u g o
        calculate_numeric_perm "${perms:0:3}" u
        calculate_numeric_perm "${perms:3:3}" g
        calculate_numeric_perm "${perms:6:3}" o
        local octal=$((u*64 + g*8 + o))
        local octal_str
        octal_str=$(printf '%o' "$octal")

        if ! $DRY_RUN; then
            echo "Setting permissions of '$path' to '$perms' (= $octal_str)..."
            chmod "$rec_option" "$octal_str" "$path"
            echo "Permissions change applied."
        else
            echo "[DRY RUN] Would set permissions of '$path' to '$perms' (= $octal_str) $rec_option."
        fi

    # Extended symbolic u=...,g=...,o=...
    elif [[ "$perms" =~ ^u=([rwx-]{1,3}),g=([rwx-]{1,3}),o=([rwx-]{1,3})$ ]]; then
        local u g o
        calculate_numeric_perm "${BASH_REMATCH[1]}" u
        calculate_numeric_perm "${BASH_REMATCH[2]}" g
        calculate_numeric_perm "${BASH_REMATCH[3]}" o
        local octal=$((u*64 + g*8 + o))
        local octal_str
        octal_str=$(printf '%o' "$octal")

        if ! $DRY_RUN; then
            echo "Setting permissions of '$path' to '$perms' (= $octal_str)..."
            chmod "$rec_option" "$octal_str" "$path"
            echo "Permissions change applied."
        else
            echo "[DRY RUN] Would set permissions of '$path' to '$perms' (= $octal_str) $rec_option."
        fi

    else
        echo "Error: Invalid permissions format '$perms'."
        exit 1
    fi

    display_permissions "$path"
}

##############################################################################
#  ARGUMENT PARSING
##############################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            show_help
            exit 0
            ;;
        --version)
            echo "$(basename "$0") version 1.4.0"
            exit 0
            ;;
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        -R|--recursive|--recursively-apply|--recurse-action|--force-recursively|--recursively-force)
            RECURSIVE=true
            if [[ "$1" == "--force-recursively" || "$1" == "--recursively-force" ]]; then
                FORCE=true
            fi
            shift
            ;;
        --noconfirm)
            NOCONFIRM=true
            shift
            ;;
        --refresh|--refresh-rc)
            REFRESH_RC=true
            shift
            ;;
        -c|--current-owner|currentowner|currentownership)
            OPERATIONS+=("SHOW_OWNER")
            shift
            ;;
        -a|--active-perms|--active-permissions|currentperms)
            OPERATIONS+=("SHOW_PERMS")
            shift
            ;;
        -o|--owner|ownership|owner)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: Missing argument for $1."
                exit 1
            fi
            OPERATIONS+=("OWNER:$2")
            shift 2
            ;;
        -g|--group)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: Missing argument for $1."
                exit 1
            fi
            OPERATIONS+=("GROUP:$2")
            shift 2
            ;;
        -p|--perm|--perms|--permission|permissions|perms|perm)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: Missing argument for $1."
                exit 1
            fi
            OPERATIONS+=("PERM:$2")
            shift 2
            ;;
        -t|--target)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: Missing argument for $1 (comma-separated list)."
                exit 1
            fi
            IFS=',' read -ra tmplist <<< "$2"
            for t in "${tmplist[@]}"; do
                TARGETS+=("$t")
            done
            shift 2
            ;;
        -*)
            echo "Error: Unknown option '$1'."
            show_help
            exit 1
            ;;
        *)
            # Non-option => treat as a path
            TARGETS+=("$1")
            shift
            ;;
    esac
done

##############################################################################
#  FINAL CHECKS
##############################################################################
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "No path(s) provided. Please specify at least one path."
    echo "Use -t/--target or pass them as positional arguments."
    exit 1
fi

# Check if we need root privileges
requires_sudo=false
for op in "${OPERATIONS[@]}"; do
    case "$op" in
        OWNER:*|GROUP:*)
            requires_sudo=true
            ;;
    esac
done

if $requires_sudo && [[ $EUID -ne 0 ]]; then
    echo "Some operations (changing owner/group) require elevated permissions (sudo)."
    read -rp "Do you want to rerun the script with sudo? [y/N]: " response
    if [[ "$response" == [Yy] ]]; then
        sudo bash "$0" "$@"
        exit $?
    else
        echo "Proceeding without sudo. Ownership/group changes may fail."
    fi
fi

if $RECURSIVE; then
    confirm_recursive
fi

# If no operations, just show ownership/perms for each target
if [[ ${#OPERATIONS[@]} -eq 0 ]]; then
    for T in "${TARGETS[@]}"; do
        echo "No operations requested. Displaying ownership & perms of '$T'"
        if [[ ! -e "$T" ]]; then
            echo "Error: '$T' does not exist."
            continue
        fi
        display_ownership "$T"
        display_permissions "$T"
        echo
    done
    # Possibly do refresh here if no operations? Usually no reason.
    exit 0
fi

##############################################################################
#  APPLY OPERATIONS FOR EACH TARGET
##############################################################################
for T in "${TARGETS[@]}"; do
    if [[ ! -e "$T" ]]; then
        echo "Error: '$T' does not exist. Skipping."
        continue
    fi

    echo "=== Processing target: '$T' ==="

    for op in "${OPERATIONS[@]}"; do
        case "$op" in
            "SHOW_OWNER")
                display_ownership "$T"
                ;;
            "SHOW_PERMS")
                display_permissions "$T"
                ;;
            OWNER:*)
                owner_val="${op#OWNER:}"
                [[ "$owner_val" == "activeuser" ]] && owner_val="$(id -un)"
                if [[ "$owner_val" =~ ^([^:]+):([^:]+)$ ]]; then
                    user="${BASH_REMATCH[1]}"
                    grp="${BASH_REMATCH[2]}"
                    if ! $DRY_RUN; then
                        echo "Changing ownership of '$T' to '$user:$grp'..."
                        chown "${RECURSIVE:+-R}" "$user:$grp" "$T"
                        echo "Ownership changed to '$user:$grp'."
                    else
                        echo "[DRY RUN] Would change ownership of '$T' to '$user:$grp' ${RECURSIVE:+-R}."
                    fi
                else
                    if ! $DRY_RUN; then
                        echo "Changing owner of '$T' to '$owner_val'..."
                        chown "${RECURSIVE:+-R}" "$owner_val" "$T"
                        echo "Owner changed to '$owner_val'."
                    else
                        echo "[DRY RUN] Would change owner of '$T' to '$owner_val' ${RECURSIVE:+-R}."
                    fi
                fi
                display_ownership "$T"
                ;;
            GROUP:*)
                group_val="${op#GROUP:}"
                if ! $DRY_RUN; then
                    echo "Changing group of '$T' to '$group_val'..."
                    chown "${RECURSIVE:+-R}" ":$group_val" "$T"
                    echo "Group changed to '$group_val'."
                else
                    echo "[DRY RUN] Would change group of '$T' to '$group_val' ${RECURSIVE:+-R}."
                fi
                display_ownership "$T"
                ;;
            PERM:*)
                perm_val="${op#PERM:}"
                apply_permissions "$T" "$perm_val" "${RECURSIVE:+-R}"
                ;;
        esac
    done

    echo
done

##############################################################################
#  (OPTIONAL) REFRESH RC LOGIC
##############################################################################
if $REFRESH_RC; then
    echo "Attempting to refresh shell RC for user '$SUDO_USER' or '$USER'..."

    # Figure out which user we should consider
    # If using sudo, $SUDO_USER is typically the original user
    if [[ -n "$SUDO_USER" ]]; then
        local_user="$SUDO_USER"
    else
        local_user="$USER"
    fi

    # Identify home directory
    user_home=$(eval echo "~$local_user")

    # Identify shell
    shell_basename="$(basename "$SHELL")"
    rc_file=""

    if [[ "$shell_basename" == "zsh" ]]; then
        rc_file="$user_home/.zshrc"
    elif [[ "$shell_basename" == "bash" ]]; then
        rc_file="$user_home/.bashrc"
    else
        # Fallback
        rc_file="$user_home/.bashrc"
    fi

    if [[ -f "$rc_file" ]]; then
        echo "Sourcing $rc_file in a subshell. (Note: won't affect your current shell.)"
        # shellcheck disable=SC1090
        source "$rc_file"
    else
        echo "No rc file found at '$rc_file'. Skipping."
    fi
fi
