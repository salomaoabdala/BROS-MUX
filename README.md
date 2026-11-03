# BROS-MUX (v.1.4)

Muxer, verificador de sync e QC para entrega de filmes, da Abdala Brothers. App nativo de macOS (SwiftUI) que embrulha MP4Box, ffmpeg, ffprobe, MediaInfo, dovi_tool e hdr10plus_tool. Nada é recomprimido: cada faixa entra e sai bit a bit. Foi feito para entregar o filme **2DIE4** ao Academy Screening Room.

## O que ele faz

- **Mux sem perda** de vídeo + áudios (PCM, Dolby Digital Plus JOC/Atmos, TrueHD) em MOV/MP4 com os átomos de canal e Dolby corretos para QuickTime, Resolve e a Academia; MKV sem perda para home theater.
- **Channel order** (v1.2): ouve cada canal de uma faixa PCM e diz quem é L, R, C, LFE, Ls, Rs com porcentagem de confiança (o LFE não tem nada acima de 120 Hz, o par de frente é o par alto que anda junto, o centro carrega a fala, os surrounds são o que sobra); você corrige se quiser e escolhe a ordem de saída (SMPTE L R C LFE Ls Rs, Film L C R Ls Rs LFE, DTS, ou personalizada). No mux os samples são permutados dentro de cada bloco, sem recompressão, e a verificação bit a bit confere contra a fonte permutada. Esquerda/direita dentro de um par seguem a ordem do arquivo, porque o som não distingue.
- **Tela de MacBook** (v1.4): o Picture Sync Check e o Sync Viewer cabem na tela (antes eram mais altos que a tela de um MacBook de 14" e o botão Done ficava escondido); na largura mínima da janela com o inspector aberto, os campos de cada faixa ficam em duas linhas em vez de cortados; com mais de 4 faixas de áudio, o seletor de faixa desses dois painéis vira um menu (segmentado, ele estourava o cabeçalho).
- **Lista de faixas** (v1.3): rola sempre, inclusive enquanto os arquivos são lidos, durante o Align e durante o mux (só os controles das linhas ficam travados); cada arquivo aparece na lista assim que é lido; avisos e o resultado do mux rolam junto com a lista em vez de empurrá-la para fora da janela.
- **Sync**: correlação cruzada das formas de onda em 15 pontos do filme (exata ao sample), semáforo verde/vermelho com tolerância ATSC (−15/+45 ms), cortes só de samples inteiros na cabeça e na cauda.
- **Picture Sync Check**: cortes de imagem contra mudanças de som, com loop de áudio e filmstrip, nas janelas entre 5% e 80% do filme.
- **Render QC**: frames verdes/magenta/pretos/brancos, cartão "Media Offline" (OCR), frames repetidos, linhas e faixas de um frame, blocos chapados, saltos de timestamp, dropouts/cliques/clipping de áudio, canais mudos, duração A/V.
- **File Checker** contra as especificações da Academia, com selo e relatório em texto.
- **HDR**: versões de playback com Dolby Vision (RPU reconstruído do IMF) e HDR10+.
- **Atmos Visualizer** 3D, loudness só como relatório, monitor de CPU/GPU/RAM/disco durante o mux.

## Instalar em outro Mac

Requer macOS 14 (Sonoma) ou mais novo. O instalador cuida do resto (Homebrew, engines e o app):

```bash
git clone https://github.com/salomaoabdala/BROS-MUX.git && cd BROS-MUX && ./install.sh
```

O `install.sh`:

1. instala o Homebrew se não existir;
2. instala `gpac` (MP4Box), `ffmpeg`, `media-info`, `dovi_tool` e `hdr10plus_tool`;
3. instala o app a partir do `BROS-MUX-v*.zip` (o zip do Release, colocado na pasta ou em `dist/`), baixando-o do GitHub se o `gh` estiver logado, ou compila do código-fonte se houver Xcode Command Line Tools;
4. copia para `/Applications`, tira a quarentena do download (o app é assinado ad hoc) e abre.

Sem Command Line Tools e sem o zip, ele dispara `xcode-select --install` e pede para rodar de novo. Para forçar a compilação: `./install.sh --build`.

A tela inicial do app mostra cada engine com a versão instalada; o que faltar aparece em vermelho com o comando `brew` para instalar.

## Compilar

```bash
./build.sh
```

Gera `build/BROS-MUX.app` universal (Apple Silicon + Intel) com `swiftc`, sem Xcode project. `FAST=1 ./build.sh` compila só para a arquitetura da máquina. A versão fica em `VERSION` no `build.sh` e em `AppInfo.version` no `Design.swift`.

## Linha de comando

O binário dentro do app aceita alguns comandos sem interface:

```bash
/Applications/BROS-MUX.app/Contents/MacOS/BROS-MUX --qc FILME.mov
```

```bash
/Applications/BROS-MUX.app/Contents/MacOS/BROS-MUX --picture FILME.mov --verbose
```

```bash
/Applications/BROS-MUX.app/Contents/MacOS/BROS-MUX --channels MIX.wav --target "L C R Ls Rs LFE" --out MIX_film.wav
```

`--qc` roda o Render QC; `--picture` roda o Picture Sync Check; `--channels` identifica os canais de um WAV e, com `--target`/`--out`, grava uma cópia reordenada; no `--job`, `--channel-order "L C R Ls Rs LFE"` reordena as faixas PCM durante o mux; `--snapshot --welcome -o tela.png` tira uma captura da tela inicial.

## Arquivos

| Arquivo | O que é |
|---|---|
| `BrosMux.swift` | modelo do projeto, mux, checagens pós-mux, File Checker, CLI |
| `MuxUI.swift`, `CheckerUI.swift`, `Design.swift`, `ABMark.swift` | interface (Apple HIG) e sistema de design |
| `SyncViewer.swift`, `PictureSync.swift` | sync por forma de onda e por cortes de imagem |
| `ChannelID.swift`, `ChannelOrderUI.swift` | identificação e reordenação de canais PCM |
| `RenderQCEngine.swift`, `RenderQC.swift` | motor e aba do Render QC |
| `HDR.swift` | Dolby Vision / HDR10+ |
| `AtmosDecoder.swift`, `AtmosOAMD.swift`, `AtmosViz.swift` | metadados Atmos e visualizador 3D |
| `Monitor.swift`, `Welcome.swift` | monitor de sistema e tela inicial |
| `CODE-REVIEW-2026-11-03.md` | revisão de código (22 achados confirmados, ideias de produto) |
| `ANALISE-2026-11-03.md` | ffmpeg × BROS-MUX, TrueHD, Zidoo, bitrates |
| `RENDER-QC-2DIE4-2026-11-03.txt` | resultado do Render QC no arquivo entregue à Academia |

## Regra da casa

O app nunca altera a mixagem nem os arquivos de origem: loudness é só relatório, cortes de sync são sem perda, e tudo que sai é cópia do que entrou.
