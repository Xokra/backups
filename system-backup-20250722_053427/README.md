# Enhanced System Backup - Tue Jul 22 05:34:30 +07 2025


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

**Platform**: wsl

## Backup Contents

### System Packages
- **Curated tools**: 16 packages
```
  curl
  fontconfig
  git
  htop
  jq
  lazygit
  less
  neovim
  nodejs
  python-pip
  ... and 6 more
```


- **Dotfile dependencies**: 4 packages
```
  git
  neovim
  tmux
  zsh
```


### Language Package Managers
- **Cargo**: None found
- **Pip**: None found
- **Npm**: None found


### Platform-Specific
- **Package source**: APT (curated list only)


## Files Created

- `restore.sh` - Automated restore script
- `config/` - Package lists and system info
- `README.md` - This documentation

## Notes

- **Font**: Meslo Nerd Font will be installed automatically
- **Shell**: Zsh will be configured as default shell
- **Mason**: Run `:MasonInstall <package>` after Neovim setup
- **Dotfiles**: Restore separately (not included in this backup)
