#!/bin/bash
# Video Disc Ripper - Improved DVD/Blu-ray ripping with MakeMKV
#
# This script handles DVD and Blu-ray ripping with:
# - MakeMKV integration with progress monitoring
# - Optional HandBrake compression
# - Automatic Plex library organization
# - Proper error handling and recovery

# Get script directory and session ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_ID="${1:-$(date +%Y%m%d_%H%M%S)}"
FORCE_MEDIA_TYPE="${2:-auto}"
CUSTOM_TITLE="${3:-auto}"
CUSTOM_PATH="${4:-}"

# Load configuration and common functions
source "$SCRIPT_DIR/rip_config.sh"
source "$SCRIPT_DIR/rip_common.sh"

# === SCRIPT VARIABLES ===
SCRIPT_NAME="video_ripper"
DISC_TITLE=""
SAFE_TITLE=""
MEDIA_TYPE=""
SESSION_DIR=""
FINAL_DIR=""

# === VIDEO-SPECIFIC FUNCTIONS ===

# Check if video disc is accessible
check_video_disc() {
    print_info "Checking for video disc (this may take up to ${DISC_DETECT_TIMEOUT}s)..."
    
    local disc_info=$(timeout $DISC_DETECT_TIMEOUT makemkvcon info disc:0 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 124 ]; then
        print_error "MakeMKV detection timed out"
        return 1
    fi
    
    if [[ $disc_info == *"no disc"* ]] || [[ -z $disc_info ]] || [[ $disc_info == *"Failed to open disc"* ]]; then
        print_error "No video disc detected"
        return 1
    fi
    
    print_success "Video disc detected"
    echo "$disc_info"
}

# Extract disc title from MakeMKV output
get_disc_title() {
    local disc_info="$1"
    local title=""
    
    # Try multiple patterns to find the title
    title=$(echo "$disc_info" | grep -E "CINFO:2,0" | cut -d'"' -f2 | head -1)
    
    # If no title found, try to extract from disc label
    if [[ -z $title ]]; then
        title=$(sudo blkid "$OPTICAL_DRIVE" 2>/dev/null | grep -o 'LABEL="[^"]*"' | cut -d'"' -f2)
    fi
    
    # Final fallback
    if [[ -z $title ]]; then
        title="Unknown_Disc_$(date +%Y%m%d_%H%M%S)"
    fi
    
    echo "$title"
}

# Get media type from user
get_media_type() {
    local disc_title="$1"
    
    print_info "Detected disc: $disc_title"
    echo ""
    echo "Media type selection:"
    echo "  1) Movie (goes to Movies library)"
    echo "  2) TV Show (goes to TV Shows library)"
    echo "  3) Custom path (specify your own location)"
    echo ""
    echo -n "Choose destination [1/2/3] or [M/T/C]: "
    read -r media_choice
    
    case ${media_choice^^} in
        M|1|MOVIE)
            echo "movie"
            ;;
        T|2|TV|SHOW)
            echo "tv"
            ;;
        C|3|CUSTOM)
            echo "custom"
            ;;
        *)
            print_warning "Invalid choice '$media_choice', defaulting to Movie"
            echo "movie"
            ;;
    esac
}

# Get custom title from user
get_custom_title() {
    local default_title="$1"
    
    echo ""
    echo "Title customization:"
    echo "Default title: $default_title"
    echo -n "Enter custom title (or press Enter to use default): "
    read -r custom_title
    
    if [ ! -z "$custom_title" ]; then
        echo "$custom_title"
    else
        echo "$default_title"
    fi
}

# Get custom path from user
get_custom_path() {
    echo ""
    echo "Custom destination path:"
    echo "Current Plex media root: $PLEX_MEDIA"
    echo "Examples:"
    echo "  $PLEX_MEDIA/Movies/Action Movies"
    echo "  $PLEX_MEDIA/TV Shows/Cartoons"
    echo "  $PLEX_MEDIA/Special Collections"
    echo ""
    echo -n "Enter full destination path: "
    read -r custom_path
    
    if [ -z "$custom_path" ]; then
        print_warning "No path entered, defaulting to Movies"
        echo "$MOVIES_DIR"
    else
        # Ensure it's under Plex media directory for safety
        if [[ "$custom_path" == "$PLEX_MEDIA"* ]]; then
            echo "$custom_path"
        else
            print_warning "Path must be under $PLEX_MEDIA for Plex integration"
            echo "$PLEX_MEDIA/$custom_path"
        fi
    fi
}

# Monitor MakeMKV progress from log file
monitor_makemkv_progress() {
    local log_file="$1"
    local last_percent=0
    local spinner_index=0
    local spinners=('|' '/' '-' '\')
    
    print_info "Monitoring rip progress..."
    
    while true; do
        if [ -f "$log_file" ]; then
            # Look for various progress patterns
            local percent=""
            
            # Pattern 1: "Saving to MKV file... nn%"
            percent=$(grep -oE "Saving to MKV file.*[0-9]+%" "$log_file" | tail -1 | grep -oE "[0-9]+%" | tr -d '%')
            
            # Pattern 2: "Progress: nn/MM"
            if [ -z "$percent" ]; then
                local progress_line=$(grep -oE "Progress: [0-9]+/[0-9]+" "$log_file" | tail -1)
                if [ ! -z "$progress_line" ]; then
                    local current=$(echo "$progress_line" | cut -d':' -f2 | cut -d'/' -f1 | tr -d ' ')
                    local total=$(echo "$progress_line" | cut -d'/' -f2)
                    if [ $total -gt 0 ]; then
                        percent=$((current * 100 / total))
                    fi
                fi
            fi
            
            # Pattern 3: "Analyzing seamless segments"
            if [ -z "$percent" ] && grep -q "Analyzing seamless segments" "$log_file"; then
                percent=10
            fi
            
            # Pattern 4: Count title processing
            local title_count=$(grep -c "Processing title" "$log_file")
            if [ $title_count -gt 0 ] && [ -z "$percent" ]; then
                percent=$((title_count * 5))
            fi
            
            # Update progress display
            if [ ! -z "$percent" ] && [ $percent -ne $last_percent ]; then
                show_progress $percent 100
                last_percent=$percent
            else
                # Show spinner if no specific progress
                local current_op=$(grep -E "(Processing|Analyzing|Saving)" "$log_file" | tail -1 | cut -c1-50)
                printf "\r[%s] %s" "${spinners[$spinner_index]}" "$current_op"
                spinner_index=$(( (spinner_index + 1) % 4 ))
            fi
            
            # Check for completion
            if grep -q -E "Copy complete|Operation successfully completed" "$log_file"; then
                printf "\r%80s\r"
                print_success "Rip completed successfully"
                break
            fi
            
            # Check for errors
            if grep -q -E "Operation failed|Fatal error" "$log_file"; then
                printf "\r%80s\r"
                print_error "Rip failed - check log for details"
                break
            fi
        fi
        
        sleep 0.5
    done
}

# Rip disc with MakeMKV
rip_disc_makemkv() {
    local output_dir="$1"
    local title="$2"
    local log_file="$LOG_DIR/makemkv_${title}_${SESSION_ID}.log"
    
    print_info "Starting MakeMKV rip..."
    print_info "Title: $title"
    print_info "Output directory: $output_dir"
    print_info "This may take 10-60 minutes depending on disc size..."
    
    # Create output directory
    create_directory "$output_dir" false
    
    # Start progress monitoring in background
    monitor_makemkv_progress "$log_file" &
    local monitor_pid=$!
    
    # Run MakeMKV with progress output
    makemkvcon mkv disc:0 all "$output_dir" --profile=default -r --progress=-same 2>&1 | tee "$log_file"
    local rip_status=${PIPESTATUS[0]}
    
    # Stop progress monitoring
    kill $monitor_pid 2>/dev/null
    wait $monitor_pid 2>/dev/null
    
    echo ""  # Ensure we're on a new line
    
    if [ $rip_status -eq 0 ]; then
        print_success "MakeMKV rip completed successfully!"
        return 0
    else
        print_error "MakeMKV rip failed! Check log: $log_file"
        return 1
    fi
}

# Monitor HandBrake progress
monitor_handbrake_progress() {
    local input="$1"
    
    print_info "HandBrake compression starting..."
    
    while IFS= read -r line; do
        # HandBrake outputs: "Encoding: task 1 of 1, 45.21 %"
        if [[ $line =~ ([0-9]+\.[0-9]+)\ % ]]; then
            local percent=${BASH_REMATCH[1]%.*}
            show_progress $percent 100
        elif [[ $line =~ "Encoding:" ]]; then
            local info=$(echo "$line" | cut -d',' -f1-2 | cut -c1-40)
            printf "\r%s" "$info"
        fi
    done
    echo ""
}

# Compress video with HandBrake
compress_video() {
    local input_file="$1"
    local output_file="$2"
    local preset="${3:-$HANDBRAKE_PRESET}"
    
    print_info "Compressing: $(basename "$input_file")"
    print_info "Preset: $preset"
    print_info "This may take 30-120 minutes depending on file size..."
    
    # Run HandBrake with progress monitoring
    HandBrakeCLI -i "$input_file" -o "$output_file" --preset="$preset" 2>&1 | monitor_handbrake_progress "$input_file"
    
    local handbrake_status=${PIPESTATUS[0]}
    
    if [ $handbrake_status -eq 0 ]; then
        print_success "Compression completed successfully"
        return 0
    else
        print_error "Compression failed"
        return 1
    fi
}

# Ask user about compression
prompt_compression() {
    if [ "$ENABLE_COMPRESSION_PROMPT" != "true" ]; then
        return 1  # No compression
    fi
    
    echo ""
    echo "Compression options:"
    echo "  Y) Compress with HandBrake (smaller files, takes longer)"
    echo "  N) Keep original MKV files (larger files, faster)"
    echo ""
    echo -n "Compress files? (y/N): "
    read -r compress_choice
    
    case ${compress_choice^^} in
        Y|YES)
            return 0  # Compress
            ;;
        *)
            return 1  # No compression
            ;;
    esac
}

# Process compression for all MKV files
process_compression() {
    local source_dir="$1"
    local mkv_files=("$source_dir"/*.mkv)
    local total_files=${#mkv_files[@]}
    
    if [ ! -f "${mkv_files[0]}" ]; then
        print_error "No MKV files found for compression"
        return 1
    fi
    
    create_directory "$source_dir/compressed" false
    
    local current_file=0
    local successful_compressions=0
    
    for mkv_file in "${mkv_files[@]}"; do
        if [ -f "$mkv_file" ]; then
            ((current_file++))
            local filename=$(basename "$mkv_file")
            local compressed_file="$source_dir/compressed/$filename"
            
            print_info "Compressing file $current_file of $total_files: $filename"
            
            if compress_video "$mkv_file" "$compressed_file"; then
                # Remove original if compression successful
                rm "$mkv_file"
                mv "$compressed_file" "$mkv_file"
                ((successful_compressions++))
                print_success "Compressed and replaced: $filename"
            else
                print_warning "Compression failed for: $filename (keeping original)"
            fi
        fi
    done
    
    # Clean up compression directory
    rmdir "$source_dir/compressed" 2>/dev/null
    
    print_info "Compression complete: $successful_compressions of $total_files files"
    return 0
}

# Organize files into Plex library structure
organize_files() {
    local source_dir="$1"
    local media_type="$2"
    local title="$3"
    local custom_path="$4"
    
    # Clean up title for directory naming
    title=$(clean_filename "$title")
    
    # Determine destination directory
    case "$media_type" in
        "movie")
            FINAL_DIR="$MOVIES_DIR/$title"
            print_info "Media type: Movie"
            ;;
        "tv")
            FINAL_DIR="$TV_DIR/$title"
            print_info "Media type: TV Show"
            ;;
        "custom")
            FINAL_DIR="$custom_path/$title"
            print_info "Media type: Custom path"
            print_info "Custom location: $custom_path"
            ;;
        *)
            print_error "Unknown media type: $media_type"
            return 1
            ;;
    esac
    
    print_info "Organizing files to: $FINAL_DIR"
    
    # Create destination directory
    create_directory "$FINAL_DIR" true
    
    # Count MKV files
    local mkv_count=$(find "$source_dir" -name "*.mkv" -type f | wc -l)
    if [ $mkv_count -eq 0 ]; then
        print_error "No MKV files found to organize"
        return 1
    fi
    
    print_info "Moving $mkv_count MKV file(s)..."
    
    # Move files and rename main file
    local file_count=0
    find "$source_dir" -name "*.mkv" -type f | sort | while read -r mkv_file; do
        if [ -f "$mkv_file" ]; then
            ((file_count++))
            local basename=$(basename "$mkv_file")
            
            if [ $file_count -eq 1 ]; then
                # Rename first file to match title
                local dest_file="$FINAL_DIR/$title.mkv"
                local sudo_pass=$(get_sudo_password)
                if [ $? -eq 0 ]; then
                    echo "$sudo_pass" | sudo -S mv "$mkv_file" "$dest_file"
                    echo "$sudo_pass" | sudo -S chown "$USER:$USER" "$dest_file"
                else
                    sudo mv "$mkv_file" "$dest_file"
                    sudo chown "$USER:$USER" "$dest_file"
                fi
                print_success "Moved: $basename → $title.mkv"
            else
                # Keep additional files with original names
                local dest_file="$FINAL_DIR/$basename"
                local sudo_pass=$(get_sudo_password)
                if [ $? -eq 0 ]; then
                    echo "$sudo_pass" | sudo -S mv "$mkv_file" "$dest_file"
                    echo "$sudo_pass" | sudo -S chown "$USER:$USER" "$dest_file"
                else
                    sudo mv "$mkv_file" "$dest_file"
                    sudo chown "$USER:$USER" "$dest_file"
                fi
                print_success "Moved: $basename"
            fi
        fi
    done
    
    return 0
}

# Cleanup function for video ripper
video_cleanup() {
    local exit_code=$?
    
    if [ ! -z "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ]; then
        # Check if directory is empty (files were moved successfully)
        if [ -z "$(ls -A "$SESSION_DIR")" ]; then
            rm -rf "$SESSION_DIR"
            print_debug "Cleaned up empty session directory: $SESSION_DIR"
        else
            print_warning "Session directory contains files: $SESSION_DIR"
            print_info "You may want to manually move these files or investigate the issue"
        fi
    fi
    
    # Return to home directory
    cd "$HOME"
    
    log_message "INFO" "Video ripper session ended with exit code $exit_code"
}

# === MAIN FUNCTION ===
main() {
    print_success "=== Video Disc Ripper v2.0 ==="
    print_info "Session ID: $SESSION_ID"
    
    # Initialize logging
    init_logging "$SCRIPT_NAME" "$SESSION_ID"
    
    # Register cleanup
    register_cleanup video_cleanup
    
    # Check for required tools
    if ! check_required_tools "makemkvcon"; then
        exit 1
    fi
    
    # Check for optional HandBrake
    if [ "$ENABLE_COMPRESSION_PROMPT" = "true" ] && ! command -v HandBrakeCLI &> /dev/null; then
        print_warning "HandBrake not found - compression will be disabled"
        ENABLE_COMPRESSION_PROMPT=false
    fi
    
    # Check for video disc
    local disc_info=$(check_video_disc)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    # Get disc title
    DISC_TITLE=$(get_disc_title "$disc_info")
    print_info "Disc title: $DISC_TITLE"
    
    # Handle forced media type or get from user
    if [ "$FORCE_MEDIA_TYPE" != "auto" ]; then
        MEDIA_TYPE="$FORCE_MEDIA_TYPE"
        print_info "Media type (forced): $MEDIA_TYPE"
    else
        MEDIA_TYPE=$(get_media_type "$DISC_TITLE")
        print_info "Media type: $MEDIA_TYPE"
    fi
    
    # Handle custom title or get from user
    print_debug "CUSTOM_TITLE parameter: '$CUSTOM_TITLE'"
    print_debug "DISC_TITLE detected: '$DISC_TITLE'"
    
    if [ "$CUSTOM_TITLE" != "auto" ] && [ ! -z "$CUSTOM_TITLE" ] && [ "$CUSTOM_TITLE" != "" ]; then
        # User provided a specific custom title
        SAFE_TITLE=$(clean_filename "$CUSTOM_TITLE")
        print_info "Using custom title: $SAFE_TITLE"
    elif [ "$CUSTOM_TITLE" = "auto" ]; then
        # User wants auto-detection - use the disc title directly
        SAFE_TITLE=$(clean_filename "$DISC_TITLE")
        print_info "Using auto-detected title: $SAFE_TITLE"
    else
        # Interactive mode - ask the user
        print_info "Interactive title selection..."
        SAFE_TITLE=$(get_custom_title "$DISC_TITLE")
        SAFE_TITLE=$(clean_filename "$SAFE_TITLE")
        print_info "Final title: $SAFE_TITLE"
    fi
    
    # Create session directory
    SESSION_DIR="$VIDEO_TEMP/session_${SAFE_TITLE}_${SESSION_ID}"
    create_directory "$SESSION_DIR" false
    
    # Clean up any previous temp directories
    cleanup_temp_dirs "session_${SAFE_TITLE}" 0
    
    # Rip the disc
    if ! rip_disc_makemkv "$SESSION_DIR" "$SAFE_TITLE"; then
        print_error "Disc ripping failed"
        exit 1
    fi
    
    # Check if compression is wanted
    if prompt_compression; then
        if ! process_compression "$SESSION_DIR"; then
            print_warning "Compression failed, but continuing with original files"
        fi
    fi
    
    # Organize files into Plex library
    if ! organize_files "$SESSION_DIR" "$MEDIA_TYPE" "$SAFE_TITLE" "$CUSTOM_PATH"; then
        print_error "Failed to organize files into Plex library"
        exit 1
    fi
    
    # Notify Plex to refresh library
    case "$MEDIA_TYPE" in
        "custom")
            # For custom paths, try to refresh the most appropriate library
            print_info "Custom path detected - refreshing all Plex libraries"
            notify_plex "movie" || notify_plex "tv" || print_warning "Plex refresh failed"
            ;;
        *)
            notify_plex "$MEDIA_TYPE"
            ;;
    esac
    
    print_success "Video disc ripping completed successfully!"
    print_info "Files are now available in Plex library"
    print_info "Location: $FINAL_DIR"
    
    # Eject disc
    if [ "$ENABLE_AUTO_EJECT" = "true" ]; then
        print_info "Ejecting disc..."
        eject "$OPTICAL_DRIVE" 2>/dev/null || true
    fi
}

# === ENTRY POINT ===

# Verify we have necessary files
if [ ! -f "$SCRIPT_DIR/rip_config.sh" ] || [ ! -f "$SCRIPT_DIR/rip_common.sh" ]; then
    echo "ERROR: Required configuration files not found"
    exit 1
fi

# Run main function
main "$@"