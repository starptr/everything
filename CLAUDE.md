# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Structure

This is a personal monorepo containing various infrastructure and system configurations, primarily managed with Nix. The repository is organized into several key areas:

- **jupiter/**: DNS and infrastructure management using Pulumi (Python) and octodns
- **venus/**: macOS system configuration using nix-darwin and home-manager
- **experimental/**: Development projects including soup (NUR repository), mv-nix (Rust tool), and legacy configs
- **whale/**: Container/deployment configurations
- **secrets/**: Configuration files for sensitive data
- **flake-profiles/**: Nix flake configurations for different development environments

## Development Environment Setup

The primary development workflow uses Nix and devenv:

```bash
# Enter the main development shell
nix develop ./flake-profiles/everything-devenv --impure

# Enter Jupiter-specific shell (for DNS/infrastructure work)
nix develop ./flake-profiles/everything-devenv#jupiter --impure

# Build specific packages
nix run ./flake-profiles/build-dns-config#build-dns-config
```

## Key Commands

### Jupiter (Infrastructure Management)
Jupiter handles DNS configuration and DigitalOcean infrastructure via Pulumi:
- **DNS Management**: Uses octodns with template files in `octodns-config-template/`
- **Infrastructure**: Manages DigitalOcean droplets, volumes, and networking
- **Build DNS Config**: `build-dns-config` tool generates octodns YAML from templates

### Venus (macOS System Management)
Venus provides nix-darwin configuration for macOS systems:
```bash
# Apply system configuration (example for sodium machine)
darwin-rebuild switch --flake ~/src/venus/flake-profiles/sodium

# Enable direnv in repository root
ln -s flake-profiles/sodium/link-to-this-from-venus-root.envrc .envrc
direnv allow
```

### Experimental Projects
- **soup**: Personal NUR (Nix User Repository) with custom packages
- **mv-nix**: Rust CLI tool for moving files while updating relative paths in Nix files
- **jellyfin-mpv-shim-darwin-compat**: macOS compatibility layer

## Version Control

**Important**: This repository uses Jujutsu (jj) as the primary VCS, not Git:
- Use `jj new` to create a new change before making modifications
- Git is present but Jujutsu is preferred for development workflow

## Architecture Notes

### Nix Configuration Architecture
- **Flake-based**: Uses Nix flakes for reproducible builds and development environments
- **Modular Design**: Home-manager and nix-darwin configurations are split into reusable modules
- **Machine-specific Profiles**: Different configurations for different machines (sodium, hydrogen-sulfide, etc.)
- **Shared Constants**: Common configuration in `magic/` directory

### Infrastructure as Code
- **Pulumi**: Python-based infrastructure definitions for cloud resources
- **octodns**: DNS management with YAML configuration files
- **Template-based**: DNS configs generated from templates for consistency

### Package Management
- **Custom Packages**: Soup NUR repository contains personal package definitions
- **Overlays**: Custom package overlays for extending nixpkgs
- **Cachix**: Binary cache setup for faster builds

## Important Files

- `flake-profiles/outputs.nix`: Main flake outputs combining all projects
- `jupiter/__main__.py`: Pulumi infrastructure definitions
- `venus/modules/`: Reusable nix-darwin and home-manager modules
- `experimental/soup/`: Personal NUR repository with custom packages
- `secrets/`: Contains sensitive configuration (handle with care)

## Project-Specific Notes

### Jupiter Project Structure
- Uses Python 3.12 with virtual environment managed by devenv
- Generates JSON files for server configurations
- Template-based DNS configuration system
- Pulumi manages DigitalOcean resources (droplets, volumes, networking)

### Venus System Configuration
- Supports multiple machine profiles (sodium, hydrogen-sulfide, etc.)
- Integrates fish shell with Tide prompt
- Includes dotfile management for various applications (alacritty, mpv, etc.)
- Uses sops-nix for secrets management