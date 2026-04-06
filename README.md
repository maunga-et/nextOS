![NextOS Banner](https://github.com/TaqsBlaze/nextOS/blob/main/banner/nexOS2.png)

# NextOS

> A minimal, transparent, and performance-focused Linux OS built from source.

<!-- [![Build Status](https://github.com/TaqsBlaze/nextOS/actions/workflows/build.yml/badge.svg)](https://github.com/TaqsBlaze/nextOS/actions) -->
[![License: GPL v2](https://img.shields.io/badge/License-GPLv2-blue.svg)](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
[![Linux](https://img.shields.io/badge/Linux-6.19-FCC624?logo=linux&logoColor=black)](https://www.kernel.org/)
[![Linux](https://img.shields.io/badge/Linux-6.19-FCC624?logo=linux&logoColor=black)](https://www.kernel.org/)
[![GitHub Stars](https://img.shields.io/github/stars/TaqsBlaze/nextOS?style=social)](https://github.com/TaqsBlaze/nextOS)
[![GitHub Issues](https://img.shields.io/github/issues/TaqsBlaze/nextOS)](https://github.com/TaqsBlaze/nextOS/issues)
[![GitHub Forks](https://img.shields.io/github/forks/TaqsBlaze/nextOS?style=social)](https://github.com/TaqsBlaze/nextOS)
[![GitHub Last Commit](https://img.shields.io/github/last-commit/TaqsBlaze/nextOS)](https://github.com/TaqsBlaze/nextOS/commits/main)
[![GitHub Contributors](https://img.shields.io/github/contributors/TaqsBlaze/nextOS)](https://github.com/TaqsBlaze/nextOS/graphs/contributors)
[![GitHub Code Size](https://img.shields.io/github/languages/code-size/TaqsBlaze/nextOS)](https://github.com/TaqsBlaze/nextOS)
[![GitHub Repo Size](https://img.shields.io/github/repo-size/TaqsBlaze/nextOS)](https://github.com/TaqsBlaze/nextOS)

---

## What is NextOS?
NextOS is a minimal Linux distribution for systems programmers, kernel developers, and OS enthusiasts. Every component is built from source for maximum control, clarity, and performance. The system is designed to be simple, auditable, and fast.

**Key Features:**
- Minimal userspace (BusyBox)
- Custom kernel config (Linux 6.19)
- Transparent, documented build process
- Fast boot, low memory footprint
- Persistent rootfs support (via /dev/sda1 if present)
- Automated, reproducible builds

---

## Quick Start

### Prerequisites
- Linux build host
- 5GB+ disk space, 2GB+ RAM
- Internet connection

### One-Command Build
```sh
./build.sh
```
This runs the full streamlined build (clean, fix rootfs, health check, build, ISO creation).

### Manual Build (Advanced)
```sh
./full-build.sh
```

### Testing the ISO
**QEMU:**
```sh
qemu-system-x86_64 -cdrom NextOS.iso -m 512M
```
**VirtualBox:**
```sh
./build/setup_virtualbox.sh
VBoxManage startvm NextOS --type gui
```

### Persistent Root Filesystem
Attach a virtual disk (e.g., /dev/sda1) in QEMU/VirtualBox. If present, NextOS will use it as the rootfs and persist all changes.

---

## Project Structure
```
nextOS/
├── build.sh              # Simple build entrypoint
├── build/streamline.sh   # Canonical build sequence
├── full-build.sh         # Full build script
├── initramfs/            # Init and core utilities
├── rootfs/               # Root filesystem template
├── iso/                  # ISO staging area
├── docs/                 # Documentation
└── ...
```

---

## Documentation
- [Design Philosophy](docs/design_philosophy.md)
- [Security Model](docs/security_model.md)
- [Kernel Build Notes](KernelBuildNotes.md)
- [CI/CD Pipeline](docs/CI_CD.md)
- [Desktop Environment Options](docs/DESKTOP_ENV_OPTIONS.md)

---

## Contributing
1. Fork & branch from `main`
2. Make changes, test with `./build/test.sh`
3. Document your changes
4. Open a PR and ensure CI passes

---

## License
GPL v2.0 — see [LICENSE](LICENSE)

---

**Built with ❤️ by the NextOS community**
./build/test.sh
