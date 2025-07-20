# Enhanced System Backup with Nerd Fonts - Sun Jul 20 09:55:10 +07 2025


## Quick Start
```bash
# 1. Install essential packages first (see ESSENTIALS.txt)
# 2. Clone this backup

git clone <your-backup-repo>

cd <backup-folder>


# 3. Restore everything (includes Nerd Fonts + Zsh setup)
./restore.sh
```

## What's Backed Up & Restored
- **Package Managers**: APT, Snap, Homebrew, Cargo, pip, npm, Flatpak, AUR, MAS

- **System Info**: Platform, version, architecture
- **Nerd Fonts**: Auto-detects latest version and installs Meslo

- **Zsh Configuration**: Sets Zsh as default shell
- **Smart Detection**: Automatically handles platform differences

## Special Features

- **WSL + Windows Alacritty**: Installs fonts to Windows (system or user directory)
- **Permission handling**: Falls back gracefully if no admin access
- **Auto-version detection**: Always gets latest Nerd Fonts release

- **Cross-platform**: Same script works on all supported platforms

## Font Installation Details
For WSL users with Windows Alacritty:
1. Tries  first (requires admin)
2. Falls back to  (user directory)
3. If both fail, installs locally (fonts won't be visible to Alacritty)


## Backup Contents
- `restore.sh` - Main restore script (cross-platform)
- `config/` - Package lists and system info

- `ESSENTIALS.txt` - Must-install packages before restore


## Original System
- **Platform**: wsl  
- **Date**: Sun Jul 20 09:55:10 +07 2025

- **Hostname**: ZedOcean


## Supported Platforms

✅ WSL (Ubuntu/Debian) - with Windows Alacritty font support  

✅ macOS (with Homebrew)  
✅ Arch Linux (with AUR)  


## Post-Install Manual Steps
1. Restart terminal/Alacritty to use new fonts

2. Restore your dotfiles
3. Firefox: Settings > General > Startup > "Open previous windows and tabs"
4. Verify shell: `echo $SHELL` (should show zsh path)

## Font Configuration

For Alacritty on Windows (WSL), use this config in `C:\Users\<username>\AppData\Roaming\Alacritty\alacritty.toml`:
```toml
[shell]
program = "wsl.exe"

args = ["~", "-d", "Ubuntu-24.04"]


[font]
normal.family = "MesloLGLDZ Nerd Font"
size = 10.5
```

## Notes
- The restore script auto-detects your current platform
- Missing package managers are automatically installed
- Failed packages are logged but don't stop the process
- Nerd Fonts are installed to the appropriate system location
- Zsh is automatically configured as default shell
