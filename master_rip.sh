#!/bin/bash
# Master Rip Fixed - User-first approach with better error handling

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_ID=$(date +%Y%m%d_%H%M%S)

# Load config but don't fail if there are issues
if [ -f "$SCRIPT_DIR/rip_config.sh" ]; then
    source "$SCRIPT_DIR/rip_config.sh" 2>/dev/null || {
        echo "Warning: Config file has issues, using defaults"
        PLEX_MEDIA="/mnt/plexmedia"
        MOVIES_DIR="$PLEX_MEDIA/Movies"
        TV_DIR="$PLEX_MEDIA/TV Shows"
        MUSIC_DIR="$PLEX_MEDIA/Music"
    }
else
    echo "Warning: Config file not found, using defaults"
    PLEX_MEDIA="/mnt/plexmedia"
    MOVIES_DIR="$PLEX_MEDIA/Movies"
    TV_DIR="$PLEX_MEDIA/TV Shows"
    MUSIC_DIR="$PLEX_MEDIA/Music"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

show_help() {
    cat << EOF
Master Ripping Script - User-First Approach

USAGE: $0

WORKFLOW:
1. Select what you want to rip
2. Choose destination  
3. Customize title
4. Rip directly!

No detection delays or hanging on copy-protected discs!
EOF
}

main() {
    # Handle help
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        show_help
        exit 0
    fi

    print_success "=== Master Ripping System v3.0 ==="
    print_info "Session: $SESSION_ID"
    echo ""
    
    print_info "What would you like to rip?"
    echo ""
    echo "  1) Audio CD → FLAC files → Music library"
    echo "  2) DVD/Blu-ray Movie → MKV files → Movies library"  
    echo "  3) DVD/Blu-ray TV Show → MKV files → TV Shows library"
    echo "  4) DVD/Blu-ray Custom → MKV files → Custom location"
    echo ""
    
    # Get choice with timeout fallback
    echo -n "Choice [1-4]: "
    if read -t 30 -r choice; then
        echo ""
    else
        echo ""
        print_error "Input timeout or error - exiting"
        exit 1
    fi
    
    # Process choice
    case "$choice" in
        1)
            media_type="audio"
            destination="$MUSIC_DIR"
            ;;
        2)
            media_type="video_movie"
            destination="$MOVIES_DIR"
            ;;
        3)
            media_type="video_tv"
            destination="$TV_DIR"
            ;;
        4)
            media_type="video_custom"
            echo ""
            echo -n "Custom path (relative to $PLEX_MEDIA): "
            if read -t 30 -r custom_path; then
                echo ""
                if [ -z "$custom_path" ]; then
                    destination="$MOVIES_DIR"
                    print_warning "No path entered, using Movies"
                else
                    destination="$PLEX_MEDIA/$custom_path"
                fi
            else
                print_error "Input timeout"
                exit 1
            fi
            ;;
        *)
            print_error "Invalid choice: $choice"
            exit 1
            ;;
    esac
    
    # Get title
    echo ""
    echo -n "Custom title (or Enter for auto-detect): "
    if read -t 30 -r title; then
        echo ""
    else
        echo ""
        title="auto"
    fi
    
    if [ -z "$title" ]; then
        title="auto"
    fi
    
    # Show summary
    echo ""
    print_info "=== Ripping Plan ==="
    echo "Type: $media_type"
    echo "Destination: $destination"
    echo "Title: $title"
    echo ""
    
    echo -n "Proceed? [Y/n]: "
    if read -t 15 -r confirm; then
        echo ""
    else
        echo ""
        confirm="Y"
    fi
    
    case ${confirm^^} in
        ""|"Y"|"YES")
            print_success "Starting rip process..."
            
            # Route to appropriate script
            case "$media_type" in
                "audio")
                    if [ -f "$SCRIPT_DIR/audio_ripper.sh" ]; then
                        exec "$SCRIPT_DIR/audio_ripper.sh" "$SESSION_ID" "$title"
                    else
                        print_error "Audio ripper not found"
                        exit 1
                    fi
                    ;;
                "video_"*)
                    if [ -f "$SCRIPT_DIR/video_ripper.sh" ]; then
                        # Convert media_type to format video_ripper expects
                        case "$media_type" in
                            "video_movie") exec "$SCRIPT_DIR/video_ripper.sh" "$SESSION_ID" "movie" "$title" ;;
                            "video_tv") exec "$SCRIPT_DIR/video_ripper.sh" "$SESSION_ID" "tv" "$title" ;;
                            "video_custom") exec "$SCRIPT_DIR/video_ripper.sh" "$SESSION_ID" "custom" "$title" "$destination" ;;
                        esac
                    else
                        print_error "Video ripper not found"
                        exit 1
                    fi
                    ;;
            esac
            ;;
        *)
            print_info "Cancelled"
            exit 0
            ;;
    esac
}

main "$@"