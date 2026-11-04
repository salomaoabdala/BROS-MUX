#!/bin/zsh
# Mede se dá para a passada 1 do x265 ser mais rápida sem piorar o filme.
#
# A passada 1 já roda com análise reduzida (slow-firstpass=0). O que sobra para
# cortar baixando o preset dela é o rc-lookahead e o b-adapt — e o b-adapt não
# pode cair, porque a passada 2 herda da 1 o tipo de cada frame. Então o teste
# compara presets com b-adapt travado em 2 e confere, no fim, se os tipos de
# frame saíram idênticos. Se saírem, a passada 1 mais rápida é neutra.
#
# Não roda com um encode do dono na máquina. Uso: ./tools/bench-firstpass.sh
set -e

SRC="${SRC:-/Volumes/A018/2DIE4_UHD_HDR_PR4444/2DIE4_UHD_P3D65_PR444_51_20260212.mov}"
INICIO="${INICIO:-00:09:00}"      # trecho com detalhe, movimento e grão
DUR="${DUR:-00:02:00}"
OUT="${OUT:-$HOME/bros-mux-bench}"
FFMPEG=/opt/homebrew/bin/ffmpeg

if pgrep -f "BROS-MUX --job" > /dev/null; then
  echo "ABORTADO: há um encode do dono rodando. O benchmark disputaria a máquina."
  pgrep -fl "BROS-MUX --job" | cut -c1-120
  exit 1
fi
[[ -f "$SRC" ]] || { echo "ABORTADO: não achei a fonte: $SRC"; exit 1; }
mkdir -p "$OUT"

# os parâmetros que o x265 confere entre as passadas, mais o b-adapt, ficam
# iguais nos três: só muda o esforço de análise
COMUM="log-level=error:bframes=4:b-adapt=2:b-pyramid=1:weightp=1:keyint=250:min-keyint=24"
COMUM="$COMUM:scenecut=40:open-gop=1:repeat-headers=1:aud=1:hrd=1:aq-mode=3:no-sao=1:qpmax=16"
COMUM="$COMUM:vbv-maxrate=160000:vbv-bufsize=160000"
VF="scale=out_range=tv:flags=lanczos+accurate_rnd+full_chroma_int+full_chroma_inp,format=yuv420p10le"

echo "Trecho: $INICIO + $DUR de $(basename "$SRC")"
echo "Cada rodada é uma passada 1 completa (slow-firstpass=0), como no trabalho real."
echo

for PRESET in slow medium fast; do
  STATS="$OUT/p1-$PRESET.stats"
  rm -f "$STATS" "$STATS.cutree" "$STATS.temp" "$STATS.cutree.temp" 2>/dev/null || true
  INI=$(date +%s)
  $FFMPEG -nostdin -v error -nostats -ss "$INICIO" -t "$DUR" -i "$SRC" \
    -map 0:v:0 -an -sn -dn -vf "$VF" \
    -c:v libx265 -preset "$PRESET" -b:v 110000k \
    -x265-params "$COMUM:pass=1:stats=$STATS:slow-firstpass=0" \
    -f null - 2>"$OUT/err-$PRESET.txt" || { echo "  $PRESET FALHOU:"; tail -3 "$OUT/err-$PRESET.txt"; continue; }
  FIM=$(date +%s)
  N=$(grep -c "^in:" "$STATS" 2>/dev/null || echo 0)
  SEG=$((FIM-INI))
  printf "  %-7s %4d s   %5.2f fps   (%s frames)\n" "$PRESET" "$SEG" \
    "$(python3 -c "print(f'{$N/max(1,$SEG):.2f}')")" "$N"
  echo "$PRESET $SEG $N" >> "$OUT/tempos.txt"
done

echo
echo "Os tipos de frame saíram iguais? (se sim, a passada 1 mais rápida é neutra)"
for P in medium fast; do
  A=$(grep -o "type:." "$OUT/p1-slow.stats" 2>/dev/null | tr -d '\n' | md5)
  B=$(grep -o "type:." "$OUT/p1-$P.stats" 2>/dev/null | tr -d '\n' | md5)
  DIF=$(python3 - "$OUT/p1-slow.stats" "$OUT/p1-$P.stats" <<'PY'
import re, sys
def tipos(p):
    return re.findall(r"type:(\w)", open(p, errors="replace").read())
try:
    a, b = tipos(sys.argv[1]), tipos(sys.argv[2])
except OSError:
    print("?"); raise SystemExit
n = min(len(a), len(b))
print(sum(1 for i in range(n) if a[i] != b[i]), "de", n)
PY
)
  [[ "$A" == "$B" ]] && echo "  slow vs $P: IDÊNTICOS" || echo "  slow vs $P: diferem em $DIF frames"
done

echo
echo "Resultados em $OUT. Apague com: rm -rf $OUT"
