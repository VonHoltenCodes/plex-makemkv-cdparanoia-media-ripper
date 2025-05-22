#!/bin/bash
# Central configuration for master ripping system
# Source this file in other scripts: source "$(dirname "$0")/rip_config.sh"

# === PATHS ===
PLEX_MEDIA="/mnt/plexmedia"
TEMP_DIR="$PLEX_MEDIA/rip_temp"
LOG_DIR="$PLEX_MEDIA/rip_logs"
MOVIES_DIR="$PLEX_MEDIA/Movies"
TV_DIR="$PLEX_MEDIA/TV Shows"
MUSIC_DIR="$PLEX_MEDIA/Music"

# Temp subdirectories
VIDEO_TEMP="$TEMP_DIR/video"
AUDIO_TEMP="$TEMP_DIR/audio"

# === DEVICES ===
OPTICAL_DRIVE="/dev/sr0"

# === PLEX SETTINGS ===
PLEX_TOKEN="YOUR_PLEX_TOKEN_HERE"
PLEX_URL="http://localhost:32400"
PLEX_MOVIES_SECTION="1"
PLEX_TV_SECTION="2" 
PLEX_MUSIC_SECTION="3"

# === ENCODING SETTINGS ===
OUTPUT_FORMAT="flac"  # flac, mp3, ogg
MP3_QUALITY="320"     # kbps for MP3
HANDBRAKE_PRESET="HQ 1080p30 Surround"

# === TIMEOUTS ===
DISC_DETECT_TIMEOUT=10
TRACK_RIP_TIMEOUT=120
MAKEMKV_TIMEOUT=60

# === RETRY SETTINGS ===
MAX_RETRY_ATTEMPTS=3
RETRY_DELAY=2

# === CDDB SETTINGS ===
CDDB_SERVER="gnudb.gnudb.org"
CDDB_TIMEOUT=10

# === SECURITY ===
# Use sudo password file instead of hardcoding
SUDO_PASS_FILE="$HOME/.rip_sudo_pass"

# === COLOR CODES ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# === LOGGING ===
LOG_LEVEL="INFO"  # DEBUG, INFO, WARN, ERROR
MAX_LOG_SIZE="10M"
MAX_LOG_FILES=5

# === FEATURES ===
ENABLE_PROGRESS_BARS=true
ENABLE_AUTO_EJECT=true
ENABLE_PLEX_NOTIFICATIONS=true
ENABLE_COMPRESSION_PROMPT=true

# Function to get sudo password securely
get_sudo_password() {
    if [ -f "$SUDO_PASS_FILE" ]; then
        cat "$SUDO_PASS_FILE"
    else
        echo "ERROR: Sudo password file not found at $SUDO_PASS_FILE" >&2
        echo "Create it with: echo 'your_password' > $SUDO_PASS_FILE && chmod 600 $SUDO_PASS_FILE" >&2
        return 1
    fi
}

# Validate configuration
validate_config() {
    local errors=0
    
    # Check required directories
    for dir in "$PLEX_MEDIA" "$TEMP_DIR" "$LOG_DIR"; do
        if [ ! -d "$dir" ]; then
            echo "ERROR: Required directory not found: $dir" >&2
            ((errors++))
        fi
    done
    
    # Check optical drive
    if [ ! -e "$OPTICAL_DRIVE" ]; then
        echo "ERROR: Optical drive not found: $OPTICAL_DRIVE" >&2
        ((errors++))
    fi
    
    # Check sudo password file exists
    if [ ! -f "$SUDO_PASS_FILE" ]; then
        echo "WARNING: Sudo password file not found: $SUDO_PASS_FILE" >&2
        echo "Some operations may require manual password entry" >&2
    fi
    
    return $errors
}