# Plano: Transcode no BROS-MUX

> Documento de contexto para continuar a discussão em outra conversa. Ainda não há nada implementado; é só o plano.

## Contexto do app

O **BROS-MUX** (v1.5) é um app nativo de macOS para Apple Silicon, feito em SwiftUI e compilado com `swiftc`, sem projeto Xcode. É da Abdala Brothers e serve para muxar, verificar sync e fazer QC na entrega de filmes (o filme **2DIE4** foi entregue com ele ao Academy Screening Room). Ele chama MP4Box, ffmpeg, ffprobe, MediaInfo, dovi_tool e hdr10plus_tool.

**Regra da casa:** nada é recomprimido. Cada faixa entra e sai bit a bit, e o app nunca altera a mixagem nem os arquivos de origem.

Abas atuais (`enum AppMode` em `BrosMux.swift:2211`): **Mux**, **File Checker**, **Atmos Visualizer** e **Render QC**. A navegação fica em `ContentView` (`MuxUI.swift`): sidebar, área central e inspector à direita.

Arquivos que interessam a este plano:

| Arquivo | O que tem |
|---|---|
| `BrosMux.swift` | modelo `Project`, `JobRunner` (mux, checagens, temporários, progresso), File Checker, CLI |
| `MuxUI.swift` | interface da aba Mux (`TrackRow`, `MuxInspector`, `OutputSection`, `QualitySheet`) |
| `HDR.swift` | `HDRSettings` (enums `Quality` e `Speed`), `VideoEncodePlan`, `VideoEncoder` (`ffmpegArguments`, `run`, `verify`), `HDRPanel` |
| `CODE-REVIEW-2026-11-03.md` | revisão de código; aponta que o encoder grava a cor BT.2020/PQ fixa |

### A aba Mux já transcodifica

Quando o usuário solta um XML de Dolby Vision ou um JSON de HDR10+, o código liga `hdr.encode = true` sozinho (`BrosMux.swift:~2410`). Aí a imagem é recodificada para **HEVC 10-bit 4:2:0** com `libx265` (`HDR.swift:684`, `VideoEncoder.ffmpegArguments`), com Dolby Vision 8.1, HDR10 e HDR10+ injetados, e o botão muda de "Mux" para "Encode & Mux". O áudio continua bit a bit.

Hoje isso só fica sinalizado no texto do botão e no rodapé do painel "HDR · Dolby Vision · HDR10+", no inspector.

Controles atuais desse encode (`HDRSettings`):

- **Quality:** Maximum (CRF 14, VBV 100 Mb/s), High (CRF 16, 70 Mb/s) e Compact (CRF 19, 40 Mb/s)
- **Speed:** Slow, Medium, Fast e Draft, que viram presets do x265

## 1. Nome da função

O nome certo é **Transcode**: decodificar e codificar de novo em outro codec ou perfil. Exemplos: ProRes 4444 → ProRes 422 HQ, ou HEVC 10-bit → H.264. **Mux** é só reembalar as faixas sem tocar nelas. A alternativa mais leiga para o nome da aba seria "Convert".

## 2. Decisão: aba nova + sinalização no Mux, com um motor só

1. **Aba nova "Transcode"**, para converter um arquivo por conta própria: solta o arquivo, escolhe o destino e exporta. A aba Mux continua seguindo a regra da casa, e é isso que dá confiança nela para entregas.
2. **Na aba Mux, a recompressão fica sempre visível:**
   - A linha do vídeo (`TrackRow`) ganha uma etiqueta: **`COPY · bit a bit`** ou **`TRANSCODE → HEVC 10-bit`**, em laranja.
   - O painel "HDR" vira **"Picture"**, com um seletor *Copiar (sem perda)* / *Transcodificar para…*. A opção Dolby Vision passa a ser um dos destinos, e a ligação automática pelo XML continua funcionando.
3. **Um motor compartilhado.** O `VideoEncodePlan`, que hoje só faz HEVC HDR, vira um `TranscodePlan` genérico, e o HEVC Dolby Vision passa a ser um preset dele. Assim o Mux também ganha os outros destinos. Exemplo: master 4444 + WAV novo → MOV 422 HQ para a Academia, num passo só.

## 3. Controles de qualidade por destino

| Destino | Controle de qualidade | Encoder |
|---|---|---|
| **ProRes** (Proxy, LT, 422, **422 HQ**, 4444, 4444 XQ) | **Nenhum slider.** No ProRes, o perfil já é a qualidade. | Encoder da própria Apple (VideoToolbox/AVFoundation), que usa o hardware de ProRes dos chips M. O `prores_ks` do ffmpeg fica como alternativa, mas não é o encoder oficial da Apple, e isso pesa numa entrega. |
| **H.264** | Qualidade em três níveis (Máxima, Alta, Compacta) e Speed, no mesmo padrão do `HDRSettings`. Num "Avançado": CRF numérico, bitrate máximo e 2 passadas para um bitrate-alvo. | `libx264` para entrega; `h264_videotoolbox` para rascunho rápido. |
| **HEVC** | O mesmo esquema que já existe (CRF, preset, VBV), só que separado do HDR. | `libx265`; `hevc_videotoolbox` no modo rascunho. |

### Cuidados que a interface tem que mostrar

- **4444 → 422 HQ:** a cor passa de 4:4:4 para 4:2:2 e de 12 para 10 bits. Se a fonte tiver canal alfa, ele é **descartado**, e isso precisa aparecer como aviso.
- **HEVC 10-bit → H.264:** na prática, H.264 é 8-bit, porque quase nenhum player toca H.264 10-bit (High 10).
  - Se a fonte for **SDR**, basta reduzir para 8 bits com dither.
  - Se for **HDR (PQ/HLG)**, a imagem sai lavada, a não ser que se faça um **tone mapping para SDR/Rec.709**. O app tem que detectar isso e oferecer o tone mapping, não fazer calado.
- **O que tem que ser preservado:**
  - a tag de cor (primárias, transferência, matriz, range);
  - o frame rate exato (23.976 como fração);
  - o timecode, o aspecto de pixel e a ordem de campos;
  - o layout de canais do áudio.

## 4. Pré-requisito: corrigir a cor fixa no código

O `CODE-REVIEW-2026-11-03.md` já aponta o problema: `VideoEncoder.ffmpegArguments` grava **BT.2020/PQ fixo** (`colorprim=bt2020`, `transfer=smpte2084`, `-color_trc smpte2084`). Um ProRes HLG ou Rec.709 sai com o rótulo errado, e o `verify()` aprova mesmo assim.

Num motor de transcode genérico, isso estragaria todo arquivo que não for HDR PQ. **Esta é a primeira coisa a corrigir:** o encoder lê a cor da fonte (ffprobe/MediaInfo) e repete na saída, a não ser que o usuário peça uma conversão.

## 5. Arquitetura proposta

### `Transcode.swift` (motor)

```swift
struct TranscodePlan {
    var segments: [Segment]          // como em VideoEncodePlan (IMF pode juntar vários arquivos)
    var frames: Int; var fps: Rational; var width: Int; var height: Int
    var video: VideoTarget           // .prores(ProResProfile), .h264(Quality, Speed), .hevc(Quality, Speed, HDRMeta?)
    var color: ColorPipeline         // .passthrough(SourceColor) | .toneMapToSDR
    var audio: AudioPlan             // .copy (padrão) | .pcm | .aac(kbps)
    var container: Container         // MOV / MP4 / MKV
}
```

- `ffmpegArguments` passa a ser um `switch` por `VideoTarget`. O HEVC Dolby Vision de hoje vira o caso `.hevc(…, HDRMeta)`.
- Ele reaproveita o que o `JobRunner` já tem: progresso, cancelamento, `beginActivity` (o Mac não dorme), o Monitor, a pasta temporária e a estimativa de espaço em disco.

### `TranscodeUI.swift` (aba)

- Um novo `case transcode` no `AppMode`, com ícone SF Symbol `arrow.triangle.2.circlepath`.
- **No centro:** a área para soltar o arquivo, com o cartão da fonte (codec, perfil, bits, chroma, cor, HDR, alfa, timecode), uma seta e o cartão do destino.
- **No inspector:**
  - preset: ProRes 422 HQ (Academia), ProRes 422, H.264 (revisão), HEVC SDR, HEVC Dolby Vision;
  - qualidade e velocidade;
  - áudio;
  - estimativa de tamanho e de tempo de encode;
  - avisos (alfa descartado, HDR → SDR, 10 → 8 bits).

### Verificação depois da saída

O "bit a bit" não se aplica a um transcode. No lugar dele:

- mesmo número de frames e mesma duração;
- tags de cor e timecode iguais à fonte (ou iguais à conversão pedida);
- opcional: PSNR/SSIM ou VMAF em alguns trechos;
- o Render QC rodando sozinho no arquivo final;
- o selo da Academia ou do Zidoo calculado sobre o resultado.

### Linha de comando

```bash
BROS-MUX --transcode IN.mov --to prores422hq --out OUT.mov
```

No mesmo estilo de `--qc`, `--picture` e `--channels`.

## 6. Em que ordem lançar

- **v1.6**
  - corrigir a cor fixa no código;
  - criar o `TranscodePlan`, com o HEVC Dolby Vision migrado para dentro dele;
  - aba Transcode, um arquivo por vez: ProRes 422 / 422 HQ, H.264 SDR e HEVC, com áudio copiado e verificação no final;
  - etiqueta COPY/TRANSCODE na aba Mux.
- **v1.7**
  - seletor "Picture: Copiar / Transcodificar" no inspector do Mux;
  - quando o File Checker reprovar um arquivo (ProRes 4444, ou HEVC para a Academia), um botão **"Corrigir → Transcode para 422 HQ"** que abre a aba Transcode com o preset certo já escolhido.
- **v1.8**
  - fila de vários arquivos;
  - tone mapping HDR → SDR para H.264;
  - mudança de resolução (UHD → HD) e VMAF.

## Perguntas em aberto

- O nome da aba fica "Transcode" ou "Convert"?
- O encoder de ProRes padrão é o da Apple (VideoToolbox/AVFoundation) e o `prores_ks` só entra como alternativa?
- Os chips M de entrada (sem hardware de ProRes) devem ganhar um aviso de que vai demorar mais?
- No Mux, o transcode para ProRes entra já na v1.6 ou espera a v1.7?
