#!/bin/bash

#
# ==========================================================================
#                            sync-holes.sh
#                  Synchronize Two Pi-hole 6 Instances
#
# ** Please back-up your Teleporter settings BEFORE testing this script!! **
# ==========================================================================
#
# MIT License
#
# (c) 2024 by Megamind
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#   Date            Who                    Description
#   -------------   -------------------    ------------------------------------
#   01-05-2025      bthrock                0.9.0 Initial Beta Release
#
# ==========================================================================
#

# =======================================
# Color Codes
# =======================================
declare -Ar COLORS=(
  [green]="\e[32m"
  [yellow]="\e[33m"
  [red]="\e[31m"
  [nc]="\e[0m"  # No Color
)

# ========================================
# Default Values for Environment Variables
# ========================================
declare -r env_file="/usr/local/etc/sync-holes.env"
declare -r default_log_file="/var/log/sync-holes.log"
declare -r default_temp_files_path="/tmp"

declare -r default_log_size_limit=1   # Default log file size limit in MB
declare -r default_max_old_logs=1     # Default max number of old log files to retain
declare -r default_verify_ssl=0       # Default to SSL verification disabled
declare -r default_mask_sensitive=1   # Default masking for sensitive data

declare -r default_import_settings_json="{}"  # Default import settings JSON placeholder
declare -r default_curl_error_log="$default_temp_files_path/curl_error_log.log"
declare -r auth_response_file="$default_temp_files_path/auth_response.json"

################################################################################
#                           ENVIRONMENT & LOGGING
################################################################################

# =======================================
# Logging & Print output functions
# =======================================
# Arguments:
#   $1 - Tag (e.g., INFO, DEBUG, ERROR)
#   $2 - Message to log (and optionally print to console)
#   $3 - Mode: "always" or "if_verbose"
#        "always" = message is both logged and printed to console
#        "if_verbose" = message is logged, but only printed when verbose=1
#   $4 - Optional color code (e.g., green, yellow, red)
#
#   Log file entries include a timestamp. Console Entries do not.
# =======================================
log_message() {
    local tag="$1"
    local message="$2"
    local mode="$3"
    local color="$4"

    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Try to append the message to the log file silently
    if [[ -n "$log_file" ]] && [[ -w "$(dirname "$log_file")" ]]; then
        echo "$timestamp [$tag] $message" >> "$log_file" 2>/dev/null
    fi

    # Handle verbosity for console output
    local is_verbose=0
    if [[ "${verbose:-0}" == "1" ]]; then
        is_verbose=1
    fi

    # Print to console if "always" or "if_verbose" and verbose mode is enabled
    if [[ "$mode" == "always" || ("$mode" == "if_verbose" && "$is_verbose" == "1") ]]; then
        if [[ -n "$color" && -n "${COLORS[$color]}" ]]; then
            if [[ "$is_verbose" == "1" ]]; then
                # Print with tag and color
                echo -e "[${COLORS[nc]}${COLORS[$color]}$tag${COLORS[nc]}] ${COLORS[$color]}$message${COLORS[nc]}" >&2
            else
                # Print message only, with color
                echo -e "${COLORS[$color]}$message${COLORS[nc]}" >&2
            fi
        else
            if [[ "$is_verbose" == "1" ]]; then
                # Print with tag, no color
                echo "[$tag] $message" >&2
            else
                # Print message only, no color
                echo "$message" >&2
            fi
        fi
    fi
}

# =======================================
# Mask Sensitive Data Function
# =======================================
# Masks sensitive information like passwords and session IDs in logs.
mask_sensitive_data() {
    local data="$1"
    # Skip masking if mask_sensitive is 0
    if [[ "$mask_sensitive" -eq 0 ]]; then
        echo "$data"
        return
    fi

    # Apply masking if enabled
    echo "$data" | sed -E '
        s/("password":[ ]*)"[^"]*"/\1"*****"/g;
        s/("sid":[ ]*)"[^"]*"/\1"*****"/g;
        s/(password:[ ]*)[^ ]*/\1*****/g;
        s/(sid:[ ]*)[^ ]*/\1*****/g;
        s/(Found sessionID:[ ]*)[^ ]*/\1*****/g;
    '
}

# =======================================
# Display Usage Instructions
# =======================================
# Prints the script's usage information and exits.
usage() {
    echo ""
    echo "============================================================================="
    echo ""
    echo "Description:"
    echo "  This script synchronizes Teleporter settings between two Pi-hole instances."
    echo "    ** Pi-hole v6 is required. This will not work with earlier versions **"
    echo ""
    echo "Usage: $(basename "$0") [-v] [-h] [-u]"
    echo ""
    echo "Options:"
    echo "  -v    Enable verbose mode"
    echo "  -h    Display this help message"
    echo "  -u    Disable masking of sensitive data in logs (unmask)"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")          # Run the script normally"
    echo "  $(basename "$0") -v       # Run the script with verbose output"
    echo "  $(basename "$0") -u       # Run the script without masking sensitive data"
    echo "  $(basename "$0") -v -u    # Run the script with verbose output and unmask data"
    echo "  $(basename "$0") -h       # Display this help message"
    echo ""
    echo "Note:"
    echo "  Depending on your installation and system configuration, you may need to run"
    echo "  this script with sudo for necessary permissions, for example:"
    echo ""
    echo "  sudo $(basename "$0")           # Run the script normally using sudo"
    echo "  sudo $(basename "$0") -v        # Run the script with verbose output using sudo"
    echo ""
    echo "============================================================================="
    echo ""
    exit 1
}

# =======================================
# Parsing Command-Line Argument(s)
# =======================================
verbose=0

# Parse options using getopts
while getopts ":vhu" opt; do
  case ${opt} in
    v )
      verbose=1
      ;;
    u )
      mask_sensitive_override=0  # Explicit override for unmasking
      ;;
    h )
      usage
      ;;
    \? )
      echo "Invalid Option: -$OPTARG" 1>&2
      usage
      ;;
  esac
done


# =======================================
# Load Environment Variables
# =======================================
# Sources the .env file to load configuration variables.
load_env() {
    if [ -f "$env_file" ]; then
        source "$env_file"
        log_message "ENV" "Environment file '$env_file' loaded." "if_verbose"

        # Ensure getopts overrides the .env file for mask_sensitive
        mask_sensitive="${mask_sensitive_override:-$mask_sensitive}"
    else
        handle_error "Environment file '$env_file' not found. Exiting."
    fi
}

# =======================================
# Check Required Dependencies
# =======================================
# Ensures that necessary commands like jq and curl are installed.
check_dependencies() {
    local missing_deps=()
    if ! command -v jq &> /dev/null; then
        missing_deps+=("'jq'")
    fi
    if ! command -v curl &> /dev/null; then
        missing_deps+=("'curl'")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        handle_error "Missing dependencies: ${missing_deps[*]}. Please install them to run this script."
    fi
}

# =======================================
# SSL Verification Check
# =======================================
# Logs whether SSL verification is enabled or disabled based on configuration.
ssl_verification() {
    if [ "${verify_ssl:-0}" -eq 0 ]; then
        log_message "ENV" "SSL verification is disabled (verify_ssl=0) in .env." "if_verbose"
    fi
}

# =======================================
# Validate Environment Variables and Paths
# =======================================
# Ensures required environment variables are set and paths are valid.
validate_env() {
    # Apply fallback defaults for environment variables after sourcing .env
    temp_files_path="${temp_files_path:-$default_temp_files_path}"
    log_file="${log_file:-$default_log_file}"
    log_size_limit="${log_size_limit:-$default_log_size_limit}"
    max_old_logs="${max_old_logs:-$default_max_old_logs}"
    verify_ssl="${verify_ssl:-$default_verify_ssl}"
    mask_sensitive="${mask_sensitive:-$default_mask_sensitive}"
    import_settings_json="${import_settings_json:-$default_import_settings_json}"

    # Derived paths based on temp_files_path
    teleporter_file="$temp_files_path/teleporter.zip"
    pi1_session_file="$temp_files_path/pi1-session.json"
    pi2_session_file="$temp_files_path/pi2-session.json"
    curl_error_log="$temp_files_path/curl_error.log"

    local required_vars=("pi1_url" "pi2_url")
    local missing_vars=()
    local invalid_urls=()

    # Regex pattern for validating URLs
    local url_regex='^(https?://)([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|([0-9]{1,3}\.){3}[0-9]{1,3})(:[0-9]{1,5})?$'

    # Validate temporary files path
    if [ ! -d "$temp_files_path" ]; then
        handle_error "Temporary files path '$temp_files_path' does not exist. Please create the directory or check your configuration."
    elif [ ! -w "$temp_files_path" ]; then
        handle_error "Temporary files path '$temp_files_path' exists but is not writable. Check permissions or use sudo."
    fi

    # Validate log file directory
    local log_dir
    log_dir=$(dirname "$log_file")
    if [ ! -d "$log_dir" ]; then
        handle_error "Log file directory '$log_dir' does not exist. Please create the directory or check your configuration."
    elif [ ! -w "$log_dir" ]; then
        handle_error "Log file directory '$log_dir' exists but is not writable. Check permissions or use sudo."
    fi

    # Check for missing environment variables
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        handle_error "Missing environment variables: ${missing_vars[*]}."
    fi

    # Validate URL formats for pi1_url and pi2_url
    for var in "${required_vars[@]}"; do
        if [[ ! "${!var}" =~ $url_regex ]]; then
            invalid_urls+=("$var")
        else
            # Further validate IP-based URLs and ports if needed
            if [[ "${!var}" =~ ^https?://([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})(:([0-9]{1,5}))?$ ]]; then
                ip="${BASH_REMATCH[1]}"
                port="${BASH_REMATCH[3]}"

                # Validate IP octets
                valid_ip=true
                IFS='.' read -r -a octets <<< "$ip"
                for octet in "${octets[@]}"; do
                    if (( octet < 0 || octet > 255 )); then
                        valid_ip=false
                        break
                    fi
                done

                # Validate port if present
                if [ -n "$port" ]; then
                    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
                        valid_ip=false
                    fi
                fi

                # Mark URL as invalid if IP/port validation fails
                if [ "$valid_ip" = false ]; then
                    invalid_urls+=("$var")
                fi
            fi
        fi
    done

    if [ ${#invalid_urls[@]} -gt 0 ]; then
        handle_error "Invalid URL format for: ${invalid_urls[*]} in $(basename "$env_file")."
    fi

    # Log validation success
    log_message "ENV" "All required environment variables and paths validated successfully." "if_verbose"
}

# =======================================
# Logging Size Limit & Rotation
# =======================================
# Manages log file size and rotates logs when necessary.
check_log_size() {
    local log_size_limit=${log_size_limit:-5}
    local max_old_logs=${max_old_logs:-5}

    if [ -f "$log_file" ]; then
        local log_size
        log_size=$(du -m "$log_file" | cut -f1)  # Get log file size in MB

        if (( log_size >= log_size_limit )); then
            rotate_log  # Rotate if size limit is exceeded
        fi
    fi

    cleanup_old_logs "$log_file" "$max_old_logs"  # Remove old logs beyond retention
}

# =======================================
# Rotate Log File
# =======================================
# Renames the current log file with a timestamp and starts a new one.
rotate_log() {
    local timestamp
    timestamp=$(date +"%Y%m%d%H%M%S")
    mv "$log_file" "${log_file}.${timestamp}"
    log_message "INFO" "Log file rotated at $(date +"%Y-%m-%d %H:%M:%S")" "if_verbose"
    log_message "INFO" "Log file rotated. Previous log saved as ${log_file}.${timestamp}." "if_verbose"
}

# =======================================
# Cleanup Old Logs
# =======================================
# Deletes logs that have exceeded their retention limit
cleanup_old_logs() {
    local log_file_base="$1"
    local retention_count="$2"

    # Find and delete logs older than the retention limit
    ls -1t "${log_file_base}."* 2>/dev/null | tail -n +$((retention_count + 1)) | while read -r old_log; do
        rm -f "$old_log"
        log_message "INFO" "Deleted old log file: $old_log" "if_verbose"
    done
}

################################################################################
#                            ERROR & CLEANUP
################################################################################

# =======================================
# Handle Errors
# =======================================
# Logs error messages, performs cleanup, and exits the script.
handle_error() {
    local message="$1"
    verbose=1  # Enable verbose to ensure error messages are printed

    if [ -s "$curl_error_log" ]; then
        # Log curl error messages if available
        log_message "ERROR" "$(cat "$curl_error_log")" "always" "red"
        rm -f "$curl_error_log"
    else
        # Otherwise, log the provided message
        log_message "ERROR" "$message" "always" "red"
    fi

    exit 1  # Exit the script with an error code
}

# =======================================
# Remove File Safely
# =======================================
# Deletes a specified file and logs the action.
remove_file() {
    local file_path="$1"
    local description="$2"

    if [ -f "$file_path" ]; then
        if rm -f "$file_path"; then
            log_message "CLEANUP" "Deleted $description: $file_path" "if_verbose"
        else
            log_message "ERROR":" Failed to delete $description: $file_path." "always"
            # Do not exit here; let cleanup handle the exit status
            return 1
        fi
    fi
    return 0
}

# =======================================
# Cleanup Temporary Files on Exit Function
# =======================================
# Performs cleanup tasks and preserves the original exit status.
cleanup() {
    local exit_code=$?  # Capture the original exit status

    log_message "CLEANUP" "Beginning cleanup..." "if_verbose"

    # Initialize a variable to track cleanup failures
    local cleanup_failed=0

    # Attempt to remove each file; if any removal fails, set cleanup_failed
    remove_file "$teleporter_file" "temporary backup file" || cleanup_failed=1
    remove_file "$curl_error_log" "curl error log" || cleanup_failed=1
    remove_file "$auth_response_file" "authentication response file" || cleanup_failed=1

    # If any cleanup task failed, set the exit code to 1
    if [ $cleanup_failed -ne 0 ]; then
        exit_code=1
    fi

    # Report Completion based on exit code. 
    if [ $exit_code -ne 0 ]; then
        log_message "INFO" "Exiting ($exit_code)." "always"
      else
        log_message "INFO" "Done." "if_verbose"
      fi

    exit "$exit_code"  # Exit with the original or modified exit code
}

# Set up trap to ensure cleanup is called on script exit
trap 'cleanup' EXIT

################################################################################
#                              RUN_CURL
################################################################################

# =======================================
# Run Curl Commands (except Upload)
# =======================================
# Executes a curl command with provided parameters and handles errors.
run_curl() {
    local method="$1"
    local url="$2"
    local headers="$3"
    local data="$4"
    local output="$5"
    local form_data="$6"

    local curl_args=(-s -k -S -X "$method" "$url")  # Initialize curl arguments

    > "$curl_error_log"  # Clear previous curl error log

    # Add headers if provided
    if [ -n "$headers" ]; then
        read -r -a header_array <<< "$headers"
        curl_args+=("${header_array[@]}")
    fi

    # Add form data if provided
    if [ -n "$form_data" ]; then
        curl_args+=($form_data)
    fi

    # Add data payload if provided
    if [ -n "$data" ]; then
        curl_args+=(--data "$data")
    fi

    # Specify output file if provided
    if [ -n "$output" ]; then
        curl_args+=(-o "$output")
    fi

    # Construct a log-friendly version of the curl command with masked sensitive data
    local curl_command="curl $(printf "%s " "${curl_args[@]}")"
    local masked_curl_cmd
    masked_curl_cmd=$(mask_sensitive_data "$curl_command")
    log_message "CURL" "Run: ${masked_curl_cmd}" "if_verbose"

    # Execute the curl command and capture the response
    local response
    response=$(curl "${curl_args[@]}" 2>"$curl_error_log")
    local curl_exit_code=$?
    # echo "Exit Code: $curl_exit_code" 1>&2 #DEBUG

    # Handle transport-level errors (e.g., DNS failures)
    if [ $curl_exit_code -ne 0 ]; then
        handle_error "Unable to complete synchronization due to CURL failure (transport or DNS error)."
    fi

    # If no output file was specified, return the response via stdout
    if [ -z "$output" ]; then
        echo "$response"
    fi
}

################################################################################
#                 AUTHENTICATION & SESSION MANAGEMENT
################################################################################

# =======================================
# Store Session
# =======================================
# Saves the session ID and its expiration time to a file for future reuse.
store_session() {
    local file="$1"
    local sid="$2"
    local validity="$3"
    local current_time
    current_time=$(date +%s)
    local expires_at=$((current_time + validity))

    # Create a JSON object with session details
    jq -n --arg sid "$sid" --argjson expires_at "$expires_at" \
        '{sid: $sid, expires_at: $expires_at}' > "$file"

    # Convert epoch time to human-readable format
    human_readable_expires_at=$(date -d "@$expires_at" '+%Y-%m-%d %H:%M:%S')

    # Log the message with masked sessionID and human-readable expiry
    log_message "AUTHENTICATION" "$(mask_sensitive_data "New sessionID (SID) stored in $file (expires at $human_readable_expires_at)")" "if_verbose"

}

# =======================================
# Reuse Session
# =======================================
# Attempts to reuse an existing session ID from a file if it's still valid.
reuse_session() {
    local file="$1"

    log_message "AUTHENTICATION" "Attempting to reuse sessionID from $file" "if_verbose"

    if [ -f "$file" ]; then
        local current_time
        current_time=$(date +%s)
        local expires_at
        expires_at=$(jq -r '.expires_at' "$file" 2>/dev/null || echo 0)
        local sid
        sid=$(jq -r '.sid' "$file" 2>/dev/null)

        if ((current_time < expires_at)); then
            # Convert epoch time to human-readable format
            human_readable_expires_at=$(date -d "@$expires_at" '+%Y-%m-%d %H:%M:%S')

            # Log the message with masked sessionID and human-readable expiry
            log_message "AUTHENTICATION" "$(mask_sensitive_data "Found sessionID: $sid (expires at $human_readable_expires_at)")" "if_verbose"

            log_message "AUTHENTICATION" "Reusing valid sessionID for $(basename "$file" | cut -d'-' -f1) from $file" "always"
            echo "$sid"
            return 0
        fi

        # If the session has expired, remove the sessionID file
        log_message "AUTHENTICATION" "sessionID in $file has expired. Removing $file." "if_verbose"
        rm -f "$file"
    else
        log_message "AUTHENTICATION" "No sessionID file found at $file." "if_verbose"
    fi

    return 1  # Indicate that session could not be reused
}

# =======================================
# Authenticate with REST API
# =======================================
# Authenticates with a Pi-hole instance and manages session IDs.
authenticate() {
    local pi_name="$1"
    local pi_pass="$2"
    local pi_url="$3"
    local pi_session_file="$4"
    local pi_sid_var_name="$5"

    local pi_sid
    pi_sid=$(reuse_session "$pi_session_file")
    if [ -z "$pi_sid" ]; then
        local pi_auth_data="{\"password\":\"$pi_pass\"}"
        local pi_auth_url="$pi_url/api/auth"
        log_message "AUTHENTICATION" "$(mask_sensitive_data "Authenticating with $pi_name using password: $pi_pass")" "if_verbose"


        # Execute the authentication request and save the response
        run_curl "POST" "$pi_auth_url" '-H Content-Type:application/json' "$pi_auth_data" "$auth_response_file"

        # Check if the authentication response file exists and is not empty
        if [ ! -s "$auth_response_file" ]; then
            handle_error "Authentication response from $pi_name is empty or missing."
        fi

        # Log the raw API response with sensitive data masked
        log_message "AUTHENTICATION" "API Response: $(mask_sensitive_data "$(cat "$auth_response_file")")" "if_verbose"

        # Parse the JSON response to extract session details
        local clean_json
        clean_json=$(cat "$auth_response_file" | tail -n 1)
        local session_valid
        session_valid=$(echo "$clean_json" | jq -r '.session.valid')
        pi_sid=$(echo "$clean_json" | jq -r '.session.sid')
        local pi_validity
        pi_validity=$(echo "$clean_json" | jq -r '.session.validity')

        if [ "$session_valid" == "false" ]; then
            # Handle authentication failure with a detailed message
            handle_error "Authentication failed for $pi_name. $(echo "$clean_json" | jq -r '.session.message' | awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')."
        elif [ -n "$pi_sid" ] && [ "$pi_sid" != "null" ]; then
            # Store the new sessionID if authentication is successful
            store_session "$pi_session_file" "$pi_sid" "$pi_validity"
            log_message "AUTHENTICATION" "$pi_name authenticated with session ID." "always"
        else
            # Log if authentication succeeded without a session ID
            log_message "AUTHENTICATION" "$pi_name authenticated without a session ID." "always"
            pi_sid=""
        fi
    else
        # Log that a valid session ID is being reused
        log_message "AUTHENTICATION" "Using stored unexpired sessionID for $pi_name." "if_verbose"
    fi

    # Dynamically assign the session ID to the provided variable name
    eval "$pi_sid_var_name='$pi_sid'"
    rm -f "$auth_response_file"  # Clean up the authentication response file
}

################################################################################
#                                 TELEPORTER
################################################################################

# =======================================
# Generate Import JSON
# =======================================
# Creates a JSON object for import settings using jq.
generate_import_json() {
    jq -n \
        --argjson config "$import_config" \
        --argjson dhcp_leases "$import_dhcp_leases" \
        --argjson gravity_group "$import_gravity_group" \
        --argjson gravity_adlist "$import_gravity_adlist" \
        --argjson gravity_adlist_by_group "$import_gravity_adlist_by_group" \
        --argjson gravity_domainlist "$import_gravity_domainlist" \
        --argjson gravity_domainlist_by_group "$import_gravity_domainlist_by_group" \
        --argjson gravity_client "$import_gravity_client" \
        --argjson gravity_client_by_group "$import_gravity_client_by_group" \
        '{config: $config, dhcp_leases: $dhcp_leases, gravity: {group: $gravity_group, adlist: $gravity_adlist, adlist_by_group: $gravity_adlist_by_group, domainlist: $gravity_domainlist, domainlist_by_group: $gravity_domainlist_by_group, client: $gravity_client, client_by_group: $gravity_client_by_group}}'
}

# =======================================
# Download Teleporter File
# =======================================
# Downloads the Teleporter settings from the primary Pi-hole.
download_teleporter_file() {
    local headers="-H Accept:application/zip"

    # Include session ID in headers if present. Skip for password-less Pi-hole instances. s
    if [ -n "$pi1_sid" ]; then
        headers="$headers -H sid:$pi1_sid"
    else
        log_message "DOWNLOAD" "No sessionID provided for $pi1_name; proceeding without authentication." "if_verbose"
    fi

    log_message "DOWNLOAD" "Downloading Teleporter settings from $pi1_name." "if_verbose"
    run_curl "GET" "$pi1_url/api/teleporter" "$headers" "" "$teleporter_file"

    # Validate the downloaded file is a valid ZIP archive
    if [ ! -f "$teleporter_file" ] || ! file "$teleporter_file" | grep -q "Zip archive data"; then
        handle_error "Failed to download or validate Teleporter file from $pi1_name."
        return  # Exit the function after handling the error
    fi

    log_message "DOWNLOAD" "Teleporter file downloaded from $pi1_name." "always"
}

# =======================================
# Upload Teleporter File to pi2
# =======================================
# Uploads the Teleporter settings to the secondary Pi-hole.
upload_teleporter_file() {
    local upload_url="$pi2_url/api/teleporter"
    log_message "UPLOAD" "Uploading Teleporter settings to $pi2_name." "if_verbose"

    # Generate the import settings JSON
    local import_settings_json
    import_settings_json=$(generate_import_json)

    # Compact the JSON to remove unnecessary whitespace
    local import_json_compact
    import_json_compact=$(echo "$import_settings_json" | jq -c .)

    # Define form data with properly quoted JSON to prevent shell interpretation issues
    local form_data="-F file=@$teleporter_file -F 'import=$import_json_compact'"

    # Execute run_curl with form data and capture the response
    local upload_response
    upload_response=$(run_curl "POST" "$upload_url" "-H accept:application/json -H sid:$pi2_sid" "" "" "$form_data")

    # If there's content in the curl error log, handle the error
    if [ -s "$curl_error_log" ]; then handle_error; fi

    # Log the full JSON API response with masking
    [[ -n "$upload_response" ]] && log_message "UPLOAD" "API Response: $(echo "$upload_response" | jq -c .)" "if_verbose"

    # Check for an error in the API response
    if echo "$upload_response" | jq -e '.error' >/dev/null 2>&1; then
      handle_error "$(echo "$upload_response" | jq -r '.error.message')"
    fi

    # Log a success message after uploading
    log_message "UPLOAD" "Teleporter file uploaded to $pi2_name." "always"
    log_message "INFO" "$pi1_name and $pi2_name settings synchronized!" "always" "green"
}

################################################################################
#                          MAIN SCRIPT EXECUTION FLOW
################################################################################

# Initialize script variables and configurations
script_name=$(basename "$0")
log_message "START" "Running $script_name..." "always"
load_env            # Load environment variables from .env file
validate_env        # Validate environment variables and paths
check_dependencies  # Ensure required commands are available
ssl_verification    # Log SSL verification status

# Authenticate with both Pi-hole instances to obtain session IDs
authenticate "$pi1_name" "$pi1_pass" "$pi1_url" "$pi1_session_file" "pi1_sid"
authenticate "$pi2_name" "$pi2_pass" "$pi2_url" "$pi2_session_file" "pi2_sid"

# Download the Teleporter file from the primary Pi-hole
download_teleporter_file

# Upload the Teleporter file to the secondary Pi-hole
upload_teleporter_file