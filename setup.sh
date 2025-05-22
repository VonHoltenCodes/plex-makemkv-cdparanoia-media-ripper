#!/bin/bash
# Master Rip System Setup Script
# 
# This script helps initialize the master_rip system by:
# - Checking dependencies
# - Creating required directories
# - Setting up secure password storage
# - Validating configuration
# - Running initial tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
if [ -f "$SCRIPT_DIR/rip_config.sh" ]; then
    source "$SCRIPT_DIR/rip_config.sh"
else
    echo "ERROR: Configuration file not found: $SCRIPT_DIR/rip_config.sh"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check if running as root
check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        print_error "This script should not be run as root"
        exit 1
    fi
}

# Check system dependencies
check_dependencies() {
    print_header "Checking Dependencies"
    
    local missing_critical=()
    local missing_optional=()
    
    # Critical dependencies
    local critical_tools="cdparanoia flac metaflac cd-discid makemkvcon curl"
    for tool in $critical_tools; do
        if command -v "$tool" &> /dev/null; then
            print_success "$tool found"
        else
            missing_critical+=("$tool")
            print_error "$tool not found"
        fi
    done
    
    # Optional dependencies
    local optional_tools="HandBrakeCLI eject"
    for tool in $optional_tools; do
        if command -v "$tool" &> /dev/null; then
            print_success "$tool found (optional)"
        else
            missing_optional+=("$tool")
            print_warning "$tool not found (optional)"
        fi
    done
    
    if [ ${#missing_critical[@]} -gt 0 ]; then
        echo ""
        print_error "Missing critical dependencies: ${missing_critical[*]}"
        echo ""
        print_info "Install with:"
        echo "sudo apt update"
        echo "sudo apt install cdparanoia flac metaflac cd-discid curl"
        echo ""
        print_info "For MakeMKV, follow the guide in /home/traxx/MAKEMKV_SETUP.md"
        return 1
    fi
    
    if [ ${#missing_optional[@]} -gt 0 ]; then
        echo ""
        print_warning "Missing optional dependencies: ${missing_optional[*]}"
        print_info "Install with: sudo apt install handbrake-cli eject"
    fi
    
    return 0
}

# Check hardware
check_hardware() {
    print_header "Checking Hardware"
    
    # Check optical drive
    if [ -e "$OPTICAL_DRIVE" ]; then
        print_success "Optical drive found: $OPTICAL_DRIVE"
        
        # Check permissions
        if [ -r "$OPTICAL_DRIVE" ]; then
            print_success "Drive is readable"
        else
            print_error "Drive is not readable (permission issue)"
            print_info "Add user to cdrom group: sudo usermod -a -G cdrom $USER"
            return 1
        fi
        
        # Check if drive is in use
        if lsof "$OPTICAL_DRIVE" &>/dev/null; then
            print_warning "Drive appears to be in use by another process"
        fi
        
    else
        print_error "Optical drive not found: $OPTICAL_DRIVE"
        print_info "Available drives:"
        lsblk | grep rom || echo "No ROM drives found"
        return 1
    fi
    
    return 0
}

# Create required directories
create_directories() {
    print_header "Creating Directories"
    
    local directories=(
        "$PLEX_MEDIA"
        "$TEMP_DIR"
        "$LOG_DIR"
        "$MOVIES_DIR"
        "$TV_DIR" 
        "$MUSIC_DIR"
        "$VIDEO_TEMP"
        "$AUDIO_TEMP"
    )
    
    for dir in "${directories[@]}"; do
        if [ -d "$dir" ]; then
            print_success "Directory exists: $dir"
        else
            print_info "Creating directory: $dir"
            if mkdir -p "$dir" 2>/dev/null; then
                print_success "Created: $dir"
            elif sudo mkdir -p "$dir" && sudo chown "$USER:$USER" "$dir"; then
                print_success "Created with sudo: $dir"
            else
                print_error "Failed to create: $dir"
                return 1
            fi
        fi
        
        # Check write permissions
        if [ -w "$dir" ]; then
            print_success "Directory is writable: $dir"
        else
            print_warning "Directory is not writable: $dir"
        fi
    done
    
    return 0
}

# Setup secure password storage
setup_password() {
    print_header "Setting Up Secure Password Storage"
    
    if [ -f "$SUDO_PASS_FILE" ]; then
        print_success "Sudo password file already exists"
        print_info "File permissions: $(ls -la "$SUDO_PASS_FILE" | cut -d' ' -f1)"
        
        # Check permissions
        local perms=$(stat -c %a "$SUDO_PASS_FILE" 2>/dev/null || stat -f %A "$SUDO_PASS_FILE" 2>/dev/null)
        if [ "$perms" = "600" ]; then
            print_success "Password file permissions are secure"
        else
            print_warning "Password file permissions should be 600"
            print_info "Fix with: chmod 600 $SUDO_PASS_FILE"
        fi
    else
        echo ""
        print_info "The master_rip system needs to store your sudo password securely"
        print_info "This is used for creating directories and setting permissions"
        echo ""
        echo -n "Do you want to set up secure password storage? (y/N): "
        read -r setup_pass
        
        if [[ ${setup_pass^^} == "Y" ]]; then
            echo ""
            echo -n "Enter your sudo password: "
            read -s password
            echo ""
            
            # Test the password
            if echo "$password" | sudo -S echo "Password test" >/dev/null 2>&1; then
                echo "$password" > "$SUDO_PASS_FILE"
                chmod 600 "$SUDO_PASS_FILE"
                print_success "Password stored securely at: $SUDO_PASS_FILE"
            else
                print_error "Password verification failed"
                return 1
            fi
        else
            print_warning "Password storage skipped - some operations may require manual sudo"
            print_info "You can set this up later with:"
            print_info "echo 'your_password' > $SUDO_PASS_FILE && chmod 600 $SUDO_PASS_FILE"
        fi
    fi
    
    return 0
}

# Check Plex integration
check_plex() {
    print_header "Checking Plex Integration"
    
    # Check if Plex is running (check both regular and snap services)
    if systemctl is-active --quiet plexmediaserver || systemctl is-active --quiet snap.plexmediaserver.plexmediaserver; then
        print_success "Plex Media Server is running"
    else
        print_error "Plex Media Server is not running"
        print_info "Start with: sudo systemctl start plexmediaserver"
        print_info "Or if using snap: sudo systemctl start snap.plexmediaserver.plexmediaserver"
        return 1
    fi
    
    # Check Plex API access
    local response=$(curl -s -w "%{http_code}" -o /dev/null \
                     -H "X-Plex-Token: $PLEX_TOKEN" \
                     "$PLEX_URL/library/sections" 2>/dev/null)
    
    if [ "$response" = "200" ]; then
        print_success "Plex API access working"
        
        # Show library sections
        local sections=$(curl -s -H "X-Plex-Token: $PLEX_TOKEN" "$PLEX_URL/library/sections" 2>/dev/null)
        if [ ! -z "$sections" ]; then
            print_info "Available library sections:"
            echo "$sections" | grep -o 'title="[^"]*"' | cut -d'"' -f2 | sed 's/^/  - /'
        fi
    else
        print_error "Plex API access failed (HTTP $response)"
        print_info "Check token and URL in rip_config.sh"
        return 1
    fi
    
    return 0
}

# Run configuration validation
validate_configuration() {
    print_header "Validating Configuration"
    
    if validate_config; then
        print_success "Configuration validation passed"
        return 0
    else
        print_error "Configuration validation failed"
        return 1
    fi
}

# Test disc detection
test_detection() {
    print_header "Testing Disc Detection"
    
    print_info "Insert a test disc (audio CD, DVD, or Blu-ray) and press Enter..."
    print_info "Or press Enter to skip this test"
    read -r
    
    print_info "Running detection test..."
    if "$SCRIPT_DIR/master_rip.sh" --test; then
        print_success "Disc detection test completed"
    else
        print_warning "Disc detection test failed or no disc found"
        print_info "This is normal if no disc is inserted"
    fi
}

# Main setup function
main() {
    echo ""
    print_header "Master Rip System Setup"
    echo ""
    print_info "This script will set up the master_rip system"
    print_info "Setup location: $SCRIPT_DIR"
    echo ""
    
    # Check we're not running as root
    check_not_root
    
    local setup_failed=false
    
    # Run all setup steps
    if ! check_dependencies; then
        setup_failed=true
    fi
    echo ""
    
    if ! check_hardware; then
        setup_failed=true
    fi
    echo ""
    
    if ! create_directories; then
        setup_failed=true
    fi
    echo ""
    
    if ! setup_password; then
        setup_failed=true
    fi
    echo ""
    
    if ! check_plex; then
        setup_failed=true
    fi
    echo ""
    
    if ! validate_configuration; then
        setup_failed=true
    fi
    echo ""
    
    # Summary
    print_header "Setup Summary"
    
    if [ "$setup_failed" = "true" ]; then
        print_error "Setup completed with errors"
        print_info "Please fix the issues above before using the system"
        echo ""
        print_info "You can run this setup script again after fixing issues"
        exit 1
    else
        print_success "Setup completed successfully!"
        echo ""
        print_info "Next steps:"
        print_info "1. Insert a test disc"
        print_info "2. Run: $SCRIPT_DIR/master_rip.sh --test"
        print_info "3. If test passes, run: $SCRIPT_DIR/master_rip.sh"
        echo ""
        print_info "For help: $SCRIPT_DIR/master_rip.sh --help"
        
        # Offer to run detection test
        echo ""
        echo -n "Run disc detection test now? (y/N): "
        read -r run_test
        
        if [[ ${run_test^^} == "Y" ]]; then
            echo ""
            test_detection
        fi
    fi
}

# Run main function
main "$@"