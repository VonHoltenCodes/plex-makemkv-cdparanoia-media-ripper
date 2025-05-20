#!/bin/bash
# Universal disc ripping script - detects media type and runs appropriate ripper
#
# This is the main entry point for all disc ripping operations on the Zentyal server.
# It automatically detects whether an inserted disc is:
#   - Audio CD (routes to auto_rip_audio.sh)
#   - DVD (routes to auto_rip_video.sh)
#   - Blu-ray (routes to auto_rip_video.sh)
#
# Usage:
#   /home/traxx/auto_rip.sh                # Auto-detect disc type
#   /home/traxx/auto_rip.sh --video        # Force video disc mode (DVD/Blu-ray)
#   /home/traxx/auto_rip.sh --audio        # Force audio CD mode
#
# The script includes fallback options if auto-detection fails.
#
# Key improvements made:
# - Fixed DVD detection pattern (was uppercase-only, now case-insensitive)
# - Added timeout handling for slow disc detection
# - Audio CD detection happens first to avoid false DVD detection
# - Manual override options when auto-detection fails
# - Audio script now has timeout handling to prevent abcde hanging
#
# Related scripts:
# - auto_rip_video.sh: Handles DVD/Blu-ray ripping with MakeMKV
# - auto_rip_audio.sh: Handles audio CD ripping with abcde
# - plex_info.sh: Shows Plex library information
#
# Configuration:
# - Drive location: /dev/sr0 (default optical drive)
# - Plex library locations: /mnt/plexmedia/Movies, /mnt/plexmedia/Music
# - Plex token: YOUR_TOKEN_HERE (for auto-scan after ripping)

# Color codes for better terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to detect disc type
# Returns: "audio", "dvd", "bluray", or "none"
# Note: Checks audio CDs first to avoid false DVD detection on enhanced CDs
detect_disc_type() {
    # Check for audio CD first (before checking for DVD)
    # cdparanoia is used for reliable audio CD detection
    # Timeout prevents hanging on empty/bad drives
    local cd_info=$(timeout 5s cdparanoia -Q 2>&1)
    if [[ $cd_info != *"Unable to"* ]] && [[ $cd_info != *"could not"* ]]; then
        # Double-check it's really an audio CD by looking for tracks
        # Some enhanced CDs might pass initial check but not have track info
        if [[ $cd_info =~ "track" ]] || [[ $cd_info =~ "TOTAL" ]]; then
            echo "audio"
            return
        fi
    fi
    
    # Check for video disc (DVD/Blu-ray) with timeout
    # MakeMKV can take 20-30 seconds to scan complex discs
    print_message $YELLOW "Checking for DVD/Blu-ray (this may take a moment)..."
    local makemkv_info=$(timeout 20s makemkvcon info disc:0 2>&1)
    
    # Exit code 124 means timeout - drive likely empty or disc unreadable
    if [[ $? -eq 124 ]]; then
        print_message $RED "MakeMKV timed out. Drive may be empty or disc is unreadable."
        echo "none"
        return
    fi
    
    # Parse MakeMKV output to determine disc type
    # Note: MakeMKV uses case-sensitive output, so we use regex for flexibility
    if [[ $makemkv_info != *"no disc"* ]] && [[ ! -z $makemkv_info ]] && [[ $makemkv_info != *"Failed to open disc"* ]]; then
        # BDMV indicates Blu-ray disc structure
        if [[ $makemkv_info == *"BDMV"* ]]; then
            echo "bluray"
            return
        # DVDs can be identified by "Dvd" or "Mpeg" in MakeMKV output
        # Fixed from original uppercase-only pattern that missed many DVDs
        elif [[ $makemkv_info =~ [Dd][Vv][Dd] ]] || [[ $makemkv_info =~ [Mm]peg ]]; then
            echo "dvd"
            return
        fi
    fi
    
    echo "none"
}

# Function to show disc info
# Displays relevant information about the detected disc
# CINFO = disc info, TINFO = title/track info
show_disc_info() {
    local disc_type=$1
    
    case $disc_type in
        bluray)
            print_message $BLUE "Blu-ray disc detected!"
            # Show disc and title info from MakeMKV
            timeout 15s makemkvcon info disc:0 | grep -E "CINFO|TINFO" | head -10
            ;;
        dvd)
            print_message $BLUE "DVD disc detected!"
            # Show disc and title info from MakeMKV
            timeout 15s makemkvcon info disc:0 | grep -E "CINFO|TINFO" | head -10
            ;;
        audio)
            print_message $BLUE "Audio CD detected!"
            # Show track listing from cdparanoia
            cdparanoia -Q 2>&1 | grep -E "track|TOTAL"
            ;;
        *)
            print_message $RED "No disc detected or unknown disc type!"
            print_message $YELLOW "Checking disc details..."
            print_message $YELLOW "CD check:"
            timeout 5s cdparanoia -Q 2>&1 | head -5
            print_message $YELLOW "DVD/Blu-ray check:"
            timeout 10s makemkvcon info disc:0 2>&1 | head -5
            return 1
            ;;
    esac
}

# Main script
# This is the primary execution flow of the auto_rip.sh script
main() {
    print_message $GREEN "=== Universal Disc Ripping Tool ==="
    
    # Command line argument handling for manual override
    # Useful when auto-detection fails or user knows disc type
    if [ "$1" == "--video" ] || [ "$1" == "-v" ]; then
        print_message $YELLOW "Skipping detection, forcing video disc mode..."
        /home/traxx/auto_rip_video.sh
        return
    elif [ "$1" == "--audio" ] || [ "$1" == "-a" ]; then
        print_message $YELLOW "Skipping detection, forcing audio disc mode..."
        /home/traxx/auto_rip_audio.sh
        return
    fi
    
    print_message $YELLOW "Checking for inserted disc..."
    
    # Detect disc type
    disc_type=$(detect_disc_type)
    
    # Show disc information
    # If detection fails, offer manual selection
    if ! show_disc_info "$disc_type"; then
        print_message $YELLOW "Detection failed or timed out."
        echo ""
        echo "Would you like to:"
        echo "1) Try video disc ripping (DVD/Blu-ray)"
        echo "2) Try audio CD ripping"
        echo "3) Exit"
        echo ""
        echo -n "Choice (1/2/3): "
        read -r manual_choice
        
        case $manual_choice in
            1)
                print_message $YELLOW "Starting video disc ripping process..."
                /home/traxx/auto_rip_video.sh
                ;;
            2)
                print_message $YELLOW "Starting audio CD ripping process..."
                /home/traxx/auto_rip_audio.sh
                ;;
            *)
                print_message $RED "Exiting."
                exit 1
                ;;
        esac
        return
    fi
    
    # Route to appropriate script based on detected disc type
    # Both Blu-ray and DVD use the same video ripping script
    case $disc_type in
        bluray|dvd)
            print_message $YELLOW "Starting video disc ripping process..."
            /home/traxx/auto_rip_video.sh
            ;;
        audio)
            print_message $YELLOW "Starting audio CD ripping process..."
            print_message $YELLOW "Using enhanced direct rip with track skipping..."
            
            # Call our improved direct ripping script
            /home/traxx/direct_rip.sh
            ;;
        *)
            print_message $RED "Unknown disc type. Cannot proceed."
            exit 1
            ;;
    esac
}

# Quick install check
# Verifies all required tools are installed before attempting to rip
check_tools() {
    local missing=()
    
    # Check for MakeMKV (required for DVD/Blu-ray ripping)
    if ! command -v makemkvcon &> /dev/null; then
        missing+=("makemkv")
    fi
    
    # Check for CD tools (required for audio CD ripping)
    if ! command -v cdparanoia &> /dev/null; then
        missing+=("cdparanoia")
    fi
    
    # Exit if any required tools are missing
    if [ ${#missing[@]} -gt 0 ]; then
        print_message $YELLOW "Missing tools: ${missing[*]}"
        print_message $YELLOW "Please run the setup script first: /home/traxx/MAKEMKV_SETUP.md"
        exit 1
    fi
}

# Script execution starts here
# 1. First check that all required tools are installed
check_tools

# 2. Then run the main function with any command line arguments
main "$@"

# Exit codes:
# 0 - Success
# 1 - Error (missing tools, unknown disc type, user cancelled)