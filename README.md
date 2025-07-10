# CinePi5 – Ultimate Production Camera Platform for Raspberry Pi 5

![CinePi5 Banner](https://raw.githubusercontent.com/YourOrg/CinePi5/main/docs/cinepi5_banner.png) <!-- Replace or remove if not available -->

---

## What is CinePi5?

**CinePi5** transforms a Raspberry Pi 5 into a fully-automated, field-ready cinema camera system with pro-level features, robust security, and cloud-ready batch workflow.

- **One-Command Installer/Updater**: From bare metal to production camera in a single script.
- **Hardened Security**: Dedicated system user, firewall, systemd sandbox, atomic file handling.
- **OTA Updates & Rollbacks**: Always up to date—never bricked.
- **Incremental Backups & Fast Restore**: Daily, verifiable backups with chain rotation.
- **Modern Camera Stack**: GPU-accelerated preview, web API/GUI controls (ISO, Shutter, AWB), Meike cine lens support.
- **Remote Management**: GUI menu (Zenity) or CLI—works on both desktop and headless installs.

---

## Key Features

- **Zero-Click Install & Upgrade**: Just run the script, everything else is automated.
- **Security by Default**: Least-privilege service user, systemd hardening, firewall locked down.
- **Batch Backups**: Incremental, automatic, verifiable, and easy to restore.
- **OTA Updates**: Checks for updates daily, safely rolls back on failure.
- **Web & CLI Control**: Control your camera and workflow from browser, touchscreen, or shell.
- **Pro Camera Controls**: Set ISO, shutter speed, and white balance via GUI, web API, or CLI.
- **Cloud/Local Workflow**: Designed for cloud-based batch upload, editing, and asset management.
- **Self-Healing & Recovery**: Repair utility for permissions/logs, safe shutdown, disaster restore.
- **Real Onboarding**: Automatic HTML onboarding page with local URLs and usage tips.

---

## Quick Start

**Minimum requirements:**
- Raspberry Pi 5 (4GB+ RAM recommended)
- Official Pi 5 power supply
- Clean install of 64-bit Raspberry Pi OS (Bookworm or later)
- Pi Camera Module (v3 recommended)
- Internet access for first install

**To install:**

```bash
curl -fsSL https://raw.githubusercontent.com/YourOrg/CinePi5/main/cinepi5-installer.sh | sudo bash
