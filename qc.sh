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
#   4c. TrueHD 5.1 copiado para um MKV (o MP4Box não importa TrueHD: ele vai direto para o Matroska, bit a bit);
#   4d. Dolby Media Encoder, quando está instalado e o master Atmos real está montado (BROS_QC_ADM troca o caminho):
#      30 s do master → DD+ Atmos num MP4 e TrueHD Atmos num MKV, conferidos (codec, Atmos, JOC, duração, bit a bit);
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
CLIPGEN=4                      # suba quando os clipes de teste mudarem: eles são gerados de novo
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
TP3="setparams=color_primaries=smpte432:color_trc=smpte2084:colorspace=bt709:range=tv"
[[ -f $CLIPS/prores4444_p3pq.mov ]] || $FF -f lavfi -i "$VSRC" -i "$R" -t 5 -vf "format=yuv444p10le,$TP3" -c:v prores_ks -profile:v 4 -pix_fmt yuv444p10le -vendor apl0 -color_primaries smpte432 -color_trc smpte2084 -colorspace bt709 -color_range tv -c:a pcm_s24le -timecode 01:00:00:00 "$CLIPS/prores4444_p3pq.mov"
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
# a picture carrying a 5.1 as six mono PCM streams inside the MOV (what DaVinci Resolve writes; the 2DIE4 master is like this)
[[ -f $CLIPS/h264_6monos.mov ]] || $FF -f lavfi -i "$VSRC" -i "$CLIPS/tone.L.wav" -i "$CLIPS/tone.R.wav" -i "$CLIPS/tone.C.wav" -i "$CLIPS/tone.LFE.wav" -i "$CLIPS/tone.Ls.wav" -i "$CLIPS/tone.Rs.wav" -t 12 -map 0:v -map 1:a -map 2:a -map 3:a -map 4:a -map 5:a -map 6:a -vf "format=yuv420p,$T709" -c:v libx264 -preset ultrafast -crf 18 -c:a pcm_s24le -timecode 01:00:00:00 "$CLIPS/h264_6monos.mov"
n=0; for f in ref.wav h264_709.mov prores4444_alpha.mov hevc10_pq2020.mov prores4444_p3pq.mov h264_6monos.mov guide.wav guide_late100ms.wav tone.L.wav tone.R.wav tone.C.wav tone.LFE.wav tone.Ls.wav tone.Rs.wav; do [[ -s $CLIPS/$f ]] && (( n++ )); done
if (( n == 14 )); then print -r -- "$CLIPGEN" > "$CLIPS/.gen"; pass "Clipes de teste: 5 vídeos (H.264 Rec.709, ProRes 4444 alfa e H.264 com 6 monos PCM embutidos de 12 s; HEVC 10-bit PQ/BT.2020 e ProRes 4444 P3-D65/PQ de 5 s), 2 guias estéreo e 6 monos"
else fail "Clipes de teste: só $n de 14 existem em $CLIPS"; finish; fi

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

# um master P3-D65 (como o 2DIE4) tem de sair BT.2020, e o app tem de dizer que converteu
tags() { echo "$(probe v:0 color_primaries "$1")/$(probe v:0 color_space "$1")/$(probe v:0 color_transfer "$1")/$(probe v:0 chroma_location "$1")" }
L=$LOGS/mux_hdr_p3.txt; rm -f "$OUT/mux/hdr_p3.mp4"
"$BIN" --job -o "$OUT/mux/hdr_p3.mp4" --video "$CLIPS/prores4444_p3pq.mov" --encode --quality maximum --speed slow > "$L" 2>&1
T=$(tags "$OUT/mux/hdr_p3.mp4")
if grep -q '^RESULT.*: ok' "$L" && grep -q 'lut3d=file=' "$L" && grep -q 'converted in linear light' "$L" && [[ $T == "bt2020/bt2020nc/smpte2084/topleft" ]]; then
  pass "Encode HDR10 de fonte P3-D65: convertida para BT.2020 (lut3d no comando, tags $T, chroma siting top-left, o log diz que converteu)"
else fail "Encode HDR10 de fonte P3-D65: tags ${T:-?} (esperado bt2020/bt2020nc/smpte2084/topleft) (veja $L)"; fi
# ... e com a conversão desligada ele sai como veio, mas AVISA — nunca em silêncio
L=$LOGS/mux_hdr_p3_keep.txt; rm -f "$OUT/mux/hdr_p3_keep.mp4"
"$BIN" --job -o "$OUT/mux/hdr_p3_keep.mp4" --video "$CLIPS/prores4444_p3pq.mov" --encode --quality maximum --speed slow --keep-source-primaries > "$L" 2>&1
T=$(tags "$OUT/mux/hdr_p3_keep.mp4")
if grep -q '^RESULT.*: ok' "$L" && grep -q 'WARNING: The source is P3-D65' "$L" && [[ $T == smpte432/bt709/smpte2084/* ]]; then
  pass "Encode HDR10 com --keep-source-primaries: sai como veio (tags $T) e o log avisa que está fora da convenção HDR10"
else fail "Encode HDR10 com --keep-source-primaries: tags ${T:-?}, aviso $(grep -c 'WARNING: The source is P3-D65' "$L") (veja $L)"; fi

# Dolby Vision de verdade: um XML sintético válido (120 frames, 2 shots), lido de volta do arquivo final
for src in hevc10_pq2020 prores4444_p3pq; do
  L=$LOGS/mux_dv_$src.txt; rm -f "$OUT/mux/dv_$src.mp4"
  "$BIN" --job -o "$OUT/mux/dv_$src.mp4" --video "$CLIPS/$src.mov" --dv "$REF/dv-120f.xml" --quality maximum --speed slow > "$L" 2>&1
  if grep -q '^RESULT.*: ok' "$L" && grep -q 'Dolby Vision 8.1 (HDR10-compatible): signalled ✓' "$L" && grep -q 'identical to the generated RPU, all 120 frames (2 shots) ✓' "$L"; then
    pass "Encode Dolby Vision de $src com XML válido: ok, DV 8.1 sinalizado, metadado lido de volta idêntico (120 frames, 2 shots)"
  else fail "Encode Dolby Vision de $src (veja $L)"; fi
done

# o caso do dono: o vídeo traz um 5.1 em 6 monos PCM; a linha de comando deixa o som do vídeo de fora e o usa como referência
L=$LOGS/mux_embedded_monos.txt; rm -f "$OUT/mux/embedded_monos.mov"
"$BIN" --job -o "$OUT/mux/embedded_monos.mov" --video "$CLIPS/h264_6monos.mov" --add "$CLIPS/guide.wav" --no-source-audio --no-picture-check > "$L" 2>&1
NA=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT/mux/embedded_monos.mov" 2>/dev/null | grep -c .)
CH=$(probe a:0 channels "$OUT/mux/embedded_monos.mov")
if grep -q '^RESULT.*: ok' "$L" && grep -q 'bit-identical ✓' "$L" && [[ $NA == 1 && $CH == 2 ]]; then
  pass "Vídeo com 6 monos embutidos + guia: o som do vídeo ficou fora (1 faixa de áudio, $CH canais), guia bit a bit"
else fail "Vídeo com 6 monos embutidos: $NA faixa(s) de áudio, $CH canais (veja $L)"; fi

# saída dourada: com a mesma entrada, o motor imprime exatamente o mesmo que o binário da base (qc/reference/golden)
norm() { sed -E "s#$PWD#.#g; s#RESULT \([0-9]+ s\)#RESULT (N s)#; s#BROS-MUX-tmp-[0-9A-Fa-f-]+#BROS-MUX-tmp-X#g; s#frames in [0-9]+ s#frames in N s#g" "$1" | grep -v '^  … ' }
golden() {
  local g n bad=() ok=0
  for g in $REF/golden/*.txt; do
    n=${g:t}
    if [[ ! -f $LOGS/$n ]]; then bad+=("$n (não gerado)"); continue; fi
    if diff -q <(norm "$LOGS/$n") "$g" > /dev/null; then (( ok++ )); else bad+=("$n"); diff <(norm "$LOGS/$n") "$g" > "$LOGS/golden_${n%.txt}.diff"; fi
  done
  if (( ${#bad} == 0 )); then pass "Saída dourada: $ok logs de --job e --transcode idênticos aos do binário da base"
  else fail "Saída dourada: ${#bad} log(s) mudaram em relação ao binário da base: ${bad[*]} (diffs em $LOGS/golden_*.diff)"; fi
}

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

golden

# 4b. Delivery: o arquivo de job (.bmjob) reproduz o projeto e roda sem janela (--job-file) --------------------------
JF=$OUT/jobs; rm -rf "$JF"; mkdir -p "$JF"
canon() { awk '/^CANONICAL:/{f=1;next} /^COMMAND:|^BEFORE YOU START:|^JOB FILE:/{f=0} f' "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' }
jobcase() {   # NAME DEST -- the --job arguments (+ --to P, --audio-delivery X, --video-copy): grava, relê, compara, roda
  local name=$1 dest=$2; shift 2
  local job=$JF/$name.bmjob L=$LOGS/jobfile_$name.txt
  "$BIN" --job-file --capture "$job" -o "$dest" "$@" > "$JF/$name.capture.txt" 2>&1
  [[ -s $job ]] || { fail "Job $name: o .bmjob não foi gravado (veja $JF/$name.capture.txt)"; return 1 }
  "$BIN" --job-file "$job" --dry-run > "$JF/$name.dry.txt" 2>&1
  if ! diff -q <(canon "$JF/$name.capture.txt") <(canon "$JF/$name.dry.txt") > /dev/null || [[ -z $(canon "$JF/$name.capture.txt") ]]; then
    fail "Job $name: o job relido não reproduz o projeto (diff entre $JF/$name.capture.txt e $JF/$name.dry.txt)"; return 1; fi
  "$BIN" --job-file "$job" > "$L" 2>&1
  grep -qE '^RESULT.*: (ok|done)' "$L" || { fail "Job $name: o render não terminou ok (veja $L)"; return 1 }
  return 0
}
if jobcase copy "$JF/copy.mov" --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide.wav" --no-picture-check; then
  pass "Job salvo e rodado sem janela (--job-file): cópia bit a bit, o job relido reproduz o projeto"; fi
if jobcase prores "$JF/prores.mov" --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide.wav" --to prores422hq --no-picture-check; then
  c=$(probe v:0 codec_name "$JF/prores.mov"); p=$(probe v:0 profile "$JF/prores.mov"); NT=$(ffprobe -v error -show_entries stream=index,codec_tag_string -of csv=p=0 "$JF/prores.mov" | sort -u | grep -c tmcd)
  if [[ $c == prores && $p == *HQ* && $NT == 1 ]] && grep -q 'TRANSCODED in step 1' "$LOGS/jobfile_prores.txt"; then pass "Job em duas etapas: ProRes 422 HQ + áudio externo bit a bit, um só timecode, o resultado diz que a imagem foi transcodada"
  else fail "Job em duas etapas: codec $c perfil $p timecodes $NT (veja $LOGS/jobfile_prores.txt)"; fi
fi
if jobcase aac "$JF/aac.mp4" --video "$CLIPS/h264_709.mov" $MONOS --audio-delivery aac --no-picture-check; then
  a=$(probe a:0 codec_name "$JF/aac.mp4"); ch=$(probe a:0 channels "$JF/aac.mp4")
  if [[ $a == aac && $ch == 6 ]] && grep -qi 'lag 0' "$LOGS/jobfile_aac.txt"; then pass "Job com áudio transcodado para AAC 5.1: 6 canais, sync conferido (atraso 0) e níveis por canal conferidos"
  else fail "Job com AAC: codec $a, $ch canais (veja $LOGS/jobfile_aac.txt)"; fi
fi
"$BIN" --job-file --capture "$JF/dvcopy.bmjob" -o "$JF/dvcopy.mp4" --video "$CLIPS/hevc10_pq2020.mov" --dv "$REF/dv-120f.xml" --video-copy > "$LOGS/jobfile_dvcopy.txt" 2>&1
if ! "$BIN" --job-file "$JF/dvcopy.bmjob" --dry-run >> "$LOGS/jobfile_dvcopy.txt" 2>&1 && grep -q 'loaded but the picture would be copied' "$LOGS/jobfile_dvcopy.txt"; then
  pass "Dolby Vision carregado com a imagem em COPY: o job se recusa a começar e diz por quê (nunca em silêncio)"
else fail "Dolby Vision com a imagem em COPY não foi recusado (veja $LOGS/jobfile_dvcopy.txt)"; fi

# 4c. TrueHD num MKV (Beta 2.0.1): o MP4Box não importa TrueHD; o app o copia direto para o Matroska, bit a bit
[[ -s $CLIPS/truehd51.thd ]] || $FF -i "$CLIPS/tone.L.wav" -i "$CLIPS/tone.R.wav" -i "$CLIPS/tone.C.wav" -i "$CLIPS/tone.LFE.wav" -i "$CLIPS/tone.Ls.wav" -i "$CLIPS/tone.Rs.wav" \
  -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]join=inputs=6:channel_layout=5.1(side)[a]" -map "[a]" -c:a truehd -strict -2 "$CLIPS/truehd51.thd"
L=$LOGS/mux_truehd_mkv.txt; rm -f "$OUT/mux/truehd.mkv"
"$BIN" --job -o "$OUT/mux/truehd.mkv" --video "$CLIPS/h264_709.mov" --add "$CLIPS/truehd51.thd" --no-picture-check > "$L" 2>&1
TC=$(probe a:0 codec_name "$OUT/mux/truehd.mkv"); NV=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$OUT/mux/truehd.mkv" 2>/dev/null | grep -c .)
if grep -q '^RESULT.*: ok' "$L" && grep -q 'bit-identical ✓' "$L" && [[ $TC == truehd && $NV == 1 ]]; then
  pass "TrueHD 5.1 num MKV com imagem: entra direto no Matroska (o MP4Box não importa TrueHD), bit a bit idêntico, sync ok"
else fail "TrueHD num MKV: áudio ${TC:-nenhum}, $NV vídeo(s) (veja $L)"; fi

# 4d. Dolby Media Encoder (Beta 2.0.1): 30 s de um master Atmos real → DD+ Atmos (MP4) e TrueHD Atmos (MKV)
ADM=${BROS_QC_ADM:-/Volumes/A018/2Die4_20260209_Atmos_Cinema .wav}
DME="/Applications/Dolby/Dolby Media Encoder/Dolby Media Encoder.app"
if [[ ! -d $DME ]]; then warn "Dolby Media Encoder: não testado — o DME não está instalado neste Mac"
elif [[ ! -f $ADM ]]; then warn "Dolby Media Encoder: não testado — o master Atmos não está aqui ($ADM; outro: BROS_QC_ADM=…)"
else
  export BROS_DME_TEST_RANGE="00:10:00:00-00:10:30:00"
  for case in ddpAtmos:mp4:eac3 trueHDAtmos:mkv:truehd; do
    d=${case%%:*}; rest=${case#*:}; ext=${rest%%:*}; codec=${rest#*:}
    o=$JF/dme_$d.$ext; L=$LOGS/jobfile_dme_$d.txt; rm -f "$o"
    "$BIN" --job-file --capture "$JF/dme_$d.bmjob" --audio-delivery $d -o "$o" --add "$ADM" > "$JF/dme_$d.capture.txt" 2>&1
    "$BIN" --job-file "$JF/dme_$d.bmjob" > "$L" 2>&1
    c=$(probe a:0 codec_name "$o"); prof=$(probe a:0 profile "$o")
    others=$(grep -E '✗|⚠' "$L" | grep -vc 'Render QC couldn.t read\|QC test range\|There.s no picture')
    if grep -qE '^RESULT.*: (ok|done|warning)' "$L" && grep -q 'Dolby Media Encoder made in step 1 ✓' "$L" && [[ $c == $codec && $prof == *Atmos* && $others == 0 ]]; then
      pass "Dolby Media Encoder → $d ($ext): $prof, $(grep -o 'Length: [^✓]*✓' "$L" | tail -1), copiado bit a bit (30 s do master, faixa de teste)"
    else fail "Dolby Media Encoder → $d: codec ${c:-nenhum} ${prof:-}, $others problema(s) (veja $L)"; fi
  done
  unset BROS_DME_TEST_RANGE
fi

# 5. capturas ---------------------------------------------------------------------------------------------------
snap() {
  local name=$1; shift
  "$BIN" --snapshot -o "$SHOTS/$name.png" "$@" > "$LOGS/snap_$name.txt" 2>&1
  if [[ -s $SHOTS/$name.png ]] && (( $(stat -f %z "$SHOTS/$name.png") > 20000 )); then pass "Captura $name.png"
  else fail "Captura $name.png não saiu (veja $LOGS/snap_$name.txt)"; fi
}
# Beta 2.0.0: uma captura por aba e por pop-up (as da v1.x tinham outros nomes: a comparação é a folha antes × depois)
snap welcome --welcome
snap gallery --popup gallery
snap video-empty --tab video
snap video-copy --tab video --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide.wav"
snap video-dv --tab video --video "$CLIPS/prores4444_p3pq.mov" --dv "$REF/dv-120f.xml"
snap popup-dv --popup dv --video "$CLIPS/prores4444_p3pq.mov" --dv "$REF/dv-120f.xml"
snap popup-transcode --popup transcode --video "$CLIPS/prores4444_p3pq.mov" --dv "$REF/dv-120f.xml"
snap video-transcode --transcode "$CLIPS/h264_709.mov" --to prores422hq
snap audio-stereo --tab audio --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide.wav"
snap audio-monos --tab audio --video "$CLIPS/h264_6monos.mov" --add "$CLIPS/guide.wav"
snap popup-useaudio --popup useaudio --video "$CLIPS/h264_6monos.mov" --add "$CLIPS/guide.wav"
snap audio-group --tab audio --video "$CLIPS/h264_709.mov" $MONOS
[[ -f $ADM ]] && snap audio-atmos-master --tab audio --video "$CLIPS/h264_709.mov" --add "$ADM"
snap subtitles --tab subtitles --video "$CLIPS/h264_709.mov"
snap delivery --tab delivery --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide.wav"
snap delivery-running --demo-running
snap popup-savejob --popup savejob --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide.wav"
snap checker --inspect "$CLIPS/h264_709.mov"
snap renderqc --tab qc
snap atmos --tab atmos
snap syncviewer --syncviewer --video "$CLIPS/h264_709.mov" --add "$CLIPS/guide_late100ms.wav" --align

# 6. o app abre -------------------------------------------------------------------------------------------------
open -n -g "$APP"; sleep 6
if pgrep -f "$PWD/$APP/Contents/MacOS/BROS-MUX" > /dev/null; then
  pass "O app abre e continua aberto depois de 6 s"; pkill -f "$PWD/$APP/Contents/MacOS/BROS-MUX"
else fail "O app não ficou aberto (fechou sozinho ao abrir?)"; fi

finish
