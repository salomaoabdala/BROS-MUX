#!/bin/zsh
# Abre o monitor de render do BROS-MUX no navegador.
# Dá para clicar duas vezes neste arquivo no Finder.
cd "$(dirname "$0")"
pkill -f "render-monitor/monitor.py" >/dev/null 2>&1
nohup /usr/bin/python3 tools/render-monitor/monitor.py >/dev/null 2>&1 &
sleep 1
open http://localhost:8787
echo "Monitor aberto em http://localhost:8787 — pode fechar esta janela."
