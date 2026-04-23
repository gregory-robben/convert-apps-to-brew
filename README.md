# Convert macOS Applications to Homebrew Installations

This script examines your applications located in the `/Applications` directory, checks if corresponding Homebrew packages (cask or formula) exist, and, if so, removes the locally installed copy and installs it via Homebrew. This allows you to manage more of your applications using Homebrew, simplifying updates and maintenance. Apps are backed up before replacement and automatically restored if installation fails.

---

## Table of Contents

- [Convert macOS Applications to Homebrew Installations](#convert-macos-applications-to-homebrew-installations)
  - [Table of Contents](#table-of-contents)
  - [How It Works](#how-it-works)
  - [Why Use It](#why-use-it)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Usage](#usage)
    - [Aliases](#aliases)
  - [Example Output](#example-output)
  - [Troubleshooting](#troubleshooting)
  - [License](#license)

---

## How It Works

1. **Scan**: The script searches `/Applications` for `.app` directories and checks if matching Homebrew packages exist (cask or formula).
2. **Review**: Candidates are written to a Brewfile you can edit to exclude apps.
3. **Convert**: Each app is backed up, then replaced with the Homebrew version. On failure, the original is automatically restored.

Apps already installed via Homebrew are skipped. Apps without a matching package are reported but ignored.

---

## Why Use It

- **Centralized Management**: Manage all (or most) of your applications and tools via Homebrew, simplifying updates (`brew upgrade`) and maintenance.
- **Consistency**: Leverage Homebrew’s version control, rollback features, and easy install/uninstall procedures.
- **Automation**: Easily replicate the same set of apps on new machines using a single script or Brewfile.

---

## Prerequisites

- [Homebrew](https://brew.sh/) must be installed on your Mac.
- You need sufficient permissions to run `sudo rm -rf` on `/Applications` (especially for apps installed from the Mac App Store).

---

## Installation

1. **Clone or Download** this repository:

   ```bash
   git clone https://github.com/oturcot/convert-apps-to-brew.git
   cd convert-apps-to-brew
   ```

2. **Make the Script Executable**:

   ```bash
   chmod +x convert-apps-to-brew.sh
   ```

---

## Usage

```bash
./convert-apps-to-brew.sh [OPTIONS]
```

**Options:**

- `--scan` — Scan for convertible apps and generate a candidates Brewfile (no changes made)
- `--candidates FILE` — Use a custom candidates file path
- `--help` — Show help message

**Recommended workflow:**

1. **Scan** to generate a candidates file:

   ```bash
   ./convert-apps-to-brew.sh --scan
   ```

2. **Edit** the candidates file (`~/.config/convert-apps-to-brew/Brewfile.candidates`) to comment out any apps you don't want to convert:

   ```
   cask "visual-studio-code"  # Visual Studio Code
   # cask "slack"  # Slack  <- commented out, will be skipped
   ```

3. **Run** without arguments to perform the conversion:

   ```bash
   ./convert-apps-to-brew.sh
   ```

Apps are backed up to `~/.app-conversion-backup/` before replacement. If installation fails, the original app is automatically restored.

### Aliases

Some apps have different names in Homebrew (e.g., `logioptionsplus` → `logi-options+`). Create an aliases file to map app names to their Homebrew package names:

**File:** `~/.config/convert-apps-to-brew/aliases.conf`

```
# Format: AppName=brew-package-name
logioptionsplus=logi-options+
BambuStudio=bambu-studio
zoom.us=zoom
```

The script will use these aliases during scanning to find the correct packages.

---

## Example Output

```
Running in SCAN mode...
Found candidate: 'Visual Studio Code' (brew package: visual-studio-code) - cask
Application 'Steam Link' is not available via Homebrew.
Application 'Docker' is already installed via Homebrew.

Candidates Brewfile written to: ~/.config/convert-apps-to-brew/Brewfile.candidates

==========================================
Summary of Operations
==========================================

Applications already installed via Homebrew (1):
  - Docker

Not available via Homebrew (1):
  - Steam Link
```

---

## Troubleshooting

- **Permission Denied**: Ensure your user is an administrator and that `sudo` is configured properly.
- **Name Mismatches**: Some apps have different names in Homebrew. Add an alias to `~/.config/convert-apps-to-brew/aliases.conf` (see [Aliases](#aliases)).
- **Failed Installation**: The script automatically restores the original app from backup. Check the error message and try installing manually with `brew install --cask <package>`.

---

## License

This project is released under the [MIT License](LICENSE).
