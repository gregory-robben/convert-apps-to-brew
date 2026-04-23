#!/bin/bash

# Directory where applications are typically installed on macOS
APPS_DIR="/Applications"

# Configuration
MODE="convert"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/convert-apps-to-brew"
CANDIDATES_FILE="$CONFIG_DIR/Brewfile.candidates"
ALIASES_FILE="$CONFIG_DIR/aliases.conf"
BACKUP_DIR=""

# Store aliases as parallel arrays (bash 3 compatible)
ALIAS_APPS=()
ALIAS_PACKAGES=()

# Initialize arrays for results
INSTALLED_VIA_BREW=()
ALREADY_INSTALLED_VIA_BREW=()
UNABLE_TO_INSTALL=()
FAILED_TO_INSTALL=()
RESTORED_APPS=()

# Arrays to hold packages scheduled for installation and their corresponding original app names
CASK_PACKAGES=()
CASK_APPS=()
FORMULA_PACKAGES=()
FORMULA_APPS=()

# Show help message
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Convert installed macOS applications to Homebrew-managed versions.

Options:
  --scan              Scan for apps that can be converted and write to candidates file.
                      Does not make any changes to installed apps.
  --candidates FILE   Specify a custom candidates file path (Brewfile format).
                      Default: ~/.config/convert-apps-to-brew/Brewfile.candidates
  --help              Show this help message and exit.

Workflow:
  1. Run with --scan to generate a candidates Brewfile
  2. Edit the file to comment out apps you don't want to convert
  3. Run without arguments to perform the conversion

The candidates file uses standard Brewfile format:
  cask "package-name"  # Original App Name
  brew "package-name"  # Original App Name

Aliases:
  Some apps have different names in Homebrew. Create an aliases file at:
    ~/.config/convert-apps-to-brew/aliases.conf

  Format (one per line):
    AppName=brew-package-name

  Example:
    logioptionsplus=logi-options+
    BambuStudio=bambu-studio
    zoom.us=zoom

The script will backup apps before replacing them and restore on failure.
EOF
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --scan)
      MODE="scan"
      shift
      ;;
    --candidates)
      if [[ -z "$2" || "$2" == --* ]]; then
        echo "Error: --candidates requires a file path argument."
        exit 1
      fi
      CANDIDATES_FILE="$2"
      shift 2
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information."
      exit 1
      ;;
  esac
done

# Acquire sudo credentials upfront for convert mode (avoids repeated password prompts)
if [ "$MODE" = "convert" ]; then
  echo "This script requires administrator privileges to move applications."
  sudo -v
  
  # Keep sudo alive in the background (refresh every 60 seconds)
  # Store the PID so we can clean it up later
  (while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 60; done) &
  SUDO_KEEPALIVE_PID=$!
fi

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
  echo "Homebrew is not installed. Please install it before continuing."
  exit 1
fi

# Function to normalize app names: convert to lowercase and replace spaces with hyphens
normalize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g'
}

# Load user-defined aliases from config file
load_aliases() {
  if [ -f "$ALIASES_FILE" ]; then
    echo "Loading aliases from: $ALIASES_FILE"
    while IFS='=' read -r app_name brew_pkg || [ -n "$app_name" ]; do
      # Skip empty lines and comments
      [[ -z "$app_name" || "$app_name" =~ ^[[:space:]]*# ]] && continue
      # Trim whitespace
      app_name=$(echo "$app_name" | xargs)
      brew_pkg=$(echo "$brew_pkg" | xargs)
      if [ -n "$app_name" ] && [ -n "$brew_pkg" ]; then
        ALIAS_APPS+=("$app_name")
        ALIAS_PACKAGES+=("$brew_pkg")
      fi
    done < "$ALIASES_FILE"
    echo "Loaded ${#ALIAS_APPS[@]} alias(es)."
  fi
}

# Look up alias for an app (returns empty if not found)
get_alias() {
  local app="$1"
  for i in "${!ALIAS_APPS[@]}"; do
    if [ "${ALIAS_APPS[$i]}" = "$app" ]; then
      echo "${ALIAS_PACKAGES[$i]}"
      return 0
    fi
  done
  return 1
}

# Get brew package name for an app (checks aliases first, then normalizes)
get_brew_name() {
  local app="$1"
  local alias_pkg
  alias_pkg=$(get_alias "$app")
  if [ -n "$alias_pkg" ]; then
    echo "$alias_pkg"
  else
    normalize_name "$app"
  fi
}

# Backup an app before removal
backup_app() {
  local app_name="$1"
  local app_path="$APPS_DIR/$app_name.app"
  
  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$HOME/.app-conversion-backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    echo "Created backup directory: $BACKUP_DIR"
  fi
  
  if [ -d "$app_path" ]; then
    echo "Backing up '$app_name' to $BACKUP_DIR/"
    sudo mv "$app_path" "$BACKUP_DIR/"
    return $?
  fi
  return 0
}

# Restore an app from backup
restore_app() {
  local app_name="$1"
  local backup_path="$BACKUP_DIR/$app_name.app"
  
  if [ -d "$backup_path" ]; then
    echo "Restoring '$app_name' from backup..."
    sudo mv "$backup_path" "$APPS_DIR/"
    if [ $? -eq 0 ]; then
      RESTORED_APPS+=("$app_name")
      echo "Successfully restored '$app_name'."
      return 0
    else
      echo "ERROR: Failed to restore '$app_name' from backup!"
      return 1
    fi
  else
    echo "WARNING: No backup found for '$app_name' at $backup_path"
    return 1
  fi
}

# Remove backup after successful installation
remove_backup() {
  local app_name="$1"
  local backup_path="$BACKUP_DIR/$app_name.app"
  
  if [ -d "$backup_path" ]; then
    sudo rm -rf "$backup_path"
    echo "Removed backup for '$app_name'."
  fi
}

# Precompute the list of installed Homebrew packages (casks and formulas)
installed_casks=$(brew list --cask --versions | awk '{print $1}')
installed_formulas=$(brew list --versions | awk '{print $1}')

# Function to check if a package is already installed via Homebrew
is_installed_via_brew() {
  local pkg="$1"
  if echo "$installed_casks" | grep -Fxq "$pkg" || echo "$installed_formulas" | grep -Fxq "$pkg"; then
    return 0
  else
    return 1
  fi
}

# Write candidates to Brewfile format (scan mode)
write_candidates_file() {
  local dir
  dir=$(dirname "$CANDIDATES_FILE")
  mkdir -p "$dir"
  
  {
    echo "# Brewfile - Apps to convert to Homebrew"
    echo "# Generated on $(date)"
    echo "# Comment out lines (with #) to exclude apps from conversion"
    echo "# The comment after each entry shows the original app name"
    echo ""
  } > "$CANDIDATES_FILE"
  
  for i in "${!CASK_PACKAGES[@]}"; do
    echo "cask \"${CASK_PACKAGES[$i]}\"  # ${CASK_APPS[$i]}" >> "$CANDIDATES_FILE"
  done
  
  for i in "${!FORMULA_PACKAGES[@]}"; do
    echo "brew \"${FORMULA_PACKAGES[$i]}\"  # ${FORMULA_APPS[$i]}" >> "$CANDIDATES_FILE"
  done
  
  echo ""
  echo "Candidates Brewfile written to: $CANDIDATES_FILE"
  echo "Edit this file to comment out apps you don't want to convert,"
  echo "then run '$(basename "$0")' without --scan to perform the conversion."
}

# Read candidates from Brewfile format (convert mode)
read_candidates_file() {
  if [ ! -f "$CANDIDATES_FILE" ]; then
    echo "No candidates file found at: $CANDIDATES_FILE"
    echo "Run with --scan first to generate a candidates Brewfile."
    exit 1
  fi
  
  echo "Reading candidates from: $CANDIDATES_FILE"
  
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and full comment lines
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Extract the app name from trailing comment (after #)
    local app_name=""
    if [[ "$line" =~ \#[[:space:]]*(.+)$ ]]; then
      app_name="${BASH_REMATCH[1]}"
      app_name=$(echo "$app_name" | xargs)
    fi
    
    # Parse Brewfile format: cask "package" or brew "package"
    if [[ "$line" =~ ^[[:space:]]*cask[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      local brew_pkg="${BASH_REMATCH[1]}"
      # If no app name in comment, use the package name
      [ -z "$app_name" ] && app_name="$brew_pkg"
      CASK_PACKAGES+=("$brew_pkg")
      CASK_APPS+=("$app_name")
      echo "Loaded candidate: '$app_name' -> $brew_pkg (cask)"
    elif [[ "$line" =~ ^[[:space:]]*brew[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      local brew_pkg="${BASH_REMATCH[1]}"
      # If no app name in comment, use the package name
      [ -z "$app_name" ] && app_name="$brew_pkg"
      FORMULA_PACKAGES+=("$brew_pkg")
      FORMULA_APPS+=("$app_name")
      echo "Loaded candidate: '$app_name' -> $brew_pkg (formula)"
    fi
  done < "$CANDIDATES_FILE"
}

# Scan applications and populate arrays
scan_applications() {
  echo "Scanning applications in $APPS_DIR..."
  
  # Load aliases before scanning
  load_aliases
  
  # Build a list of application names from /Applications using find
  app_list=()
  while IFS= read -r -d '' app; do
    app_name=$(basename "$app" .app)
    app_list+=("$app_name")
  done < <(find "$APPS_DIR" -maxdepth 1 -type d -name "*.app" -print0)
  
  # Process each application: check if available via Homebrew and not already installed
  for app in "${app_list[@]}"; do
    brew_name=$(get_brew_name "$app")
    local used_alias=""
    get_alias "$app" > /dev/null && used_alias=" via alias"
    
    if is_installed_via_brew "$brew_name"; then
      echo "Application '$app' is already installed via Homebrew."
      ALREADY_INSTALLED_VIA_BREW+=("$app")
    else
      if brew info --cask "$brew_name" &> /dev/null; then
        CASK_PACKAGES+=("$brew_name")
        CASK_APPS+=("$app")
        echo "Found candidate: '$app' (brew package: $brew_name$used_alias) - cask"
      elif brew info "$brew_name" &> /dev/null; then
        FORMULA_PACKAGES+=("$brew_name")
        FORMULA_APPS+=("$app")
        echo "Found candidate: '$app' (brew package: $brew_name$used_alias) - formula"
      else
        echo "Application '$app' is not available via Homebrew."
        UNABLE_TO_INSTALL+=("$app")
      fi
    fi
  done
}

# Install cask packages one by one with backup/restore
install_casks() {
  if [ ${#CASK_PACKAGES[@]} -eq 0 ]; then
    return
  fi
  
  echo -e "\nInstalling ${#CASK_PACKAGES[@]} cask package(s)..."
  
  for i in "${!CASK_PACKAGES[@]}"; do
    local pkg="${CASK_PACKAGES[$i]}"
    local app="${CASK_APPS[$i]}"
    
    echo -e "\n--- Processing '$app' ($pkg) ---"
    
    # Backup the app first
    if ! backup_app "$app"; then
      echo "ERROR: Failed to backup '$app'. Skipping installation."
      FAILED_TO_INSTALL+=("$app")
      continue
    fi
    
    # Attempt installation
    echo "Installing $pkg via brew cask..."
    if brew install --cask "$pkg"; then
      echo "Successfully installed '$pkg'."
      INSTALLED_VIA_BREW+=("$pkg")
      remove_backup "$app"
    else
      echo "ERROR: Failed to install '$pkg'. Restoring '$app'..."
      restore_app "$app"
      FAILED_TO_INSTALL+=("$app")
    fi
  done
}

# Install formula packages one by one with backup/restore
install_formulas() {
  if [ ${#FORMULA_PACKAGES[@]} -eq 0 ]; then
    return
  fi
  
  echo -e "\nInstalling ${#FORMULA_PACKAGES[@]} formula package(s)..."
  
  for i in "${!FORMULA_PACKAGES[@]}"; do
    local pkg="${FORMULA_PACKAGES[$i]}"
    local app="${FORMULA_APPS[$i]}"
    
    echo -e "\n--- Processing '$app' ($pkg) ---"
    
    # Backup the app first
    if ! backup_app "$app"; then
      echo "ERROR: Failed to backup '$app'. Skipping installation."
      FAILED_TO_INSTALL+=("$app")
      continue
    fi
    
    # Attempt installation
    echo "Installing $pkg via brew formula..."
    if brew install "$pkg"; then
      echo "Successfully installed '$pkg'."
      INSTALLED_VIA_BREW+=("$pkg")
      remove_backup "$app"
    else
      echo "ERROR: Failed to install '$pkg'. Restoring '$app'..."
      restore_app "$app"
      FAILED_TO_INSTALL+=("$app")
    fi
  done
}

# Print summary of operations
print_summary() {
  echo -e "\n=========================================="
  echo "Summary of Operations"
  echo "=========================================="
  
  if [ ${#ALREADY_INSTALLED_VIA_BREW[@]} -gt 0 ]; then
    echo -e "\nApplications already installed via Homebrew (${#ALREADY_INSTALLED_VIA_BREW[@]}):"
    printf "  - %s\n" "${ALREADY_INSTALLED_VIA_BREW[@]}"
  fi
  
  if [ ${#INSTALLED_VIA_BREW[@]} -gt 0 ]; then
    echo -e "\nSuccessfully installed via Homebrew (${#INSTALLED_VIA_BREW[@]}):"
    printf "  - %s\n" "${INSTALLED_VIA_BREW[@]}"
  fi
  
  if [ ${#RESTORED_APPS[@]} -gt 0 ]; then
    echo -e "\nApps restored from backup after failed installation (${#RESTORED_APPS[@]}):"
    printf "  - %s\n" "${RESTORED_APPS[@]}"
  fi
  
  if [ ${#FAILED_TO_INSTALL[@]} -gt 0 ]; then
    echo -e "\nFailed to install (${#FAILED_TO_INSTALL[@]}):"
    printf "  - %s\n" "${FAILED_TO_INSTALL[@]}"
  fi
  
  if [ ${#UNABLE_TO_INSTALL[@]} -gt 0 ]; then
    echo -e "\nNot available via Homebrew (${#UNABLE_TO_INSTALL[@]}):"
    printf "  - %s\n" "${UNABLE_TO_INSTALL[@]}"
    echo -e "\n  Tip: Some apps may have different names in Homebrew."
    echo "  Add aliases to: $ALIASES_FILE"
    echo "  Format: AppName=brew-package-name"
  fi
  
  if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    # Check if backup directory is empty
    if [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
      rmdir "$BACKUP_DIR" 2>/dev/null
      echo -e "\nBackup directory cleaned up (was empty)."
    else
      echo -e "\nBackup directory retained at: $BACKUP_DIR"
      echo "You may delete it manually after verifying installations."
    fi
  fi
}

# Main execution
if [ "$MODE" = "scan" ]; then
  echo "Running in SCAN mode..."
  scan_applications
  
  if [ ${#CASK_PACKAGES[@]} -eq 0 ] && [ ${#FORMULA_PACKAGES[@]} -eq 0 ]; then
    echo -e "\nNo candidates found for conversion."
  else
    write_candidates_file
  fi
  
  print_summary
else
  echo "Running in CONVERT mode..."
  read_candidates_file
  
  if [ ${#CASK_PACKAGES[@]} -eq 0 ] && [ ${#FORMULA_PACKAGES[@]} -eq 0 ]; then
    echo -e "\nNo apps to convert. Check your candidates Brewfile."
    exit 0
  fi
  
  echo -e "\nAbout to convert ${#CASK_PACKAGES[@]} cask(s) and ${#FORMULA_PACKAGES[@]} formula(s)."
  echo "Apps will be backed up before replacement and restored on failure."
  read -p "Continue? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  
  install_casks
  install_formulas
  print_summary
  
  # Clean up the sudo keepalive process
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  fi
fi
