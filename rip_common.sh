#!/bin/bash
# Common functions library for master ripping system
# Source both config and this file: 
# source "$(dirname "$0")/rip_config.sh"
# source "$(dirname "$0")/rip_common.sh"

# === LOGGING FUNCTIONS ===

# Initialize logging
init_logging() {
    local script_name="$1"
    local session_id="${2:-$(date +%Y%m%d_%H%M%S)}"
    
    LOG_FILE="$LOG_DIR/${script_name}_${session_id}.log"
    
    # Create log directory if needed
    mkdir -p "$LOG_DIR"
    
    # Rotate logs if they get too large
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 10485760 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
    
    # Start new log session
    echo "=== $(date): Starting $script_name session $session_id ===" >> "$LOG_FILE"
}

# Unified logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Write to log file
    if [ ! -z "$LOG_FILE" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
    
    # Also write to stderr for ERROR level
    if [ "$level" = "ERROR" ]; then
        echo "[$timestamp] [$level] $message" >&2
    fi
}

# === PRINT FUNCTIONS ===

print_message() {
    local color="$1"
    local message="$2"
    local level="${3:-INFO}"
    
    # Print colored message
    echo -e "${color}${message}${NC}"
    
    # Log the message
    log_message "$level" "$message"
}

print_info() {
    print_message "$CYAN" "$1" "INFO"
}

print_success() {
    print_message "$GREEN" "$1" "INFO"
}

print_warning() {
    print_message "$YELLOW" "$1" "WARN"
}

print_error() {
    print_message "$RED" "$1" "ERROR"
}

print_debug() {
    if [ "$LOG_LEVEL" = "DEBUG" ]; then
        print_message "$BLUE" "[DEBUG] $1" "DEBUG"
    else
        log_message "DEBUG" "$1"
    fi
}

# === PROGRESS MONITORING ===

# Display progress bar
show_progress() {
    local current="$1"
    local total="$2"
    local width="${3:-50}"
    
    if [ "$ENABLE_PROGRESS_BARS" != "true" ] || [ "$total" -eq 0 ]; then
        return
    fi
    
    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    printf "\r["
    printf "%${filled}s" | tr ' ' '='
    printf ">"
    printf "%${empty}s" | tr ' ' ' '
    printf "] %3d%% " "$percent"
}

# Spinner for unknown progress
show_spinner() {
    local pid="$1"
    local message="${2:-Working...}"
    local delay=0.1
    local spinstr='|/-\'
    
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r[%c] %s" "$spinstr" "$message"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\r%80s\r"  # Clear the line
}

# Monitor log file for progress patterns
monitor_progress_from_log() {
    local log_file="$1"
    local patterns="$2"  # Space-separated list of grep patterns
    local last_percent=0
    
    while [ ! -f "$log_file" ]; do
        sleep 0.5
    done
    
    tail -f "$log_file" | while read -r line; do
        # Check for percentage patterns
        for pattern in $patterns; do
            if echo "$line" | grep -q "$pattern"; then
                local percent=$(echo "$line" | grep -oE '[0-9]+%' | tr -d '%' | tail -1)
                if [ ! -z "$percent" ] && [ "$percent" != "$last_percent" ]; then
                    show_progress "$percent" 100
                    last_percent="$percent"
                fi
                break
            fi
        done
        
        # Check for completion
        if echo "$line" | grep -q -E "(complete|finished|done|success)"; then
            printf "\r%80s\r"
            break
        fi
        
        # Check for errors
        if echo "$line" | grep -q -E "(error|failed|fatal)"; then
            printf "\r%80s\r"
            break
        fi
    done
}

# === DIRECTORY MANAGEMENT ===

# Create directory with proper permissions
create_directory() {
    local dir_path="$1"
    local use_sudo="${2:-false}"
    
    if [ -d "$dir_path" ]; then
        return 0
    fi
    
    log_message "INFO" "Creating directory: $dir_path"
    
    if [ "$use_sudo" = "true" ]; then
        local sudo_pass=$(get_sudo_password)
        if [ $? -eq 0 ]; then
            echo "$sudo_pass" | sudo -S mkdir -p "$dir_path"
            echo "$sudo_pass" | sudo -S chown "$USER:$USER" "$dir_path"
        else
            sudo mkdir -p "$dir_path"
            sudo chown "$USER:$USER" "$dir_path"
        fi
    else
        mkdir -p "$dir_path"
    fi
}

# Clean up temporary directories
cleanup_temp_dirs() {
    local session_pattern="$1"
    local max_age_days="${2:-7}"
    
    print_info "Cleaning up temporary directories older than $max_age_days days..."
    
    # Clean up old session directories
    find "$TEMP_DIR" -type d -name "*${session_pattern}*" -mtime +$max_age_days -exec rm -rf {} + 2>/dev/null || true
    
    # Clean up orphaned files
    find "$HOME" -maxdepth 1 -name "*.wav" -o -name "*.cdda.wav" -mtime +1 -exec rm -f {} + 2>/dev/null || true
    find "$HOME" -maxdepth 1 -name "abcde.*" -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
    
    log_message "INFO" "Temporary cleanup completed"
}

# === DISC DETECTION ===

# Check if optical drive is available
check_optical_drive() {
    if [ ! -e "$OPTICAL_DRIVE" ]; then
        print_error "Optical drive not found at $OPTICAL_DRIVE"
        return 1
    fi
    
    if [ ! -r "$OPTICAL_DRIVE" ]; then
        print_error "Cannot read from optical drive $OPTICAL_DRIVE (permission denied)"
        return 1
    fi
    
    return 0
}

# Detect disc type with improved logic
detect_disc_type() {
    print_info "Detecting disc type..."
    
    # Check for audio CD first (prevents false DVD detection on enhanced CDs)
    print_debug "Checking for audio CD..."
    local cd_info=$(timeout 5s cdparanoia -Q 2>&1)
    
    if [[ $cd_info != *"Unable to"* ]] && [[ $cd_info != *"could not"* ]]; then
        if [[ $cd_info =~ "track" ]] || [[ $cd_info =~ "TOTAL" ]]; then
            print_success "Audio CD detected"
            echo "audio"
            return 0
        fi
    fi
    
    # Check for video disc (DVD/Blu-ray)
    print_debug "Checking for DVD/Blu-ray (may take up to ${DISC_DETECT_TIMEOUT}s)..."
    local makemkv_info=$(timeout $DISC_DETECT_TIMEOUT makemkvcon info disc:0 2>&1)
    
    if [ $? -eq 124 ]; then
        print_warning "MakeMKV detection timed out - disc may be present but unreadable"
        echo "timeout"
        return 1
    fi
    
    if [[ $makemkv_info != *"no disc"* ]] && [[ ! -z $makemkv_info ]] && [[ $makemkv_info != *"Failed to open disc"* ]]; then
        if [[ $makemkv_info == *"BDMV"* ]]; then
            print_success "Blu-ray disc detected"
            echo "bluray"
            return 0
        elif [[ $makemkv_info =~ [Dd][Vv][Dd] ]] || [[ $makemkv_info =~ [Mm]peg ]]; then
            print_success "DVD disc detected"
            echo "dvd"
            return 0
        fi
    fi
    
    print_warning "No disc detected or unknown disc type"
    echo "none"
    return 1
}

# === PLEX INTEGRATION ===

# Get Plex library sections
get_plex_sections() {
    curl -s -H "X-Plex-Token: $PLEX_TOKEN" "$PLEX_URL/library/sections" 2>/dev/null
}

# Trigger Plex library refresh
notify_plex() {
    local media_type="$1"  # movie, tv, music
    local section_id=""
    
    if [ "$ENABLE_PLEX_NOTIFICATIONS" != "true" ]; then
        print_debug "Plex notifications disabled"
        return 0
    fi
    
    print_info "Notifying Plex to refresh library..."
    
    case "$media_type" in
        "movie") section_id="$PLEX_MOVIES_SECTION" ;;
        "tv") section_id="$PLEX_TV_SECTION" ;;
        "music") section_id="$PLEX_MUSIC_SECTION" ;;
        *) 
            print_error "Unknown media type: $media_type"
            return 1
            ;;
    esac
    
    local response=$(curl -s -X POST "$PLEX_URL/library/sections/$section_id/refresh" \
                     -H "X-Plex-Token: $PLEX_TOKEN" \
                     -w "%{http_code}" -o /dev/null 2>/dev/null)
    
    if [ "$response" = "200" ]; then
        print_success "Plex refresh triggered successfully"
        return 0
    else
        print_warning "Plex refresh failed (HTTP $response)"
        return 1
    fi
}

# === ERROR HANDLING ===

# Retry function with exponential backoff
retry_command() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local command="$@"
    
    for ((i=1; i<=max_attempts; i++)); do
        print_debug "Attempt $i of $max_attempts: $command"
        
        if eval "$command"; then
            return 0
        fi
        
        if [ $i -lt $max_attempts ]; then
            print_warning "Attempt $i failed, retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
        fi
    done
    
    print_error "Command failed after $max_attempts attempts: $command"
    return 1
}

# === FILE OPERATIONS ===

# Clean filename for filesystem compatibility
clean_filename() {
    local filename="$1"
    echo "$filename" | sed 's/[^a-zA-Z0-9._-]/ /g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//'
}

# Move files with verification
move_files_safely() {
    local source_dir="$1"
    local dest_dir="$2"
    local file_pattern="$3"
    local use_sudo="${4:-false}"
    
    local moved_count=0
    local total_count=$(find "$source_dir" -name "$file_pattern" -type f | wc -l)
    
    if [ $total_count -eq 0 ]; then
        print_warning "No files matching pattern '$file_pattern' found in $source_dir"
        return 1
    fi
    
    create_directory "$dest_dir" "$use_sudo"
    
    find "$source_dir" -name "$file_pattern" -type f | while read -r file; do
        local basename=$(basename "$file")
        local dest_file="$dest_dir/$basename"
        
        if [ "$use_sudo" = "true" ]; then
            local sudo_pass=$(get_sudo_password)
            if [ $? -eq 0 ]; then
                echo "$sudo_pass" | sudo -S mv "$file" "$dest_file"
                echo "$sudo_pass" | sudo -S chown "$USER:$USER" "$dest_file"
            else
                sudo mv "$file" "$dest_file"
                sudo chown "$USER:$USER" "$dest_file"
            fi
        else
            mv "$file" "$dest_file"
        fi
        
        if [ -f "$dest_file" ]; then
            print_success "Moved: $basename"
            ((moved_count++))
        else
            print_error "Failed to move: $basename"
        fi
    done
    
    print_info "Successfully moved $moved_count of $total_count files"
    return 0
}

# === TOOL VERIFICATION ===

# Check if required tools are installed
check_required_tools() {
    local tools="$1"  # Space-separated list
    local missing_tools=()
    
    for tool in $tools; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_info "Please install missing tools and try again"
        return 1
    fi
    
    return 0
}

# === CLEANUP ON EXIT ===

# Register cleanup function to run on script exit
register_cleanup() {
    local cleanup_function="$1"
    trap "$cleanup_function" EXIT INT TERM
}