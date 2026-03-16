#!/bin/bash -e
# Add ClockworkPi repository for DevTerm-specific packages

on_chroot << EOF
# Add ClockworkPi APT repository key
curl -fsSL https://raw.githubusercontent.com/clockworkpi/apt/main/debian/KEY.gpg \
    | gpg --dearmor -o /usr/share/keyrings/clockworkpi-archive-keyring.gpg

# Add ClockworkPi APT repository
echo "deb [arch=armhf signed-by=/usr/share/keyrings/clockworkpi-archive-keyring.gpg] \
    https://raw.githubusercontent.com/clockworkpi/apt/main/debian/ stable main" \
    > /etc/apt/sources.list.d/clockworkpi.list

apt-get update
EOF
