# DVD & Blu-ray Ripper Project Notes

## Project Overview
This repository contains scripts for automating DVD and Blu-ray ripping to a Plex media server.

## Key Scripts
- `auto_rip.sh` - Main entry point that detects disc type and routes to appropriate ripper
- `direct_ripper.sh` - Direct DVD/Blu-ray ripper for main features
- `auto_rip_video.sh` - Video-specific ripping with additional options

## Critical Parameters
- **Plex Token**: `your_plex_token_here`
- **Movie Directory**: `/mnt/plexmedia/Movies`
- **Temp Directory**: `/mnt/plexmedia/rip_temp/video`
- **Log Directory**: `/mnt/plexmedia/rip_logs`

## Development Notes
- Added better timeout handling for larger discs (2-hour timeout)
- Added direct I/O option with `--directio=true` flag
- Added elapsed time display during ripping
- Improved error handling with detailed feedback
- Added alternative ripping approach for problematic discs

## Command Formats
- MakeMKV main command:
```bash
makemkvcon -r --directio=true --progress=-same mkv disc:0 $title "$output_dir"
```

- Alternative command for problematic discs:
```bash
makemkvcon --noscan -r --progress=-same mkv disc:0 $title "$output_dir"
```

## Plex Library Update
```bash
curl -X POST "http://localhost:32400/library/sections/1/refresh" -H "X-Plex-Token: $PLEX_TOKEN"
```

## Testing Commands
```bash
# Test MakeMKV detection
timeout 30s makemkvcon info disc:0

# Check if drive is recognized
lsblk | grep rom

# See what's in the drive
sudo blkid /dev/sr0
```

## Error Codes
- Status 124: Timeout (process took too long)
- Status 12: Likely a timeout or read error

## Future Improvements
- Add HandBrake integration option for compression
- Add chapter extraction
- Add subtitle selection options
- Improve metadata tagging