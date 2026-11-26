#!/usr/bin/env bash
set -euo pipefail
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ $EUID -eq 0 ]]; then SUDO=(); else SUDO=(sudo); fi
"${SUDO[@]}" systemctl disable --now conky_digital_cockpit.service 2>/dev/null || true
"${SUDO[@]}" rm -f /etc/systemd/system/conky_digital_cockpit.service
"${SUDO[@]}" systemctl daemon-reload
"${SUDO[@]}" rm -rf /usr/local/lib/conky-digital-cockpit
rm -f "$TARGET_HOME/.config/autostart/conky-digital-cockpit.desktop"
echo 'Serviço e autostart removidos. ~/.config/conky foi preservado.'
