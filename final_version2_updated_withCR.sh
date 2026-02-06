#!/bin/bash
# Description: A menu-driven automation for Linux server patching and cloud build operations.

# --- Global Variables ---
LOG_DIR="/tmp/automation/logs"
Compare_output_file=""
LOG_FILE=""
PRECHECK_FILE=""
POSTCHECK_FILE=""
SERVER_LIST="" # Initialize global server list variable
CR_NUMBER="" 
POLL_INTERVAL=10
POLL_TIMEOUT=800

# --- Function Definitions ---

# Function to initialize logging directories and files
initialize_logging() {
    # Define the desired permissions for the log directory
    local LOG_PERMISSIONS="777"
    
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
}

# --- Function Definitions ---

# Function to log messages with a timestamp and status
log_message() {
  local status="$1"
  local message="$2"
  # Add user info for auditing
#  echo "$(date +'%Y-%m-%d %H:%M:%S')-[$(whoami)]-[$input_cr]-$status-$message" | tee -a "$LOG_FILE"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')]-[$(whoami)]-[$input_cr]-$status-$message" | tee -a "$LOG_FILE"
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
        RHEL)
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
            RHEL)
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

#	# --- NEW: Automated OS Version and EOL Check (Post-Patching Audit) ---
#    if [[ "$action_name" == *"Post-Patching Checks"* ]]; then
#        log_message "--- Starting OS Version and EOL Check (Post-Patch Audit) ---"
#        # This function must be defined elsewhere and should iterate over SERVER_LIST/SERVER_ARRAY
#        check_os_version_and_eol 
#        log_message "--- Automated OS Version and EOL Check complete. ---"
#    fi
#    # --------------------------------------------------------------------

 #   log_message "--- $action_name complete. Results saved to $output_file ---"
 #   echo "The $action_name report has been saved to $output_file."
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
    if [[ -z "$SERVER_LIST" ]]; then
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
    local duration=$1
    local current_time=$2
    local total_time=$3

    # FIX: Check for total_time <= 0 to prevent division by zero and logical errors.
    if [[ "$total_time" -le 0 ]]; then
        # Print a simple message and return early to avoid the error.
        printf "\r[--------------------] 0%% Elapsed: %d/%d sec (Error: Invalid total time)" "$duration" "$total_time"
        return
    fi
    
    # Calculate percentage (using integer arithmetic)
    local percentage=$(( (current_time * 100) / total_time ))
    
    # Ensure percentage doesn't exceed 100 (in case of floating point inaccuracies or forcing 100%)
    if [[ "$percentage" -gt 100 ]]; then
        percentage=100
    fi
    
    # Calculate bar segments (20 characters total length)
    local bar_length=20
    local filled=$(( (percentage * bar_length) / 100 ))
    local empty=$(( bar_length - filled ))
    
    local bar=""
    
    # Construct the filled part (using '#' characters)
    bar=$(printf "%${filled}s" | tr ' ' '#')
    
    # Construct the empty part (using '-' characters)
    bar+=$(printf "%${empty}s" | tr ' ' '-')
    
    # Use '\r' (carriage return) to overwrite the current line for the animation effect
    printf "\r[%s] %3d%% Elapsed: %d/%d sec" "$bar" "$percentage" "$duration" "$total_time"
}

reboot_servers() {
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi
    log_message "--- Starting server reboot process ---"
    for server in $SERVER_LIST; do
        log_message "Rebooting server: $server"
        ssh "$server" "sudo reboot" 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -ne 0 ]]; then
            log_message "❌ Error: Could not initiate reboot on $server."
            continue # Move to the next server if reboot fails
        else
            log_message "✅ Reboot command sent to $server. Waiting for server to come back up..."
            
            local start_time=$(date +%s)
            local current_time
            local elapsed_time
            local timeout=$POLL_TIMEOUT
            
            while true; do
                current_time=$(date +%s)
                elapsed_time=$(( current_time - start_time ))
                
                # Update and display the progress bar
                show_progress "$elapsed_time" "$elapsed_time" "$timeout"
                
                if (( elapsed_time > timeout )); then
                    printf "\n"
                    log_message "❌ Timeout: Server $server did not respond after $timeout seconds. Skipping..."
                    break
                fi
                
                # Try to connect and run uptime
                if ssh "$server" "uptime" &>/dev/null; then
                    # Add this line to show 100% progress before breaking the loop
                    show_progress "$elapsed_time" "$elapsed_time" "$elapsed_time"
                    printf "\n" # Move to a new line after the progress bar
                    log_message "✅ Server $server is back online."
                    log_message "Uptime output for $server:"
                    ssh "$server" "uptime" | tee -a "$LOG_FILE"
                    break
                else
                    sleep "$POLL_INTERVAL"
                fi
            done
        fi
    done
    log_message "--- Server reboot process complete. ---"
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
    local patch_os="$1"
    local patch_command="$2"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi
	echo ""
	log_message "--- Checking OS EOL  ---"
    # Run EOL check and capture output (for warnings)
    check_os_version_and_eol 
	echo ""
    log_message "--- OS EOL Checks Done........Proceeding with patching... ---"
	echo ""
	echo ""
	echo "=========================================="
    echo "   Starting $patch_os patching   "
    echo "=========================================="
    #log_message "--- Starting $patch_os patching ---"
    for server in $SERVER_LIST; do
        local remote_os
        remote_os=$(get_remote_os "$server")
        if [[ "$remote_os" == "$patch_os" ]]; then
		echo ""
		    echo "==============================================="
            log_message "✅ Patching $remote_os server: $server"
			echo "==============================================="
			echo ""
            ssh "$server" "sudo $patch_command" 2>&1 | tee -a "$LOG_FILE"
            if [[ $? -ne 0 ]]; then
                log_message "Error or failure during patching on $server."
            fi
        else
            log_message "Skipped. You have selected $patch_os patching, but $server current OS is $remote_os. Please choose $remote_os server patching option."
        fi
    done
    log_message "--- $patch_os patching complete. ---"
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
            RHEL)
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
            RHEL)
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
            RHEL)
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

# Function to check for Azure Resource Group existence
check_rg_exists() {
    az group show --name "$1" &>/dev/null
}

# Function to check if a VNet and Subnet exist in Azure
check_vnet_subnet_exists() {
    local rg_name="$1"
    local vnet_name="$2"
    local subnet_name="$3"
    az network vnet subnet show --resource-group "$rg_name" --vnet-name "$vnet_name" --name "$subnet_name" &>/dev/null
}

# Function to check if an AWS VPC and Subnet exist
check_aws_vpc_subnet_exists() {
    local vpc_id="$1"
    local subnet_id="$2"
    aws ec2 describe-vpcs --vpc-ids "$vpc_id" &>/dev/null && aws ec2 describe-subnets --subnet-ids "$subnet_id" &>/dev/null
}

# Common function to handle cluster commands on a single server
run_cluster_command() {
    local server="$1"
    local command_name="$2"
    local command="$3"
    log_message "Running '$command_name' on $server..."
    ssh "$server" "sudo $command" 2>&1 | tee -a "$LOG_FILE"
    if [ $? -eq 0 ]; then
        log_message "Command '$command_name' executed successfully on $server."
    else
        log_message "Error executing '$command_name' on $server. Check logs for details."
    fi
}

# Cluster command menus
suse_cluster() {
    while true; do
        clear
        echo "======================================================="
        echo "   SUSE Cluster Menu"
        echo "======================================================="
        echo "---------------------------------------"
        echo " 1.➡️ Enter Server List"
		echo " 2.➡️ Enter CR Number"
        echo " 3.➡️ Check SUSE Cluster Status"
        echo " 4.➡️ Move SUSE Cluster resources"
        echo " 5.➡️ Perform Resource Cleanup"
        echo " 6.➡️ Clear Location Constraints"
        echo " 7.➡️ Return to Previous Menu"
		echo " 8.➡️ Return to Main Menu"
		echo " 9.➡️ Exit"
        echo "---------------------------------------"
        echo ""
		echo ""
        if [ -n "$SERVER_LIST" ]; then
            echo "Please validate the below provided servers: if not sure, Please use option 1."
            echo "$SERVER_LIST"
        else
            echo ""
            echo "🚨 WARNING 🚨: No servers found. Don't worry ...Please use option 1."
            echo ""
        fi
        echo ""
		echo ""
        read -p "Enter your choice: " choice
		echo ""
		echo ""
        case $choice in
        1) get_server_list ;;
		2) prompt_for_change_request ;;
         # --- CR NUMBER ENFORCEMENT STARTS HERE ---
            3|4|5|6)
            if [[ -z "$CR_NUMBER" ]]; then
                log_message "❌ ABORTED: Operation $choice requested, but CR Number is missing."
                echo "🚨 MANDATORY: You must enter a Change Request (CR) number using Option 2 before proceeding with any operation."
                # Do nothing, exit the case block, and prompt the user to continue.
                #continue
				else				
          #  fi 
            # If CR_NUMBER is set, proceed to the secondary case block for the actual operation
         case $choice in
        3) for server in $SERVER_LIST; do run_cluster_command "$server" "crm status" "crm status"; done ;;
        4)
            read -p "Enter the name of the resource to move: " resource_name
            read -p "Enter the destination node name: " node_name
            for server in $SERVER_LIST; do run_cluster_command "$server" "crm resource move" "crm resource move $resource_name $node_name"; done
            ;;
        5)
            read -p "Enter the name of the resource to cleanup: " resource_name
            for server in $SERVER_LIST; do run_cluster_command "$server" "crm resource cleanup" "crm resource cleanup $resource_name"; done
            ;;
        6)
            read -p "Enter the name of the resource to clear constraints: " resource_name
            for server in $SERVER_LIST; do run_cluster_command "$server" "crm resource clear" "crm resource clear $resource_name"; done
            ;;
		esac 
            fi
            ;;
        7) log_message "Going back to Previous Menu... please wait✋."
            return ;;
		8 ) log_message "Going back to Main Menu... please wait✋."
		    return 2 ;;
		9 ) log_message "Exiting script. Have a Great Day !!! Goodbye! 👋😀"
            exit 0 ;;
        *) echo "Oops Invalid option selected ❌. Please enter a number from 1 to 9." ;;
        esac
        echo
        read -p "Press Enter to continue..."
    done
}

rhel_cluster() {
    while true; do
        clear
        echo "========================================"
        echo " Preparing Menu ....Please wait ✋...."
        echo "========================================="
        sleep 2
        clear
        echo "======================================================="
        echo "   RHEL Cluster Menu"
        echo "======================================================="
        echo "---------------------------------------"
        echo " 1.➡️ Enter Server List"
		echo " 2.➡️ Enter CR Number"
        echo " 3.➡️ Check RHEL Cluster Status"
        echo " 4.➡️ Move RHEL Cluster resources"
        echo " 5.➡️ Perform Resource Cleanup"
        echo " 6.➡️ Clear Location Constraints"
        echo " 7.➡️ Return to Previous Menu"
		echo " 8.➡️ Return to Main Menu"
		echo " 9.➡️ Exit"
        echo "---------------------------------------"
		echo ""
		echo ""
        if [ -n "$SERVER_LIST" ]; then
            echo "Please validate the below provided servers: if not sure, Please use option 1."
            echo "$SERVER_LIST"
        else
            echo ""
            echo "🚨 WARNING 🚨: No servers found. Don't worry ...Please use option 1."
            echo ""
        fi
		echo ""
		echo ""
        read -p "Enter your choice: " choice
		echo ""
        case $choice in
        1) get_server_list ;;
		2) prompt_for_change_request ;;
         # --- CR NUMBER ENFORCEMENT STARTS HERE ---
            3|4|5|6)
            if [[ -z "$CR_NUMBER" ]]; then
                log_message "❌ ABORTED: Operation $choice requested, but CR Number is missing."
                echo "🚨 MANDATORY: You must enter a Change Request (CR) number using Option 2 before proceeding with any operation."
                # Do nothing, exit the case block, and prompt the user to continue.
                #continue
				else				
          #  fi 
            # If CR_NUMBER is set, proceed to the secondary case block for the actual operation
         case $choice in
        3) for server in $SERVER_LIST; do run_cluster_command "$server" "pcs status" "pcs status"; done ;;
        4)
            read -p "Enter the name of the resource to move: " resource_name
            read -p "Enter the destination node name: " node_name
            for server in $SERVER_LIST; do run_cluster_command "$server" "pcs resource move" "pcs resource move $resource_name $node_name"; done
            ;;
        5)
            read -p "Enter the name of the resource to cleanup: " resource_name
            for server in $SERVER_LIST; do run_cluster_command "$server" "pcs resource cleanup" "pcs resource cleanup $resource_name"; done
            ;;
        6)
            read -p "Enter the name of the resource to clear constraints: " resource_name
            for server in $SERVER_LIST; do run_cluster_command "$server" "pcs resource clear" "pcs resource clear $resource_name"; done
            ;;
		esac 
            fi
            ;;
        7)  log_message "Going back to Previous Menu... please wait✋."
            return ;;
		8 ) log_message "Going back to Main Menu... please wait✋."
		    return 2 ;;
		9 ) log_message "Exiting script. Have a Great Day !!! Goodbye! 👋😀"
            exit 0 ;;
        *) echo "Oops Invalid option selected ❌. Please enter a number from 1 to 9." ;;
        esac
        echo
        read -p "Press Enter to continue..."
    done
}

# Main patching menu
patching_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Preparing Menu ....Please wait ✋...."
        echo "========================================="
        sleep 2
        clear
        echo "====================================================="
        echo "   Welcome to Server Patch Management Menu 😀..."
        echo "====================================================="
        echo "-----------------------------------------------------"
        echo " 1.➡️ Enter Server List"
		echo " 2.➡️ Enter CR Number"
        echo " 3.➡️ Check Connectivity"
        echo " 4.➡️ Check Filesystem Utilization"
        echo " 5.➡️ Run Patching Pre-checks"
		echo " 6.➡️ Update Repositories"
		echo " 7.➡️ Check Updates"
        echo " 8.➡️ RHEL Patching"
        echo " 9.➡️ SUSE Patching"
        echo "10.➡️ Ubuntu Patching"
        echo "11.➡️ Check yum logs"
        echo "12.➡️ Run Patching Post-checks"
        echo "13.➡️ Compare Patching Pre-checks and Post-checks"
		echo "14.➡️ Mount Missing Filesystems (Post-Reboot)"
		echo "15.➡️ Run Ad-hoc Command"
        echo "16.➡️ Reboot"
        echo "17.➡️ Return to Previous Menu"
		echo "18.➡️ Return to Main Menu"
		echo "19.➡️ Exit"
        echo "-----------------------------------------------------"
		echo ""
		echo ""
         if [ -n "$SERVER_LIST" ]; then
            echo "Please validate the below provided servers: if not sure, Please use option 1."
            echo "$SERVER_LIST"
        else
            echo ""
            echo "🚨 WARNING 🚨: No servers found. Don't worry ...Please use option 1."
            echo ""
        fi
		echo ""
		echo ""
        read -p "Enter your choice: " choice
		echo ""
		echo ""
        case $choice in
         1) get_server_list ;;
		 2) prompt_for_change_request ;;
         # --- CR NUMBER ENFORCEMENT STARTS HERE ---
            3|4|5|6|7|8|9|10|11|12|13|14|15|16)
            if [[ -z "$CR_NUMBER" ]]; then
                log_message "❌ ABORTED: Operation $choice requested, but CR Number is missing."
                echo "🚨 MANDATORY: You must enter a Change Request (CR) number using Option 2 before proceeding with any operation."
                # Do nothing, exit the case block, and prompt the user to continue.
                #continue
				else				
          #  fi 
            # If CR_NUMBER is set, proceed to the secondary case block for the actual operation
         case $choice in
         3) check_uptime ;;
         4) check_filesystem_utilization ;;
         5) run_checks "$PRECHECK_FILE" "Pre-Patching Checks" ;;
		 6) update_repos_by_os ;;
         7) check_updates_by_os ;;
         8) patch_servers "RHEL" "yum update -y" ;;
         9) patch_servers "SUSE" "zypper update -y" ;;
        10) patch_servers "UBUNTU" "apt update -y && apt upgrade -y" ;;
        11) check_patching_status ;;
        12) run_checks "$POSTCHECK_FILE" "Post-Patching Checks" ;;
        13) compare_reports ;;
		14) mount_missing_filesystems ;;
		15) run_adhoc_command ;;
        16) reboot_servers ;;
		esac 
            fi
            ;;
         
        17)
            log_message "Going back to Previous Menu... please wait✋."
            return ;;
		18) log_message "Going back to Main Menu... please wait✋."
		    return 1 ;;
		19) log_message "Exiting script. Have a Great Day !!! Goodbye! 👋😀"
           exit 0 ;; 
        *) echo "Oops Invalid option selected ❌. Please enter a number from 1 to 19." ;;
        esac
        echo
       read -p "Press Enter to continue..."
	 #  read -p "Enter your Selection if you want to perform more operations: " choice
    done
}
# Function to get user input with a default value
get_input_with_default() {
    local prompt="$1"
    local default_value="$2"
    read -p "$prompt [$default_value]: " user_input
	if [[ -z "$user_input" ]]; then
        echo "$default_value"
    else
        echo "$user_input"
    fi
    
}

#function to check if vm is actually created or not
wait_for_vm() {
    local vm_name=$1
    local rg_name=$2
    local start_time=$(date +%s)
    local provisioning_state=""
    local elapsed_time
    local timeout=$POLL_TIMEOUT

    log_message "Waiting for VM '$vm_name' to be created..."

    while [[ "$provisioning_state" != "Succeeded" ]]; do
        elapsed_time=$(( $(date +%s) - start_time ))
        
        # FIX for "Invalid total time" error:
        # Assuming show_progress takes (current_value, max_value)
        # Use elapsed_time as current progress, and timeout as max duration.
        # This will show the progress towards the timeout limit.
        show_progress "$elapsed_time" "$timeout" 

        if (( elapsed_time > timeout )); then
            printf "\n"
            log_message "❌ Timed out waiting for VM creation (Max time: ${timeout}s). Check the Azure portal for status."
            return 1
        fi

        provisioning_state=$(az vm show \
            --resource-group "$rg_name" \
            --name "$vm_name" \
            --query "provisioningState" \
            --output tsv 2>/dev/null)

        if [[ -z "$provisioning_state" ]]; then
            sleep "$POLL_INTERVAL"
        elif [[ "$provisioning_state" == "Failed" ]]; then
            printf "\n"
            log_message "❌ VM creation failed. Check logs for details."
            return 1
        elif [[ "$provisioning_state" == "Succeeded" ]]; then
            local final_time=$(( $(date +%s) - start_time ))
            
            # Show final 100% status with actual time taken
            # Pass the final time as the 'current' value to ensure 100% calculation
            # and that the progress bar displays the final elapsed time.
            show_progress "$final_time" "$final_time" # Forces 100% progress for visual clarity

            printf "\n"
            log_message "✅ VM '$vm_name' provisioned successfully."
            # Display the time taken
            log_message "⏰ Time taken for VM build: ${final_time} seconds." 
            return 0
        else
            sleep "$POLL_INTERVAL"
        fi
    done
}
# Function to install Azure CLI based on OS
install_az_cli() {
    local os_id os_version_id
    log_message "--- Attempting to detect OS for Azure CLI installation... ---"
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        os_id=$ID
        os_version_id=$VERSION_ID
    else
        log_message "❌ Unable to determine OS. Please install Azure CLI manually."
        return 1
    fi
    
    log_message "Detected OS: $os_id $os_version_id"
    
    case "$os_id" in
        rhel|centos|fedora)
            log_message "Installing Azure CLI for RHEL/CentOS..."
            sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>&1 | tee -a "$LOG_FILE"
            sudo sh -c 'echo -e "[azure-cli]\nname=Azure CLI\nbaseurl=https://packages.microsoft.com/yumrepos/azure-cli\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo' 2>&1 | tee -a "$LOG_FILE"
            sudo yum install -y azure-cli 2>&1 | tee -a "$LOG_FILE"
            ;;
        sles|opensuse)
            log_message "Installing Azure CLI for SUSE/openSUSE..."
            sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>&1 | tee -a "$LOG_FILE"
            sudo sh -c 'echo -e "[azure-cli]\nname=Azure CLI\nbaseurl=https://packages.microsoft.com/yumrepos/azure-cli\nenabled=1\nautorefresh=1\nkeeppackages=0\ntype=rpm-md\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/zypp/repos.d/azure-cli.repo' 2>&1 | tee -a "$LOG_FILE"
            sudo zypper install -y azure-cli 2>&1 | tee -a "$LOG_FILE"
            ;;
        ubuntu|debian)
            log_message "Installing Azure CLI for Ubuntu/Debian..."
            sudo apt-get update 2>&1 | tee -a "$LOG_FILE"
            sudo apt-get install ca-certificates curl apt-transport-https lsb-release gnupg -y 2>&1 | tee -a "$LOG_FILE"
            sudo curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null 2>&1 | tee -a "$LOG_FILE"
            AZ_REPO=$(lsb_release -cs)
            echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | sudo tee /etc/apt/sources.list.d/azure-cli.list 2>&1 | tee -a "$LOG_FILE"
            sudo apt-get update 2>&1 | tee -a "$LOG_FILE"
            sudo apt-get install azure-cli -y 2>&1 | tee -a "$LOG_FILE"
            ;;
        *)
            log_message "❌ Unsupported OS: $os_id. Please install Azure CLI manually by following the instructions at https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
            return 1
            ;;
    esac
    
    if command -v az &>/dev/null; then
        log_message "✅ Azure CLI installed successfully."
        return 0
    else
        log_message "❌ Azure CLI installation failed."
        return 1
    fi
}


# --- Main Azure VM Build Function (Revised) ---
azure_vm_build() {
    log_message "--- Starting Azure VM creation ---"

    # Assume log_message, install_az_cli, get_input_with_default, and wait_for_vm exist
    # Add a log file definition for clarity if not globally defined
    # LOG_FILE="vm_build.log"

    # Check for Azure CLI
    if ! command -v az &>/dev/null; then
        read -p "❌ Azure CLI ('az') not found. Do you want to install it? (y/n): " install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            if ! install_az_cli; then
                log_message "Azure CLI is required. Please install it manually to proceed."
                return 1
            fi
        else
            log_message "Azure CLI is required to proceed. Please install it and try again."
            return 1
        fi
    else
        log_message "✅ Azure CLI is already installed."
    fi

    # Check for login status
    if ! az account show &>/dev/null; then
        log_message "❌ You are not logged in to Azure. Please log in with 'az login'."
        read -p "Press Enter to open the login page in your browser..."
        az login 2>&1 | tee -a "$LOG_FILE"
        # Re-check login
        if ! az account show &>/dev/null; then
            log_message "❌ Azure login failed. Please ensure you have authenticated successfully."
            return 1
        fi
    else
        log_message "✅ Found an active Azure login session."
        local subscription_name
        subscription_name=$(az account show --query name -o tsv)
        log_message "Active subscription: $subscription_name"

    fi

    local rg_name location vm_name vm_size vm_os vnet_rg_name vnet_name subnet_name admin_user admin_pass os_disk_size os_disk_type zone_choice zone_id
    echo "========================================"
    echo "         VM Build Configuration"
    echo "========================================"

    # Resource Group Selection and Creation
    while true; do
        echo "Please choose a Resource Group option:"
        echo "(1) Use an existing Resource Group"
        echo "(2) Create a new Resource Group"
        read -p "Enter your selection: " rg_choice

        if [[ "$rg_choice" == "1" ]]; then
            read -p "Enter the name of the existing Resource Group: " rg_name
            if az group show --name "$rg_name" &>/dev/null; then
                location=$(az group show --name "$rg_name" --query location -o tsv)
                log_message "✅ Using existing Resource Group: $rg_name in location $location"
                break
            else
                log_message "❌ Error: Resource Group '$rg_name' not found. Please try again."
            fi
        elif [[ "$rg_choice" == "2" ]]; then
            read -p "Enter a name for the new Resource Group: " rg_name
            read -p "Enter the location (e.g., eastus): " location
            log_message "Creating Resource Group '$rg_name' in location '$location'..."
            if az group create --name "$rg_name" --location "$location" --output none 2>&1 | tee -a "$LOG_FILE"; then
                log_message "✅ Resource Group '$rg_name' created successfully."
                break
            else
                log_message "❌ Failed to create Resource Group '$rg_name'. Check the log for details."
            fi
        else
            log_message "❗ Invalid choice. Please enter '1' or '2'."
        fi
    done

    # --- VM Core Configuration ---
    echo "========================================="
    echo "          VM Core Settings"
    echo "========================================="
    read -p "Enter the desired VM name: " vm_name
    read -p "Enter the desired VM size (e.g., Standard_B2s,Standard_D2s_v3): " vm_size

    # OS Image Selection and Validation
    while true; do
        read -p "Enter the desired OS image (e.g., Ubuntu2204, Win2022Datacenter,RedHat:RHEL:94_gen2:latest): " vm_os
        if az vm image show --location "$location" --alias "$vm_os" &>/dev/null || az vm image show --location "$location" --urn "$vm_os" &>/dev/null; then
            log_message "✅ OS image '$vm_os' found."
            break
        else
            log_message "❌ Error: OS image '$vm_os' not found or is invalid for this location."
            read -p "Do you want to search for available images? (y/n): " search_choice
            if [[ "$search_choice" =~ ^[Yy]$ ]]; then
                read -p "Enter a search term (e.g., Ubuntu, RHEL, Windows): " search_term
                log_message "Searching for images with '$search_term' in location '$location'..."
                az vm image list --location "$location" --all --query "[?contains(urn, '$search_term')].urn" -o table | head -n 10
                log_message "------------------------------------------"
            fi
        fi
    done

    # --- OS Disk Configuration ---
    echo "========================================="
    echo "        OS Disk Configuration"
    echo "========================================="
    # FIX #1: Define os_disk_name for use in the VM creation command
    local os_disk_name="${vm_name}-os-disk" # Simplified name; date is too long for Azure resources
    read -p "Enter the desired OS disk size in GB (e.g., 64): " os_disk_size
    while true; do
        read -p "Enter the OS disk type (Standard_LRS, Premium_LRS, StandardSSD_LRS): " os_disk_type
        case "$os_disk_type" in
            Standard_LRS|Premium_LRS|StandardSSD_LRS)
                log_message "✅ Using disk type: $os_disk_type"
                break
                ;;
            *)
                log_message "❌ Invalid disk type. Please choose from: Standard_LRS, Premium_LRS, StandardSSD_LRS."
                ;;
        esac
    done

    # --- Availability Zone Validation and Configuration ---
    echo "========================================="
    echo "    Availability Zone Configuration "
    echo "========================================="
    # FIX #2: zone_param will now be an array
    local zone_params=()
    local location_has_zones=false
    local zone_selected=false # Flag to track if a zone was selected
    zone_id="N/A" # Default for summary

    # Check if the chosen location supports zones
    if az account list-locations --query "[?name=='$location'].metadata.capabilities[?name=='Zone'].name" --output tsv | grep -q "Zone"; then
        location_has_zones=true
    fi

    if [[ "$location_has_zones" == true ]]; then
        log_message "✅ The location '$location' supports Availability Zones."
        read -p "Do you want to create the VM in an Availability Zone? (y/n): " zone_choice
        if [[ "$zone_choice" =~ ^[Yy]$ ]]; then
            read -p "Enter the desired zone ID (e.g., 1, 2, or 3): " zone_id
            # Correctly append the parameters as separate array elements
            zone_params+=( "--zone" "$zone_id" )
            zone_selected=true
        fi
    else
        log_message "❌ The location '$location' does NOT support Availability Zones."
        read -p "Do you want to proceed without an Availability Zone? (y/n): " proceed_choice
        if [[ ! "$proceed_choice" =~ ^[Yy]$ ]]; then
            log_message "Aborting VM creation to select a different location."
            read -p "Press Enter to return to the main menu..."
            return 1
        fi
        log_message "Continuing without an Availability Zone."
    fi
    
    # --- Networking Configuration ---
    echo "========================================="
    echo "         Networking Settings "
    echo "========================================="
    local nic_name="${vm_name}-nic"
    local public_ip_params=()
    local private_ip_params=()
    local public_ip_status="No"
    local private_ip_status="No"

    # VNet/Subnet choice
    local vnet_rg_name=$rg_name # Assume VNet is in the same RG for simplicity, as per original script
    while true; do
        echo "Please choose a VNet option:"
        echo "(1) Use an existing VNet and Subnet"
        echo "(2) Create a new VNet and Subnet"
        read -p "Enter your selection: " vnet_choice
        
        if [[ "$vnet_choice" == "1" ]]; then
            # Use existing VNet logic
            read -p "Enter the name of the existing Virtual Network (VNet): " vnet_name
            read -p "Enter the name of the existing Subnet: " subnet_name
            if az network vnet subnet show --resource-group "$vnet_rg_name" --vnet-name "$vnet_name" --name "$subnet_name" &>/dev/null; then
                log_message "✅ Found VNet/Subnet: $vnet_name/$subnet_name"
                break
            else
                log_message "❌ Error: VNet/Subnet '$vnet_name/$subnet_name' not found."
                log_message "Please ensure the names are correct and the VNet is in the specified Resource Group."
            fi
        elif [[ "$vnet_choice" == "2" ]]; then
            # Create new VNet logic
            read -p "Enter a name for the new VNet: " vnet_name
            read -p "Enter a name for the new Subnet: " subnet_name
            read -p "Enter a VNet address prefix (e.g., 10.0.0.0/16): " vnet_prefix
            read -p "Enter a Subnet address prefix (e.g., 10.0.1.0/24): " subnet_prefix

            log_message "Creating new VNet '$vnet_name' and Subnet '$subnet_name'..."
            if az network vnet create \
                --resource-group "$vnet_rg_name" \
                --name "$vnet_name" \
                --location "$location" \
                --address-prefix "$vnet_prefix" \
                --subnet-name "$subnet_name" \
                --subnet-prefix "$subnet_prefix" 2>&1 | tee -a "$LOG_FILE"; then
                log_message "✅ New VNet '$vnet_name' and Subnet '$subnet_name' created successfully."
                break
            else
                log_message "❌ Failed to create VNet/Subnet. Check the log for details."
            fi
        else
            log_message "❗ Invalid choice. Please enter '1' or '2'."
        fi
    done

    # IP configuration
    # FIX #3: Correctly configure Public IP parameters for array execution
    if [[ "$(get_input_with_default "Do you want a Public IP? (yes/no)" "yes")" =~ ^[yY] ]]; then
        public_ip_params+=( "--public-ip-address" "${vm_name}-pip" )
        public_ip_params+=( "--public-ip-sku" "standard" ) # Explicitly setting SKU is necessary for standard IPs
        public_ip_status="Yes"
    else
        public_ip_params+=( "--no-public-ip" )
    fi
    # Private IP configuration
    if [[ "$(get_input_with_default "Do you want a Private IP? (yes/no)" "yes")" =~ ^[yY] ]]; then
        # The value is empty string, which means 'allocate automatically from subnet'
        private_ip_params+=( "--private-ip-address" "" ) 
        private_ip_status="Yes"
    fi

    # --- Administrator Credentials ---
    echo "========================================="
    echo "       Administrator Credentials"
    echo "========================================="
    read -p "Enter a new admin username: " admin_user
    read -s -p "Enter a secure admin password: " admin_pass
    echo

    # --- VM Creation Command and Summary ---
    local vm_create_args=(
        "vm" "create"
        "--resource-group" "$rg_name"
        "--name" "$vm_name"
        "--image" "$vm_os"
        "--size" "$vm_size"
        "--os-disk-name" "$os_disk_name" # FIX #1: Added OS disk name
        "--os-disk-size-gb" "$os_disk_size"
        "--storage-sku" "$os_disk_type"
        "--vnet-name" "$vnet_name"
        "--subnet" "$subnet_name"
        "--admin-username" "$admin_user"
        "--admin-password" "$admin_pass"
        "--output" "table"
    )

    # Append optional parameters
    vm_create_args+=( "${public_ip_params[@]}" ) # FIX #3: Array expansion for public IP
    vm_create_args+=( "${private_ip_params[@]}" )
    vm_create_args+=( "${zone_params[@]}" ) # FIX #2: Array expansion for zone

    echo "========================================="
    log_message "--- Summary of VM Configuration ---"
    log_message "Resource Group: $rg_name"
    log_message "VM Name: $vm_name"
    log_message "VM Size: $vm_size"
    log_message "OS Image: $vm_os"
    log_message "OS Disk Name: $os_disk_name"
    log_message "OS Disk Size: $os_disk_size GB"
    log_message "OS Disk Type: $os_disk_type"
    log_message "Availability Zone: $(if [[ "$zone_selected" == true ]]; then echo "$zone_id"; else echo "Not specified"; fi)" # Corrected summary output
    log_message "VNet: $vnet_name"
    log_message "Subnet: $subnet_name"
    log_message "Public IP: $public_ip_status"
    log_message "Private IP: $private_ip_status"
    log_message "-----------------------------------"
    echo "========================================="
    echo ""

    read -p "Press Enter to start VM creation..."
    log_message "Creating VM... this may take a few minutes."

    # Execute the command and log output
    if ! az "${vm_create_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "❌ Initial VM creation command failed. Check log for details."
        return 1
    fi

    # Wait for the VM to be created and provisioned
    if ! wait_for_vm "$vm_name" "$rg_name"; then
        return 1
    fi

    # Final success message and VM details
    log_message "✅ VM '$vm_name' is fully created and running."
    log_message "Retrieving VM details..."
    az vm show --resource-group "$rg_name" --name "$vm_name" --show-details --output table 2>&1 | tee -a "$LOG_FILE"

    log_message "VM build process completed successfully."
   # read -p "Press Enter to return to the menu..."

    # Clear the error trap upon successful completion
    trap - ERR

}

handle_error() {
    local error_msg="$1"
    log_message "❌ ERROR: $error_msg"
    read -p "Press Enter to return to the main menu..."
    return 1
}

azure_vm_snapshot() {
    log_message "--- Starting Azure VM snapshot creation ---"

    # Check for Azure CLI and login status
    if ! command -v az &>/dev/null; then
        log_message "❌ Azure CLI ('az') not found. Please install it to use this feature."
        return 1
    fi
    if ! az account show &>/dev/null; then
        log_message "❌ You are not logged in to Azure. Please log in with 'az login'."
        read -p "Press Enter to open the login page in your browser..."
        az login 2>&1 | tee -a "$LOG_FILE"
        if ! az account show &>/dev/null; then
            log_message "❌ Azure login failed. Please ensure you have authenticated successfully."
            return 1
        fi
    fi

    local rg_name vm_name base_snapshot_name
    
    # Get user input for VM details
    read -p "Enter the Resource Group name of the VM: " rg_name
    read -p "Enter the VM name to snapshot: " vm_name

    # Check if VM and RG exist
    if ! az vm show --resource-group "$rg_name" --name "$vm_name" &>/dev/null; then
        log_message "❌ Error: VM '$vm_name' in Resource Group '$rg_name' not found. Please check the names and try again."
        return 1
    fi

    # Generate a default base snapshot name
    base_snapshot_name="${vm_name}-snapshot-$(date +%Y%m%d%H%M%S)"
    read -p "Enter a base name for the snapshots (default: $base_snapshot_name): " user_base_snapshot_name
    if [[ -n "$user_base_snapshot_name" ]]; then
        base_snapshot_name="$user_base_snapshot_name"
    fi

    local os_disk_id os_disk_name snapshot_name
    local data_disks_found=0

    # Retrieve OS disk information
    log_message "Retrieving disk IDs for VM '$vm_name'..."
    os_disk_info=$(az vm show \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --query "{osDiskId: storageProfile.osDisk.managedDisk.id, osDiskName: storageProfile.osDisk.name}" \
        --output json)

     os_disk_id=$(az vm show --resource-group "$rg_name" --name "$vm_name" --query "storageProfile.osDisk.managedDisk.id" -o tsv)
    os_disk_name=$(az vm show --resource-group "$rg_name" --name "$vm_name" --query "storageProfile.osDisk.name" -o tsv)
  # os_disk_id=$(echo "$os_disk_info" | jq -r '.osDiskId')
  #  os_disk_name=$(echo "$os_disk_info" | jq -r '.osDiskName')

    if [[ -z "$os_disk_id" ]]; then
        log_message "❌ Error: Could not retrieve OS disk ID for VM '$vm_name'."
        return 1
    fi

    # Create snapshot of the OS disk
    snapshot_name="${base_snapshot_name}-os"
    log_message "Creating snapshot '$snapshot_name' for OS disk '$os_disk_name'..."
    if az snapshot create \
        --resource-group "$rg_name" \
        --name "$snapshot_name" \
        --source "$os_disk_id" \
        --output none 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✅ Snapshot for OS disk completed successfully: $snapshot_name"
    else
        log_message "❌ Snapshot for OS disk failed. Aborting."
       # read -p "Press Enter to return to the menu..."
        return 1
    fi

    # Retrieve and snapshot all data disks
    data_disk_ids=$(az vm show \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --query "storageProfile.dataDisks[].managedDisk.id" \
        --output tsv)

    if [[ -n "$data_disk_ids" ]]; then
        data_disks_found=1
        log_message "Taking snapshots of data disks now..."
        for disk_id in $data_disk_ids; do
            disk_name=$(az disk show --ids "$disk_id" --query "name" -o tsv)
            disk_lun=$(az vm show \
                --resource-group "$rg_name" \
                --name "$vm_name" \
                --query "storageProfile.dataDisks[?managedDisk.id=='$disk_id'].lun" \
                --output tsv)

            snapshot_name="${base_snapshot_name}-datadisk-${disk_lun}"
            log_message "Creating snapshot '$snapshot_name' for data disk '$disk_name' (LUN: $disk_lun)..."
            if az snapshot create \
                --resource-group "$rg_name" \
                --name "$snapshot_name" \
                --source "$disk_id" \
                --output none 2>&1 | tee -a "$LOG_FILE"; then
                log_message "✅ Snapshot for data disk '$disk_name' completed successfully: $snapshot_name"
            else
                log_message "❌ Snapshot for data disk '$disk_name' failed. Check logs."
            fi
        done
    else
        log_message "✅ No data disks attached to VM '$vm_name'."
    fi

    # Final success message
    log_message "--- Snapshot process completed successfully ---"
    log_message "All snapshots for VM '$vm_name' created with base name '$base_snapshot_name'."
  #  read -p "Press Enter to return to the menu..."
}

## New function for Azure VM Deletion
azure_vm_delete() {
    log_message "--- Starting Azure VM deletion ---"

    if ! command -v az &>/dev/null; then
        log_message "❌ Azure CLI ('az') not found. Please install it to use this feature."
        return 1
    fi
    if ! az account show &>/dev/null; then
        log_message "❌ You are not logged in to Azure. Please log in with 'az login'."
        return 1
    fi

    local rg_name vm_name
    read -p "Enter the Resource Group of the VM to delete: " rg_name
    read -p "Enter the VM name to delete: " vm_name

    # Check if VM and RG exist
    if ! az vm show --resource-group "$rg_name" --name "$vm_name" &>/dev/null; then
        log_message "❌ Error: VM '$vm_name' in Resource Group '$rg_name' not found."
        return 1
    fi

    read -p "Are you sure you want to delete VM '$vm_name' and its associated resources (NIC, public IP, etc.)? This action is irreversible. (y/n): " confirm_delete
    if [[ ! "$confirm_delete" =~ ^[Yy]$ ]]; then
        log_message "VM deletion aborted by user."
        echo "VM deletion aborted."
        return
    fi

    log_message "Deleting VM '$vm_name' and associated resources..."
    if az vm delete --resource-group "$rg_name" --name "$vm_name" --yes 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✅ VM '$vm_name' deleted successfully."
        echo "VM '$vm_name' deleted successfully."
    else
        log_message "❌ Error deleting VM '$vm_name'. Check logs for details."
        echo "Error deleting VM '$vm_name'. Check the log file for errors."
    fi
   # read -p "Press Enter to return to the menu..."
}

## New function for Azure Snapshot Deletion
azure_snapshot_delete() {
    log_message "--- Starting Azure snapshot deletion ---"

    if ! command -v az &>/dev/null; then
        log_message "❌ Azure CLI ('az') not found. Please install it to use this feature."
        return 1
    fi
    if ! az account show &>/dev/null; then
        log_message "❌ You are not logged in to Azure. Please log in with 'az login'."
        return 1
    fi

    local rg_name snapshot_name
    read -p "Enter the Resource Group of the snapshot: " rg_name
    read -p "Enter the name of the snapshot to delete: " snapshot_name

    if ! az snapshot show --resource-group "$rg_name" --name "$snapshot_name" &>/dev/null; then
        log_message "❌ Error: Snapshot '$snapshot_name' in Resource Group '$rg_name' not found."
        return 1
    fi

    read -p "Are you sure you want to delete snapshot '$snapshot_name'? This action is irreversible. (y/n): " confirm_delete
    if [[ ! "$confirm_delete" =~ ^[Yy]$ ]]; then
        log_message "Snapshot deletion aborted by user."
        echo "Snapshot deletion aborted."
        return
    fi

    log_message "Deleting snapshot '$snapshot_name'..."
    if az snapshot delete --resource-group "$rg_name" --name "$snapshot_name" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✅ Snapshot '$snapshot_name' deleted successfully."
        echo "Snapshot '$snapshot_name' deleted successfully."
    else
        log_message "❌ Error deleting snapshot '$snapshot_name'. Check logs for details."
        echo "Error deleting snapshot '$snapshot_name'. Check the log file for errors."
    fi
   # read -p "Press Enter to return to the menu..."
}
# NOTE: This function needs access to the AWS CLI to work correctly.
check_aws_vpc_subnet_exists() {
    local vpc_id="$1"
    local subnet_id="$2"
    
    # Check if VPC exists
    local vpc_check
    vpc_check=$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
    if [[ "$vpc_check" != "$vpc_id" ]]; then
        return 1
    fi

    # Check if Subnet exists within the VPC
    local subnet_check
    subnet_check=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" --query 'Subnets[0].[SubnetId, VpcId]' --output text 2>/dev/null)
    if [[ "$subnet_check" != "$subnet_id"* || ! "$subnet_check" =~ "$vpc_id" ]]; then
        return 1
    fi
    
    return 0
}

# --- AWS CLI Setup and Check Functions ---

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "Linux";;
        Darwin*) echo "macOS";;
        CYGWIN*|MINGW32*|MSYS*) echo "Windows";;
        *)       echo "UNKNOWN"
    esac
}

install_aws_cli() {
    local os_type
    os_type=$(detect_os)
    
    read -r -p "The AWS CLI is not installed. Do you want to install it now? (y/n): " install_choice
    
    if [[ "$install_choice" =~ ^[Yy]$ ]]; then
        log_message "Attempting to install AWS CLI on $os_type."
        echo "Starting AWS CLI installation..."
        
        case "$os_type" in
            Linux|macOS)
                echo "Installing on $os_type using the bundled installer..."
                # Use /tmp for download and extraction
                curl "https://awscli.amazonaws.com/awscli-exe-$(uname -s | tr '[:upper:]' '[:lower:]')/awscli.zip" -o "/tmp/awscliv2.zip"
                if [[ $? -ne 0 ]]; then
                    echo "❌ Failed to download AWS CLI. Check your internet connection."
                    return 1
                fi
                
                unzip -q /tmp/awscliv2.zip -d /tmp
                /tmp/aws/install
                
                if [[ $? -eq 0 ]]; then
                    echo "✅ AWS CLI installed successfully."
                    rm -rf /tmp/awscliv2.zip /tmp/aws
                    return 0
                else
                    echo "❌ AWS CLI installation failed. Please check official AWS documentation for your specific setup."
                    return 1
                fi
                ;;
            Windows)
                echo "Please download the MSI installer from the AWS website and run it."
                echo "URL: https://awscli.amazonaws.com/AWSCLIV2.msi"
                return 1
                ;;
            *)
                echo "Could not detect OS. Please install the AWS CLI manually."
                return 1
                ;;
        esac
    else
        echo "Installation skipped. Aborting VM build."
        return 1
    fi
}

check_aws_login() {
    local identity
    # Try to get the user ARN/identity
    identity=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
    local exit_code=$?

    if [[ $exit_code -eq 0 && -n "$identity" && "$identity" != "None" ]]; then
        echo "✅ Active AWS session found."
        echo "   Identity: $identity"
        log_message "Active AWS session found: $identity"
        return 0 # Logged in
    else
        echo "⚠️ No active AWS session found. Initiating login process..."
        log_message "No active AWS session. Starting configuration."
        
        read -r -p "Do you use AWS IAM Identity Center (SSO)? (y/n): " use_sso
        if [[ "$use_sso" =~ ^[Yy]$ ]]; then
            echo "Running 'aws sso login' (requires SSO configuration in your AWS CLI profiles)..."
            aws sso login
        else
            echo "Running 'aws configure' (standard Access Key/Secret Key setup)..."
            aws configure
        fi

        # Re-check login after configuration attempt
        identity=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
        if [[ $? -eq 0 && -n "$identity" && "$identity" != "None" ]]; then
            echo "✅ Login successful! Identity: $identity"
            return 0
        else
            echo "❌ AWS login failed or was cancelled. Please check your credentials or SSO setup."
            return 1
        fi
    fi
}


# --- Main VM Creation Function ---

aws_vm_build() {
    log_message "--- Starting AWS VM creation (Single Instance) ---"
    
    # 1. Check AWS CLI installation
    if ! command -v aws &>/dev/null; then
        if ! install_aws_cli; then
            echo "AWS CLI setup failed. Cannot proceed."
            return 1
        fi
    else
        echo "✅ AWS CLI is already installed."
    fi

    # 2. Check and establish AWS Login Session
    if ! check_aws_login; then
        echo "AWS login failed. Cannot proceed with VM creation."
        return 1
    fi

    echo "========================================"
    echo "         Single VM Build Setup"
    echo "========================================"
    echo "Note: You will need the AMI ID, Key Pair name, and VPC/Subnet IDs."

    # --- CONFIGURATION (Instance Details, Key Pair, AMI, Network) ---
    local ami_id key_name vpc_id subnet_id security_group_ids
    local instance_name instance_type

    # Get VM-specific details
    read -p "Enter a name for the EC2 instance: " instance_name
    read -p "Enter the desired instance type (e.g., t2.micro): " instance_type

    # Get OS and Key details
    read -p "Enter the AMI ID for the OS image (e.g., ami-0abcdef1234567890): " ami_id
    read -p "Enter the name of your AWS Key Pair: " key_name

    # Get Network details and validate
    while true; do
        read -p "Enter the VPC ID to use: " vpc_id
        read -p "Enter the Subnet ID to use: " subnet_id
        
        if check_aws_vpc_subnet_exists "$vpc_id" "$subnet_id"; then
            echo "✅ Found existing VPC/Subnet: $vpc_id/$subnet_id"
            break
        else
            echo "❌ Error: VPC '$vpc_id' or Subnet '$subnet_id' not found. Please try again or check your AWS region."
        fi
    done
    read -p "Enter the Security Group ID(s) (comma-separated if multiple): " security_group_ids

    # --- SUMMARY AND EXECUTION ---
    echo "--- Summary of EC2 Instance Configuration ---"
    echo "Instance Name: $instance_name"
    echo "Instance Type: $instance_type"
    echo "AMI ID: $ami_id"
    echo "Key Name: $key_name"
    echo "VPC ID: $vpc_id"
    echo "Subnet ID: $subnet_id"
    echo "Security Group(s): $security_group_ids"
    echo "Public IP: No (Default in the script - use default subnet setting)"
    echo "-----------------------------------"
    
    read -p "Press Enter to start creation for '$instance_name'..."
    log_message "Creating EC2 instance '$instance_name'..."
    
    # AWS CLI Command to create the instance
    # NOTE: We use --tag-specifications to apply the Name tag immediately
    aws ec2 run-instances \
        --instance-type "$instance_type" \
        --image-id "$ami_id" \
        --key-name "$key_name" \
        --subnet-id "$subnet_id" \
        --security-group-ids $(echo "$security_group_ids" | tr ',' ' ') \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$instance_name}]" 2>&1 | tee -a "$LOG_FILE"
    
    # Check command exit status
    if [[ $? -eq 0 ]]; then
        log_message "✅ EC2 instance '$instance_name' creation started successfully."
        echo "✅ EC2 instance '$instance_name' creation started successfully. Check the status in the AWS Console."
    else
        log_message "❌ Error creating EC2 instance '$instance_name'. Check the log file for details."
        echo "❌ EC2 instance creation failed for '$instance_name'. Please check the log file for errors."
    fi
    
    log_message "EC2 build process completed."
}
## New function for AWS VM Deletion
aws_vm_delete() {
    log_message "--- Starting AWS VM deletion ---"
    if ! command -v aws &>/dev/null; then
        log_message "❌ AWS CLI ('aws') not found. Please install it to use this feature."
        return 1
    fi

    local instance_id
    read -p "Enter the EC2 Instance ID to terminate: " instance_id

    # Check if instance exists
    if ! aws ec2 describe-instances --instance-ids "$instance_id" &>/dev/null; then
        log_message "❌ Error: EC2 Instance ID '$instance_id' not found."
        return 1
    fi

    read -p "Are you sure you want to terminate instance '$instance_id'? This action is irreversible. (y/n): " confirm_delete
    if [[ ! "$confirm_delete" =~ ^[Yy]$ ]]; then
        log_message "EC2 instance termination aborted by user."
        echo "EC2 instance termination aborted."
        return
    fi

    log_message "Terminating EC2 instance '$instance_id'..."
    if aws ec2 terminate-instances --instance-ids "$instance_id" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✅ EC2 instance '$instance_id' termination request sent successfully. The instance will shut down shortly."
        echo "EC2 instance '$instance_id' termination request sent successfully."
    else
        log_message "❌ Error terminating EC2 instance '$instance_id'. Check logs for details."
        echo "Error terminating EC2 instance '$instance_id'. Check the log file for errors."
    fi
   #   read -p "Press Enter to return to the menu..."
}

## New function for AWS Snapshot Deletion
aws_snapshot_delete() {
    log_message "--- Starting AWS snapshot deletion ---"
    if ! command -v aws &>/dev/null; then
        log_message "❌ AWS CLI ('aws') not found. Please install it to use this feature."
        return 1
    fi

    local snapshot_id
    read -p "Enter the EBS Snapshot ID to delete: " snapshot_id

    if ! aws ec2 describe-snapshots --snapshot-ids "$snapshot_id" &>/dev/null; then
        log_message "❌ Error: EBS Snapshot ID '$snapshot_id' not found."
        return 1
    fi

    read -p "Are you sure you want to delete snapshot '$snapshot_id'? This action is irreversible. (y/n): " confirm_delete
    if [[ ! "$confirm_delete" =~ ^[Yy]$ ]]; then
        log_message "Snapshot deletion aborted by user."
        echo "Snapshot deletion aborted."
        return
    fi

    log_message "Deleting EBS snapshot '$snapshot_id'..."
    if aws ec2 delete-snapshot --snapshot-id "$snapshot_id" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✅ EBS snapshot '$snapshot_id' deleted successfully."
        echo "EBS snapshot '$snapshot_id' deleted successfully."
    else
        log_message "❌ Error deleting EBS snapshot '$snapshot_id'. Check logs for details."
        echo "Error deleting EBS snapshot '$snapshot_id'. Check the log file for errors."
    fi
   # read -p "Press Enter to return to the menu..."
}



# Azure and AWS menus
azure_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Preparing Menu ....Please wait ✋...."
        echo "========================================="
        sleep 2
        clear
        echo "======================================================="
        echo "   Welcome to Azure Cloud ☁️ Build Operations Menu 🙂"
        echo "======================================================="
        echo "---------------------------------------"
        echo "1.➡️ Create VM "
		echo "2.➡️ Create VM Snapshot "
        echo "3.➡️ Delete a VM"
        echo "4.➡️ Delete Snapshots"
		echo "5.➡️ Return to Previous Menu"
        echo "6.➡️ Return to Main Menu"
        echo "7.➡️ Exit"
        echo "---------------------------------------"
		echo ""
        read -p "Please Enter your choice: " choice
		echo ""
        case $choice in
        1) azure_vm_build ;;
		2) azure_vm_snapshot ;;
        3) azure_vm_delete ;;
        4) azure_snapshot_delete ;;
        5) log_message "Going back to Previous Menu... please wait✋."
		   return ;;
		6) log_message "Going back to Main Menu... please wait✋."
		   return 2 ;;
		7) log_message "Exiting script. Have a Great Day !!! Goodbye! 👋😀"
           exit 0 ;;
        *) echo "Oops Invalid option selected ❌. Please enter a number from 1 to 7." ;;
        esac
        echo
        read -p "Press Enter to continue..."
    done
}

aws_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Preparing Menu ....Please wait ✋...."
        echo "========================================="
        sleep 2
        clear
        echo "======================================================="
        echo "   Welcome to AWS Cloud ☁️ Build Operations Menu 🙂"
        echo "======================================================="
        echo "---------------------------------------"
        echo "1.➡️ Create VM"
	    echo "2.➡️ Create Snapshot"
        echo "3.➡️ Delete VM"
        echo "4.➡️ Delete Snapshot"
		echo "5.➡️ Return to Previous Menu"
        echo "6.➡️ Return to Main Menu"
        echo "7.➡️ Exit"
        echo "---------------------------------------"
		echo ""
        read -p "Please Enter your choice: " choice
		echo ""
        case $choice in
        1) aws_vm_build ;;
		2) azure_vm_snapshot ;;
        3) azure_vm_delete ;;
        4) azure_snapshot_delete ;;
        5) log_message "Going back to Previous Menu... please wait.✋"
		   return ;;
		6) log_message "Going back to Main Menu... please wait.✋"
		   return 2 ;;
		7) log_message "Exiting script. Have a Great Day !!! Goodbye! 👋😀"
           exit 0 ;;
        *) echo "Oops Invalid option selected ❌. Please enter a number from 1 to 7." ;;
        esac
        echo
        read -p "Press Enter to continue..."

    done
}

# Main build menu
build_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Preparing Menu ....Please wait ✋...."
        echo "========================================="
        sleep 2
        clear
        echo "================================================="
        echo "   Welcome to Cloud Build Operations Menu ☁️ "
        echo "================================================="
        echo "----------------------------------"
        echo "1.➡️ AWS Build Menu"
        echo "2.➡️ Azure Build Menu"
        echo "3.➡️ Return to Previous Menu"
        echo "4.➡️ Return to Main Menu"
        echo "5.➡️ Exit"
        echo "----------------------------------"
		echo ""
        read -p "Please choose your cloud provider : " choice
		echo ""
        case $choice in
        1) aws_menu ;;
        2) azure_menu ;;
        3) log_message "Going back to Previous Menu... please wait.✋"
		   return ;;
		4) log_message "Going back to Main Menu... please wait.✋"
		   return 1 ;;
		5) log_message "Exiting script. Have a Great Day !!! Goodbye! 👋😀"
           exit 0 ;;
        *) echo "Oops Invalid option selected ❌. Please enter a number from 1 to 5." ;;
        esac
        echo
        read -p "Press Enter to continue..."
    done
}
# Function to display the help menu and workflow diagram
# Function to show the help menu with the updated workflow and mandatory steps
show_help_menu() {
    clear
    echo "=========================================================="
    echo "       🚀 LINUX SERVER PATCHING WORKFLOW & HELP 🚀"
    echo "=========================================================="
    echo "This automation enforces compliance and auditing measures. Follow the"
    echo "steps below for a successful and compliant patching cycle."
    echo ""
    
    # ------------------------------------------------------------------
    echo "---  MANDATORY STARTUP & COMPLIANCE ---"
    echo "------------------------------------------------------------------"
    echo "1. ➡️  Enter Server List (Option 1):"
    echo "   - Input all target servers."
    echo ""
    echo "2. ➡️   Enter CR Number (Option 2):"
    echo "   - **MANDATORY:** You must enter a valid Change Request (CR) number."
    echo "   - All subsequent operational tasks (3-16) are BLOCKED until the CR is set."
    echo "   - The CR is automatically logged in all audit files."
    echo ""

    # ------------------------------------------------------------------
    echo "--- ✅ PRE-PATCHING & RISK ASSESSMENT ---"
    echo "------------------------------------------------------------------"
    echo "3. ➡️  Run Patching Pre-checks (Option 5):"
    echo "   - **Automated EOL Warning:** This step automatically performs the"
    echo "     OS End-of-Life (EOL) check to warn if servers are unsupported."
    echo "   - Also captures baseline data (uptime, FS utilization, etc.)."
    echo ""
    
    # ------------------------------------------------------------------
    echo "--- PATCHING & EXECUTION ---"
    echo "------------------------------------------------------------------"
    echo "4. ➡️  Patch Operations (Options 8, 9, 10):"
    echo "   - Select the OS-specific patching option (RHEL, SUSE, or Ubuntu)."
    echo "   - Note: The automation can now run operations on multiple servers "
    echo "     **in parallel** (concurrently) for faster execution."
    echo ""

    # ------------------------------------------------------------------
    echo "--- 📊 POST-PATCHING & AUDIT ---"
    echo "------------------------------------------------------------------"
    echo "5. ➡️  Reboot (Option 16):"
    echo "   - Reboots servers in a controlled manner."
    echo ""
    echo "6. ➡️  Run Patching Post-checks (Option 12):"
    echo "   - Captures post-patch data to verify system health."
    echo "   - **Automated EOL Audit:** This step automatically repeats the EOL"
    echo "     check to audit the final support status of the patched system."
    echo ""
    echo "7. ➡️  Compare Reports (Option 13):"
    echo "   - Compare Pre-check and Post-check reports to identify critical changes."
    
    echo "------------------------------------------------------------------"
    echo ""
  #  read -p "Press Enter to return to the Main Menu..."
}


# --- Main Script Loop ---
clear
echo "--------------------------------------------------------------------------------------------------------"
echo " Welcome to the Automation Tool , you are performing the automation as user - $(whoami) !!! ...."
echo "--------------------------------------------------------------------------------------------------------"
sleep 2
echo "================================================"
echo " Creating log Directory .....Please wait ✋...."
echo "================================================="
initialize_logging
echo "==================================================================="
echo " Log Directory is created ....Loading Main menu Please wait ✋...."
echo "===================================================================="
sleep 2
clear
while true; do
    clear
    echo "========================================"
    echo " Preparing Menu ....Please wait ✋...."
    echo "========================================="
    sleep 2
    clear
    echo "======================================="
    echo " Welcome to Automation Main Menu 🙂"
    echo "======================================="
    echo "---------------------------------------"
    echo "1.➡️ Linux Server Patching Operations"
    echo "2.➡️ SUSE Cluster Server Operations"
    echo "3.➡️ RHEL Cluster Server Operations"
    echo "4.➡️ Cloud Build Operations"
    echo "5.➡️ Help & Workflow"
	echo "6.➡️ Ask AI"
    echo "7.➡️ Exit"
    echo "---------------------------------------"
	echo ""
    read -p "Enter your choice: " choice
	echo ""
    case $choice in
    1) patching_menu ;;
    2) suse_cluster ;;
    3) rhel_cluster ;;
    4) build_menu ;;
    5) show_help_menu ;;
	6) echo "option in development phase " 
        ;;
            
    7)
        log_message "Exiting script. Have a Great Day !!! Goodbye! 👋😀"
        exit 0
        ;;
    *) echo "Oops Invalid option selected ❌. Please enter a number from 1 to 7." ;;
    esac
    echo
    read -p "Press Enter to continue..."
done