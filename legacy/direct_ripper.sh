#!/bin/bash
# Simple, direct DVD ripper for Plex
# Focus on main feature only

# Configuration
PLEX_DIR="/mnt/plexmedia/Movies"
TEMP_DIR="/mnt/plexmedia/rip_temp/video"
LOG_DIR="/mnt/plexmedia/rip_logs"
PLEX_TOKEN="your_plex_token_here"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Print colored message
echo_color() {
    echo -e "${1}${2}${NC}"
}

# Create temp dir
mkdir -p "$TEMP_DIR"

# Clear the screen
clear

# Title
echo_color $GREEN "==== Direct DVD Ripper for Plex ===="
echo_color $GREEN "This script rips only the main feature"
echo_color $GREEN "==============================="
echo

# Step 1: Get disc info
echo_color $YELLOW "Step 1: Scanning disc for titles..."
echo

# Direct MakeMKV title scan
title_output=$(timeout 60s makemkvcon -r info disc:0 2>&1)

# Extract titles with durations
echo_color $BLUE "Available titles on disc:"
echo_color $BLUE "-------------------------------------------"

# Parse title information
title_info=()
longest_title=0
longest_seconds=0

while read -r line; do
    if [[ $line =~ MSG:3028.*Title\ #([0-9]+)\ was\ added.*\(([0-9]+)\ cell.*\ ([0-9]+:[0-9]+:[0-9]+)\) ]]; then
        title_num="${BASH_REMATCH[1]}"
        cells="${BASH_REMATCH[2]}"
        duration="${BASH_REMATCH[3]}"
        
        # Calculate seconds
        hours=$(echo $duration | cut -d: -f1)
        minutes=$(echo $duration | cut -d: -f2)
        seconds=$(echo $duration | cut -d: -f3)
        total_seconds=$((hours*3600 + minutes*60 + seconds))
        
        # Store in array
        title_info[$title_num]="$duration"
        
        # Display to user
        echo_color $BLUE "Title #$title_num - Duration: $duration ($cells cells)"
        
        # Check if longest
        if [ $total_seconds -gt $longest_seconds ]; then
            longest_seconds=$total_seconds
            longest_title=$title_num
        fi
    fi
done <<< "$title_output"

echo_color $BLUE "-------------------------------------------"

# Check if we found any titles
if [ ${#title_info[@]} -eq 0 ]; then
    echo_color $RED "Error: No valid titles found on disc!"
    exit 1
fi

# Display recommendation
if [ $longest_title -gt 0 ]; then
    echo_color $GREEN "Recommended title: #$longest_title (${title_info[$longest_title]})"
fi

# Step 2: Get user selection
echo
echo_color $YELLOW "Step 2: Select title to rip"
echo -n "Enter title number (or press Enter for recommended #$longest_title): "
read title_choice

# Use default if empty
if [ -z "$title_choice" ]; then
    title_choice=$longest_title
fi

# Validate
if [[ ! "$title_choice" =~ ^[0-9]+$ ]]; then
    echo_color $RED "Error: Invalid title number"
    exit 1
fi

# Check if title exists in our list
if [ -z "${title_info[$title_choice]}" ]; then
    echo_color $RED "Error: Title #$title_choice not found on disc"
    echo_color $YELLOW "Please choose one of the available titles"
    exit 1
fi

# Step 3: Get movie name
echo
echo_color $YELLOW "Step 3: Movie title"
# Get current disc label
disc_label=$(blkid /dev/sr0 2>/dev/null | grep -o 'LABEL="[^"]*"' | cut -d'"' -f2)
if [ -z "$disc_label" ]; then
    disc_label="MOVIE_$(date +%Y%m%d)"
fi

echo -n "Enter movie name (or press Enter for '$disc_label'): "
read movie_name

# Use default if empty
if [ -z "$movie_name" ]; then
    movie_name="$disc_label"
fi

# Clean up name for filesystem
safe_name=$(echo "$movie_name" | tr -d '/\\')

# Step 4: Rip selected title
echo
echo_color $YELLOW "Step 4: Ripping title #$title_choice to temp directory"
echo_color $YELLOW "This will take 10-30 minutes depending on disc size..."

# Create temp directory
temp_movie_dir="$TEMP_DIR/$safe_name"
mkdir -p "$temp_movie_dir"

# Zero-indexed title for MakeMKV
makemkv_index=$((title_choice - 1))

# Start ripping with a spinner
echo_color $YELLOW "Starting ripper..."

# Create log file
log_file="$LOG_DIR/rip_${safe_name}_$(date +%Y%m%d_%H%M%S).log"

# Show more detailed command
echo_color $YELLOW "Running: makemkvcon -r --directio=true --progress=-same mkv disc:0 $makemkv_index \"$temp_movie_dir\""

# Start MakeMKV with direct I/O option for better reliability
# Use a very long timeout to handle large discs (2 hours)
timeout 7200 makemkvcon -r --directio=true --progress=-same mkv disc:0 $makemkv_index "$temp_movie_dir" > "$log_file" 2>&1 &
rip_pid=$!

# Show spinner with elapsed time
spin='-\|/'
i=0
start_time=$(date +%s)
while kill -0 $rip_pid 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    minutes=$((elapsed / 60))
    seconds=$((elapsed % 60))
    
    # Format time
    if [ $minutes -lt 10 ]; then
        minutes="0$minutes"
    fi
    if [ $seconds -lt 10 ]; then
        seconds="0$seconds"
    fi
    
    printf "\r[%c] Ripping in progress... Time: %s:%s" "${spin:$i:1}" "$minutes" "$seconds"
    sleep 1
done
printf "\r                                                \r"

# Show last few lines of log for debugging
echo_color $YELLOW "Last log entries:"
tail -n 5 "$log_file"

# Check if process was successful
wait $rip_pid
rip_status=$?

if [ $rip_status -ne 0 ]; then
    echo_color $RED "Error: Ripping failed with status $rip_status"
    echo_color $YELLOW "Checking log file for errors..."
    
    # Show more log details
    echo_color $RED "Error details:"
    grep -i "error\|fail\|abort\|status" "$log_file" | tail -n 10
    
    # If status 124, it's likely a timeout
    if [ $rip_status -eq 124 ]; then
        echo_color $YELLOW "It appears the process timed out. This can happen with larger or complex discs."
    fi
    
    # Ask if user wants to try alternative approach
    echo
    echo_color $YELLOW "Would you like to try an alternative ripping approach? (y/n)"
    read -r try_alt
    
    if [[ $try_alt =~ ^[Yy] ]]; then
        echo_color $GREEN "Trying alternative approach with minimal settings..."
        
        # Try without direct I/O and with minimal options
        echo_color $YELLOW "Running: makemkvcon --noscan -r --progress=-same mkv disc:0 $makemkv_index \"$temp_movie_dir\""
        
        # Start MakeMKV with minimal options and longer timeout
        echo_color $YELLOW "This alternative method will run for up to 3 hours if needed..."
        timeout 10800 makemkvcon --noscan -r --progress=-same mkv disc:0 $makemkv_index "$temp_movie_dir" > "${log_file}.retry" 2>&1 &
        alt_pid=$!
        
        # Show spinner with elapsed time for alternative approach
        i=0
        start_time=$(date +%s)
        while kill -0 $alt_pid 2>/dev/null; do
            i=$(( (i+1) % 4 ))
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))
            minutes=$((elapsed / 60))
            seconds=$((elapsed % 60))
            
            # Format time
            if [ $minutes -lt 10 ]; then
                minutes="0$minutes"
            fi
            if [ $seconds -lt 10 ]; then
                seconds="0$seconds"
            fi
            
            printf "\r[%c] Alternative ripping in progress... Time: %s:%s" "${spin:$i:1}" "$minutes" "$seconds"
            sleep 1
        done
        printf "\r                                                              \r"
        
        # Check if alternative process was successful
        wait $alt_pid
        alt_status=$?
        
        if [ $alt_status -eq 0 ]; then
            echo_color $GREEN "Alternative approach succeeded!"
            # Continue processing
        else
            echo_color $RED "Alternative approach also failed with status $alt_status"
            echo_color $RED "Error details from alternative attempt:"
            grep -i "error\|fail\|abort" "${log_file}.retry" | tail -n 10
            echo_color $RED "Please check disc for damage or try another disc"
            exit 1
        fi
    else
        echo_color $RED "Ripping aborted. Please check disc for damage or try another disc"
        exit 1
    fi
fi

# Check if files were created
mkv_files=("$temp_movie_dir"/*.mkv)
if [ ${#mkv_files[@]} -eq 0 ] || [ ! -f "${mkv_files[0]}" ]; then
    echo_color $RED "Error: No MKV files were created"
    exit 1
fi

echo_color $GREEN "Ripping completed successfully!"

# Step 5: Move to Plex
echo
echo_color $YELLOW "Step 5: Moving to Plex library"

# Create movie directory
plex_movie_dir="$PLEX_DIR/$safe_name"
mkdir -p "$plex_movie_dir"

# Find the largest file (if multiple)
largest_file=""
largest_size=0

for file in "$temp_movie_dir"/*.mkv; do
    if [ -f "$file" ]; then
        file_size=$(stat -c %s "$file")
        
        if [ $file_size -gt $largest_size ]; then
            largest_size=$file_size
            largest_file="$file"
        fi
    fi
done

# If no largest file found
if [ -z "$largest_file" ]; then
    echo_color $RED "Error: Could not find largest file"
    exit 1
fi

# Calculate size in MB
size_mb=$((largest_size / 1024 / 1024))
echo_color $GREEN "Main feature identified: $(basename "$largest_file") ($size_mb MB)"

# Move largest file (main feature)
echo_color $YELLOW "Moving main feature to Plex..."
mv "$largest_file" "$plex_movie_dir/$safe_name.mkv"

# Check if move was successful
if [ ! -f "$plex_movie_dir/$safe_name.mkv" ]; then
    echo_color $RED "Error: Failed to move file to Plex"
    exit 1
fi

echo_color $GREEN "File moved successfully to: $plex_movie_dir/$safe_name.mkv"

# Clean up any remaining files (bonus features)
echo_color $YELLOW "Removing bonus features..."
rm -f "$temp_movie_dir"/*.mkv
rmdir "$temp_movie_dir" 2>/dev/null

# Step 6: Update Plex
echo
echo_color $YELLOW "Step 6: Updating Plex library"
curl -s -X POST "http://localhost:32400/library/sections/1/refresh" -H "X-Plex-Token: $PLEX_TOKEN" > /dev/null

# Done!
echo
echo_color $GREEN "=== Process completed successfully! ==="
echo_color $GREEN "Movie: $safe_name is now available in Plex"

# Show summary of key information
echo
echo_color $BLUE "====== SUMMARY ======"
echo_color $BLUE "Title ripped: #$title_choice (${title_info[$title_choice]})"
echo_color $BLUE "Final file: $plex_movie_dir/$safe_name.mkv"
echo_color $BLUE "File size: $size_mb MB"
echo_color $BLUE "Log file: $log_file"
echo_color $BLUE "===================="

# Eject disc
eject /dev/sr0 2>/dev/null || true
echo