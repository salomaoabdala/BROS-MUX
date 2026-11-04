#!/bin/zsh
# BROS-MUX — controle de qualidade (QC) antes de publicar uma versão. A regra está em CLAUDE.md:
# nada é publicado (GitHub, main, Release) sem este QC aprovado e sem as capturas olhadas.
#
# O que ele faz, nesta ordem:
#   1. compila o app (./build.sh) e confere que VERSION (build.sh), AppInfo.version (Design.swift), o Info.plist
#      e a entrada do CHANGELOG.md falam da mesma versão;
#   2. gera clipes de teste em qc/out/clips, só na primeira vez (ou quando CLIPGEN muda): H.264 Rec.709 e
#      ProRes 4444 com alfa de 12 s, HEVC 10-bit PQ/BT.2020 com HDR10 de 5 s (120 frames, o que a referência do
#      comando x265 espera), todos com o mesmo ruído rosa de referência como áudio; um guia estéreo igual ao ruído,
#      outro atrasado 100 ms, e 6 monos L R C LFE Ls Rs derivados dele (o sync "as muxed" tem que bater em 0 ms);
#   3. Mux pelo --job (sem o Picture Check, que precisa de cortes secos de verdade e fica para o teste manual):
#      guia estéreo (verificação bit a bit + sync "as muxed" = 0 ms), guia atrasado com --align (o corte de 100 ms
#      tem que sair sample exato), 6 monos virando uma faixa 5.1 (cada canal conferido, sync 0 ms), encode
#      HDR10 de uma fonte PQ/BT.2020 com o comando ffmpeg/x265 comparado a qc/reference/dv-command.txt (o comando
#      do encode Dolby Vision não pode mudar sem querer);
#   4. Transcode pelo --transcode: cada preset (ProRes 422 HQ, ProRes 422, H.264, HEVC) em cada clipe, conferindo com
#      ffprobe codec, pixel format, frames, frame rate, tags de cor (iguais às da fonte), timecode e áudio;
#   5. capturas de cada aba (--snapshot) em qc/out/shots, com as da rodada anterior em qc/out/previous para comparar;
#   6. abre o app e confere que ele continua aberto.
# Escreve qc/out/QC-REPORT.txt e termina com código 1 se algo reprovou. Os caminhos não podem ter espaços.
#
# Uso: ./qc.sh              (tudo)
#      ./qc.sh --no-build   (usa o build.noindex que já existe)
set -u
cd "$(dirname "$0")"
OUT=qc/out; REF=qc/reference; CLIPS=$OUT/clips; SHOTS=$OUT/shots; LOGS=$OUT/logs
APP=build.noindex/BROS-MUX.app; BIN=$APP/Contents/MacOS/BROS-MUX
REPORT=$OUT/QC-REPORT.txt
CLIPGEN=2                      # suba quando os clipes de teste mudarem: eles são gerados de novo
mkdir -p "$CLIPS" "$LOGS" "$OUT/mux" "$OUT/transcode"
rm -rf "$OUT/previous"; [[ -d $SHOTS ]] && mv "$SHOTS" "$OUT/previous"
mkdir -p "$SHOTS"
PASS=0; FAIL=0; WARN=0
: > "$REPORT"
say()  { print -r -- "$*" | tee -a "$REPORT" }
pass() { (( PASS++ )); say "[PASS] $*" }
fail() { (( FAIL++ )); say "[FAIL] $*" }
warn() { (( WARN++ )); say "[WARN] $*" }
finish() {
  say ""
  say "Capturas em $SHOTS (as da rodada anterior em $OUT/previous): olhar uma a uma e comparar."
  if (( FAIL == 0 )); then say "QC: APROVADO — $PASS ok, $WARN aviso(s), 0 falhas"; exit 0
  else say "QC: REPROVADO — $FAIL falha(s), $WARN aviso(s), $PASS ok"; exit 1; fi
}
# probe STREAM KEY FILE: one value; "default" output and the blank-line filter skip ffprobe's empty stream-group
# sections and the side-data separators that csv prints for HDR streams
probe() { ffprobe -v error -select_streams "$1" -show_entries "stream=$2" -of default=nw=1:nk=1 "$3" 2>/dev/null | grep -v '^$' | head -1 }

COMMIT=$(git rev-parse --short HEAD 2>/dev/null || print '?')
DIRTY=$(git status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' ')
say "BROS-MUX QC — $(date '+%Y-%m-%d %H:%M') — commit $COMMIT$([[ $DIRTY != 0 ]] && print ' + mudanças não commitadas')"

# 1. compilação e versão ---------------------------------------------------------------------------------------
if [[ ${1:-} != --no-build ]]; then
  if ./build.sh > "$LOGS/build.log" 2>&1; then pass "Compilação: $(tail -1 "$LOGS/build.log")"
  else fail "Compilação: erro (veja $LOGS/build.log)"; finish; fi
fi
[[ -x $BIN ]] || { fail "Compilação: $BIN não existe"; finish }
V=$(sed -nE 's/^VERSION=([0-9.]+).*/\1/p' build.sh | head -1)
D=$(sed -nE 's/.*static let version = "([0-9.]+)".*/\1/p' Design.swift | head -1)
P=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)
if [[ -n $V && $V == "$D" && $V == "$P" ]]; then pass "Versão $V igual em build.sh, Design.swift e Info.plist"
else fail "Versão: build.sh=$V Design.swift=$D Info.plist=$P"; fi
if grep -qE "^## v$V — [0-9]{4}-[0-9]{2}-[0-9]{2}" CHANGELOG.md; then pass "CHANGELOG.md tem a entrada v$V"
else fail "CHANGELOG.md sem a entrada \"## v$V — AAAA-MM-DD\""; fi
DEV=$(awk '/^## Em desenvolvimento/{f=1;next} /^## /{f=0} f' CHANGELOG.md | grep -vE '^[[:space:]]*$|nada ainda' | head -1)
[[ -n $DEV ]] && warn "CHANGELOG.md: \"Em desenvolvimento\" tem itens fora de uma versão (${DEV:0:80}…)"

# 2. clipes de teste --------------------------------------------------------------------------------------------
[[ "$(cat "$CLIPS/.gen" 2>/dev/null)" == "$CLIPGEN" ]] || { rm -rf "$CLIPS"; mkdir -p "$CLIPS"; }
T709="setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"
VSRC="testsrc2=size=1920x1080:rate=24"
FF=(ffmpeg -nostdin -v error -y)
R=$CLIPS/ref.wav                                       # the same pink noise is the sound of every clip: sync = 0 ms
[[ -f $R ]] || $FF -f lavfi -i "anoisesrc=color=pink:seed=7:sample_rate=48000:amplitude=0.5" -t 12 -c:a pcm_s24le -ac 2 "$R"
[[ -f $CLIPS/h264_709.mov ]] || $FF -f lavfi -i "$VSRC" -i "$R" -t 12 -vf "format=yuv420p,$T709" -c:v libx264 -preset ultrafast -crf 18 -c:a pcm_s24le -timecode 01:00:00:00 "$CLIPS/h264_709.mov"
[[ -f $CLIPS/prores4444_alpha.mov ]] || $FF -f lavfi -i "$VSRC" -i "$R" -t 12 -vf "format=yuva444p10le,$T709" -c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le -vendor apl0 -c:a pcm_s24le -timecode 01:00:00:00 "$CLIPS/prores4444_alpha.mov"
[[ -f $CLIPS/hevc10_pq2020.mov ]] || $FF -f lavfi -i "$VSRC" -i "$R" -t 5 -pix_fmt yuv420p10le -c:v libx265 -preset ultrafast -crf 18 -x265-params "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv -tag:v hvc1 -c:a pcm_s24le -timecode 01:00:00:00 "$CLIPS/hevc10_pq2020.mov"
[[ -f $CLIPS/guide.wav ]] || cp "$R" "$CLIPS/guide.wav"
[[ -f $CLIPS/guide_late100ms.wav ]] || $FF -i "$R" -af "adelay=100|100" -c:a pcm_s24le "$CLIPS/guide_late100ms.wav"
typeset -A GAIN; GAIN=(L 1.0 R 1.0 C 0.7 Ls 0.5 Rs 0.5)
MONOS=()
for ch in L R C LFE Ls Rs; do
  if [[ ! -f $CLIPS/tone.$ch.wav ]]; then
    if [[ $ch == LFE ]]; then $FF -f lavfi -i "sine=frequency=60:sample_rate=48000" -t 12 -c:a pcm_s24le -ac 1 "$CLIPS/tone.$ch.wav"
    else $FF -i "$R" -af "pan=mono|c0=${GAIN[$ch]}*c0" -c:a pcm_s24le "$CLIPS/tone.$ch.wav"; fi
  fi
  MONOS+=(--add "$CLIPS/tone.$ch.wav")
done
n=0; for f in ref.wav h264_709.mov prores4444_alpha.mov hevc10_pq2020.mov guide.wav guide_late100ms.wav tone.L.wav tone.R.wav tone.C.wav tone.LFE.wav tone.Ls.wav tone.Rs.wav; do [[ -s $CLIPS/$f ]] && (( n++ )); done
if (( n == 12 )); then print -r -- "$CLIPGEN" > "$CLIPS/.gen"; pass "Clipes de teste: 3 vídeos (H.264 Rec.709 e ProRes 4444 alfa de 12 s, HEVC 10-bit PQ/BT.2020 de 5 s), 2 guias estéreo e 6 monos"
else fail "Clipes de teste: só $n de 12 existem em $CLIPS"; finish; fi

# 3. Mux --------------------------------------------------------------------------------------------------------
L=$LOGS/mux_stereo.txt; rm -f "$OUT/mux/stereo.mov"
"$BIN" --job -o "$OUT/mux/stereo.mov" --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide.wav" --no-picture-check > "$L" 2>&1
if grep -q '^RESULT.*: ok' "$L" && grep -q 'bit-identical ✓' "$L" && grep -q 'Picture: bit-exact copy' "$L" && grep -q 'exact sync' "$L"; then
  pass "Mux com guia estéreo: ok, áudio bit a bit idêntico, imagem copiada sem recodificar, sync medido no arquivo final"
else fail "Mux com guia estéreo (veja $L)"; fi

L=$LOGS/mux_align.txt; rm -f "$OUT/mux/align.mov"
"$BIN" --job -o "$OUT/mux/align.mov" --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide_late100ms.wav" --align --no-picture-check > "$L" 2>&1
if grep -q '^RESULT.*: ok' "$L" && grep -q 'bit-identical ✓' "$L" && grep -qE 'cut 4,?800 samples' "$L" && grep -q 'exact sync' "$L"; then
  pass "Mux com guia 100 ms atrasado e --align: cortou 4.800 samples (0,100 s) sample exato, verificação bit a bit e sync ok"
else fail "Mux com guia 100 ms atrasado e --align (veja $L)"; fi

L=$LOGS/mux_group.txt; rm -f "$OUT/mux/group.mov"
"$BIN" --job -o "$OUT/mux/group.mov" --video "$CLIPS/h264_709.mov" $MONOS --no-picture-check > "$L" 2>&1
CH=$(probe a:0 channels "$OUT/mux/group.mov")
if grep -q '^RESULT.*: ok' "$L" && grep -q 'bit-identical ✓ (6 channels' "$L" && grep -q 'exact sync' "$L" && [[ $CH == 6 ]]; then
  pass "Mux com 6 monos: viraram uma faixa 5.1 (6 canais no arquivo), cada canal bit a bit igual ao mono de origem, sync ok"
else fail "Mux com 6 monos: canais no arquivo = ${CH:-?} (veja $L)"; fi

L=$LOGS/mux_hdr.txt; rm -f "$OUT/mux/hdr.mp4"
"$BIN" --job -o "$OUT/mux/hdr.mp4" --video "$CLIPS/hevc10_pq2020.mov" --encode --quality maximum --speed slow > "$L" 2>&1
if grep -q '^RESULT.*: ok' "$L" && grep -q 'Picture: RE-ENCODED' "$L" && grep -q 'signalled ✓' "$L"; then
  pass "Mux com encode HDR10 (fonte PQ/BT.2020): ok, imagem recodificada, HDR10 sinalizado no arquivo final"
else fail "Mux com encode HDR10 (veja $L)"; fi
GOT=$(grep '^COMMAND:' "$L" | sed -E 's#^COMMAND: ##; s#(-i) [^ ]+#\1 INPUT#; s#(-y) [^ ]+#\1 OUTPUT#')
if [[ -n $GOT && $GOT == "$(cat "$REF/dv-command.txt")" ]]; then
  pass "Comando ffmpeg/x265 do encode HDR/Dolby Vision idêntico à referência (qc/reference/dv-command.txt)"
else fail "Comando ffmpeg/x265 do encode HDR/Dolby Vision mudou em relação à referência:"; say "  ref: $(cat "$REF/dv-command.txt")"; say "  got: ${GOT:-nenhum}"; fi

# 4. Transcode --------------------------------------------------------------------------------------------------
for clip in prores4444_alpha hevc10_pq2020 h264_709; do
  src=$CLIPS/$clip.mov; SP=$(probe v:0 color_primaries "$src"); ST=$(probe v:0 color_transfer "$src"); FR=$(probe v:0 nb_frames "$src")
  for to in prores422hq prores422 h264 hevc; do
    case $to in
      prores*) ext=mov; codec=prores; pix=yuv422p10le;;
      h264)    ext=mp4; codec=h264;   pix=yuv420p;;
      hevc)    ext=mp4; codec=hevc;   pix=yuv420p10le;;
    esac
    o=$OUT/transcode/${clip}_$to.$ext; L=$LOGS/transcode_${clip}_$to.txt; rm -f "$o"
    "$BIN" --transcode "$src" --to $to --out "$o" > "$L" 2>&1
    if ! grep -q '^RESULT.*: ok' "$L"; then fail "Transcode $clip → $to: $(grep -m1 -E 'ERROR|✗|failed' "$L" | cut -c1-140) (veja $L)"; continue; fi
    got="$(probe v:0 codec_name "$o")/$(probe v:0 pix_fmt "$o")/$(probe v:0 nb_frames "$o")/$(probe v:0 r_frame_rate "$o")/$(probe v:0 color_primaries "$o")/$(probe v:0 color_transfer "$o")"
    want="$codec/$pix/$FR/24/1/$SP/$ST"
    tc=$(ffprobe -v error -show_entries stream_tags=timecode -of default=nw=1:nk=1 "$o" 2>/dev/null | grep -v '^$' | head -1)
    au=$(probe a:0 codec_name "$o")
    if [[ $got == "$want" && $tc == "01:00:00:00" && -n $au ]]; then pass "Transcode $clip → $to: $got, timecode $tc, áudio $au"
    else fail "Transcode $clip → $to: $got (esperado $want), timecode ${tc:-nenhum}, áudio ${au:-nenhum} (veja $L)"; fi
  done
done

# 5. capturas ---------------------------------------------------------------------------------------------------
snap() {
  local name=$1; shift
  "$BIN" --snapshot -o "$SHOTS/$name.png" "$@" > "$LOGS/snap_$name.txt" 2>&1
  if [[ -s $SHOTS/$name.png ]] && (( $(stat -f %z "$SHOTS/$name.png") > 20000 )); then pass "Captura $name.png"
  else fail "Captura $name.png não saiu (veja $LOGS/snap_$name.txt)"; fi
}
snap welcome --welcome
snap mux-stereo --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide.wav"
snap mux-group --video "$CLIPS/h264_709.mov" $MONOS
snap mux-banner --video "$CLIPS/hevc10_pq2020.mov" --dv "$REF/dummy_dv.xml"
snap mux-dark --dark --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide.wav"
snap transcode --transcode "$CLIPS/h264_709.mov"
snap transcode-hevc --transcode "$CLIPS/hevc10_pq2020.mov" --to hevc
snap checker --inspect "$CLIPS/h264_709.mov"

# 6. o app abre -------------------------------------------------------------------------------------------------
open -n -g "$APP"; sleep 6
if pgrep -f "$PWD/$APP/Contents/MacOS/BROS-MUX" > /dev/null; then
  pass "O app abre e continua aberto depois de 6 s"; pkill -f "$PWD/$APP/Contents/MacOS/BROS-MUX"
else fail "O app não ficou aberto (fechou sozinho ao abrir?)"; fi

finish
