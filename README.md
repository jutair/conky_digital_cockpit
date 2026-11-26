# Conky Digital Cockpit

## Instalação rápida (Debian/Ubuntu, LXQt/X11)

```bash
git clone https://github.com/jutair/conky_digital_cockpit.git
cd conky_digital_cockpit
chmod +x install.sh
./install.sh
```

Execute como usuário normal; o script solicita sudo para operações administrativas. Ele instala Conky, Python 3, NetHogs e iproute2, configura o painel, instala o coletor e ativa o serviço Systemd. O Conky será iniciado no próximo login.

## Arquivos
- `dashboard.lua`: interface gráfica Cairo.
- `conky.conf`: posição, transparência, tamanho e hook Lua.
- `collector.py`: CPU/RAM por `/proc`, tráfego por processo via NetHogs e detecção de interfaces via `/sys/class/net`.
- `conky_digital_cockpit.service`: serviço de coleta.
- `install.sh`: instalação automatizada.
- `uninstall.sh`: remove serviço/autostart, preservando `~/.config/conky`.

## Dados em runtime
`/run/conky-digital-cockpit/` contém `top-processes.tsv` e `interfaces.tsv`. O Systemd recria o diretório a cada boot.

## Diagnóstico
```bash
systemctl status conky_digital_cockpit.service
journalctl -u conky_digital_cockpit.service -n 80 --no-pager
cat /run/conky-digital-cockpit/top-processes.tsv
cat /run/conky-digital-cockpit/interfaces.tsv
```

## Notas
- Interfaces Ethernet, Wi-Fi e VPN são detectadas automaticamente. Se uma categoria não existir, seu cartão aparece offline/not detected.
- NetHogs monitora a interface selecionada pela rota padrão; a atribuição de tráfego a processos depende do que o NetHogs consegue associar a PID.
- CPU precisa de duas amostras para calcular o percentual.
- O painel tem 835 px de altura e foi desenhado para X11. Em telas menores, pode ser necessário ajustar coordenadas e altura.
