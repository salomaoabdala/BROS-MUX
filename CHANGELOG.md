# Changelog

Toda atualização do BROS-MUX é registrada aqui: o que entrou, o que mudou, o que foi corrigido.

## Em desenvolvimento

### Adicionado
- **O app avisa e recomenda a conversão para BT.2020** (regra do dono: todo erro corrigido vira um aviso dentro do app). Na aba Mux (painel HDR) e na aba Transcode, quando a fonte não é BT.2020 e o destino é HDR, aparece a caixa "Convert P3-D65 → BT.2020 (recommended)", ligada por padrão, com a explicação; desligada, o aviso fica laranja dizendo que o stream vai sair fora da convenção HDR10 e que players que assumem BT.2020 deslocam as cores. A linha "Colour:" diz quando converteu, e o log do `--job` também. Linha de comando: `--keep-source-primaries` desliga a conversão. **Render QC** ganhou o item "Colour tags": erro quando um stream PQ/HLG não está marcado BT.2020 / BT.2020 nc, aviso quando um HEVC UHD HDR não tem chroma siting top-left — pega esse erro em qualquer arquivo, nosso ou de fora.
- **Medidor de QP real** (`tools/render-monitor/qpreal.py`, ferramenta de desenvolvimento): depois do encode pronto, diz com que QP cada frame realmente saiu e quanto do filme ficou pior que o piso de qualidade. A passada 1 grava bits e QP por frame, de onde sai a complexidade; o tamanho de cada frame no arquivo final diz quanto a passada 2 gastou; dividindo um pelo outro sai o QP efetivo. Imprime QP médio, mediana, percentil 95, pior frame, e os piores trechos com timecode. Medido num encode 2-pass de controle, o QP derivado puxa de +0,2 a +1,0 para cima (a passada 1 mede com análise reduzida e superestima a complexidade), então a ferramenta também conta separado o que passa do piso por mais de 1,5 QP — é esse número que vale. Para o QP exato, o x265 teria de rodar com `--csv --csv-log-level 2`.
- **Monitor de render** (`tools/render-monitor/`, ferramenta de desenvolvimento, fora do app): página local em `http://localhost:8787` que acompanha os jobs do BROS-MUX rodando (`--job`) sem interferir neles — só lê o `ps` e o log do job. Mostra, por job: progresso do trabalho inteiro (as duas passadas somadas), **fps de agora** (medido numa janela de 90 s, em vez da média acumulada que o app imprime), fps médio da passada, frames feitos, quanto falta nesta passada e até o fim, horário previsto de término, gráfico do fps ao longo do tempo, o **tempo decorrido em cada etapa** (ler a metadata Dolby Vision, passada 1, passada 2, mux) e a lista das sessões de render abertas com início, tempo decorrido e CPU. Reconstrói a curva de fps da passada inteira a partir do próprio log (cada linha de progresso traz frame e fps médio, e daí sai o tempo decorrido), então o gráfico e a conta não dependem de o monitor estar aberto desde o começo. A previsão usa a **mediana dos últimos 20 min**, não a média acumulada, que fica inflada pelo preto e os créditos do começo do filme; e, como o x265 roda a passada 1 com `slow-firstpass=0`, conta a passada 2 como 2 a 3,5× mais lenta e mostra o término como uma faixa. Abre com dois cliques no **`monitor.command`** na pasta do projeto (ou `python3 tools/render-monitor/monitor.py`).
- **Monitor de render, visualizador de frame e de bitrate por cena.** A página mostra agora a **imagem do frame que está sendo processado** (extraída da fonte a cada 12 s, com uma thread só, sem atrapalhar o encode) e um **gráfico do bitrate que cada cena vai receber**, com o alvo e o teto marcados e o ponto onde o encode está. Os números saem do arquivo de estatísticas que a passada 1 do x265 escreve (bits, QP e tipo de cada frame), com a mesma conta do controle de taxa do x265 (complexidade = bits × qscale; bits da passada 2 ∝ complexidade^0,6), redistribuindo o que passa do `vbv-maxrate` para os outros frames, de modo que a média feche no bitrate-alvo. Ao lado da imagem, a **cena de agora**: quantos Mbps ela deve receber e em que posição ela está entre as mais pesadas. Abaixo, as cinco cenas mais pesadas e as cinco mais leves, com horário e duração. No 2DIE4 isso mostra o começo preto a 0,8 Mbps e as cenas de arquibancada batendo no teto de 160 Mbps.
- **Monitor de render acompanha também o app aberto por você**, não só os jobs da linha de comando. Sem log nenhum, ele descobre o que o BROS-MUX está fazendo pelos processos filhos (ffmpeg/x265, MP4Box, dovi_tool, mkvmerge) e pelo que eles já escreveram: na passada 1, o número de linhas do arquivo de estatísticas dá o frame exato; na passada 2, o tamanho do `.hevc` já gravado, convertido em frame pela previsão de bits que veio da passada 1; num encode de uma passada só com bitrate-alvo, o tamanho escrito. A tabela de sessões mostra cada BROS-MUX aberto, o que ele está fazendo, desde quando e quanto de CPU está usando — inclusive "parado, esperando você" quando o app está aberto sem processar nada.
- `qc.sh`: controle de qualidade automático antes de publicar — compila, confere a versão (build.sh, Design.swift, Info.plist, CHANGELOG), gera clipes de teste, roda o Mux com verificação bit a bit (guia estéreo, grupo de 6 monos, encode HDR10 com o comando ffmpeg/x265 conferido contra `qc/reference/dv-command.txt`), o Transcode de cada preset em cada clipe conferido com ffprobe, capturas de cada aba e a abertura do app; escreve `qc/out/QC-REPORT.txt`. A regra (nada é publicado no GitHub nem no `main` sem o QC aprovado) está no `CLAUDE.md`.
- Linha de comando, `--job`: `--no-source-audio` deixa de fora do mux o som que veio dentro do arquivo de vídeo (`--video`) e o mantém só como referência de sync do `--align`, inclusive quando os monos PCM dele viraram um grupo 5.1 (antes o grupo 5.1 entrava no arquivo e o `--align` ficava sem referência).
- **Medidor de alinhamento** (`Alignment.swift`): toda medição de sync vira um veredito de quanto do filme está alinhado e onde desalinha. Nos pontos medidos pelo "Align" (áudio contra a referência) e nas janelas do Picture check (som contra os cortes da imagem), o app agrupa os trechos com o mesmo deslocamento e escreve, por exemplo, "aligned 62% of the film (37:05 of 60:09) · from 37:05 to the end the sound is 1 fr + 0.0 ms late (41.7 ms)" — sempre em ms e em frames + ms. Aparece: no painel Sync de cada faixa (linha "Alignment meter", com semáforo, recalculada na hora quando o "Head trim (ms)" é digitado à mão, ou seja, diz quanto do filme o ajuste manual alinhou); nas linhas do "Align" e no `--job`/`--align` da linha de comando; na mensagem do Picture check (aba Mux, após o mux e `--picture`, que também lista trecho a trecho); e no **Render QC**, novo item "Sound vs picture" por faixa de áudio (info quando ≥ 95 % alinhado dentro da tolerância, aviso quando desalinha em parte, erro quando o trecho principal está fora de −15/+45 ms).
- "Align", quando nenhum deslocamento único serve (as faixas têm edições diferentes): além de dizer que as medições discordam, o app calcula o corte que alinha a maior parte do filme e escreve, por exemplo, "The one that aligns the most film is a head trim of +88.7 ms: aligned 62% … from 37:05 the sound is 1 fr late — type it in Head trim (ms) to use it".
- Linha de comando, `--job`: `--trim-ms N` define à mão o corte de cabeça (ms; negativo = o som começa depois) de cada faixa de áudio muxada, como o campo "Head trim (ms)", e imprime o medidor de alinhamento quando houve `--align`.

### Mudado
- **As chaves de qualidade do x265 passam a ser fixadas pelo app, em vez de virem do preset**: `psy-rd=2.0`, `psy-rdoq=1.0`, `rdoq-level=2`, `b-intra=1`, `weightb=1`. Lido do cabeçalho que o próprio x265 grava para cada preset: `psy-rdoq` e `rdoq-level` só ligam de `slow` para cima; `b-intra` (predição intra dentro de frames B) está **desligado no `slow`** e ligado no `medium` e de `slower` para cima — uma esquisitice do x265; `weightb` (predição ponderada nos frames B, que ajuda fades e fusões) só liga de `slower` para cima. Com isso, trocar o preset muda só o esforço de busca (o tempo), nunca o que o encoder pode fazer por textura, grão, fades e frames B. SAO continua desligado de propósito (ele suaviza grão), e o `aq-mode=3` continua forçado. Correção de um efeito colateral da troca do padrão para `medium`, feita hoje: no x265 o `psy-rdoq` e o `rdoq-level` só ligam nos presets `slow`, `slower` e `veryslow`. Conferido rodando o x265 aqui — em `slow` ele imprime `rd=4 psy-rd=2.00 rdoq=2 psy-rdoq=1.00`, em `medium` imprime `rd=3 psy-rd=2.00` e mais nada. Ou seja, mudar o preset estava desligando em silêncio o tratamento de textura, que é justamente o que preserva grão de filme. Agora trocar o preset muda a velocidade, e só.
- **O encode HDR da aba Mux passa a sair em `medium`** (era `slow`; `HDRSettings.speed`). Decisão do dono em 2026-11-04, confirmada pelo bench do 2DIE4 (cena difícil de 60 s, 2-pass): com as mesmas chaves de qualidade, o `slow` levou 1,7 a 1,9 vez o tempo do trabalho inteiro e ganhou no máximo 0,05 dB (Streaming 4K 25/40: 509 s contra 273 s; UHD Blu-ray 80/100: 735 s contra 439 s). No Master 110/160, numa rodada em que o `b-intra` ainda mudava com o preset, o `slow` levou 720 s contra 469 s e saiu 0,34 dB pior. Quem quiser o `slow` continua escolhendo na interface ou com `--speed slow`. A aba Transcode já saía em `medium`. **Não afeta encodes já rodando.**
- **Piso de qualidade agora é QP 16** (era 18), nos modos Average e Constant (`qpmax=16`). Decisão do dono em 2026-11-04, depois de medir no 2DIE4: o piso é uma garantia para os trabalhos de orçamento apertado, onde ele realmente entra; num master a 110 Mbps de média ele fica inerte de todo jeito (o filme inteiro custaria 65 Mbps em QP 18 e 82 Mbps em QP 16, bem abaixo dos 110 pedidos). O custo de subir o piso aparece nos encodes de bitrate baixo: cena fácil passa a consumir mais bits do que a repartição daria, e esses bits saem das cenas difíceis. **Não afeta encodes já rodando.**
- **E-AC-3 alinhado com exatidão**: um corte de cabeça que não cai num frame Dolby inteiro (1536 amostras, 32 ms) agora corta um frame a mais e atrasa o som pela diferença com um start delay no container (edit list, `moovts=-1`) — o resultado é exato, em vez de ficar até 32 ms atrasado. Vale no Mux, no Sync Viewer (o nudge já mostra o valor exato) e no Picture check "as it will be muxed". Os textos do painel Sync e do Sync Viewer que ainda falavam de "até 32 ms de atraso" foram atualizados.

### Corrigido
- **Marcação de cor do encode HDR/Dolby Vision corrigida — era o erro mais grave do app.** Um master P3-D65 (como o 2DIE4) saía marcado `colorprim=12` (P3-D65) e `colormatrix=1` (BT.709) num stream PQ, sem `chromaloc`, e com o `hdr10-opt` desligado em silêncio pelo x265 (ele só funciona com primárias 9, transfer 16, matriz 9). A camada base de um Dolby Vision 8.1 é um HDR10, e HDR10 é BT.2020; não existe matriz Y'CbCr padronizada para P3-D65 (SMPTE ST 2067-21:2020 diz textualmente que P3-D65 com Y'CbCr não é suportado). A causa era `outputColor` em `Transcode.swift`: "a matriz segue as primárias", que mandava P3-D65 para BT.709, e `isBT2020` dando falso pulava o chroma siting. Agora, num encode HDR, um master P3-D65 ou BT.709 é **convertido para BT.2020 em luz linear** (`ColorLUT.swift`: PQ decodificado → matriz 3×3 → PQ, numa LUT 3D de 65³ aplicada em float pelo `lut3d` do ffmpeg, porque este ffmpeg não tem `zscale`), e sai `bt2020 / smpte2084 / bt2020nc`, `chromaloc=2`, chroma siting top-left, caixa `colr` 9/16/9 — com o `hdr10-opt` finalmente ativo. As cores não mudam: BT.2020 é o recipiente; o mastering display continua P3-D65 no SEI, que é o lugar dele. Conferido contra a conta exata num frame real do 2DIE4: erro máximo de 0,58 código em 10 bits, 100% dos pixels dentro de 1 código. **Masters já codificados com a marcação antiga precisam ser reencodados; trocar só a etiqueta deixaria pior** (expandiria o gamut de pixels P3).
- **Picture check: cortes deslocados em 1 frame em algumas janelas.** O ffmpeg descarta os frames anteriores ao `-ss` depois de convertê-lo para a base de tempo do vídeo (1/24 num MOV de 24 fps); o app pedia meio frame antes do frame-alvo com seis casas decimais, e isso caía ora de um lado, ora do outro do arredondamento — numa janela saía um frame a mais no início e todos os cortes daquela janela (e as miniaturas do Sync Viewer) ficavam 1 frame atrasados (visto no 2DIE4: o corte de 21:30.583 lido como 21:30.625 numa conferência de 60 janelas). Agora o seek começa um quarto de frame antes, que arredonda sempre para o frame certo.

## v2.0.0 — 2026-11-05 · Beta 2.0.0 (prévia de trabalho, não publicada)

Versão de trabalho, instalada ao lado do app estável (`/Applications/BROS-MUX Beta 2.0.0.app`, bundle próprio). Inclui também tudo o que está em "Em desenvolvimento" acima (a v1.7 em preparo). Projeto e regras em `PLANO-BETA-2.0.0.md`.

### Adicionado
- **Novo caminho em passos**, no lugar das abas Mux e Transcode: **01 Video → 02 Audio → 03 Subtitles → 04 Delivery**. Depois de um divisor, "CHECK A FILE": File Checker, Render QC e Atmos Visualizer. Cada passo mostra o seu estado na barra lateral e marca em âmbar o que está pendente. Atalhos ⌘1 a ⌘7.
- **Roteamento automático:** cada arquivo solto vai para a aba a que pertence (imagem e metadados para Video, áudio para Audio, legendas para Subtitles, `.bmjob` para Delivery), com o aviso "X goes on the Y tab — added there". Uma imagem nova pergunta "Replace the picture?" e limpa o alinhamento. Várias imagens de uma vez oferecem "uma entrega por arquivo".
- **Aba Video:**
  - "Where will this file play?" (MOV, MP4 ou MKV);
  - cartão "You have: …" com miniatura e metadados;
  - análise na hora do XML Dolby Vision e do JSON HDR10+, com logo e linhas DETECTED → RECOMMENDED: frames, frame rate, Level 5 contra a letterbox medida, MaxCLL/MaxFALL zerados, P3-D65 → BT.2020, piso de qualidade × teto do Level 5.1. Cada linha tem a correção num clique;
  - o pop-up "a imagem não carrega isso", com os destinos possíveis (HEVC 10-bit Dolby Vision 8.1 pelo x265; hardware Apple desligado, com o motivo) ou "entregar sem Dolby Vision";
  - os assets de transcode (presets, modo, velocidade, Fonte → Destino, tamanho e tempo) dentro da própria aba.
- **Aba Audio:**
  - o som que veio no vídeo começa fora do arquivo e pergunta "Use it / Don't use". "Don't use" deixa a faixa com cadeado, servindo só de referência de sync;
  - cada faixa ganha o seletor "Not in the file / Audio track 1, 2, 3…";
  - alinhamento automático ao soltar a mix;
  - transcode opcional para AAC (640 Kbps no 5.1, 256 Kbps no estéreo) ou PCM 24-bit, com sync, nível e ordem dos canais verificados depois de escrever. Dolby (Atmos, E-AC-3, TrueHD) sai só em cópia.
- **Aba Subtitles:** espaço reservado. As legendas encontradas começam fora do arquivo e "Include" as põe dentro.
- **Aba Delivery:**
  - lista "BEFORE YOU START" com as pendências, cada uma ligada à aba dela;
  - plano do arquivo final com a "linha de sinal" (COPY ou TRANSCODE);
  - SAVE JOB (arquivo `.bmjob` + `.job.txt` legível); ADD TO QUEUE; START DELIVERY (⌘↩), que salva o job e o log antes de começar;
  - o render roda solto do app e sobrevive se ele for fechado;
  - a página de render, no estilo do Resolve: % total, etapas, frames, frame atual com miniatura, fps, ETA, achados ao vivo e uso da máquina;
  - o relatório "HOW THIS FILE WAS MADE" ao lado do arquivo.
- **Linguagem visual A · CRYO** em todo o app: vidro escuro congelado, luz ciano de borda que vira a barra de progresso, logos Dolby Vision e HDR10+ desenhados em vetor. A pasta `Logos/` aceita a arte oficial.
- **Linha de comando:**
  - `--job-file A.bmjob [B.bmjob…] [--dry-run]` roda jobs salvos sem janela;
  - `--job-file --capture OUT.bmjob <argumentos do --job>` grava um job;
  - `--selftest` é o autoteste do motor;
  - no `--snapshot`: `--tab`, `--popup` (dv, transcode, useaudio, savejob, replace, gallery) e `--demo-running`.

### Mudado
- As abas Mux e Transcode deixam de existir. O transcode em lote vira "uma entrega por arquivo" na fila da Delivery.
- O XML Dolby Vision ou o JSON HDR10+ soltos na janela não ligam mais a recodificação sozinhos: o app explica e pergunta. Na linha de comando (`--job --dv`), tudo continua como antes.
- O app é só escuro.
- **QC:**
  - saída dourada: os logs de `--job` e `--transcode` têm de ser idênticos aos do binário da base;
  - encode Dolby Vision real com um XML sintético de 120 frames;
  - clipe com 6 monos PCM embutidos no vídeo;
  - jobs `.bmjob` de ida e volta (cópia, ProRes em duas etapas, AAC);
  - recusa de Dolby Vision com a imagem em cópia;
  - capturas novas, uma por aba e por pop-up.

### Corrigido
- Nada é decidido em silêncio:
  - um som do vídeo sem resposta não entra mais no arquivo por engano;
  - um metadado Dolby Vision ou HDR10+ carregado com a imagem copiada impede o Start e diz por quê, em vez de sair sem o metadado.

## v1.6 — 2026-11-04

### Adicionado
- **Aba Transcode** (nova, ícone `arrow.triangle.2.circlepath`): o único lugar onde codec, qualidade, tamanho, resolução e cor mudam. Faixa fixa no topo: "Transcode · the file is re-encoded — codec, quality, size, resolution and colour can change. The original is never touched; a new file is always written." Área para soltar arquivos (vários viram uma fila, pastas são lidas), fila com estado por arquivo (Waiting / Transcoding… / Done ✓ / Failed ✗) e o cartão **Source → Destination** do arquivo selecionado: codec, bits, chroma, alfa, resolução, frame rate, cor, HDR, bitrate, áudio, timecode e container, com o que muda em laranja e o que é preservado em cinza, mais estimativa de tamanho e de tempo.
- Transcode, inspector: presets **ProRes 422 HQ — Academy**, **ProRes 422**, **H.264 — review copy**, **HEVC SDR**, **HEVC Dolby Vision** e Custom; codec (Apple ProRes / H.264 / HEVC); perfil ProRes (Proxy, LT, 422, 422 HQ, 4444, 4444 XQ) sem slider de qualidade; Quality (Master / Maximum / High / Compact) e Speed para H.264/HEVC; resolução Same / UHD (3840) / HD (1920); áudio Copy (bit a bit) / PCM 24-bit / AAC / none; formato MOV / MP4 / MKV; pasta de destino e nome do arquivo; tamanho e tempo estimados; espaço livre; Render QC e VMAF opcionais; selo previsto da Academia (ou "Where it plays" para HDR); comando ffmpeg para referência.
- Transcode, encoders: ProRes pelo encoder da própria Apple (`prores_videotoolbox`, o hardware de ProRes dos chips M; `prores_ks` do ffmpeg só se aquele não existir, conferido em `ffmpeg -encoders`); H.264 `libx264` (High, 8-bit); HEVC `libx265` (Main 10); a velocidade Draft usa `h264_videotoolbox` / `hevc_videotoolbox`. O ProRes 422 HQ de um clipe 1080p24 saiu a 141 Mbps (tabela da Apple) e o VideoToolbox codificou 120 frames em 1 s.
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
- Aba Mux: **banner laranja** enquanto a recodificação está ligada. Título "Re-encoding turned on automatically" quando foi um arquivo que a ligou (IMF, XML Dolby Vision ou JSON HDR10+; o banner diz qual e por quê) ou "Re-encoding on" quando foi a pessoa; fonte → destino com codec, bits, chroma e bitrate da fonte (ffprobe/MediaInfo) e do destino (HEVC Main 10 · 10-bit · 4:2:0 · ~Mbps), os formatos (Dolby Vision 8.1 + HDR10 + HDR10+), a cor escrita e "The audio stays bit for bit."; **Got it** encolhe para uma linha (o banner nunca some enquanto o encode está ligado; "Details" reabre); **Don't re-encode** tira o Dolby Vision e o HDR10+ e desliga o encode (desativado para IMF/MXF, que não podem ser copiados).
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
- HDR: nível de qualidade "Master" para a versão de playback HEVC, acima de "Maximum": CRF 4, teto 160 Mbps, média ~100 Mbps (medido no master do 2DIE4 pela outra sessão: CRF 10 dava só 8–22 Mbps nesse filme limpo, sem grão).

### Mudado
- Motor: `VideoEncodePlan` e `VideoEncoder` saíram do `HDR.swift` para o novo `Transcode.swift` como `TranscodePlan` e `Transcode` (`arguments`, `encodeElementary`, `verifyElementary`), com `VideoTarget` (.prores / .h264 / .hevc), `ColorPipeline` (.passthrough / .toneMapToSDR), `AudioPlan`, `OutputResolution` e `HDRMeta`. O encode Dolby Vision do Mux usa esse motor com destino fixo HEVC 10-bit; **para uma fonte PQ/BT.2020 os argumentos do ffmpeg/x265 são idênticos aos da v1.5** (diff vazio entre o binário anterior e o novo no mesmo clipe).
- O `TranscodeRunner` reaproveita do mux: progresso por frame com tempo restante, cancelamento, `beginActivity` (o Mac não dorme), pasta temporária ao lado do destino, limpeza de temporários antigos, checagem de espaço livre e o monitor de CPU/GPU/RAM/disco.
- Cada faixa de vídeo guarda a descrição da fonte (`Track.source`: codec, perfil, bits, chroma, alfa, cor, frame rate racional, frames, timecode, SAR, ordem de campos), lida no mesmo ffprobe/MediaInfo de sempre; `ProbeStream` passa a ler `color_range`, `color_space`, `color_transfer`, `color_primaries`, `field_order`, `sample_aspect_ratio`, `nb_frames` e `chroma_location`.
- Unidades: bitrate (o que define o tamanho do arquivo final) aparece como **Mbps** e **Kbps** em toda a interface (antes "Mb/s" / "kb/s"): `Fmt.bitrate`, níveis de qualidade, File Checker, inspector da Transcode, cartão Fonte → Destino, checagem do AAC da Academia ("640 Kbps for 5.1 or 256 Kbps for stereo"). Velocidade de leitura e gravação do disco (monitor mostrado durante um trabalho) fica em **MB/s** e **KB/s**.
- Modo Quality (CRF): argumentos do ffmpeg/x265 inalterados (os modos novos só trocam a parte de rate control quando escolhidos).
- Nível **Master** do HEVC: CRF 4 (medido no master do 2DIE4: CRF 10 dava 8–22 Mbps, CRF 4 dá ~100 Mbps de média), teto 160 Mbps.
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
