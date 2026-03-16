# DevTerm CM3 — Trixie arm32 Image

Custom [pi-gen](https://github.com/RPi-Distro/pi-gen) build configuration for creating
a **Debian Trixie (arm32/armhf)** image for the
[ClockworkPi DevTerm CM3](https://www.clockworkpi.com/devterm).

---

## Hardware

| Component | Details |
|-----------|---------|
| SoC | Raspberry Pi CM3 (BCM2837, ARMv8 @ 1.2 GHz) |
| Display | 4.5" IPS 1280×480 |
| Audio | ES8388 codec via I2S |
| Wireless | AP6256 (WiFi 802.11ac + BT 5.0) |
| Printer | Thermal printer on UART |
| Input | Keyboard + trackball |

---

## Prerequisites

- **Docker** — used by pi-gen for reproducible builds
- **Git**
- ~10 GB free disk space
- Linux host recommended (macOS may work with Docker Desktop)

---

## Build

```bash
# Clone this repository
git clone <repo-url> cm3
cd cm3

# Run the build (downloads pi-gen automatically)
./build.sh
```

The finished image is placed in `deploy/DevTerm-CM3-Trixie-*.img.xz`.

---

## Repository layout

```
cm3/
├── config                   # pi-gen build variables
├── build.sh                 # Main build driver script
└── stage-devterm/           # Custom pi-gen stage
    ├── SKIP_IMAGES          # Don't create intermediate image
    ├── 00-packages-devterm/ # Add ClockworkPi repo & packages
    │   ├── 00-run.sh
    │   └── packages
    ├── 01-devterm-config/   # Boot config, audio, display
    │   ├── 01-run.sh
    │   └── files/
    │       ├── config.txt
    │       ├── cmdline.txt
    │       ├── modules
    │       ├── asound.conf
    │       └── devterm-init
    └── 02-devterm-services/ # Systemd service enablement
        ├── 00-run.sh
        └── files/
            └── devterm-init.service
```

---

## Default credentials

| | |
|--|--|
| Username | `clockwork` |
| Password | `clockwork` |
| Hostname | `devterm` |
| SSH | Enabled |

Change the password on first login: `passwd`

---

## Customisation

Edit `config` to change locale, timezone, username, or the stage list.
Edit files under `stage-devterm/` to add packages, overlays, or services.
