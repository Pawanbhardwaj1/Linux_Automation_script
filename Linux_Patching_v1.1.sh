#!/usr/bin/env bash
# Description: A menu-driven automation for Linux server patching and cloud build operations.
#set -Eeuo pipefail
#IFS=$'\n\t'

# ================= CONFIGURATION =================
BASE_DIR="/var/log/linux_patching"
LOG_DIR="${BASE_DIR}/logs"
LOCK_FILE="/var/run/linux_patching.lock"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/patching_${TIMESTAMP}.log"
PRECHECK_FILE="${LOG_DIR}/precheck_${TIMESTAMP}.log"
POSTCHECK_FILE="${LOG_DIR}/postcheck_${TIMESTAMP}.log"
COMPARE_FILE="${LOG_DIR}/compare_${TIMESTAMP}.log"

POLL_INTERVAL=10
POLL_TIMEOUT=900
SSH_TIMEOUT=15
RECIPIENT_EMAIL="your.email@example.com"

SCRIPT_USER="$(whoami)"
SERVER_LIST=()
CR_NUMBER=""

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=${SSH_TIMEOUT}"

# ================= INITIALIZATION =================

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required command '$1' not found."
        exit 1
    }
}
safe_ssh() {
    local server="$1"
    local cmd="$2"
    ssh $SSH_OPTS -o StrictHostKeyChecking=no "$server" "$cmd" 2>&1
}
initialize() {
    require_cmd ssh
    require_cmd diff
    require_cmd mail

    mkdir -p "$LOG_DIR"
    chmod 750 "$LOG_DIR"

    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"

    if [[ -f "$LOCK_FILE" ]]; then
        echo "Another instance is running."
        exit 1
    fi
    echo $$ > "$LOCK_FILE"
}

cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT INT TERM
log_info()  { echo "[$(date +'%F %T')] [INFO]  $1" | tee -a "$LOG_FILE"; }
log_error() { echo "[$(date +'%F %T')] [ERROR] $1" | tee -a "$LOG_FILE"; }



# --- Function Definitions ---
# Function to log messages with a timestamp and status
log_message() {
  local status="$1"
  local message="$2"
  # Add user info for auditing
#  echo "$(date +'%Y-%m-%d %H:%M:%S')-[$(whoami)]-[$input_cr]-$status-$message" | tee -a "$LOG_FILE"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')]-[$(whoami)]-[$CR_NUMBER]-$status-$message" | tee -a "$LOG_FILE"
}

# Function to send email reports
send_email() {
    # $1 is the descriptive stage message (e.g., "Pre-Checks Completed")
    local stage_message="$1" 
    local attach_log="$2"  # "yes" or "no"
    
    # The subject now uses the descriptive message directly
    local subject="Patching Report: $stage_message | CR: $CR_NUMBER"
    
    local body="This is an automated notification from the patching script.

Execution Stage: $stage_message
CR Number: $CR_NUMBER
Server List: ${SERVER_LIST}
Timestamp: $(date)

Please review the attached log file ($LOG_FILE) for full details."

    log_message "Attempting to send email for stage: $stage_message to $RECIPIENT_EMAIL"

    if [[ "$attach_log" == "yes" ]]; then
        # Email with attachment
        echo "$body" | mail -s "$subject" -a "$LOG_FILE" "$RECIPIENT_EMAIL"
    else
        # Email without attachment
        echo "$body" | mail -s "$subject" "$RECIPIENT_EMAIL"
    fi

    if [[ $? -eq 0 ]]; then
        log_message "✅ Email sent successfully for stage: $stage_message."
    else
        log_message "❌ FAILED to send email for stage: $stage_message. Check 'mail' utility configuration."
        echo "🚨 WARNING: FAILED TO SEND EMAIL for $stage_message. Check your system's mail setup."
    fi
}
# Function to handle Ctrl+C (SIGINT) or termination (SIGTERM)
ctrl_c_handler() {
    # Log the forced stop
    log_message "🚨 Script forcefully interrupted by user: $SCRIPT_USER (Ctrl+C / SIGINT)."
    
    # Send the emergency email (5th email trigger)
    # The stage name is customized to include the user for clarity
    send_email "Automation Forced Stop by user -- $SCRIPT_USER" "yes"

    # Optional: If you had any lock files (as suggested in the previous response), 
    # call your cleanup function here:
    # check_and_set_remote_lock "cleanup"

    log_message "Script terminated by user interrupt. Exiting with status 130."
#	send_email "Script terminated by user interrupt" "$server" "yes"
    
    # Exit with a status code indicating a fatal error/interruption (128 + signal number)
    exit 130 
}
# --- TRAP Command for Interruption Handling ---
# Instructs the shell to run the 'ctrl_c_handler' function when it receives 
# the SIGINT (Ctrl+C) or SIGTERM (standard termination) signal.
trap 'ctrl_c_handler' INT TERM

# Function to initialize logging directories and files
initialize_logging() {
    # Define the desired permissions for the log directory
    local LOG_PERMISSIONS="755"
    
    # Check if the log directory exists
    if [ ! -d "$LOG_DIR" ]; then
       
        if ! sudo mkdir -p -m "$LOG_PERMISSIONS" "$LOG_DIR"; then
            echo "❌ Error: Failed to create log directory '$LOG_DIR' with permissions $LOG_PERMISSIONS. Exiting."
            exit 1
        else
            echo "✅ Created log directory '$LOG_DIR' with permissions $LOG_PERMISSIONS."
        fi
    else
        # If the directory already exists, ensure it has the desired permissions
        if ! sudo chmod "$LOG_PERMISSIONS" "$LOG_DIR"; then
            echo "⚠️ Warning: Failed to set log directory permissions to $LOG_PERMISSIONS for '$LOG_DIR'."
        else
            echo "✅ Log directory '$LOG_DIR' verified and permissions set to $LOG_PERMISSIONS."
        fi
    fi
    
    # Set the full paths for the log files
    # The date format is simplified for readability in file names.
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    LOG_FILE="$LOG_DIR/automation_script-$timestamp.log"
    PRECHECK_FILE="$LOG_DIR/precheck_report-$timestamp.log"
    POSTCHECK_FILE="$LOG_DIR/postcheck_report-$timestamp.log"
    Compare_output_file="$LOG_DIR/result_comparison-$timestamp.log"

    # Note: 'log_message' is assumed to be defined elsewhere, but using 'echo' here 
    # for initialization status before the main log file is fully functional.
    echo "---"
    echo "✅ Logging initialized. All logs will be stored in '$LOG_DIR'."
	send_email " Automation Eexecution Start by User -- $(whoami)" "no"
}

# Function to prompt the user for a Change Request (CR) number before patching
prompt_for_change_request() {
    log_message "--- Starting Change Management Check ---"
    read -r -p "🚨 ENTER CHANGE REQUEST (CR) NUMBER: " input_cr
    
    if [[ -z "$input_cr" ]]; then
        log_message "❌ CR Number not entered. Patching cannot proceed without a CR."
        echo "❌ CR Number is mandatory. Please enter a valid CR to continue the patching process."
        CR_NUMBER="" # Ensure it is empty if user cancels
        return 1 # Indicate failure
    fi
    
    CR_NUMBER="$input_cr"
    log_message "✅ Change Request Number set: $CR_NUMBER"
    echo "Change Request Number '$CR_NUMBER' recorded. All patching logs will be associated with this CR."
    return 0 # Indicate success
}
# Function to get the OS version of a remote server (e.g., 8.9, 22.04)
get_remote_os_version() {
    local server="$1"
    local os_id=$(get_remote_os "$server") # Uses existing get_remote_os
    local version_info

    case "$os_id" in
        RHEL|Rocky| Alma)
            # Get major.minor version (e.g., 8.9) from /etc/redhat-release
            version_info=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$server" "grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1" 2>/dev/null)
            ;;
        SUSE)
            # Get major version (e.g., 15) from SLES
            version_info=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$server" "grep -oE '[0-9]+' /etc/os-release | head -1" 2>/dev/null)
            ;;
        UBUNTU)
            # Get major version (e.g., 22.04) from lsb_release
            version_info=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$server" "lsb_release -rs" 2>/dev/null)
            ;;
        *)
            version_info="unknown"
            ;;
    esac
    echo "$version_info"
}

# Function to check the OS version against a simplified End-of-Life (EOL) map
check_os_version_and_eol() {
    log_message "--- Starting OS Version and EOL Check ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi
    
    echo "=========================================="
    echo "   OS Version / EOL Status Report"
    echo "=========================================="

    for server in $SERVER_LIST; do
        local os_id=$(get_remote_os "$server")
        local os_version
        local major_version
        
        os_version=$(get_remote_os_version "$server")
        
        log_message "Checking EOL for $server ($os_id $os_version)..."
        
        local eol_status="✅ SUPPORTED"
        local eol_note="Supported by vendor (or current LTS)."

        case "$os_id" in
            RHEL|Rocky| Alma)
                # Check for RHEL major version less than 8
                major_version=$(echo "$os_version" | cut -d'.' -f1)
                if [[ "$major_version" -lt 8 ]]; then
                    eol_status="⚠️ WARNING: MAJOR VERSION EOL"
                    eol_note="RHEL $major_version is likely past or nearing EOL (e.g., RHEL 7 EOL: Jun 2024). Consider upgrading."
                fi
                ;;
            SUSE)
                # Check for SLES major version less than 15
                major_version=$(echo "$os_version" | cut -d'.' -f1)
                if [[ "$major_version" -lt 15 ]]; then
                    eol_status="⚠️ WARNING: MAJOR VERSION EOL"
                    eol_note="SLES $major_version is likely past or nearing EOL (e.g., SLES 12 EOL: Oct 2024). Consider upgrading."
                fi
                ;;
            UBUNTU)
                # Check for Ubuntu LTS version less than 22.04
                major_version=$(echo "$os_version" | cut -d'.' -f1)
                if [[ "$major_version" -lt 22 ]]; then
                    eol_status="⚠️ WARNING: MAJOR VERSION EOL"
                    eol_note="Ubuntu $os_version (e.g., 20.04) is past or nearing standard LTS EOL. Review support contract."
                fi
                ;;
            unknown)
                eol_status="❓ UNKNOWN OS"
                eol_note="Could not determine OS to check EOL status."
                ;;
        esac
        
        echo "Server: $server (OS: $os_id $os_version)" | tee -a "$LOG_FILE"
        echo "Status: $eol_status" | tee -a "$LOG_FILE"
        echo "Note:   $eol_note" | tee -a "$LOG_FILE"
        echo "------------------------------------------"
        log_message "$server EOL Check: $eol_status. Note: $eol_note"
    done
    
    log_message "--- OS Version and EOL Check complete. ---"
}
# Function to run checks on servers and save to a specified file
run_checks() {
    local output_file="$1"
    local action_name="$2"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi
	
    log_message "--- Starting $action_name ---"
    echo "--- $action_name started on $(date) ---" >>"$output_file"
    for server in $SERVER_LIST; do
        log_message "Running checks on $server..."
        echo "==========================================" >>"$output_file"
        echo "Hostname: $server" >>"$output_file"
        echo "Timestamp: $(date)" >>"$output_file"
        echo "==========================================" >>"$output_file"

        # List of commands to run
        local commands=(
            "uptime"
            "df -h"
            "uname -a"
            "cat /etc/fstab"
            "cat /etc/resolv.conf"
            "free -h"
            "lsblk"
        )
        for cmd in "${commands[@]}"; do
            echo "------------ $cmd on $server ------------" >>"$output_file"
            ssh "$server" "$cmd" 2>&1 | tee -a "$LOG_FILE" >>"$output_file"
			echo "----------------------------------------" >>"$output_file"
            echo "" >>"$output_file" # Add a newline for spacing
        done
    done
    log_message "--- $action_name complete. Results saved to $output_file ---"
    echo "The $action_name report has been saved to $output_file."
	 # --- NEW: Automated OS Version and EOL Check (Pre-Patch Warning) ---
    if [[ "$action_name" == *"Pre-Patching Checks"* ]]; then
        log_message "--- Starting OS Version and EOL Check (Pre-Patch Warning) ---"
        echo "=================================================" >>"$output_file"
        echo "  OS EOL WARNING (Risk Assessment - Pre-Patch)" >>"$output_file"
        echo "=================================================" >>"$output_file"
        
        # This function runs the EOL check logic and logs the output
        check_os_version_and_eol | tee -a "$output_file"
        
        log_message "--- Automated OS Version and EOL Check complete. ---"
        echo "The $action_name report has been saved to $output_file."
    fi
}
# Function to compare pre-check and post-check files and highlight changes
compare_reports() {
    log_message "--- Comparing pre-check and post-check reports ---"
    if [ ! -f "$PRECHECK_FILE" ] || [ ! -f "$POSTCHECK_FILE" ]; then
        log_message "Pre-check or post-check file is missing. Cannot compare."
        echo "Pre-check or post-check report is missing. Please run the checks first."
        return
    fi

    # Create temporary files to store filtered content
    local temp_pre="/tmp/precheck_filtered-$(date +%s).log"
    local temp_post="/tmp/postcheck_filtered-$(date +%s).log"

    # Filter out timestamps, uptime, and other dynamic content
    # This also removes the first few header lines
    grep -Ev 'Timestamp:|uptime|uname -a|automation_script-|result_comparison-|precheck_report-|postcheck_report-' "$PRECHECK_FILE" > "$temp_pre"
    grep -Ev 'Timestamp:|uptime|uname -a|automation_script-|result_comparison-|precheck_report-|postcheck_report-' "$POSTCHECK_FILE" > "$temp_post"

    echo "Differences between pre-check and post-check reports:" | tee -a "$LOG_FILE" "$Compare_output_file"
    echo "-----------------------------------------------------" | tee -a "$LOG_FILE" "$Compare_output_file"

    local diff_output
    diff_output=$(diff -u --label="Pre-Check" "$temp_pre" --label="Post-Check" "$temp_post")

    if [[ -z "$diff_output" ]]; then
        log_message "✅ No significant changes detected between pre-check and post-check reports (excluding uname -a, timestamps and uptime)."
        echo "✅ No significant changes detected." | tee -a "$LOG_FILE" "$Compare_output_file"
    else
        log_message "⚠️ Found changes between reports. See details below."
        
        # Parse and highlight changes from the unified diff output
        echo "$diff_output" | while read -r line; do
            if [[ "$line" =~ ^--- ]] || [[ "$line" =~ ^\+\+\+ ]] || [[ "$line" =~ ^@@ ]]; then
                # Skip diff header lines
                continue
            elif [[ "$line" =~ ^- ]]; then
                echo "❌ Removed line: ${line:1}" | tee -a "$LOG_FILE" "$Compare_output_file"
            elif [[ "$line" =~ ^\+ ]]; then
                echo "✅ Added line: ${line:1}" | tee -a "$LOG_FILE" "$Compare_output_file"
            else
                # Print context lines
                echo "$line" | tee -a "$LOG_FILE" "$Compare_output_file"
            fi
        done
    fi

    echo "-----------------------------------------------------" | tee -a "$LOG_FILE" "$Compare_output_file"
    log_message "--- Comparison complete. ---"
    echo "The comparison results have been saved to the main log file and compare_output_file."
    
    # Clean up temporary files
    rm -f "$temp_pre" "$temp_post"
}
# Function to get server list from user
get_server_list() {
    echo "Enter server hostnames (one per line). Press Ctrl+D when you're done:"
    # This reads all lines from standard input until EOF (Ctrl+D)
    SERVER_LIST=$(cat)
#	mapfile -t SERVER_LIST
    if [[ ${#SERVER_LIST[@]} -eq 0 ]]; then
 #   if [[ -z "$SERVER_LIST" ]]; then
        log_message "No servers entered."
    else
        log_message "Server list updated."
    fi
}


# Function to check server uptime
check_uptime() {
    log_message "--- Checking Connectivity of servers by checking Uptime ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi
    for server in $SERVER_LIST; do
        log_message "Checking uptime for $server..."
        ssh "$server" "uptime" 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -ne 0 ]]; then
            log_message "Error connecting to $server. Skipping."
        fi
    done
    log_message "--- Uptime check completed. ---"
}

# Function to check filesystem utilization
check_filesystem_utilization() {
    log_message "--- Checking Filesystem Utilization for Servers ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi
    for server in $SERVER_LIST; do
        log_message "Checking filesystem utilization for $server..."
        ssh "$server" "df -h" 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -ne 0 ]]; then
            log_message "Error connecting to $server. Skipping."
        fi
    done
    log_message "--- Filesystem utilization check complete. ---"
}

# --- NEW Function for a simple progress bar ---
show_progress() {
    local elapsed="$1"
    local total="$2"
    local width=40

    # Prevent division by zero
    (( total <= 0 )) && total=1
    (( elapsed < 0 )) && elapsed=0

    local percent=$(( elapsed * 100 / total ))
    (( percent > 100 )) && percent=100

    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))

    printf "\rProgress: ["
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%*s' "$empty" '' | tr ' ' '-'
    printf "] %3d%% (%d/%ds)" "$percent" "$elapsed" "$total"
}

reboot_handler() {

    # ---- Validation ----
    [[ -z "$SERVER_LIST" ]] && { log_error "SERVER_LIST is empty"; return 1; }
    [[ -z "$POLL_TIMEOUT" ]] && { log_error "POLL_TIMEOUT not set"; return 1; }
    [[ -z "$POLL_INTERVAL" ]] && { log_error "POLL_INTERVAL not set"; return 1; }

    # Convert SERVER_LIST to array safely
    read -r -a servers <<< "$SERVER_LIST"

    local overall_status=0

    for server in "${servers[@]}"; do
        log_info "Initiating reboot: $server"

        # Attempt reboot
        if ! safe_ssh "$server" "sudo reboot" &>/dev/null; then
            log_error "Failed to send reboot command to $server"
            overall_status=1
            continue
        fi

        local start
        start=$(date +%s)

        while true; do
            local now elapsed
            now=$(date +%s)
            elapsed=$(( now - start ))

            show_progress "$elapsed" "$POLL_TIMEOUT"

            if (( elapsed >= POLL_TIMEOUT )); then
                printf "\n"
                log_error "Timeout reached for $server after ${POLL_TIMEOUT}s"
                overall_status=1
                break
            fi

            # Check if SSH is back
            if safe_ssh "$server" "uptime" &>/dev/null; then
                printf "\n"
                log_info "✅ $server is back online"
                break
            fi

            sleep "$POLL_INTERVAL"
        done
    done

    return "$overall_status"
}
# Function to check the OS of a remote server via SSH
get_remote_os() {
    local server="$1"
    local os_info
    os_info=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "$server" '
        if [ -f /etc/redhat-release ]; then
            echo "RHEL"
        elif [ -f /etc/SuSE-release ] || grep -q "SUSE" /etc/os-release; then
            echo "SUSE"
        elif [ -f /etc/lsb-release ] || [ -f /etc/debian_version ]; then
            echo "UBUNTU"
        else
            echo "unknown"
        fi
    ' 2>/dev/null)
    echo "$os_info"
}

# Function to perform OS-specific patching
patch_servers() {

    if [[ ${#SERVER_LIST[@]} -eq 0 ]]; then
        log_error "Server list is empty."
        return 1
    fi

    local MAX_PARALLEL=15
    local PATCH_TIMEOUT=3600
    local REBOOT_TIMEOUT=600
    local REBOOT_INTERVAL=10

    log_info "Max Parallel Jobs: $MAX_PARALLEL"

    patch_single_server() {

        local server="$1"
        local os before_kernel after_kernel reboot_required=0
        local cmd

        log_info "----- $server : Starting -----"

        # Detect OS
        os=$(safe_ssh "$server" "awk -F= '/^ID=/{print \$2}' /etc/os-release 2>/dev/null | tr -d '\"'")

        if [[ -z "$os" ]]; then
            log_error "$server : Unable to detect OS."
            return 1
        fi

        before_kernel=$(safe_ssh "$server" "uname -r")

        case "$os" in
            rhel|rocky|centos|almalinux)
                cmd="sudo timeout ${PATCH_TIMEOUT}s bash -c 'dnf -y upgrade || yum -y update'"
                ;;
            ubuntu|debian)
                cmd="sudo timeout ${PATCH_TIMEOUT}s bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get upgrade -y'"
                ;;
            sles|suse)
                cmd="sudo timeout ${PATCH_TIMEOUT}s zypper --non-interactive update -y"
                ;;
            *)
                log_error "$server : Unsupported OS [$os]"
                return 1
                ;;
        esac

        log_info "$server : OS [$os] → Patching..."

        if ! safe_ssh "$server" "$cmd"; then
            log_error "$server : Patch failed"
            return 1
        fi

        # Detect new kernel
        case "$os" in
            rhel|rocky|centos|almalinux)
                after_kernel=$(safe_ssh "$server" "rpm -q --last kernel | head -1 | awk '{print \$1}' | sed 's/kernel-//'")
                ;;
            ubuntu|debian)
                after_kernel=$(safe_ssh "$server" "dpkg -l | grep linux-image | awk '{print \$2}' | sort -V | tail -1 | sed 's/linux-image-//'")
                ;;
            sles|suse)
                after_kernel=$(safe_ssh "$server" "rpm -q --last kernel-default | head -1 | awk '{print \$1}' | sed 's/kernel-default-//'")
                ;;
        esac

        if [[ "$before_kernel" != "$after_kernel" && -n "$after_kernel" ]]; then
            reboot_required=1
            log_info "$server : Kernel updated ($before_kernel → $after_kernel). Reboot required."
        else
            log_info "$server : No kernel change detected."
        fi

        if [[ $reboot_required -eq 1 ]]; then
            log_info "$server : Initiating reboot..."
            safe_ssh "$server" "sudo reboot" || return 1

            sleep 20
            local elapsed=0

            while ! safe_ssh "$server" "echo ok" >/dev/null 2>&1; do
                sleep "$REBOOT_INTERVAL"
                elapsed=$((elapsed + REBOOT_INTERVAL))

                if [[ $elapsed -ge $REBOOT_TIMEOUT ]]; then
                    log_error "$server : Reboot timeout exceeded."
                    return 1
                fi
            done

            log_info "$server : Back online."
        fi

        if safe_ssh "$server" "uptime && systemctl is-system-running"; then
            log_info "$server : ✅ Health check passed."
        else
            log_error "$server : ❌ Health check failed."
            return 1
        fi

        log_info "----- $server : Completed Successfully -----"
        return 0
    }

    # Ensure script is running in bash
    if [[ -z "$BASH_VERSION" ]]; then
        echo "This script must be run with bash."
        exit 1
    fi

    # Export required functions
    export -f patch_single_server safe_ssh log_info log_error

    printf "%s\n" "${SERVER_LIST[@]}" | \
        xargs -P "$MAX_PARALLEL" -I{} bash -c 'patch_single_server "$@"' _ {}

    if [[ $? -ne 0 ]]; then
        log_error "⚠ Some servers failed during patch cycle."
        return 1
    fi

    log_info "🎯 All patch cycles completed."
    return 0
}
# Function to check for available updates based on OS
check_updates_by_os() {
    log_message "--- Starting OS-aware Update Check for Servers ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi

    for server in $SERVER_LIST; do
        local remote_os
        # The existing get_remote_os function is used to determine the OS
        remote_os=$(get_remote_os "$server")
        local check_command

        log_message "Checking available updates on $server (OS: $remote_os)..."
        echo "Updates for $server (OS: $remote_os):"

        case "$remote_os" in
            RHEL|Rockylinux|Alma)
                # Check for RHEL/CentOS updates using yum or dnf
                check_command="sudo yum check-update -y || sudo dnf check-update -y"
                ;;
            SUSE)
                # Check for SUSE/SLES updates
                check_command="sudo zypper list-updates"
                ;;
            UBUNTU)
                # Refresh local package index, then list upgradable packages
                check_command="sudo apt update > /dev/null 2>&1 && apt list --upgradable"
                ;;
            *)
                log_message "Skipped $server: Unknown OS ($remote_os). Cannot check updates."
                echo "Skipped $server: Unknown OS ($remote_os). Cannot check updates." | tee -a "$LOG_FILE"
                continue
                ;;
        esac

        # Execute the check command
        echo "--- Running command: $check_command ---" | tee -a "$LOG_FILE"
        ssh "$server" "$check_command" 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -eq 0 ]]; then
            log_message "✅ Update check successful on $server."
        else
            log_message "⚠️ Note: Update check on $server returned a non-zero exit code. Check the detailed output above."
        fi
    done
    log_message "--- Update Check completed. ---"
}
# === NEW FUNCTION: Update Repositories by OS ===
update_repos_by_os() {
    log_message "--- Starting Repository Update (OS Auto-Detect) ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi

    for server in $SERVER_LIST; do
        local remote_os
        remote_os=$(get_remote_os "$server")
        local update_command

        case "$remote_os" in
            RHEL|Rocky|Alma)
                # Refresh repository metadata for RHEL/CentOS
                update_command="sudo yum clean all && sudo yum repolist"
                ;;
            SUSE)
                # Refresh repository metadata for SUSE/SLES
                update_command="sudo zypper refresh"
                ;;
            UBUNTU)
                # Refresh package list for Ubuntu/Debian
                update_command="sudo apt update"
                ;;
            *)
                log_message "Skipped $server: Unknown OS ($remote_os). Cannot update repositories."
                echo "Skipped $server: Unknown OS. Cannot update repositories."
                continue
                ;;
        esac

        log_message "Running '$remote_os' repo update on $server using command: $update_command"
        echo "=========================================="
        echo "Repo update for $server ($remote_os):"
        echo "=========================================="
        ssh "$server" "$update_command" 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -ne 0 ]]; then
            log_message "❌ Error: Repository update failed on $server."
            echo "❌ Repository update failed on $server. Check log file."
        else
            log_message "✅ Repository update successful on $server."
            echo "✅ Repository update successful on $server."
        fi
    done
    log_message "--- Repository Update completed. ---"
}
# Function to mount filesystems defined in /etc/fstab that are not mounted
mount_missing_filesystems() {
    log_message "--- Starting Mount Missing Filesystems (mount -a) ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi

    for server in $SERVER_LIST; do
        log_message "Attempting to mount all filesystems on $server defined in /etc/fstab..."
        echo "=========================================="
        echo "Mount missing filesystems on $server:"
        echo "=========================================="
        
        # The 'mount -a' command attempts to mount all filesystems listed in /etc/fstab
        # that are not already mounted (and are not explicitly excluded, e.g., by 'noauto').
        local mount_output
        mount_output=$(ssh "$server" "sudo mount -a" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            log_message "✅ Filesystem mounting successful on $server (mount -a returned 0)."
            echo "✅ Filesystem mounting successful on $server. Checking current mounts (df -h):" | tee -a "$LOG_FILE"
            ssh "$server" "df -h" 2>&1 | tee -a "$LOG_FILE"
        else
            log_message "⚠️ Note: mount -a failed on $server. Output: $mount_output"
            echo "❌ Filesystem mounting failed on $server. The server may still be usable, but check the fstab configuration." | tee -a "$LOG_FILE"
            echo "$mount_output" | tee -a "$LOG_FILE"
        fi
    done
    log_message "--- Mount Missing Filesystems completed. ---"
}

# Function to execute an arbitrary command on all listed servers
run_adhoc_command() {
    log_message "--- Starting Ad-hoc Command Execution ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi

    # Prompt the user for the command
    read -r -p "Enter the ad-hoc command to run on all servers (e.g., 'cat /proc/cpuinfo' or 'sudo systemctl status httpd'): " adhoc_command
    if [[ -z "$adhoc_command" ]]; then
        log_message "No command entered. Ad-hoc execution aborted."
        echo "No command entered. Ad-hoc execution aborted."
        return
    fi
    
    log_message "Executing ad-hoc command: '$adhoc_command' on all servers."
    echo "=========================================="
    echo "Running command: $adhoc_command"
    echo "=========================================="

    for server in $SERVER_LIST; do
        log_message "Executing on $server..."
		echo ""
        echo "--- Output from $server ---" | tee -a "$LOG_FILE"
        echo ""
        # Execute the command via SSH. Output is piped to the log file and the console.
        ssh "$server" "$adhoc_command" 2>&1 | tee -a "$LOG_FILE"
        
        if [[ $? -ne 0 ]]; then
            log_message "❌ Command execution failed on $server."
        else
            log_message "✅ Command execution successful on $server."
        fi
        echo "--------------------------" | tee -a "$LOG_FILE"
    done

    log_message "--- Ad-hoc Command Execution completed. ---"
}

# Function to check patching completion status by auto-detecting OS and checking relevant logs
check_patching_status() {
    log_message "--- Starting OS-aware Patching Status Check ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi

    for server in $SERVER_LIST; do
        local remote_os
        remote_os=$(get_remote_os "$server")
        local log_command=""
        local success_message=""
        local check_failed=false

        log_message "Checking patching status on $server (OS: $remote_os)..."
        echo "=========================================="
        echo "Patching Status for $server (OS: $remote_os):"
        echo "=========================================="

        case "$remote_os" in
            RHEL|Rocky|Alma)
                # Check for RHEL/CentOS logs (dnf and yum)
                log_command="sudo grep -iE 'completed|updated:|upgraded:' /var/log/dnf.log /var/log/yum.log | tail -n 5"
                success_message="SUCCESS: Found recent 'completed' or 'updated' messages in DNF/YUM logs."
                ;;
            SUSE)
                # Check for SUSE logs (zypper)
                log_command="sudo grep -iE 'installed|committed' /var/log/zypp/history | tail -n 5"
                success_message="SUCCESS: Found recent 'installed' or 'committed' messages in ZYPP history."
                ;;
            UBUNTU)
                # Check for Ubuntu logs (apt)
                log_command="sudo grep -iE 'Commandline: apt(-get)? (install|upgrade|dist-upgrade)|status installed' /var/log/apt/history.log | tail -n 5"
                success_message="SUCCESS: Found recent 'upgrade' commands or 'installed' status in APT history."
                ;;
            *)
                log_message "Skipped $server: Unknown OS ($remote_os). Cannot check logs."
                echo "Skipped $server: Unknown OS ($remote_os). Cannot check logs." | tee -a "$LOG_FILE"
                continue
                ;;
        esac

        # Execute the check command
        local log_output
        log_output=$(ssh "$server" "$log_command" 2>&1)
        local ssh_exit_code=$?
        
        # Check for success indicators
        if [[ "$ssh_exit_code" -eq 0 && -n "$log_output" ]]; then
            log_message "✅ $server: $success_message"
            echo "$log_output" | tee -a "$LOG_FILE"
        else
            log_message "❌ $server: FAILURE. Could not find recent patching success indicators or command failed."
            echo "❌ FAILURE: No clear patching completion confirmation found in logs on $server." | tee -a "$LOG_FILE"
            if [[ -n "$log_output" ]]; then
                 echo "Last 5 lines of related logs (even if command failed):" | tee -a "$LOG_FILE"
                 echo "$log_output" | tee -a "$LOG_FILE"
            fi
        fi
        echo "----------------------------------------"
    done
    log_message "--- Patching Status Check completed. ---"
}

# Main patching menu
patching_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Preparing Menu ....Please wait ✋...."
        echo "========================================="
        sleep 1
        clear
        echo "====================================================="
        echo "   Welcome to Server Patch Management Menu 😀..."
        echo "====================================================="
        echo "-----------------------------------------------------"
        echo "01.➡️ Enter Server List"
        echo "02.➡️ Enter CR Number"
        echo "03.➡️ Check Connectivity"
        echo "04.➡️ Check Filesystem Utilization"
        echo "05.➡️ Run Patching Pre-checks"
        echo "06.➡️ Update Repositories"
        echo "07.➡️ Check Updates"
        echo "08.➡️ Linux Patching"
        echo "09.➡️ Check yum logs"
        echo "10.➡️ Run Patching Post-checks"
        echo "11.➡️ Compare Patching Pre-checks and Post-checks"
        echo "12.➡️ Mount Missing Filesystems (Post-Reboot)"
        echo "13.➡️ Run Ad-hoc Command"
        echo "14.➡️ Reboot"
        echo "15.➡️ Exit"
        echo "-----------------------------------------------------"
        echo ""

        # Corrected check for Array length
        if [ ${#SERVER_LIST[@]} -gt 0 ]; then
            echo "Please validate the below provided servers: if not sure, Please use option 1"
            printf "%s\n" "${SERVER_LIST[@]}"
        else
            echo "🚨 WARNING 🚨: No servers found. Please use option 1."
        fi

        echo ""
        read -p "Enter your choice: " choice
        echo ""

        case $choice in
            1) get_server_list ;;
            2) prompt_for_change_request ;;
            3|4|5|6|7|8|9|10|11|12|13|14)
                if [[ -z "$CR_NUMBER" ]]; then
                    log_message "❌ ABORTED: Operation $choice requested, but CR Number is missing."
                    echo "🚨 MANDATORY: You must enter a Change Request (CR) number using Option 2 first."
                else
                    # Inner case to handle the actual commands
                    case $choice in
                        3) check_uptime ;;
                        4) check_filesystem_utilization ;;
                        5) 
                           run_checks "$PRECHECK_FILE" "Pre-Patching Checks" 
                           send_email "Patching Pre_Checks_completed" "yes" ;;
                        6) update_repos_by_os ;;
                        7) check_updates_by_os ;;
                        8) patch_servers ;;
                        9) check_patching_status ;;
                        10) 
                           run_checks "$POSTCHECK_FILE" "Post-Patching Checks" 
                           send_email "Patching Post_Checks_completed" "yes" ;;
                        11) 
                           compare_reports
                           send_email "Pre & Post Patching Comparison Report" "yes" ;;
                        12) mount_missing_filesystems ;;
                        13) run_adhoc_command ;;
                        14) reboot_handler ;;
                    esac
                fi
                ;;
            15) 
                log_message "Exiting script. Goodbye! 👋😀"
                exit 0 ;; 
            *) 
                echo "Oops Invalid option selected ❌. Please enter 1 to 15." ;;
        esac
        echo
        read -p "Press Enter to continue..."
    done
}
# ================= START SCRIPT =================
initialize

patching_menu



