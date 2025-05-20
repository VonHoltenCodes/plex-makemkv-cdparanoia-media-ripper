#!/bin/bash
# Automated DVD/Blu-ray ripping script for MakeMKV and Plex

# Configuration
PLEX_MEDIA="/mnt/plexmedia"
TEMP_DIR="$PLEX_MEDIA/rip_temp/video"
MOVIES_DIR="$PLEX_MEDIA/Movies"
TV_DIR="$PLEX_MEDIA/TV Shows"
LOG_DIR="$PLEX_MEDIA/rip_logs"
MAKEMKV_PROFILE="default"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create directories if they don't exist
mkdir -p "$TEMP_DIR" "$LOG_DIR" "$MOVIES_DIR" "$TV_DIR"

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if disc is inserted
check_disc() {
    print_message $YELLOW "Checking disc (this may take a moment)..."
    local disc_info=$(timeout 30s makemkvcon info disc:0 2>&1)
    if [[ $disc_info == *"no disc"* ]] || [[ -z $disc_info ]]; then
        print_message $RED "No disc detected. Please insert a disc and try again."
        exit 1
    fi
    echo "$disc_info"
}

# Function to get disc title
get_disc_title() {
    local disc_info="$1"
    # Try multiple patterns to find the title
    local title=$(echo "$disc_info" | grep -E "CINFO:2,0" | cut -d'"' -f2)
    
    # If no title found, try to extract from disc label
    if [[ -z $title ]]; then
        title=$(sudo blkid /dev/sr0 2>/dev/null | grep -o 'LABEL="[^"]*"' | cut -d'"' -f2)
    fi
    
    # Final fallback
    if [[ -z $title ]]; then
        title="Unknown_Disc_$(date +%Y%m%d_%H%M%S)"
    fi
    
    echo "$title"
}

# Function to display progress bar
show_progress() {
    local current=$1
    local total=$2
    local width=50
    
    if [ $total -eq 0 ]; then
        return
    fi
    
    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    # Build the progress bar
    printf "\r["
    printf "%${filled}s" | tr ' ' '='
    printf ">"
    printf "%${empty}s" | tr ' ' ']'
    printf "] %3d%% " $percent
}

# Function to monitor MakeMKV progress
monitor_progress() {
    local log_file="$1"
    local last_percent=0
    local spinner_index=0
    local spinners=('|' '/' '-' '\')
    
    while true; do
        if [ -f "$log_file" ]; then
            # Look for various progress patterns in MakeMKV output
            # Pattern 1: "Saving to MKV file... nn%" (for title save progress)
            local percent=$(grep -oE "Saving to MKV file.*[0-9]+%" "$log_file" | tail -1 | grep -oE "[0-9]+%" | tr -d '%')
            
            # Pattern 2: "Progress: nn/MM" or "PRGV:" format
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
            
            # Pattern 3: "Analyzing seamless segments" (shows during analysis phase)
            if [ -z "$percent" ] && grep -q "Analyzing seamless segments" "$log_file"; then
                percent=10  # Show some progress during analysis
            fi
            
            # Pattern 4: "Processing title" messages
            local title_count=$(grep -c "Processing title" "$log_file")
            if [ $title_count -gt 0 ] && [ -z "$percent" ]; then
                percent=$((title_count * 5))  # Rough estimate based on titles processed
            fi
            
            # Update progress display
            if [ ! -z "$percent" ] && [ $percent -ne $last_percent ]; then
                show_progress $percent 100
                last_percent=$percent
            else
                # Show spinner if no specific progress
                printf "\r[%s] Working... %s" "${spinners[$spinner_index]}" "$(grep -E "(Processing|Analyzing|Saving)" "$log_file" | tail -1 | cut -c1-60)"
                spinner_index=$(( (spinner_index + 1) % 4 ))
            fi
            
            # Check if ripping is complete
            if grep -q "Copy complete" "$log_file" || grep -q "Operation successfully completed" "$log_file"; then
                printf "\r%80s\r"  # Clear the line
                break
            fi
            
            # Check for errors
            if grep -q "Operation failed" "$log_file" || grep -q "Fatal error" "$log_file"; then
                printf "\r%80s\r"  # Clear the line
                break
            fi
        fi
        
        sleep 0.5
    done
}

# Function to rip disc
rip_disc() {
    local output_dir="$1"
    local title="$2"
    local log_file="$LOG_DIR/rip_${title}_$(date +%Y%m%d_%H%M%S).log"
    
    print_message $YELLOW "Starting rip of: $title"
    print_message $YELLOW "Output directory: $output_dir"
    print_message $YELLOW "Log file: $log_file"
    print_message $YELLOW "This may take 10-30 minutes depending on disc size..."
    
    # Start progress monitoring in background
    monitor_progress "$log_file" &
    local monitor_pid=$!
    
    # Rip all titles from disc with progress output
    makemkvcon mkv disc:0 all "$output_dir" --profile="$MAKEMKV_PROFILE" -r --progress=-same 2>&1 | tee "$log_file"
    local rip_status=${PIPESTATUS[0]}
    
    # Stop progress monitoring
    kill $monitor_pid 2>/dev/null
    wait $monitor_pid 2>/dev/null
    
    echo ""  # Ensure we're on a new line
    
    if [ $rip_status -eq 0 ]; then
        print_message $GREEN "Rip completed successfully!"
        return 0
    else
        print_message $RED "Rip failed! Check log file: $log_file"
        return 1
    fi
}

# Function to monitor HandBrake progress
monitor_handbrake_progress() {
    local last_percent=0
    
    while IFS= read -r line; do
        # HandBrake outputs progress as "Encoding: task 1 of 1, 45.21 %"
        if [[ $line =~ ([0-9]+\.[0-9]+)\ % ]]; then
            local percent=${BASH_REMATCH[1]%.*}  # Get integer part
            if [ $percent -ne $last_percent ]; then
                show_progress $percent 100
                last_percent=$percent
            fi
        elif [[ $line =~ "Encoding:" ]]; then
            # Show the encoding info on the same line as progress
            local info=$(echo "$line" | cut -d',' -f1-2 | cut -c1-40)
            printf "\r%s" "$info"
        fi
    done
    echo ""  # New line after completion
}

# Function to compress video with HandBrake (optional)
compress_video() {
    local input_file="$1"
    local output_file="$2"
    local preset="${3:-HQ 1080p30 Surround}"
    
    print_message $YELLOW "Compressing: $(basename "$input_file")"
    print_message $YELLOW "Using preset: $preset"
    print_message $YELLOW "This may take 30-90 minutes depending on file size..."
    
    # Run HandBrake with progress monitoring
    HandBrakeCLI -i "$input_file" -o "$output_file" --preset="$preset" 2>&1 | monitor_handbrake_progress
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        print_message $GREEN "Compression completed!"
        return 0
    else
        print_message $RED "Compression failed!"
        return 1
    fi
}

# Function to organize files
organize_files() {
    local source_dir="$1"
    local media_type="$2"
    local title="$3"
    local destination_dir
    
    if [ "$media_type" == "movie" ]; then
        destination_dir="$MOVIES_DIR/$title"
    else
        destination_dir="$TV_DIR/$title"
    fi
    
    # Clean up the title for directory naming
    title=$(echo "$title" | sed 's/[^a-zA-Z0-9._-]/ /g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    destination_dir="$MOVIES_DIR/$title"
    
    print_message $YELLOW "Creating directory: $destination_dir"
    # Try to create directory; if it fails due to permissions, prompt for sudo
    if ! mkdir -p "$destination_dir" 2>/dev/null; then
        print_message $YELLOW "Need elevated permissions to create directory..."
        # Ask for password if not already cached
        sudo mkdir -p "$destination_dir"
        sudo chown $USER:$USER "$destination_dir"
    fi
    
    # Move all MKV files to destination, rename main file
    local count=0
    for mkv_file in "$source_dir"/*.mkv; do
        if [ -f "$mkv_file" ]; then
            if [ $count -eq 0 ]; then
                # Rename first file to match the title
                mv "$mkv_file" "$destination_dir/$title.mkv"
                print_message $GREEN "Moved: $(basename "$mkv_file") -> $title.mkv"
            else
                # Keep additional files with original names
                mv "$mkv_file" "$destination_dir/"
                print_message $GREEN "Moved: $(basename "$mkv_file")"
            fi
            count=$((count + 1))
        fi
    done
    
    if [ $count -eq 0 ]; then
        print_message $RED "Warning: No MKV files found in $source_dir"
    else
        print_message $GREEN "Moved $count file(s) to: $destination_dir"
    fi
}

# Function to notify Plex to scan
notify_plex() {
    local library_type="$1"
    print_message $YELLOW "Checking for Plex library sections..."
    
    # Get library sections
    local sections=$(curl -s -H "X-Plex-Token: $(get_plex_token)" http://localhost:32400/library/sections)
    
    # Find the section ID for the library type
    local section_id=""
    if [ "$library_type" == "movie" ]; then
        section_id=$(echo "$sections" | grep -B1 'type="movie"' | grep -o 'key="[^"]*"' | cut -d'"' -f2)
    else
        section_id=$(echo "$sections" | grep -B1 'type="show"' | grep -o 'key="[^"]*"' | cut -d'"' -f2)
    fi
    
    if [ ! -z "$section_id" ]; then
        print_message $YELLOW "Triggering Plex scan for section $section_id..."
        curl -X POST "http://localhost:32400/library/sections/$section_id/refresh" \
             -H "X-Plex-Token: $(get_plex_token)" 2>/dev/null || true
    else
        print_message $YELLOW "No Plex library section found for $library_type. Please create libraries in Plex."
    fi
}

# Function to get Plex token
get_plex_token() {
    echo "your_plex_token_here"
}

# Main script
main() {
    print_message $GREEN "=== Automated DVD/Blu-ray Ripping Script ==="
    
    # Check for disc
    disc_info=$(check_disc)
    disc_title=$(get_disc_title "$disc_info")
    
    # Clean up title for filesystem
    safe_title=$(echo "$disc_title" | sed 's/[^a-zA-Z0-9._-]/_/g')
    
    # Ask user for media type
    print_message $YELLOW "Detected disc: $disc_title"
    echo "Is this a [M]ovie or [T]V Show? (M/T): "
    read -r media_choice
    
    case ${media_choice^^} in
        M)
            media_type="movie"
            final_dir="$MOVIES_DIR"
            ;;
        T)
            media_type="tv"
            final_dir="$TV_DIR"
            ;;
        *)
            print_message $RED "Invalid choice. Exiting."
            exit 1
            ;;
    esac
    
    # Allow user to override title
    echo "Enter custom title (or press Enter to use: $safe_title): "
    read -r custom_title
    if [ ! -z "$custom_title" ]; then
        safe_title=$(echo "$custom_title" | sed 's/[^a-zA-Z0-9._-]/_/g')
    fi
    
    # Create temporary directory for this rip
    rip_temp_dir="$TEMP_DIR/$safe_title"
    mkdir -p "$rip_temp_dir"
    
    # Rip the disc
    if rip_disc "$rip_temp_dir" "$safe_title"; then
        
        # Optional: Ask if user wants to compress
        echo "Do you want to compress the files with HandBrake? (y/N): "
        read -r compress_choice
        
        if [[ ${compress_choice^^} == "Y" ]]; then
            mkdir -p "$rip_temp_dir/compressed"
            local mkv_files=("$rip_temp_dir"/*.mkv)
            local total_files=${#mkv_files[@]}
            local current_file=0
            
            for mkv_file in "${mkv_files[@]}"; do
                if [ -f "$mkv_file" ]; then
                    current_file=$((current_file + 1))
                    filename=$(basename "$mkv_file")
                    print_message $YELLOW "Compressing file $current_file of $total_files: $filename"
                    compress_video "$mkv_file" "$rip_temp_dir/compressed/$filename"
                    if [ $? -eq 0 ]; then
                        rm "$mkv_file"  # Remove original if compression successful
                    fi
                fi
            done
            # Use compressed files
            mv "$rip_temp_dir/compressed"/*.mkv "$rip_temp_dir/" 2>/dev/null
            rmdir "$rip_temp_dir/compressed" 2>/dev/null
        fi
        
        # Organize files
        organize_files "$rip_temp_dir" "$media_type" "$safe_title"
        
        # Only clean up temporary directory if it's empty (files were successfully moved)
        if [ -z "$(ls -A "$rip_temp_dir")" ]; then
            rm -rf "$rip_temp_dir" 2>/dev/null
        else
            print_message $YELLOW "Warning: Files remain in temp directory: $rip_temp_dir"
            print_message $YELLOW "Please manually move them to the appropriate location."
        fi
        
        # Notify Plex
        notify_plex "$media_type"
        
        print_message $GREEN "Process completed successfully!"
        print_message $GREEN "Files are now available in Plex."
        
        # Eject disc
        eject /dev/sr0 2>/dev/null || true
        
    else
        print_message $RED "Ripping failed. Check logs for details."
        exit 1
    fi
}

# Run main function
main "$@"