#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || { echo "HOME do usuário não encontrado" >&2; exit 1; }
command -v apt-get >/dev/null || { echo "Este instalador requer Debian/Ubuntu com APT" >&2; exit 1; }
if [[ $EUID -eq 0 ]]; then SUDO=(); else SUDO=(sudo); fi

echo '[1/6] Dependências'
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y conky-all python3 nethogs iproute2

echo '[2/6] Configuração Conky'
install -d -m 755 "$TARGET_HOME/.config/conky"
install -m 644 "$REPO/dashboard.lua" "$TARGET_HOME/.config/conky/dashboard.lua"
install -m 644 "$REPO/conky.conf" "$TARGET_HOME/.config/conky/conky.conf"

echo '[3/6] Coletor'
"${SUDO[@]}" install -d -m 755 /usr/local/lib/conky-digital-cockpit
"${SUDO[@]}" install -m 755 "$REPO/collector.py" /usr/local/lib/conky-digital-cockpit/collector.py

echo '[4/6] Serviço systemd'
"${SUDO[@]}" install -m 644 "$REPO/conky_digital_cockpit.service" /etc/systemd/system/conky_digital_cockpit.service
"${SUDO[@]}" systemctl daemon-reload
"${SUDO[@]}" systemctl enable --now conky_digital_cockpit.service

echo '[5/6] Autostart gráfico'
install -d -m 755 "$TARGET_HOME/.config/autostart"
cat > "$TARGET_HOME/.config/autostart/conky-digital-cockpit.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Conky Digital Cockpit
Comment=System monitor dashboard
Exec=/usr/bin/conky -c $TARGET_HOME/.config/conky/conky.conf
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$TARGET_HOME/.config/conky" "$TARGET_HOME/.config/autostart"

echo '[6/6] Concluído'
echo 'O Conky será iniciado automaticamente no próximo login.'
echo "Para iniciar agora: conky -c '$TARGET_HOME/.config/conky/conky.conf'"
echo 'Verifique o coletor: sudo systemctl status conky_digital_cockpit.service'
