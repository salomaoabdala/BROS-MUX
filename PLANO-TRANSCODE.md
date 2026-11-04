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

## 2. Decisão: separação total entre Mux e Transcode

**Princípio:** o app está ganhando funções e corre o risco de ficar confuso. Cada aba faz **uma coisa só** e diz isso logo no topo, com uma frase fixa. Nenhuma função de transcode aparece espalhada pela aba Mux.

### Aba Mux: "Os arquivos não são tocados. Só são juntados."

- Uma faixa fixa no topo da aba diz: **"Mux · nada é recomprimido. Imagem e som entram e saem bit a bit; as faixas só são juntadas num arquivo."**
- **Não ganha** nenhum controle de transcode: nada de seletor de codec, de mudança de resolução, de qualidade ou de cor.
- Fica o caminho para o Transcode: quando o File Checker reprova um arquivo, o botão "Corrigir" **leva para a aba Transcode**. Ele não converte nada dentro do Mux.
- **Única exceção: Dolby Vision e HDR10+.** Embutir o RPU do Dolby Vision exige recodificar a imagem. **Decisão: continua ligando no automático, como hoje** (soltar o XML de Dolby Vision ou o JSON de HDR10+ já prepara a versão de playback). Só que, quando isso acontece, o app tem que **avisar que ligou sozinho, dizer por quê e dizer exatamente o que vai fazer** (detalhes abaixo).

#### O alerta de transcode dentro do Mux (caso Dolby Vision)

Quando o `hdr.encode` liga, seja sozinho (ao soltar o XML) ou na mão (os textos abaixo estão em português só para o plano; no app saem em inglês, como o resto da interface):

1. **Um banner laranja grande no topo da aba**, por cima da faixa "nada é recomprimido". Ele diz **o que ligou a recodificação** e mostra a fonte e o destino lado a lado:

   > ⚠️ **Recodificação ligada automaticamente**
   > Você adicionou **DolbyVision_2DIE4.xml** (metadados Dolby Vision). Para embutir o Dolby Vision, a imagem precisa virar HEVC 10-bit, então o BROS-MUX ligou a recodificação sozinho.
   > **ProRes 4444 · 12-bit · 4:4:4 · 1,2 Gb/s** → **HEVC Main 10 · 10-bit · 4:2:0 · ~60 Mb/s**
   > Dolby Vision 8.1 + HDR10. O áudio continua bit a bit.
   > [Entendi] [Não recodificar (tirar o Dolby Vision)]

   Se foi o usuário que ligou na mão, o título muda para "Recodificação ligada" e a frase do motivo some. O banner continua visível enquanto a recodificação estiver ligada. "Entendi" só o deixa mais compacto, numa linha só, e ele nunca desaparece.

2. **Na linha do vídeo**, a etiqueta muda de `COPY · bit a bit` (cinza) para **`RECODIFICA → HEVC 10-bit`** (laranja).
3. **O botão principal** muda de "Mux" para **"Recodificar e Mux"**, em laranja.
4. **Na primeira vez, uma confirmação** antes de começar, repetindo a frase fonte → destino e o tempo estimado (pode levar a noite toda). Tem a opção "não perguntar de novo neste projeto".
5. **O relatório final** ganha a linha "Imagem: RECODIFICADA (ProRes 4444 → HEVC Main 10)". Sem recodificação, a linha diz "Imagem: cópia bit a bit".

### Aba Transcode: "Os arquivos são alterados."

- Uma faixa fixa no topo diz: **"Transcode · o arquivo é recodificado. Codec, qualidade, tamanho, resolução e cor podem mudar. O original nunca é alterado; sai sempre um arquivo novo."**
- **Tudo o que mexe na imagem mora só aqui:** codec e perfil, qualidade e bitrate, resolução (UHD → HD), cor (tone mapping HDR → SDR) e bit depth.
- O inspector mostra sempre o cartão **Fonte → Destino**, com cada diferença destacada: o que muda aparece em laranja, o que é preservado aparece em cinza.

### Por trás: um motor só

Isso é invisível para o usuário. O `VideoEncodePlan`, que hoje só faz HEVC HDR, vira um `TranscodePlan` genérico, e a aba Transcode usa esse motor. O encode de Dolby Vision do Mux também passa a usar o `TranscodePlan`, mas **sempre com o destino fixo (HEVC 10-bit Dolby Vision)**. O Mux não ganha os outros destinos.

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

## 6. Entrega: uma atualização só (v1.6)

Tudo sai numa única versão, a **v1.6**, com estas mudanças:

**Aba Mux (clareza)**
1. Frase fixa no topo: "Mux · nada é recomprimido. Imagem e som entram e saem bit a bit; as faixas só são juntadas num arquivo."
2. Recodificação automática do Dolby Vision e do HDR10+ mantida, agora com:
   - o banner "Recodificação ligada automaticamente", que diz qual arquivo a ligou e mostra a fonte e o destino;
   - a etiqueta `COPY · bit a bit` / `RECODIFICA → HEVC 10-bit` na linha do vídeo;
   - o botão "Recodificar e Mux";
   - a confirmação antes de começar;
   - a linha "Imagem: RECODIFICADA / cópia bit a bit" no relatório.

**Aba Transcode (nova)**
3. Aba própria, com a frase fixa no topo e o cartão Fonte → Destino.
4. Destinos: ProRes (Proxy, LT, 422, 422 HQ, 4444, 4444 XQ, pelo encoder da Apple), H.264 (`libx264`) e HEVC (`libx265`), com Qualidade e Velocidade. O VideoToolbox entra no modo rascunho.
5. Áudio copiado por padrão; PCM em MOV, ou AAC quando o container exige.
6. Mudança de resolução (UHD → HD) e de bit depth.
7. Tone mapping HDR → SDR/Rec.709 quando o destino é H.264 e a fonte é HDR, com aviso.
8. Avisos de canal alfa descartado, 4:4:4 → 4:2:2 e 10 → 8 bits.
9. Fila de vários arquivos.
10. Verificação no final: frames, duração, cor e timecode, Render QC automático, selo da Academia ou do Zidoo e VMAF opcional.
11. Linha de comando: `--transcode IN --to <preset> --out OUT`.

**File Checker**
12. O botão "Corrigir → Transcode para 422 HQ" abre a aba Transcode com o preset já escolhido.

**Por trás**
13. Correção da cor fixa no código: o encoder repete a cor da fonte, em vez de gravar BT.2020/PQ sempre.
14. O `VideoEncodePlan` vira o `TranscodePlan`, um motor só usado pelas duas abas.

**Documentação**
15. A entrada da v1.6 no `CHANGELOG.md` lista cada item acima, e o README ganha a seção da aba Transcode.

## Perguntas em aberto

- O nome da aba fica "Transcode" ou "Convert"?
- O encoder de ProRes padrão é o da Apple (VideoToolbox/AVFoundation) e o `prores_ks` só entra como alternativa?
- Os chips M de entrada (sem hardware de ProRes) devem ganhar um aviso de que vai demorar mais?
