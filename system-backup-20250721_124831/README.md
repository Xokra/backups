# Enhanced System Backup - Mon Jul 21 12:48:09 +07 2025

## Philosophy
This backup focuses on **your personal computing environment** - only the tools you actually chose to install, not system noise.


## Quick Restore

```bash
./restore.sh
```

## What Gets Backed Up


✅ **Your curated tools**: Development environment, CLI utilities  
✅ **Dotfile dependencies**: Tools your configs require  
✅ **Language packages**: cargo, pip --user, npm -g  
✅ **Manual choices**: Homebrew (macOS), AUR (Arch)  
❌ **System noise**: Base packages, auto-dependencies


## Mason & Language Servers

This script installs **nodejs** (which includes npm), but Mason installs language servers locally in:
- `~/.local/share/nvim/mason/`

After restoring, run `:MasonInstall <package>` in Neovim to reinstall language servers.


## Features


- 🎯 Smart package detection (20-50 packages vs hundreds)
- 🔄 Cross-platform name translation  
- 🎨 Auto Nerd Fonts + Zsh setup
- 📋 Dotfile dependency scanning
- 🔧 Auto package manager bootstrapping


**Platform**: wsl | **Date**: Mon Jul 21 12:48:09 +07 2025
