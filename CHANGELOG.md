# Changelog

Toda atualização do BROS-MUX é registrada aqui: o que entrou, o que mudou, o que foi corrigido.

## Em desenvolvimento

(nada ainda)

## v1.6 — 2026-11-04

### Adicionado
- **Aba Transcode** (nova, ícone `arrow.triangle.2.circlepath`): o único lugar onde codec, qualidade, tamanho, resolução e cor mudam. Faixa fixa no topo: "Transcode · the file is re-encoded — codec, quality, size, resolution and colour can change. The original is never touched; a new file is always written." Área para soltar arquivos (vários viram uma fila, pastas são lidas), fila com estado por arquivo (Waiting / Transcoding… / Done ✓ / Failed ✗) e o cartão **Source → Destination** do arquivo selecionado: codec, bits, chroma, alfa, resolução, frame rate, cor, HDR, bitrate, áudio, timecode e container, com o que muda em laranja e o que é preservado em cinza, mais estimativa de tamanho e de tempo.
- Transcode, inspector: presets **ProRes 422 HQ — Academy**, **ProRes 422**, **H.264 — review copy**, **HEVC SDR**, **HEVC Dolby Vision** e Custom; codec (Apple ProRes / H.264 / HEVC); perfil ProRes (Proxy, LT, 422, 422 HQ, 4444, 4444 XQ) sem slider de qualidade; Quality (Master / Maximum / High / Compact) e Speed para H.264/HEVC; resolução Same / UHD (3840) / HD (1920); áudio Copy (bit a bit) / PCM 24-bit / AAC / none; formato MOV / MP4 / MKV; pasta de destino e nome do arquivo; tamanho e tempo estimados; espaço livre; Render QC e VMAF opcionais; selo previsto da Academia (ou "Where it plays" para HDR); comando ffmpeg para referência.
- Transcode, encoders: ProRes pelo encoder da própria Apple (`prores_videotoolbox`, o hardware de ProRes dos chips M; `prores_ks` do ffmpeg só se aquele não existir, conferido em `ffmpeg -encoders`); H.264 `libx264` (High, 8-bit); HEVC `libx265` (Main 10); a velocidade Draft usa `h264_videotoolbox` / `hevc_videotoolbox`. O ProRes 422 HQ de um clipe 1080p24 saiu a 141 Mb/s (tabela da Apple) e o VideoToolbox codificou 120 frames em 1 s.
- **Controle de bitrate do HEVC** (painel HDR da aba Mux e inspector da aba Transcode, picker "Bitrate"), com três modos: **Quality (CRF)**, o de sempre (nível Master / Maximum / High / Compact, bitrate segue a imagem até o teto); **Average (2-pass VBR)**, média alvo em Mbps sobre o filme inteiro — o ffmpeg roda duas vezes, a primeira só mede (`pass=1`, `slow-firstpass=0`, saída descartada) e a segunda gasta os bits onde o filme precisa (`pass=2`), com teto (`vbv-maxrate`/`vbv-bufsize` no pico); e **Constant (CBR)**, o mesmo bitrate do primeiro ao último frame (`-b:v` = `vbv-maxrate` = `vbv-bufsize`, `strict-cbr=1`).
- Presets de bitrate para os modos Average e Constant: **Streaming 4K** (25 Mbps, pico 40), **Blu-ray** (35, pico 40), **UHD Blu-ray** (80, pico 100), **Kaleidescape 4K Cinematic** (110, pico 160 — valor da própria Kaleidescape), **Master file** (200, pico 240) e **Custom**, com campos para digitar a média (ou o bitrate constante) e o pico em Mbps.
- **Piso de qualidade** (caixa "Quality floor", ligada por padrão) nos modos Average e Constant: `qpmax=18`, nenhum frame fica pior que QP 18 por mais fácil que a cena seja. O x265 não tem piso de bitrate; o piso é de qualidade.
- Linha de resumo sob o preset: modo, média, pico, piso e o Level HEVC — em laranja quando o pico passa de 160 Mbps (Level 5.2, fora do envelope Level 5.1 do UHD Blu-ray e da maioria dos players).
- Linha de comando: `--rate crf|2pass|cbr --mbps N [--max-mbps N] [--no-floor]` no `--job` e no `--transcode`.
- Estimativa de tamanho nos modos Average e Constant = alvo × duração; estimativa de tempo do 2-pass inclui a primeira passada (~35 %).
- Log e linhas de resultado dizem o modo usado: "CRF 4 (max 160 Mbps)", "2-pass average 110 Mbps (peak 160 Mbps, floor QP 18)" ou "CBR 110 Mbps".
- Transcode, HEVC com metadados HDR: HDR10 (mastering display, MaxCLL/MaxFALL lidos da fonte), Dolby Vision 8.1 (XML) e HDR10+ (JSON) — com Dolby Vision/HDR10+ a aba usa o mesmo caminho do Mux (stream HEVC + dovi_tool/hdr10plus_tool + MP4Box com o áudio bit a bit).
- Transcode, avisos no cartão: canal alfa descartado, 4:4:4 → 4:2:2 ou 4:2:0, 12/10 → 8 bits (com dither), fonte HDR em H.264 sem tone mapping ("washed out"), HEVC sem metadados HDR de uma fonte HDR, fonte SDR com metadados HDR, tags de cor incompletas, upscaling, ProRes fora do MOV, PCM em MP4 (vira AAC), fonte entrelaçada, Draft.
- Transcode, tone mapping HDR → SDR/BT.709 (`zscale` + `tonemap`) oferecido quando a fonte é HDR; se o ffmpeg não tiver o filtro `zscale` (o deste Mac, 9.0.2 do Homebrew, não tem libzimg), o app avisa no inspector e bloqueia o transcode com a mensagem do que instalar.
- Transcode, preservado: frame rate racional (`-r num/den`), timecode (`-timecode`, faixa tmcd no MOV/MP4), aspecto de pixel (vai nos frames) e layout de canais do áudio (copiado, ou PCM regravado com o mesmo layout).
- Transcode, verificação no fim: número de frames, duração, codec/perfil/bits/chroma/resolução/frame rate, tags de cor (primárias/transferência/matriz) e timecode contra a fonte, número de faixas de áudio; **Render QC** automático no resultado (ligado por padrão; erro vira ✗, aviso vira ⚠); **VMAF** opcional em até três trechos de 8 s contra a fonte (só aparece se o ffmpeg tiver `libvmaf`; 99,9 no teste); selos da **Academia** e do **Zidoo** no arquivo final. Se uma checagem falha e já existe um arquivo com o nome, o resultado fica ao lado como `_FAILED`.
- **File Checker**: quando o codec do vídeo reprova ou avisa (4444, HEVC etc.), aparece "The picture isn't what the Academy asks for" com o botão **Fix → Transcode to ProRes 422 HQ**, que abre a aba Transcode com o arquivo na fila e o preset escolhido.
- **Linha de comando**: `--transcode IN --to prores422hq|prores422|h264|hevc|hevcdv [--res hd|uhd] [--tonemap] [--quality master|maximum|high|compact] [--speed slow|medium|fast|draft] [--audio copy|pcm|aac|none] [--mov|--mp4|--mkv] [--dv XML] [--hdr10plus JSON] [--no-qc] [--vmaf] --out OUT` (imprime fonte, destino, o que muda, avisos, estimativa, comando, resultado e selos); `--snapshot --transcode FILE [--to preset]` fotografa a aba.
- **Aba Mux, clareza**: faixa fixa verde no topo, "Mux · nothing is re-encoded — picture and sound go in and out bit for bit; tracks are only combined.", também com a lista vazia.
- Aba Mux: **banner laranja** enquanto a recodificação está ligada. Título "Re-encoding turned on automatically" quando foi um arquivo que a ligou (IMF, XML Dolby Vision ou JSON HDR10+; o banner diz qual e por quê) ou "Re-encoding on" quando foi a pessoa; fonte → destino com codec, bits, chroma e bitrate da fonte (ffprobe/MediaInfo) e do destino (HEVC Main 10 · 10-bit · 4:2:0 · ~Mb/s), os formatos (Dolby Vision 8.1 + HDR10 + HDR10+), a cor escrita e "The audio stays bit for bit."; **Got it** encolhe para uma linha (o banner nunca some enquanto o encode está ligado; "Details" reabre); **Don't re-encode** tira o Dolby Vision e o HDR10+ e desliga o encode (desativado para IMF/MXF, que não podem ser copiados).
- Aba Mux: etiqueta na linha do vídeo, "COPY · bit-exact" em cinza ou "RE-ENCODE → HEVC 10-bit" em laranja; o botão principal vira **Re-encode & Mux**, laranja.
- Aba Mux: **confirmação** antes de começar quando o encode está ligado, com fonte → destino, formatos, tempo estimado e a opção "Don't ask again for this project" (volta a perguntar em Clear All).
- Aba Mux: linha **"Picture: RE-ENCODED (ProRes 4444 → HEVC Main 10)"** ou **"Picture: bit-exact copy (codec)"** no resultado do mux, no `--job` e no relatório `--write-report`.
- Painel HDR do Mux: linha "Colour: … — read from the source and repeated in the output" (ou "primaries/transfer missing in the source; BT.2020 / PQ assumed").
- `HDRSettings` registra quem ligou o encode (`autoEnabledBy`, `autoReason`), o estado do banner e a confirmação dispensada; `--job --dv XML` liga o encode sozinho como a janela faz.
- Aba Mux: vários sons mono PCM (WAVs mono, um por canal, ou os streams mono que o Resolve grava dentro do MOV ProRes) viram UMA faixa multicanal (estéreo, LCR, quad, 5.0, 5.1 ou 7.1) assim que os arquivos são lidos. A lista mostra "PCM 24-bit · 5.1 · 6 mono files/streams", os arquivos de cada canal e a ordem de saída; quem é quem vem dos rótulos de canal gravados nos arquivos, depois dos nomes (`.L.wav`, `_LFE`, `Ls`, `Lss`, `Rsr`…) e, se nada disser, da escuta do ChannelID em segundo plano.
- Aba Mux: botão "Channels…" na linha do grupo abre a folha de canais com o nome de cada arquivo por canal, correção manual, ordem de saída (SMPTE L R C LFE Ls Rs por padrão) e "Ungroup"; monos que ficaram soltos ganham o aviso "N mono PCM tracks on their own" com o botão "Group into one track".
- Aba Mux: Align, Sync Viewer e Picture Check tratam o grupo como uma faixa só (a referência de correlação é a soma dos canais sem o LFE) e um único offset corta os mesmos samples inteiros em todos os canais; no Picture Check o grupo toca com todos os canais juntos.
- Mux: os monos são intercalados num WAV temporário sem recompressão, entram no MP4Box como uma faixa só com os rótulos de canal, e a verificação bit a bit desintercala a faixa final e confere cada canal contra o mono de origem.
- Linha de comando: o `--job` agrupa os monos do mesmo jeito que a janela.
- HDR: nível de qualidade "Master" para a versão de playback HEVC, acima de "Maximum": CRF 4, teto 160 Mb/s, média ~100 Mb/s (medido no master do 2DIE4 pela outra sessão: CRF 10 dava só 8–22 Mb/s nesse filme limpo, sem grão).

### Mudado
- Motor: `VideoEncodePlan` e `VideoEncoder` saíram do `HDR.swift` para o novo `Transcode.swift` como `TranscodePlan` e `Transcode` (`arguments`, `encodeElementary`, `verifyElementary`), com `VideoTarget` (.prores / .h264 / .hevc), `ColorPipeline` (.passthrough / .toneMapToSDR), `AudioPlan`, `OutputResolution` e `HDRMeta`. O encode Dolby Vision do Mux usa esse motor com destino fixo HEVC 10-bit; **para uma fonte PQ/BT.2020 os argumentos do ffmpeg/x265 são idênticos aos da v1.5** (diff vazio entre o binário anterior e o novo no mesmo clipe).
- O `TranscodeRunner` reaproveita do mux: progresso por frame com tempo restante, cancelamento, `beginActivity` (o Mac não dorme), pasta temporária ao lado do destino, limpeza de temporários antigos, checagem de espaço livre e o monitor de CPU/GPU/RAM/disco.
- Cada faixa de vídeo guarda a descrição da fonte (`Track.source`: codec, perfil, bits, chroma, alfa, cor, frame rate racional, frames, timecode, SAR, ordem de campos), lida no mesmo ffprobe/MediaInfo de sempre; `ProbeStream` passa a ler `color_range`, `color_space`, `color_transfer`, `color_primaries`, `field_order`, `sample_aspect_ratio`, `nb_frames` e `chroma_location`.
- Bitrates aparecem como **Mbps** (e **kbps**) em toda a interface (antes "Mb/s" / "kb/s"): `Fmt.bitrate`, níveis de qualidade, File Checker, inspector da Transcode, cartão Fonte → Destino.
- Modo Quality (CRF): argumentos do ffmpeg/x265 inalterados (os modos novos só trocam a parte de rate control quando escolhidos).
- Nível **Master** do HEVC: CRF 4 (medido no master do 2DIE4: CRF 10 dava 8–22 Mb/s, CRF 4 dá ~100 Mb/s de média), teto 160 Mb/s.
- Tela inicial: o texto do FFmpeg cita a aba Transcode.
- Aba Mux: um 5.1 (ou qualquer áudio com mais de 2 canais) dentro do arquivo de vídeo deixa de virar referência de sync sozinho quando chegam áudios soltos; só um guia estéreo ou mono vira. Um 5.1 embutido é entrega, não guia.
- Zidoo: os textos das checagens falam do Z9X PRO da sala (Realtek RTD1619BPD): H.264 passa a "plays" (confirmado pelo dono no aparelho), VP9 e AV1 ficam "provável, não confirmado", HLG vira aviso, ProRes e codecs de masterização continuam reprovados.
- `build.sh` gera o app em `build.noindex/` (o Spotlight ignora a pasta, então só a cópia em /Applications aparece na busca); `install.sh` e o README seguem a mudança.

### Corrigido
- **Cor fixa no encode** (achado 2.8 do `CODE-REVIEW-2026-11-03.md`): o HEVC não é mais tagueado BT.2020/PQ sempre. Primárias, transferência, matriz e range são lidas da fonte (ffprobe, com MediaInfo para as tags que o ffprobe não conhece) e repetidas na saída, nos parâmetros do x265 e nas opções `-color_*`; BT.2020/PQ só é assumido quando a fonte HDR não traz as tags, e uma fonte tagueada SDR com Dolby Vision ligado é recusada antes de horas de encode ("The picture is tagged … (SDR)").
- A verificação do encode HDR do Mux confere as tags de cor escritas no arquivo final contra o plano (antes só testava o `2086` que o próprio x265 grava).
- ffmpeg 9 tira as tags de cor da saída dos frames, não das opções `-color_*`: ProRes e H.264 de uma fonte sem primárias/transferência saíam sem tags. O Transcode carimba os frames (`setparams`) para todos os encoders que não são o libx265, e ProRes 422 HQ / H.264 saem BT.709 / BT.709 / BT.709.

## v1.5 — 2026-11-03

### Adicionado
- Zidoo: o File Checker ganha a seção "Zidoo playback checks" e um selo dizendo se o arquivo toca no Zidoo da sala de projeção (container, vídeo e áudio contra as especificações publicadas pela Zidoo, linha Z9X / Z9X PRO), com a ressalva de que não foi testado no aparelho.
- Zidoo no resultado do mux: o banner de resultado mostra o selo Zidoo lido do arquivo final (também em MKV e com encode HDR, onde o selo da Academia não aparece).
- Zidoo na aba Mux: nova seção "Zidoo (screening room)" que prevê o selo a partir das fontes antes de muxar e lista até 3 problemas encontrados.
- Relatório em texto do File Checker ganha a seção ZIDOO PLAYBACK.
- Faixa Dolby Digital Plus (E-AC-3) que precisa começar mais tarde recebe um start delay no container (edit list, `delay=N/48000:moovts=-1` no MP4Box) em vez de silêncio recodificado; nenhum frame Dolby é tocado.

### Mudado
- O app passa a ser compilado só para Apple Silicon (arm64), sem fatia Intel, de propósito: o macOS 26 deixa de mostrar o aviso "Support Ending for Intel-based Apps". Requer Mac M1 ou mais novo.
- O Info.plist declara `LSRequiresNativeExecution` e `LSArchitecturePriority = arm64`, então o app nunca roda via Rosetta.
- `build.sh` compila com whole-module optimization (como o Release do Xcode), em uma única passada; a opção `FAST=1` deixou de existir.
- `install.sh` recusa instalar em Mac Intel, com mensagem explicando o motivo.
- Align (aba Mux): uma faixa E-AC-3 adiantada em relação à imagem agora é alinhada com start delay em vez de ser recusada com "can't be delayed without re-encoding".
- Sync Viewer: em faixas Dolby, o botão "1 Dolby frame (32 ms) ▶" não para mais em zero e pode empurrar o som para depois do início; os textos explicam que é um start delay no container.
- Semáforo de sync, resumo do plano, campo de corte da faixa e rodapé do painel Sync passam a descrever o atraso de E-AC-3 como start delay no container.
- A duração prevista da saída (selo da Academia previsto) passa a incluir o start delay das faixas E-AC-3.

### Corrigido
- Um erro de compilação agora interrompe o build, em vez de seguir e entregar só a fatia que compilou.

## v1.4 — 2026-11-03

### Mudado
- Picture Sync Check (1280×980) e Sync Viewer (1240×960) se ajustam à área visível da tela: antes eram mais altos que a tela de um MacBook de 14" e o botão Done ficava fora de alcance.
- O seletor de faixa no cabeçalho do Picture Sync Check e do Sync Viewer continua segmentado até 4 opções e, acima disso, vira um menu pop-up (título · nome do arquivo), para não estourar o cabeçalho com dezenas de faixas de áudio.
- Aba Mux: na largura mínima da janela com o inspector aberto, os campos de cada faixa passam para duas linhas em vez de ficarem cortados na borda.

## v1.3 — 2026-11-03

### Mudado
- Aba Mux: a lista de faixas rola sempre, inclusive enquanto os arquivos são lidos, durante o Align e durante o mux; só os controles das linhas (checkbox, campos, remover, arrastar) ficam travados.
- Aba Mux: avisos e o banner de resultado viram linhas no topo da lista, em vez de uma pilha acima dela que, com muitos arquivos, empurrava a lista para fora da janela; ao terminar o mux, a lista rola até eles.
- Aba Mux: cada arquivo aparece na lista assim que é lido, em vez de todos de uma vez no fim do lote.
- O comando MP4Box no inspector e o relatório MediaInfo no File Checker crescem junto com a página, em vez de ficarem numa caixa com rolagem própria que prendia a roda do mouse.
- A linha de cada faixa escolhe o layout largo ou compacto a partir da largura da lista.
- A tela de boas-vindas passa a ser uma folha (sheet) sobre a janela principal, menor (1040×700); Start, ou um arquivo aberto pelo Finder, a fecha.
- `install.sh` baixa o zip do Release direto do repositório público, sem precisar do `gh` logado.

### Corrigido
- A janela principal, depois da tela de boas-vindas, abria com a barra de ferramentas e as colunas mal configuradas: conteúdo por baixo da toolbar, lista sem rolagem e barra lateral vazia.
- Com muitos arquivos, a lista de faixas parecia travada e sem barra de rolagem.

## v1.2 — 2026-11-03

### Adicionado
- Identificação de canais PCM: o app ouve cada canal de uma faixa e diz quem é L, R, C, LFE, Ls, Rs, com porcentagem de confiança por canal e geral (LFE sem nada acima de 120 Hz, par frontal alto e correlacionado, centro com a fala, surrounds o que sobra); L/R dentro de um par seguem a ordem do arquivo.
- Painel de ordem de canais nas configurações do Mux: ouvir cada canal, corrigir os papéis e escolher a ordem de saída (SMPTE, Film, DTS ou personalizada).
- Reordenação no mux: os samples são permutados dentro de cada bloco do WAV, sem recompressão, e a verificação bit a bit confere contra a fonte permutada.
- O rótulo de canais (chan) segue a ordem gravada (MPEG_5_1_A/B/C/D) e não é escrito quando nenhuma tag da Apple descreve essa ordem.
- Resumo e janela de qualidade indicam faixas reordenadas ("+ reordered", "1:1 copy + reorder").
- Linha de comando: `--channels ARQUIVO.wav [--target ORDEM --out X.wav]`, `--channel-order ORDEM` no `--job` e `--snapshot --channelsheet`.

### Mudado
- README traz a URL real do repositório para o `git clone`.
- `install.sh` localiza o zip do Release com glob seguro (`null_glob` e array), então a falta do zip cai no download ou na compilação em vez de abortar.

### Corrigido
- Tag de layout 7.1 corrigida para MPEG_7_1_C.
- Resumo e estimativa de espaço livre levam em conta cópias que só reordenam canais.
- Ordens de saída inválidas são rejeitadas, e quantidades de canais e sample rates não suportados são recusados pelo motor.

## v1.1 — 2026-11-03

Primeira versão pública.

### Adicionado
- Mux sem perda de vídeo + áudios (PCM, Dolby Digital Plus JOC/Atmos, TrueHD) em MOV/MP4 com os átomos de canal e Dolby corretos para QuickTime, Resolve e a Academia; MKV sem perda para home theater.
- Sync por forma de onda: correlação cruzada em 15 pontos do filme, exata ao sample, com cortes só de samples inteiros na cabeça e na cauda, e Sync Viewer para ajuste fino.
- Semáforo de sync verde/vermelho com tolerância ATSC (−15/+45 ms) e checagem de imagem no arquivo já muxado.
- Picture Sync Check: cortes de imagem contra mudanças de som nas janelas entre 5% e 80% do filme, com loop de áudio e filmstrip.
- Aba Render QC: frames verdes/magenta/pretos/brancos, cartão "Media Offline" (OCR), frames repetidos, linhas e faixas de um frame, blocos chapados, saltos de timestamp, dropouts/cliques/clipping de áudio, canais mudos e duração A/V.
- File Checker contra as especificações do Academy Screening Room, com selo e relatório em texto.
- HDR: versões de playback com Dolby Vision (RPU reconstruído do IMF) e HDR10+.
- Atmos Visualizer 3D e loudness apenas como relatório.
- Painel de saída (pasta, nome, tamanho estimado, espaço livre) e monitor de CPU/GPU/RAM/disco durante o mux.
- Interface redesenhada no padrão Apple HIG, com a marca AB, e tela de boas-vindas que mostra cada engine com a versão instalada (o que faltar aparece em vermelho com o comando `brew`).
- Binário universal (Apple Silicon + Intel) gerado por `build.sh` com `swiftc`, sem projeto Xcode.
- `install.sh`: instala Homebrew, as engines (gpac/MP4Box, ffmpeg, media-info, dovi_tool, hdr10plus_tool) e o app, a partir do zip do Release ou compilando do código-fonte; `--build` força a compilação.
- Linha de comando: `--qc` (Render QC), `--picture` (Picture Sync Check) e `--snapshot --welcome`.

### Corrigido
- Correções da revisão de código: luminância de masterização, pontos de concatenação, stepper de sync e nome das checagens que falham.
