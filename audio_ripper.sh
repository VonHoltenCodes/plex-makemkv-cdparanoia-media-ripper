#!/bin/bash
# Audio CD Ripper - Improved version with reliable direct ripping
#
# This script handles audio CD ripping with:
# - Direct cdparanoia ripping (no abcde complexity)
# - Automatic track skipping for damaged tracks
# - FLAC conversion with metadata
# - Proper error handling and recovery

# Get script directory and session ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_ID="${1:-$(date +%Y%m%d_%H%M%S)}"
CUSTOM_ARTIST="${2:-auto}"

# Load configuration and common functions
source "$SCRIPT_DIR/rip_config.sh"
source "$SCRIPT_DIR/rip_common.sh"

# === SCRIPT VARIABLES ===
SCRIPT_NAME="audio_ripper"
DISC_ID=""
TRACK_COUNT=0
SESSION_DIR=""
ALBUM_DIR=""

# === AUDIO-SPECIFIC FUNCTIONS ===

# Get disc ID for unique identification
get_disc_id() {
    local disc_id=$(cd-discid "$OPTICAL_DRIVE" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$disc_id" ]; then
        print_error "Could not get CD disc ID"
        return 1
    fi
    echo "$disc_id"
}

# Count tracks on the CD
count_tracks() {
    local cd_info="$1"
    local count=$(echo "$cd_info" | grep -c "^\s*[0-9]\+\.")
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        print_error "Could not determine track count"
        return 1
    fi
    echo "$count"
}

# Check if CD is still accessible
verify_cd_access() {
    local cd_info=$(timeout 5s cdparanoia -Q 2>&1)
    if [[ $cd_info == *"Unable to"* ]] || [[ $cd_info == *"could not"* ]]; then
        print_error "CD is no longer accessible"
        return 1
    fi
    return 0
}

# Rip a single track with retry logic
rip_single_track() {
    local track_num="$1"
    local output_dir="$2"
    local track_formatted=$(printf "%02d" "$track_num")
    local cdparanoia_output="track${track_formatted}.cdda.wav"
    local flac_output="${track_formatted}.track.flac"
    
    print_info "Ripping track $track_formatted..."
    
    # Change to output directory
    cd "$output_dir" || return 1
    
    # Attempt to rip track with retry logic
    local success=false
    for ((attempt=1; attempt<=MAX_RETRY_ATTEMPTS; attempt++)); do
        print_debug "Track $track_formatted attempt $attempt of $MAX_RETRY_ATTEMPTS"
        
        # Verify CD is still accessible
        if ! verify_cd_access; then
            print_error "CD access lost during ripping"
            return 1
        fi
        
        # Run cdparanoia with timeout
        timeout "$TRACK_RIP_TIMEOUT" cdparanoia "$track_num" "$cdparanoia_output" >/dev/null 2>&1 &
        local rip_pid=$!
        
        # Show progress
        show_spinner $rip_pid "Ripping track $track_formatted (attempt $attempt)"
        wait $rip_pid
        local rip_status=$?
        
        # Check if rip was successful
        if [ $rip_status -eq 0 ] && [ -f "$cdparanoia_output" ] && [ -s "$cdparanoia_output" ]; then
            print_debug "Track $track_formatted ripped successfully"
            success=true
            break
        else
            print_warning "Track $track_formatted rip attempt $attempt failed"
            
            # Clean up failed attempt
            rm -f "$cdparanoia_output"
            
            if [ $attempt -lt $MAX_RETRY_ATTEMPTS ]; then
                print_info "Retrying in ${RETRY_DELAY}s..."
                sleep $RETRY_DELAY
                
                # Try to reset the drive
                eject -t "$OPTICAL_DRIVE" 2>/dev/null || true
                sleep 1
            fi
        fi
    done
    
    if [ "$success" = "false" ]; then
        print_error "Failed to rip track $track_formatted after $MAX_RETRY_ATTEMPTS attempts"
        echo "SKIPPED_TRACK_${track_formatted}" > "${track_formatted}.skipped"
        return 1
    fi
    
    # Convert to FLAC
    print_debug "Converting track $track_formatted to FLAC..."
    if flac -8 "$cdparanoia_output" -o "$flac_output" >/dev/null 2>&1; then
        print_success "Track $track_formatted converted to FLAC"
        rm "$cdparanoia_output"
        
        # Add basic metadata
        metaflac --set-tag="TRACKNUMBER=$track_num" \
                --set-tag="TITLE=Track $track_formatted" \
                --set-tag="ALBUM=Unknown Album_$DISC_ID" \
                --set-tag="ARTIST=Unknown Artist" \
                --set-tag="DATE=$(date +%Y)" \
                "$flac_output" 2>/dev/null
        
        return 0
    else
        print_error "Failed to convert track $track_formatted to FLAC"
        rm -f "$cdparanoia_output"
        return 1
    fi
}

# Process all tracks on the CD
rip_all_tracks() {
    local successful_tracks=0
    local skipped_tracks=0
    
    print_info "Starting full CD rip: $TRACK_COUNT tracks"
    print_info "Output directory: $ALBUM_DIR"
    
    # Rip each track
    for ((track=1; track<=TRACK_COUNT; track++)); do
        print_info "Progress: Track $track of $TRACK_COUNT"
        
        if rip_single_track "$track" "$ALBUM_DIR"; then
            ((successful_tracks++))
        else
            ((skipped_tracks++))
            print_warning "Track $track skipped due to errors"
        fi
        
        # Show overall progress
        show_progress $track $TRACK_COUNT
    done
    
    echo ""  # New line after progress
    
    print_info "Ripping complete: $successful_tracks successful, $skipped_tracks skipped"
    
    # Log results
    {
        echo "Disc ID: $DISC_ID"
        echo "Total tracks: $TRACK_COUNT"
        echo "Successfully ripped: $successful_tracks"
        echo "Skipped tracks: $skipped_tracks"
        echo "Date: $(date)"
        echo "Session: $SESSION_ID"
    } >> "$LOG_FILE"
    
    # Create partial rip notice if tracks were skipped
    if [ $skipped_tracks -gt 0 ]; then
        print_warning "$skipped_tracks track(s) were skipped due to errors"
        echo "PARTIAL RIP: $skipped_tracks/$TRACK_COUNT tracks missing" > "$ALBUM_DIR/README_PARTIAL_RIP.txt"
        echo "Skipped tracks may be damaged or copy-protected." >> "$ALBUM_DIR/README_PARTIAL_RIP.txt"
        echo "Disc ID: $DISC_ID" >> "$ALBUM_DIR/README_PARTIAL_RIP.txt"
        echo "Date: $(date)" >> "$ALBUM_DIR/README_PARTIAL_RIP.txt"
    fi
    
    # Check if we got any tracks at all
    if [ $successful_tracks -eq 0 ]; then
        print_error "Failed to rip any tracks from the CD"
        return 1
    fi
    
    return 0
}

# Move ripped files to Plex Music library
organize_to_plex() {
    local dest_dir="$MUSIC_DIR/Unknown Artist/Unknown Album_${DISC_ID}"
    
    print_info "Moving files to Plex Music library..."
    print_info "Destination: $dest_dir"
    
    # Create destination directory
    create_directory "$dest_dir" true
    
    # Count files to move
    local flac_files=$(find "$ALBUM_DIR" -name "*.flac" -type f | wc -l)
    if [ $flac_files -eq 0 ]; then
        print_error "No FLAC files found to move"
        return 1
    fi
    
    print_info "Moving $flac_files FLAC files..."
    
    # Move FLAC files
    if move_files_safely "$ALBUM_DIR" "$dest_dir" "*.flac" true; then
        print_success "FLAC files moved successfully"
    else
        print_error "Failed to move some FLAC files"
        return 1
    fi
    
    # Move any documentation files
    if [ -f "$ALBUM_DIR/README_PARTIAL_RIP.txt" ]; then
        local sudo_pass=$(get_sudo_password)
        if [ $? -eq 0 ]; then
            echo "$sudo_pass" | sudo -S cp "$ALBUM_DIR/README_PARTIAL_RIP.txt" "$dest_dir/"
        else
            sudo cp "$ALBUM_DIR/README_PARTIAL_RIP.txt" "$dest_dir/"
        fi
    fi
    
    # Copy any skipped track markers
    find "$ALBUM_DIR" -name "*.skipped" -type f | while read -r skipped_file; do
        local basename=$(basename "$skipped_file")
        local sudo_pass=$(get_sudo_password)
        if [ $? -eq 0 ]; then
            echo "$sudo_pass" | sudo -S cp "$skipped_file" "$dest_dir/"
        else
            sudo cp "$skipped_file" "$dest_dir/"
        fi
    done
    
    return 0
}

# Cleanup function for audio ripper
audio_cleanup() {
    local exit_code=$?
    
    if [ ! -z "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ]; then
        if [ $exit_code -eq 0 ]; then
            # Success - clean up temp directory
            rm -rf "$SESSION_DIR"
            print_debug "Cleaned up session directory: $SESSION_DIR"
        else
            # Error - leave temp directory for debugging
            print_warning "Session directory preserved for debugging: $SESSION_DIR"
        fi
    fi
    
    # Return to home directory
    cd "$HOME"
    
    log_message "INFO" "Audio ripper session ended with exit code $exit_code"
}

# === MAIN FUNCTION ===
main() {
    print_success "=== Audio CD Ripper v2.0 ==="
    print_info "Session ID: $SESSION_ID"
    
    # Initialize logging
    init_logging "$SCRIPT_NAME" "$SESSION_ID"
    
    # Register cleanup
    register_cleanup audio_cleanup
    
    # Check for required tools
    if ! check_required_tools "cdparanoia flac metaflac cd-discid"; then
        exit 1
    fi
    
    # Verify CD access
    print_info "Checking for audio CD..."
    local cd_info=$(timeout 5s cdparanoia -Q 2>&1)
    if [[ $cd_info == *"Unable to"* ]] || [[ $cd_info == *"could not"* ]]; then
        print_error "No audio CD detected or cannot access drive"
        exit 1
    fi
    
    print_success "Audio CD detected"
    
    # Get disc ID
    DISC_ID=$(get_disc_id)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    print_info "Disc ID: $DISC_ID"
    
    # Count tracks
    TRACK_COUNT=$(count_tracks "$cd_info")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    print_info "Total tracks: $TRACK_COUNT"
    
    # Show track listing
    print_info "Track listing:"
    echo "$cd_info" | grep -E "track|TOTAL" | head -10
    
    # Create session directory
    SESSION_DIR="$AUDIO_TEMP/session_${DISC_ID}_${SESSION_ID}"
    ALBUM_DIR="$SESSION_DIR/Unknown Artist/Unknown Album_${DISC_ID}"
    
    create_directory "$ALBUM_DIR" false
    
    # Clean up any previous temp directories for this disc
    cleanup_temp_dirs "$DISC_ID" 0
    
    # Rip all tracks
    if ! rip_all_tracks; then
        print_error "CD ripping failed"
        exit 1
    fi
    
    # Move to Plex library
    if ! organize_to_plex; then
        print_error "Failed to organize files in Plex library"
        exit 1
    fi
    
    # Notify Plex to scan
    notify_plex "music"
    
    print_success "Audio CD ripping completed successfully!"
    print_info "Files are now available in Plex Music library"
    print_info "Location: $MUSIC_DIR/Unknown Artist/Unknown Album_${DISC_ID}"
    
    # Eject CD
    if [ "$ENABLE_AUTO_EJECT" = "true" ]; then
        print_info "Ejecting CD..."
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