#!/bin/bash

##############################################################
# NIDDK Connect to Server Manager  v1.0
# SwiftDialog based tool for backing up and restoring the
# user's Finder "Connect to Server" lists (Favorites, Recent
# Servers, Recent Hosts) to/from OneDrive or any user chosen
# location (flash drive, external disk, network share, etc).
#
#   Back Up -> copy the saved server list files to
#              <dest>/Connect to Server Backup/
#                     Backup YYYY-MM-DD HH.MM.SS/
#                     com.apple.sharedfilelist/
#
#   Restore -> copy the saved server list files from a backup
#              set back into the user's sharedfilelist folder,
#              moving any existing copies aside to a
#              PreRestore <stamp> safety folder first, then
#              refreshing Finder so the change appears.
#
# What this does and does NOT do:
#   - It saves/restores the *list entries* only (the servers
#     that show under Finder > Go > Connect to Server and the
#     "Recent Servers" list). It does NOT copy any files from
#     the servers themselves, and it stores no passwords.
#
# Style and plumbing follow Browser Data Manager v1.2 /
# Loaner Manager v2.6. Built by reusing that skeleton with the
# browser specific pieces removed (the payload here is a fixed
# set of files, so there is no per item selection window for this).
#
# If needed Jamf Parameters:
#   $4 - (optional) Banner image override
#   $5 - (optional) Icon override
#
# Flags (manual/testing use):
#   --dry-run   log what would be copied, copy nothing
#   --merge     restore copies over existing files instead of
#               moving them aside first (no pre-restore copy)
#   --debug     dump every dialog's raw output to the log
#
# v1.0.1:
#   - FIX: infobox macOS line showed literal "** 27.0**". The
#     license RTF name parse returned empty on Golden Gate, so
#     OS_DISPLAY was " 27.0" (leading space)   and SwiftDialog
#     markdown won't open bold on "**" followed by a space, so
#     the asterisks rendered literally. OS name resolution is
#     now RTF-parse with a major-version->name fallback map, and
#     the display string is built trimmed. Shows "Golden Gate
#     27.0", "Tahoe 26.7.1", etc.
##############################################################

##############################################################
# Global Config
##############################################################

DIALOG="/usr/local/bin/dialog"
BANNER="${4:-/Library/NIDDK/SuperFriends/NIDDKBanner.png}"
ICON="${5:-/Library/NIDDK/SuperFriends/NIDDKGreenLogo.png}"

TITLE="NIDDK Connect to Server Manager"
SCRIPT_VERSION="1.0"

MIN_SD_REQUIRED_VERSION="2.3.3"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"

ORG_HINT="National Institutes of Health"   # picks the right OneDrive if several exist
BACKUP_BASENAME="Connect to Server Backup"

# The sharedfilelist files that hold the Connect to Server data.
# Glob patterns — extension varies by macOS version (sfl2/sfl3).
SFL_SUBDIR="com.apple.sharedfilelist"
TARGET_PATTERNS=(
    "com.apple.LSSharedFileList.FavoriteServers.sfl*"
    "com.apple.LSSharedFileList.RecentServers.sfl*"
    "com.apple.LSSharedFileList.RecentHosts.sfl*"
)

LOG_DIR="/Library/NIDDK/logs"
LOG_FILE="${LOG_DIR}/ConnectToServerManager.log"

TMP_JSON="/tmp/niddk_ctsmgr_dialog.json"
SELECT_JSON="/tmp/niddk_ctsmgr_select.json"
WAIT_CMDFILE="/tmp/niddk_ctsmgr_cmdfile"
DIALOG_OUT="/tmp/niddk_ctsmgr_dialog_out"

# Set to 1 to dump every dialog's raw output to the log.
DEBUG_DIALOG=0

# Behavior toggles (flags can flip these)
DRYRUN=0
REPLACE_EXISTING=1     # 1 = move existing aside then restore; 0 = merge in place

##############################################################
# Cleanup / Trap
##############################################################

cleanup() {
    # Tell any live progress dialog to close before we yank its files
    [[ -f "$WAIT_CMDFILE" ]] && echo "quit:" >> "$WAIT_CMDFILE" 2>/dev/null
    rm -f "$TMP_JSON" "$SELECT_JSON" "$WAIT_CMDFILE" "$DIALOG_OUT"
}
trap cleanup EXIT

##############################################################
# Logging
##############################################################

create_log_directory() {
    [[ ! -d "$LOG_DIR" ]] && /bin/mkdir -p "$LOG_DIR"
    /bin/chmod 755 "$LOG_DIR"
    [[ ! -f "$LOG_FILE" ]] && /usr/bin/touch "$LOG_FILE"
    /bin/chmod 644 "$LOG_FILE"
}

logMe() {
    echo "${1}" 1>&2
    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" >> "$LOG_FILE"
}

debug_dump_dialog_output() {
    [[ "$DEBUG_DIALOG" -eq 1 ]] || return 0
    logMe "DEBUG [$1] dialog raw output:"
    [[ -f "$DIALOG_OUT" ]] && /bin/cat "$DIALOG_OUT" >> "$LOG_FILE"
}

##############################################################
# SwiftDialog install / version check
##############################################################

install_swift_dialog() {
    /usr/local/bin/jamf policy -trigger "$DIALOG_INSTALL_POLICY"
}

# version compare without zsh's is-at-least:
# returns 0 if $1 >= $2
ver_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | /usr/bin/sort -V | /usr/bin/head -n1)" == "$2" ]]
}

check_swift_dialog_install() {
    local sd_version="0.0.0"
    if [[ ! -x "$DIALOG" ]]; then
        logMe "SwiftDialog missing  installing via Jamf trigger '$DIALOG_INSTALL_POLICY'"
        install_swift_dialog
    fi
    [[ -x "$DIALOG" ]] && sd_version=$("$DIALOG" --version 2>/dev/null)
    if ! ver_ge "$sd_version" "$MIN_SD_REQUIRED_VERSION"; then
        logMe "SwiftDialog $sd_version < required $MIN_SD_REQUIRED_VERSION  updating via Jamf"
        install_swift_dialog
        sd_version=$("$DIALOG" --version 2>/dev/null)
    fi
    if [[ ! -x "$DIALOG" ]]; then
        logMe "FATAL: SwiftDialog unavailable after install attempt. Exiting."
        exit 1
    fi
    logMe "SwiftDialog version in use: $sd_version"
}

check_support_files() {
    [[ ! -e "$BANNER" ]] && /usr/local/bin/jamf policy -trigger "$SUPPORT_FILE_INSTALL_POLICY"
}

##############################################################
# Console user / home
##############################################################

CONSOLE_USER=$(/usr/bin/stat -f%Su /dev/console)
[[ "$CONSOLE_USER" == "root" && -n "${SUDO_USER:-}" ]] && CONSOLE_USER="$SUDO_USER"

resolve_console_user() {
    if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
        logMe "FATAL: no GUI console user — cannot display dialogs."
        exit 1
    fi
    USER_HOME=$(/usr/bin/dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
    [[ -z "$USER_HOME" ]] && USER_HOME=$(eval echo "~${CONSOLE_USER}")
    if [[ ! -d "$USER_HOME" ]]; then
        logMe "FATAL: home folder not found for ${CONSOLE_USER}"
        exit 1
    fi
    CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER")
    # Where the live Connect to Server lists live for this user.
    SFL_DIR="${USER_HOME}/Library/Application Support/${SFL_SUBDIR}"
    logMe "Console user: ${CONSOLE_USER} (uid ${CONSOLE_UID}) home: ${USER_HOME}"
}

# Run something inside the console user's GUI session.
# Needed for osascript 'choose folder' and 'open'; plain dialog
# calls work fine as root from Self Service (Loaner Manager pattern).
as_user() {
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$@"
}

##############################################################
# Tech identity (Loaner Manager pattern)
##############################################################

get_tech_identity() {
    local source=""
    if [[ -n "${JSSUsername:-}" ]]; then
        TECH_USER_FULL="$JSSUsername"; source="env"
    elif [[ -f "/Library/Application Support/JAMF/tmp/JSSUsername" ]]; then
        TECH_USER_FULL=$(/bin/cat "/Library/Application Support/JAMF/tmp/JSSUsername" 2>/dev/null); source="jamf-tmp"
    elif [[ -n "$CONSOLE_USER" ]]; then
        TECH_USER_FULL="$CONSOLE_USER"; source="console"
    else
        TECH_USER_FULL="unknown"; source="none"
    fi
    if [[ "$TECH_USER_FULL" == aa* && "$TECH_USER_FULL" != "unknown" ]]; then
        TECH_USER_DISPLAY="${TECH_USER_FULL#aa}"
    else
        TECH_USER_DISPLAY="$TECH_USER_FULL"
    fi
    logMe "Tech identity: ${TECH_USER_FULL} (source: ${source})"
}

##############################################################
# Device icon + static system info (Loaner Manager pattern)
##############################################################

get_device_icon() {
    local model
    model=$(/usr/sbin/ioreg -l 2>/dev/null | /usr/bin/awk '/product-name/ { split($0, line, "\""); printf("%s\n", line[4]); }')
    if [[ "$model" == *"Book"* ]]; then
        DEVICE_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/com.apple.macbookpro-14-2021-silver.icns"
    elif [[ "$model" == *"mini"* ]]; then
        DEVICE_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/com.apple.macmini-2020.icns"
    elif [[ "$model" == *"iMac"* ]]; then
        DEVICE_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/com.apple.imac-unibody-27.icns"
    else
        DEVICE_ICON="$ICON"
    fi
}

get_uptime() {
    local boot now diff d h m
    boot=$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/awk '{print $4}' | /usr/bin/tr -d ',')
    now=$(/bin/date +%s)
    diff=$((now - boot))
    d=$((diff/86400)); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
    if (( d > 0 )); then printf "%dd %dh %dm\n" "$d" "$h" "$m"
    elif (( h > 0 )); then printf "%dh %dm\n" "$h" "$m"
    else printf "%dm\n" "$m"; fi
}

# Resolve the macOS marketing name + full version (e.g. "Tahoe 26.7.1",
# "Golden Gate 27.0") into OS_DISPLAY. Two sources, in order:
#   1) The macOS Software License Agreement RTF — carries the marketing
#      name and needs no edits per release, WHEN the parse succeeds.
#   2) A major-version -> name fallback map, for releases where the RTF
#      parse comes back empty (the format shifts between versions — that
#      empty result was the bug behind "macOS:** 27.0**").
# OS_DISPLAY is always built trimmed: a leading space makes SwiftDialog's
# markdown render the bold "**" literally, which is what showed on screen.
get_macos_display() {
    local ver major name=""
    ver=$(/usr/bin/sw_vers -productVersion 2>/dev/null)
    major="${ver%%.*}"

    name=$(/usr/bin/awk '
        /SOFTWARE LICENSE AGREEMENT FOR macOS/ {
            s = $0
            sub(/^.*SOFTWARE LICENSE AGREEMENT FOR macOS[[:space:]]*/, "", s)
            sub(/\\.*$/, "", s)                  # strip trailing RTF control words
            sub(/[[:space:]]*[0-9].*$/, "", s)   # strip a trailing version number
            sub(/[[:space:]]+$/, "", s)
            print s; exit
        }' "/System/Library/CoreServices/Setup Assistant.app/Contents/Resources/en.lproj/OSXSoftwareLicense.rtf" 2>/dev/null)

    if [[ -z "$name" ]]; then
        case "$major" in
            12) name="Monterey" ;;
            13) name="Ventura" ;;
            14) name="Sonoma" ;;
            15) name="Sequoia" ;;
            26) name="Tahoe" ;;
            27) name="Golden Gate" ;;
            # New major release: add its name here if the RTF parse ever
            # comes back empty for it.
        esac
    fi

    OS_VER="$ver"
    if [[ -n "$name" ]]; then
        OS_DISPLAY="${name} ${ver}"
    else
        OS_DISPLAY="macOS ${ver}"
    fi
}

gather_static_info() {
    local model
    model=$(/usr/sbin/ioreg -l 2>/dev/null | /usr/bin/awk '/product-name/ { split($0, line, "\""); printf("%s\n", line[4]); }')

    COMP_NAME_STATIC=$(/usr/sbin/scutil --get ComputerName 2>/dev/null || /bin/hostname)
    SERIAL=$(/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null | /usr/bin/awk -F': ' '/Serial Number/ {print $2; exit}')
    CHIP=$(/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null | /usr/bin/awk -F': ' '/Chip|Processor Name/ {print $2; exit}')
    RAM=$(/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null | /usr/bin/awk -F': ' '/Memory/ {print $2; exit}' | /usr/bin/xargs)
    FREE_DISK=$(/bin/df -H / | /usr/bin/awk 'NR==2 {print $4 " free of " $2}')
    UPTIME_STR="$(get_uptime)"

    get_macos_display

    SD_INFOBOX="User:**${CONSOLE_USER}**\nName:**${COMP_NAME_STATIC}**\nModel:**${model}**\nSerial:**${SERIAL}**\nOS:**${OS_DISPLAY}**\nProcessor:**${CHIP}**\nMemory:**${RAM}**\nDisk:**${FREE_DISK}**\nUptime:**${UPTIME_STR}**\n\nTech:**${TECH_USER_DISPLAY}**"
}

##############################################################
# Dialog output parsing (Loaner Manager / Browser Data Manager
# pattern). parse_dialog_value <keypath> <file>
# plutil keypath extraction against the --json output. This is
# the fix for the old zsh tool, which scraped 'SelectedOption'
# out of plain text with awk -F ': ' and broke on SD 2.5.x —
# that empty parse fell through to "Invalid location selection".
##############################################################

parse_dialog_value() {
    local keypath="$1" file="$2" val=""
    [[ -s "$file" ]] || { echo ""; return; }
    val=$(/usr/bin/plutil -extract "$keypath" raw -o - "$file" 2>/dev/null)
    [[ "$val" == *"error"* || "$val" == "<stdin>"* ]] && val=""
    echo "$val"
}

##############################################################
# OneDrive detection
##############################################################

norm_str() {
    printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d ' -_'
}

find_onedrive() {
    local cs="${USER_HOME}/Library/CloudStorage" best="" d
    if [[ -d "$cs" ]]; then
        for d in "$cs"/OneDrive*; do
            [[ -d "$d" ]] || continue
            [[ "$(norm_str "$d")" == *"$(norm_str "$ORG_HINT")"* ]] && { echo "$d"; return; }
            best="$d"
        done
        [[ -n "$best" ]] && { echo "$best"; return; }
    fi
    for d in "$USER_HOME"/OneDrive*; do
        [[ -d "$d" ]] || continue
        [[ "$(norm_str "$d")" == *"$(norm_str "$ORG_HINT")"* ]] && { echo "$d"; return; }
        best="$d"
    done
    [[ -n "$best" ]] && { echo "$best"; return; }
    echo ""
}

# Find newest "Backup YYYY-MM-DD HH.MM.SS" under $1; empty if none.
find_latest_backup() {
    local base="$1" latest=""
    [[ -d "$base" ]] || { echo ""; return; }
    latest=$(/bin/ls -1t "$base" 2>/dev/null | /usr/bin/grep -E '^Backup [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}\.[0-9]{2}\.[0-9]{2}$' | /usr/bin/head -n1)
    [[ -n "$latest" && -d "$base/$latest" ]] && echo "$base/$latest" || echo ""
}

##############################################################
# Payload helpers (replaces the browser arrays)
##############################################################

# Echo the matching sharedfilelist files found in a directory,
# one per line. Used for both the live source ($SFL_DIR) and a
# backup set's payload folder.
collect_matching_files() {
    local src_dir="$1" pattern f
    [[ -d "$src_dir" ]] || return 0
    for pattern in "${TARGET_PATTERNS[@]}"; do
        for f in "$src_dir"/$pattern; do
            [[ -e "$f" ]] && echo "$f"
        done
    done
}

# Count matching files in a directory (used for the confirm window).
count_matching_files() {
    collect_matching_files "$1" | /usr/bin/grep -c . 2>/dev/null || echo 0
}

# Accept either a backup set itself or its container; echo the
# folder that actually holds the sharedfilelist payload. Mirrors
# resolve_backup_root from Browser Data Manager but keyed on the
# sharedfilelist subfolder (or loose .sfl* files) instead of the
# browser subdirs.
#
# Resolution order for a chosen path:
#   1) path/com.apple.sharedfilelist/<matching files>   -> that subfolder
#   2) path/<matching files> directly                   -> path
#   3) newest Backup */com.apple.sharedfilelist/...      -> that subfolder
#   4) newest Backup */<matching files> directly         -> that set
resolve_backup_payload() {
    local path="$1" latest

    if [[ -d "$path/$SFL_SUBDIR" ]] && [[ -n "$(collect_matching_files "$path/$SFL_SUBDIR")" ]]; then
        echo "$path/$SFL_SUBDIR"; return 0
    fi
    if [[ -n "$(collect_matching_files "$path")" ]]; then
        echo "$path"; return 0
    fi

    latest=$(find_latest_backup "$path")
    if [[ -n "$latest" ]]; then
        if [[ -d "$latest/$SFL_SUBDIR" ]] && [[ -n "$(collect_matching_files "$latest/$SFL_SUBDIR")" ]]; then
            echo "$latest/$SFL_SUBDIR"; return 0
        fi
        if [[ -n "$(collect_matching_files "$latest")" ]]; then
            echo "$latest"; return 0
        fi
    fi
    return 1
}

##############################################################
# Dialog: Mode Select (Window 1)
# selectitems dropdown with Continue / Cancel (Browser Data
# Manager v1.2 pattern — infobutton doesn't render with
# --buttonstyle center on SD 2.5.x).
# Sets MODE_CHOICE ("backup"/"restore") when DIALOG_EXIT=0.
##############################################################

show_mode_select() {
    local message choice
    local OPT_BACKUP="Back up Connect to Server list from this Mac"
    local OPT_RESTORE="Restore Connect to Server list from a backup"

    message="
This tool backs up and restores the Finder **Connect to Server** list for the current user — the **Favorite Servers**, **Recent Servers**, and **Recent Hosts** that appear under **Finder ▸ Go ▸ Connect to Server**.

Use it when moving a user to a new Mac, or any time the saved server list needs a safety copy. There is also now an Extension Attribute in Jamf to list them. 

- **Back up** — copy the saved server list from this Mac to OneDrive or a location you choose (flash drive, external disk, network share).
- **Restore** — restores a saved server list from a previous backup onto this Mac.

This only saves the **list of servers** it does **not** copy any files from the servers and stores no passwords. Finder may relaunch briefly during a restore so the updated list appears."

    /bin/cat > "$SELECT_JSON" <<EOF
{
    "selectitems" : [
        {
            "title" : "Action",
            "values" : ["${OPT_BACKUP}","${OPT_RESTORE}"],
            "default" : "${OPT_BACKUP}",
            "required" : true
        }
    ]
}
EOF
    /bin/chmod 644 "$SELECT_JSON"
    rm -f "$DIALOG_OUT"

    "$DIALOG" \
        --bannerimage "$BANNER" \
        --bannertitle "Connect to Server Manager" \
        --titlefont 'shadow=1' \
        --icon "$DEVICE_ICON" \
        --message "$message" \
        --infobox "$SD_INFOBOX" \
        --jsonfile "$SELECT_JSON" \
        --json \
        --button1text "Continue" \
        --button2text "Cancel" \
        --height 600 \
        --width 830 \
        --moveable \
        --buttonstyle "center" > "$DIALOG_OUT" 2>>"$LOG_FILE"

    DIALOG_EXIT=$?
    debug_dump_dialog_output "mode_select"
    [[ "$DIALOG_EXIT" -ne 0 ]] && return

    choice=$(parse_dialog_value "Action.selectedValue" "$DIALOG_OUT")
    [[ -z "$choice" ]] && choice=$(parse_dialog_value "Action" "$DIALOG_OUT")
    logMe "Mode dropdown choice: '$choice'"

    if [[ "$choice" == Restore* ]]; then
        MODE_CHOICE="restore"
    else
        MODE_CHOICE="backup"
    fi
}

##############################################################
# Folder chooser (runs in the user's GUI session)
# choose_folder <prompt> <default_path>
# Echoes the chosen POSIX path (no trailing slash) or
# "USER_CANCELLED". Quote/backslash escaping carried over from
# Browser Data Manager v1.2 (fixes the -2741 instant-cancel bug).
##############################################################

choose_folder() {
    local prompt="$1" default_loc="$2" chosen p_esc d_esc
    p_esc="${prompt//\\/\\\\}"; p_esc="${p_esc//\"/\\\"}"
    d_esc="${default_loc//\\/\\\\}"; d_esc="${d_esc//\"/\\\"}"
    chosen=$(as_user /usr/bin/osascript <<OSA
try
    set defaultAlias to POSIX file "$d_esc"
on error
    set defaultAlias to (path to home folder)
end try
try
    set theFolder to choose folder with prompt "$p_esc" default location defaultAlias
    POSIX path of theFolder
on error number -128
    return "USER_CANCELLED"
end try
OSA
)
    chosen="${chosen%/}"
    echo "$chosen"
}

##############################################################
# Destination write test (Browser Data Manager pattern)
# Creates base+dest owned by the user, then verifies the USER
# can actually write there (catches OneDrive offline / Files
# On-Demand placeholders and read-only external media).
# Returns 0 writable / 1 not.
##############################################################

test_destination_writable() {
    local base="$1" dest="$2"
    /usr/bin/install -d -m 0755 -o "$CONSOLE_USER" -g staff "$base" "$dest" 2>>"$LOG_FILE" || return 1
    if as_user /usr/bin/touch "$dest/.write_test" 2>/dev/null; then
        /bin/rm -f "$dest/.write_test"
        return 0
    fi
    return 1
}

##############################################################
# Dialog: Backup Destination (Window 2 — backup path)
# Sets BACKUP_BASE, BACKUP_DEST, BACKUP_PAYLOAD on success.
# DIALOG_EXIT: 0 = destination ready, 2 = Back, 3 = Quit
##############################################################

show_backup_destination_select() {
    local od_root od_label choice values_json default_chooser picked

    od_root=$(find_onedrive)
    if [[ -n "$od_root" ]]; then
        od_label="OneDrive — $(/usr/bin/basename "$od_root")"
    else
        od_label="OneDrive — not detected (opens sign-in)"
    fi
    logMe "OneDrive detection: ${od_root:-none}"

    values_json="[\"${od_label}\",\"Choose a location… (flash drive, external disk, etc.)\"]"

    /bin/cat > "$SELECT_JSON" <<EOF
{
    "selectitems" : [
        {
            "title" : "Backup destination",
            "values" : ${values_json},
            "default" : "${od_label}",
            "required" : true
        }
    ]
}
EOF
    /bin/chmod 644 "$SELECT_JSON"
    rm -f "$DIALOG_OUT"

    "$DIALOG" \
        --bannerimage "$BANNER" \
        --bannertitle "Choose Back Up Destination" \
        --titlefont 'shadow=1' \
        --icon "SF=externaldrive.fill.badge.icloud,color=blue,weight=bold,bgcolor=bgnone" \
        --message "Where should the backup be saved?\n\n- **OneDrive** — recommended. The backup lives in the user's OneDrive and follows them to their new Mac.\n- **Choose a location…** — pick any mounted volume: flash drive, external disk, target-disk-mode Mac, or network share.\n\nBackups are stored under:\n\`${BACKUP_BASENAME}/Backup YYYY-MM-DD HH.MM.SS/\`" \
        --infobox "$SD_INFOBOX" \
        --jsonfile "$SELECT_JSON" \
        --json \
        --button1text "Continue" \
        --button2text "Back" \
        --infobuttontext "Quit" \
        --height 580 \
        --width 830 \
        --moveable \
        --buttonstyle "center" > "$DIALOG_OUT" 2>>"$LOG_FILE"

    DIALOG_EXIT=$?
    debug_dump_dialog_output "backup_destination"
    [[ "$DIALOG_EXIT" -ne 0 ]] && return

    choice=$(parse_dialog_value "Backup destination.selectedValue" "$DIALOG_OUT")
    [[ -z "$choice" ]] && choice=$(parse_dialog_value "Backup destination" "$DIALOG_OUT")
    logMe "Destination choice: '$choice'"

    BACKUP_TS=$(/bin/date '+%Y-%m-%d %H.%M.%S')

    if [[ "$choice" == OneDrive* ]]; then
        if [[ -z "$od_root" ]]; then
            "$DIALOG" \
                --bannerimage "$BANNER" \
                --bannertitle "OneDrive Not Set Up" \
                --titlefont 'shadow=1' \
                --icon "SF=icloud.slash,color=orange,weight=bold,bgcolor=bgnone" \
                --message "No OneDrive folder was found for **${CONSOLE_USER}**.\n\n- **Open OneDrive** to sign in, then run this tool again.\n- **Choose a Location** to back up somewhere else right now." \
                --infobox "$SD_INFOBOX" \
                --button1text "Open OneDrive" \
                --button2text "Choose a Location" \
                --infobuttontext "Quit" \
                --height 580 --width 830 --moveable --buttonstyle "center"
            case $? in
                0)  as_user /usr/bin/open -a "OneDrive" 2>/dev/null
                    logMe "Opened OneDrive for sign-in; exiting so user can retry."
                    DIALOG_EXIT=3; return ;;
                2)  choice="Choose" ;;
                *)  DIALOG_EXIT=3; return ;;
            esac
        else
            BACKUP_BASE="${od_root}/${BACKUP_BASENAME}"
            BACKUP_DEST="${BACKUP_BASE}/Backup ${BACKUP_TS}"
            BACKUP_PAYLOAD="${BACKUP_DEST}/${SFL_SUBDIR}"
            if test_destination_writable "$BACKUP_BASE" "$BACKUP_DEST"; then
                logMe "Destination ready (OneDrive): $BACKUP_DEST"
                DIALOG_EXIT=0; return
            fi
            logMe "WARN: OneDrive destination not writable (offline / Files On-Demand?)"
            "$DIALOG" \
                --bannerimage "$BANNER" \
                --bannertitle "OneDrive Not Writable" \
                --titlefont 'shadow=1' \
                --icon "SF=exclamationmark.icloud.fill,color=orange,weight=bold,bgcolor=bgnone" \
                --message "OneDrive was found but the backup folder couldn't be written — OneDrive may be paused, offline, or still syncing.\n\n- **Open OneDrive** to check its status, then run this tool again.\n- **Choose a Location** to back up somewhere else right now." \
                --infobox "$SD_INFOBOX" \
                --button1text "Open OneDrive" \
                --button2text "Choose a Location" \
                --infobuttontext "Quit" \
                --height 580 --width 830 --moveable --buttonstyle "center"
            case $? in
                0)  as_user /usr/bin/open -a "OneDrive" 2>/dev/null
                    DIALOG_EXIT=3; return ;;
                2)  choice="Choose" ;;
                *)  DIALOG_EXIT=3; return ;;
            esac
        fi
    fi

    # Chooser path (picked directly, or fell through from OneDrive issues)
    default_chooser="${USER_HOME}/Desktop"
    [[ -d "/Volumes" ]] && default_chooser="/Volumes"
    picked=$(choose_folder "Select where to save the backup (a '${BACKUP_BASENAME}' folder will be created here):" "$default_chooser")
    if [[ "$picked" == "USER_CANCELLED" || -z "$picked" ]]; then
        logMe "User cancelled folder chooser."
        DIALOG_EXIT=2; return
    fi

    BACKUP_BASE="${picked}/${BACKUP_BASENAME}"
    BACKUP_DEST="${BACKUP_BASE}/Backup ${BACKUP_TS}"
    BACKUP_PAYLOAD="${BACKUP_DEST}/${SFL_SUBDIR}"
    if test_destination_writable "$BACKUP_BASE" "$BACKUP_DEST"; then
        logMe "Destination ready (chooser): $BACKUP_DEST"
        DIALOG_EXIT=0; return
    fi

    "$DIALOG" \
        --bannerimage "$BANNER" \
        --bannertitle "Destination Not Writable" \
        --titlefont 'shadow=1' \
        --icon "SF=xmark.circle.fill,color=red,weight=bold,bgcolor=bgnone" \
        --message "The selected location isn't writable:\n\n\`${picked}\`\n\nThe volume may be read-only or full. Click **Go Back** to pick a different destination." \
        --infobox "$SD_INFOBOX" \
        --button1text "Go Back" \
        --infobuttontext "Quit" \
        --height 580 --width 830 --moveable --buttonstyle "center"
    if [[ $? -eq 0 ]]; then
        show_backup_destination_select
    else
        DIALOG_EXIT=3
    fi
}

##############################################################
# Dialog: Restore Source (Window 2 — restore path)
# Sets RESTORE_PAYLOAD (folder holding the .sfl* files) and
# RESTORE_SET (the human-facing backup set path) on success.
# DIALOG_EXIT: 0 = source ready, 2 = Back, 3 = Quit
##############################################################

show_restore_source_select() {
    local od_root od_base latest latest_label values_json choice picked payload default_chooser

    od_root=$(find_onedrive)
    od_base=""
    latest=""
    [[ -n "$od_root" ]] && od_base="${od_root}/${BACKUP_BASENAME}"
    [[ -n "$od_base" ]] && latest=$(find_latest_backup "$od_base")

    if [[ -n "$latest" ]]; then
        latest_label="Latest OneDrive backup — $(/usr/bin/basename "$latest")"
        values_json="[\"${latest_label}\",\"Choose a backup folder…\"]"
    else
        latest_label=""
        values_json="[\"Choose a backup folder…\"]"
        logMe "No OneDrive backup sets found (OneDrive: ${od_root:-none})"
    fi

    /bin/cat > "$SELECT_JSON" <<EOF
{
    "selectitems" : [
        {
            "title" : "Restore from",
            "values" : ${values_json},
            "required" : true
        }
    ]
}
EOF
    /bin/chmod 644 "$SELECT_JSON"
    rm -f "$DIALOG_OUT"

    "$DIALOG" \
        --bannerimage "$BANNER" \
        --bannertitle "Choose Backup Restore Source" \
        --titlefont 'shadow=1' \
        --icon "SF=clock.arrow.circlepath,color=blue,weight=bold,bgcolor=bgnone" \
        --message "Where is the backup?\n\n$( [[ -n "$latest_label" ]] && echo "- **Latest OneDrive backup** — the newest set found in this user's OneDrive.\n- " || echo "- " )**Choose a backup folder…** — browse to any backup set: older OneDrive backups, a flash drive, external disk, or a Mac in target disk mode.\n\nYou can select either a specific \`Backup YYYY-MM-DD HH.MM.SS\` folder or the \`${BACKUP_BASENAME}\` folder that contains them (the newest set will be used)." \
        --infobox "$SD_INFOBOX" \
        --jsonfile "$SELECT_JSON" \
        --json \
        --button1text "Continue" \
        --button2text "Back" \
        --infobuttontext "Quit" \
        --height 580 \
        --width 830 \
        --moveable \
        --buttonstyle "center" > "$DIALOG_OUT" 2>>"$LOG_FILE"

    DIALOG_EXIT=$?
    debug_dump_dialog_output "restore_source"
    [[ "$DIALOG_EXIT" -ne 0 ]] && return

    choice=$(parse_dialog_value "Restore from.selectedValue" "$DIALOG_OUT")
    [[ -z "$choice" ]] && choice=$(parse_dialog_value "Restore from" "$DIALOG_OUT")
    logMe "Restore source choice: '$choice'"

    if [[ "$choice" == Latest* && -n "$latest" ]]; then
        payload=$(resolve_backup_payload "$latest")
        if [[ -n "$payload" ]]; then
            RESTORE_PAYLOAD="$payload"
            RESTORE_SET="$latest"
            logMe "Restore source (latest OneDrive): payload=$RESTORE_PAYLOAD"
            DIALOG_EXIT=0; return
        fi
        logMe "WARN: latest OneDrive set had no payload; falling through to chooser."
    fi

    default_chooser="${od_base:-${USER_HOME}/Desktop}"
    [[ -d "$default_chooser" ]] || default_chooser="$USER_HOME"
    picked=$(choose_folder "Select the backup folder (a 'Backup …' set, or the '${BACKUP_BASENAME}' folder that contains them):" "$default_chooser")
    if [[ "$picked" == "USER_CANCELLED" || -z "$picked" ]]; then
        logMe "User cancelled restore source chooser."
        DIALOG_EXIT=2; return
    fi

    payload=$(resolve_backup_payload "$picked")
    if [[ -z "$payload" ]]; then
        "$DIALOG" \
            --bannerimage "$BANNER" \
            --bannertitle "Not a Valid Backup" \
            --titlefont 'shadow=1' \
            --icon "SF=questionmark.folder.fill,color=orange,weight=bold,bgcolor=bgnone" \
            --message "No Connect to Server backup was found at:\n\n\`${picked}\`\n\nA valid backup set contains a \`${SFL_SUBDIR}\` folder with at least one saved server list file.\n\nClick **Go Back** to pick a different folder." \
            --infobox "$SD_INFOBOX" \
            --button1text "Go Back" \
            --infobuttontext "Quit" \
            --height 580 --width 830 --moveable --buttonstyle "center"
        if [[ $? -eq 0 ]]; then
            show_restore_source_select
        else
            DIALOG_EXIT=3
        fi
        return
    fi

    RESTORE_PAYLOAD="$payload"
    RESTORE_SET="$picked"
    logMe "Restore source (chooser): payload=$RESTORE_PAYLOAD"
    DIALOG_EXIT=0
}

##############################################################
# Dialog: Confirm (Window 3 — both paths)
# One last look before files move, with a live file count.
# DIALOG_EXIT: 0 = go, 2 = Back, 3 = Quit
##############################################################

show_confirm() {
    local mode="$1" warn path_line count

    if [[ "$mode" == "backup" ]]; then
        count=$(count_matching_files "$SFL_DIR")
        path_line="Saving to:\n\`${BACKUP_DEST}\`"
        warn="Found **${count}** saved server list file(s) to back up.\n\nNothing on this Mac is changed by a backup."
    else
        count=$(count_matching_files "$RESTORE_PAYLOAD")
        path_line="Restoring from:\n\`${RESTORE_SET}\`"
        warn="Found **${count}** saved server list file(s) in this backup.\n\nYour current Connect to Server list is moved to a \`Pre-Restore\` safety copy first — nothing is deleted. Finder will relaunch so the restored list appears."
    fi

    [[ "$DRYRUN" -eq 1 ]] && warn="� **DRY RUN** — nothing will actually be copied.\n\n${warn}"

    "$DIALOG" \
        --bannerimage "$BANNER" \
        --bannertitle "Ready to $( [[ "$mode" == "backup" ]] && echo "Back Up" || echo "Restore" )" \
        --titlefont 'shadow=1' \
        --icon "$DEVICE_ICON" \
        --message "${path_line}\n\n${warn}" \
        --infobox "$SD_INFOBOX" \
        --button1text "Start" \
        --button2text "Back" \
        --infobuttontext "Quit" \
        --height 580 \
        --width 830 \
        --moveable \
        --buttonstyle "center"

    DIALOG_EXIT=$?
}

##############################################################
# Progress dialog (650x310 mini, commandfile — Loaner pattern)
##############################################################

start_progress_dialog() {
    local title="$1" msg="$2" icon="$3"
    rm -f "$WAIT_CMDFILE"
    /usr/bin/touch "$WAIT_CMDFILE"
    /bin/chmod 644 "$WAIT_CMDFILE"

    "$DIALOG" \
        --bannerimage "$BANNER" \
        --title "$title" \
        --titlefont 'shadow=1' \
        --message "$msg" \
        --icon "$icon" \
        --progress \
        --progresstext "Starting…" \
        --height 310 \
        --width 650 \
        --mini \
        --moveable \
        --button1disabled \
        --button1text "Please wait..." \
        --commandfile "$WAIT_CMDFILE" &
    PROGRESS_DIALOG_PID=$!
    /bin/sleep 0.3
}

progress_update() {
    echo "progress: $1" >> "$WAIT_CMDFILE"
    echo "progresstext: $2" >> "$WAIT_CMDFILE"
}

end_progress_dialog() {
    local final_text="$1"
    echo "progress: 100" >> "$WAIT_CMDFILE"
    echo "progresstext: ${final_text}" >> "$WAIT_CMDFILE"
    /bin/sleep 1
    echo "quit:" >> "$WAIT_CMDFILE"
    /bin/sleep 0.5
    kill "$PROGRESS_DIALOG_PID" 2>/dev/null
    wait "$PROGRESS_DIALOG_PID" 2>/dev/null
    rm -f "$WAIT_CMDFILE"
}

##############################################################
# Result bookkeeping (single-payload version)
# set_result <ok|skip|fail|dry> <text>
##############################################################

init_results() {
    RESULT_TEXT="Not run"
    RESULT_ICON="SF=minus.circle,color=gray,bgcolor=bgnone"
    RESULT_COUNT=0
    OVERALL_FAILS=0
}

set_result() {
    local kind="$1" text="$2"
    RESULT_TEXT="$text"
    case "$kind" in
        ok)   RESULT_ICON="SF=checkmark.circle.fill,color=green,weight=bold,bgcolor=bgnone" ;;
        skip) RESULT_ICON="SF=minus.circle.fill,color=orange,weight=bold,bgcolor=bgnone" ;;
        dry)  RESULT_ICON="SF=testtube.2,color=blue,weight=bold,bgcolor=bgnone" ;;
        fail) RESULT_ICON="SF=xmark.circle.fill,color=red,weight=bold,bgcolor=bgnone"
              OVERALL_FAILS=$((OVERALL_FAILS+1)) ;;
    esac
}

##############################################################
# README for the backup set
##############################################################

write_readme() {
    local readme="${BACKUP_BASE}/README.txt"
    [[ -f "$readme" ]] && return 0
    /bin/cat > "$readme" <<'TXT'
Connect to Server Backups - Restore Guide
=========================================

Created by the NIDDK "Connect to Server Manager" Self Service tool.
Each run is stored under:
  Connect to Server Backup/Backup YYYY-MM-DD HH.MM.SS/
    com.apple.sharedfilelist/

What is saved
-------------
The Finder "Connect to Server" list entries for the user:
  - Favorite Servers
  - Recent Servers
  - Recent Hosts

These come from:
  ~/Library/Application Support/com.apple.sharedfilelist/

This does NOT contain any files from those servers, and no
passwords are stored.

Easiest restore
---------------
Run "Connect to Server Manager" from Self Service on the new
Mac, pick Restore, and point it at this folder.

Notes
-----
- The exact file extension can differ by macOS version
  (for example sfl2 or sfl3). The tool copies whatever is
  present.
- After a restore, Finder relaunches so the updated list
  appears under Go > Connect to Server.
- For long-term safety, right-click this folder in OneDrive
  and choose "Always Keep on This Device".
TXT
    /usr/sbin/chown "$CONSOLE_USER":staff "$readme" 2>/dev/null
}

##############################################################
# Engine: Back Up
##############################################################

do_backup() {
    local f bn count=0 copied=0
    local files=()

    start_progress_dialog "Backing Up Connect to Server List…" \
        "Saving to:\n\`${BACKUP_DEST}\`" \
        "SF=arrow.up.doc.fill,color=blue,weight=bold,animation=pulse"

    progress_update 10 "Checking saved server lists…"
    if [[ ! -d "$SFL_DIR" ]]; then
        logMe "No sharedfilelist folder for ${CONSOLE_USER} at $SFL_DIR"
        set_result fail "No Connect to Server data found on this Mac"
        end_progress_dialog "Nothing to back up."
        return
    fi

    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(collect_matching_files "$SFL_DIR")

    count=${#files[@]}
    if [[ "$count" -eq 0 ]]; then
        logMe "No matching .sfl* files in $SFL_DIR"
        set_result skip "No saved server list entries found"
        end_progress_dialog "Nothing to back up."
        return
    fi
    logMe "Found ${count} file(s) to back up."

    if [[ "$DRYRUN" -eq 1 ]]; then
        for f in "${files[@]}"; do
            logMe "DRY-RUN: would copy $f -> ${BACKUP_PAYLOAD}/$(/usr/bin/basename "$f")"
        done
        set_result dry "Dry run — would back up ${count} file(s)"
        RESULT_COUNT=$count
        end_progress_dialog "Dry run complete."
        return
    fi

    progress_update 30 "Copying saved server lists…"
    /usr/bin/install -d -m 0755 -o "$CONSOLE_USER" -g staff "$BACKUP_PAYLOAD" 2>>"$LOG_FILE"

    local i pct
    for (( i=0; i<count; i++ )); do
        f="${files[$i]}"
        bn=$(/usr/bin/basename "$f")
        pct=$(( 30 + (i+1) * 50 / count ))
        progress_update "$pct" "Copying ${bn}…"
        if /usr/bin/ditto "$f" "${BACKUP_PAYLOAD}/${bn}" 2>>"$LOG_FILE"; then
            copied=$((copied+1))
        else
            logMe "ERROR: ditto failed for $f"
        fi
    done

    progress_update 85 "Writing notes and manifest…"
    write_readme
    {
        echo "Connect to Server backup created: $(/bin/date)"
        echo "User: ${CONSOLE_USER}"
        echo "Source: ${SFL_DIR}"
        echo "Files copied: ${copied} of ${count}"
        echo ""
        echo "Copied files:"
        for f in "${files[@]}"; do echo "- $(/usr/bin/basename "$f")"; done
    } > "${BACKUP_DEST}/MANIFEST.txt" 2>>"$LOG_FILE"

    progress_update 95 "Setting ownership on new backup…"
    /usr/sbin/chown -R "$CONSOLE_USER":staff "$BACKUP_DEST" 2>/dev/null
    /bin/chmod -R u+rwX "$BACKUP_DEST" 2>/dev/null
    /usr/sbin/chown "$CONSOLE_USER":staff "$BACKUP_BASE" 2>/dev/null

    RESULT_COUNT=$copied
    if [[ "$copied" -eq "$count" ]]; then
        set_result ok "Backed up ${copied} file(s)"
    elif [[ "$copied" -gt 0 ]]; then
        set_result fail "Backed up ${copied} of ${count} (see log)"
    else
        set_result fail "Copy failed (see log)"
    fi

    end_progress_dialog "Backup complete."
}

##############################################################
# Finder refresh (after restore)
# Bounce the daemons that cache the server lists and relaunch
# Finder so the restored entries appear. Carried over from the
# original zsh tool.
##############################################################

refresh_finder_views() {
    if [[ "$DRYRUN" -eq 1 ]]; then
        logMe "DRY-RUN: would refresh sharedfilelistd / cfprefsd / Finder"
        return 0
    fi
    /usr/bin/killall -u "$CONSOLE_USER" sharedfilelistd >/dev/null 2>&1
    /usr/bin/killall -u "$CONSOLE_USER" cfprefsd        >/dev/null 2>&1
    /usr/bin/killall -u "$CONSOLE_USER" Finder          >/dev/null 2>&1
    /bin/sleep 1
    as_user /usr/bin/open -a Finder >/dev/null 2>&1
}

##############################################################
# Engine: Restore
##############################################################

do_restore() {
    local f bn target count=0 copied=0 prev_dir
    local files=()

    RESTORE_STAMP=$(/bin/date +%Y%m%d_%H%M%S)

    start_progress_dialog "Restoring Connect to Server List…" \
        "Restoring from:\n\`${RESTORE_SET}\`" \
        "SF=arrow.down.doc.fill,color=green,weight=bold,animation=pulse"

    progress_update 10 "Reading backup…"
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(collect_matching_files "$RESTORE_PAYLOAD")

    count=${#files[@]}
    if [[ "$count" -eq 0 ]]; then
        logMe "No matching .sfl* files in $RESTORE_PAYLOAD"
        set_result fail "No server list files in this backup"
        end_progress_dialog "Nothing to restore."
        return
    fi
    logMe "Found ${count} file(s) to restore."

    if [[ "$DRYRUN" -eq 1 ]]; then
        for f in "${files[@]}"; do
            logMe "DRY-RUN: would restore $f -> ${SFL_DIR}/$(/usr/bin/basename "$f") (REPLACE_EXISTING=$REPLACE_EXISTING)"
        done
        set_result dry "Dry run would restore ${count} file(s)"
        RESULT_COUNT=$count
        end_progress_dialog "Dry run complete."
        return
    fi

    progress_update 25 "Preparing restore location…"
    /usr/bin/install -d -m 0755 -o "$CONSOLE_USER" -g staff "$SFL_DIR" 2>>"$LOG_FILE"

    # Move existing matching files aside (default) — the safety copy
    if [[ "$REPLACE_EXISTING" -eq 1 ]]; then
        prev_dir="${SFL_DIR}/Pre-Restore-ConnectToServer-${RESTORE_STAMP}"
        progress_update 35 "Saving current list aside…"
        /usr/bin/install -d -m 0755 -o "$CONSOLE_USER" -g staff "$prev_dir" 2>>"$LOG_FILE"
        for f in "${files[@]}"; do
            bn=$(/usr/bin/basename "$f")
            target="${SFL_DIR}/${bn}"
            if [[ -e "$target" ]]; then
                logMe "Preserving existing ${bn} -> ${prev_dir}/${bn}"
                /usr/bin/ditto "$target" "${prev_dir}/${bn}" 2>>"$LOG_FILE"
            fi
        done
        /usr/sbin/chown -R "$CONSOLE_USER":staff "$prev_dir" 2>/dev/null
    fi

    local i pct
    for (( i=0; i<count; i++ )); do
        f="${files[$i]}"
        bn=$(/usr/bin/basename "$f")
        target="${SFL_DIR}/${bn}"
        pct=$(( 45 + (i+1) * 35 / count ))
        progress_update "$pct" "Restoring ${bn}…"
        if /usr/bin/ditto "$f" "$target" 2>>"$LOG_FILE"; then
            /usr/sbin/chown "$CONSOLE_USER":staff "$target" 2>/dev/null
            /bin/chmod 644 "$target" 2>/dev/null
            copied=$((copied+1))
        else
            logMe "ERROR: ditto failed restoring $f"
        fi
    done

    progress_update 85 "Refreshing Finder…"
    refresh_finder_views

    RESULT_COUNT=$copied
    RESTORE_PREV_DIR="${prev_dir:-}"
    if [[ "$copied" -eq "$count" ]]; then
        set_result ok "Restored ${copied} file(s)"
    elif [[ "$copied" -gt 0 ]]; then
        set_result fail "Restored ${copied} of ${count} (see log)"
    else
        set_result fail "Restore failed (see log)"
    fi

    end_progress_dialog "Restore complete."
}

##############################################################
# Dialog: Summary (Window 4 — listitem style, AD tool pattern)
##############################################################

show_summary() {
    local mode="$1" path_title path_value overall_text overall_icon rows=""

    if [[ "$mode" == "backup" ]]; then
        path_title="Saved to:"
        path_value="$BACKUP_DEST"
    else
        path_title="Restored from:"
        path_value="$RESTORE_SET"
    fi

    if [[ "$DRYRUN" -eq 1 ]]; then
        overall_text="Dry run — no files were copied"
        overall_icon="SF=testtube.2,color=blue,weight=bold,bgcolor=bgnone"
    elif [[ "$OVERALL_FAILS" -gt 0 ]]; then
        overall_text="Completed with ${OVERALL_FAILS} failure(s) — check the log"
        overall_icon="SF=exclamationmark.triangle.fill,color=red,weight=bold,bgcolor=bgnone"
    else
        overall_text="Completed successfully"
        overall_icon="SF=checkmark.seal.fill,color=green,weight=bold,bgcolor=bgnone"
    fi

    rows+="        {\"title\" : \"Connect to Server list:\", \"icon\" : \"${RESULT_ICON}\", \"statustext\" : \"${RESULT_TEXT}\"},\n"

    # Restore-only row: where the previous list was parked.
    if [[ "$mode" == "restore" && "$DRYRUN" -ne 1 && -n "${RESTORE_PREV_DIR:-}" ]]; then
        rows+="        {\"title\" : \"Previous list saved to:\", \"icon\" : \"SF=shippingbox.fill,color=gray,weight=bold,bgcolor=bgnone\", \"statustext\" : \"${RESTORE_PREV_DIR}\"},\n"
    fi

    /bin/cat > "$TMP_JSON" <<EOF
{
    "listitem" : [
$(printf '%b' "$rows")        {"title" : "${path_title}",  "icon" : "SF=folder.fill,color=blue,weight=bold,bgcolor=bgnone",      "statustext" : "${path_value}"},
        {"title" : "Log:",            "icon" : "SF=doc.text,color=gray,weight=bold,bgcolor=bgnone",         "statustext" : "${LOG_FILE}"},
        {"title" : "Overall Status:", "icon" : "${overall_icon}",                                            "statustext" : "${overall_text}"}
    ]
}
EOF

    local DIALOG_ARGS=(
        --bannerimage "$BANNER"
        --bannertitle "$( [[ "$mode" == "backup" ]] && echo "Back Up Summary" || echo "Restore Summary" )"
        --titlefont 'shadow=1'
        --message none
        --icon "$DEVICE_ICON"
        --jsonfile "$TMP_JSON"
        --infobox "$SD_INFOBOX"
        --height 580
        --width 830
        --moveable
        --buttonstyle "center"
    )

    if [[ "$mode" == "backup" && "$DRYRUN" -ne 1 ]]; then
        "$DIALOG" "${DIALOG_ARGS[@]}" \
            --button1text "Done" \
            --button2text "Open Backup Folder"
        if [[ $? -eq 2 ]]; then
            as_user /usr/bin/open "$BACKUP_DEST" 2>/dev/null
        fi
    else
        "$DIALOG" "${DIALOG_ARGS[@]}" \
            --button1text "Done"
    fi
}

##############################################################
# Main
##############################################################

main() {
    # Flags
    local a
    for a in "$@"; do
        case "$a" in
            --dry-run) DRYRUN=1 ;;
            --merge)   REPLACE_EXISTING=0 ;;
            --replace) REPLACE_EXISTING=1 ;;
            --debug)   DEBUG_DIALOG=1 ;;
        esac
    done

    create_log_directory
    logMe "=== Connect to Server Manager v${SCRIPT_VERSION} start (dryrun=${DRYRUN} replace=${REPLACE_EXISTING}) ==="

    resolve_console_user
    check_swift_dialog_install
    check_support_files
    get_tech_identity
    get_device_icon
    gather_static_info
    init_results

    # State machine: Back (exit 2) walks one step backward,
    # Quit (infobutton, exit 3) or window close exits clean.
    local STEP="mode"

    while true; do
        case "$STEP" in

            mode)
                show_mode_select
                if [[ "$DIALOG_EXIT" -eq 0 ]]; then
                    logMe "Mode: ${MODE_CHOICE}"
                    [[ "$MODE_CHOICE" == "restore" ]] && STEP="restore_source" || STEP="backup_dest"
                else
                    logMe "Cancelled at mode select."
                    exit 0
                fi
                ;;

            # ---------- Backup path ----------
            backup_dest)
                show_backup_destination_select
                case $DIALOG_EXIT in
                    0) STEP="backup_confirm" ;;
                    2) STEP="mode" ;;
                    *) logMe "Quit at destination select."; exit 0 ;;
                esac
                ;;

            backup_confirm)
                show_confirm "backup"
                case $DIALOG_EXIT in
                    0) do_backup; show_summary "backup"; break ;;
                    2) STEP="backup_dest" ;;
                    *) logMe "Quit at confirm."; exit 0 ;;
                esac
                ;;

            # ---------- Restore path ----------
            restore_source)
                show_restore_source_select
                case $DIALOG_EXIT in
                    0) STEP="restore_confirm" ;;
                    2) STEP="mode" ;;
                    *) logMe "Quit at source select."; exit 0 ;;
                esac
                ;;

            restore_confirm)
                show_confirm "restore"
                case $DIALOG_EXIT in
                    0) do_restore; show_summary "restore"; break ;;
                    2) STEP="restore_source" ;;
                    *) logMe "Quit at confirm."; exit 0 ;;
                esac
                ;;
        esac
    done

    logMe "=== Connect to Server Manager finished (failures: ${OVERALL_FAILS}) ==="
    exit 0
}

main "$@"