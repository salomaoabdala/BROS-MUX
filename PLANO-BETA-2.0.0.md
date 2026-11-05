# Beta 2.0.0: a nova estrutura do BROS-MUX, na linguagem Cryo

Pedido do dono (2026-11-05). A divisão atual entre as abas Mux e Transcode deixa de existir. Hoje o Mux funciona como uma "lixeira de arquivos": tudo entra no mesmo lugar e vídeo e áudio se misturam na mesma lista. No fim o resultado sai certo, mas é fácil errar quando uma pessoa está no controle. O caso real: o estéreo do vídeo, que não interessa, aparece na mesma lista que o Atmos, e a pessoa não sabe o que marcar nem em que faixa.

A Beta 2.0.0 troca isso por um caminho em passos, uma coisa por aba. Cada aba diz sempre se mexe no arquivo ou não. O app **nunca decide em silêncio**: o que o dono não respondeu fica pendente e impede o Start, com o motivo à vista.

Esta versão de trabalho se chama **Beta 2.0.0**. Ela se instala **ao lado** do BROS-MUX estável (bundle `com.abdalabrothers.brosmux.beta`, `/Applications/BROS-MUX Beta 2.0.0.app`) e não substitui o app usado na entrega. Fica no branch `beta-2.0.0` e não vai para o `main` sem o dono ver. Isso é uma exceção à regra de publicação do `CLAUDE.md`, porque a Beta é uma prévia.

Revisado em 2026-11-05 depois de três revisões adversariais: fidelidade ao pedido, segurança do motor e do QC, e viabilidade do contrato. Elas apontaram 14 bloqueios e 42 problemas maiores, todos tratados abaixo.

---

## Parte 1: o que o dono vê

### Glossário: uma palavra para cada coisa, em todas as telas e no relatório

| Palavra | Quer dizer |
|---|---|
| **COPY · bit-exact** | os bits vão para o arquivo novo sem mudar nada |
| **MUX** | juntar faixas copiadas num arquivo novo |
| **TRANSCODE** | recomprimir: os bits mudam. Vale para vídeo e áudio. |
| **READ ONLY** | as ferramentas de checagem: leem e nunca mudam o arquivo |

O motor continua escrevendo "Picture: RE-ENCODED", porque o QC procura esse texto. O relatório da Delivery acrescenta "(= transcode)".

### A janela

- **Material A · CRYO.**
  - Placa de vidro escuro congelado (#05080C), com luz ciano de acrílico gravado na borda.
  - Geada só nos cantos e nas áreas de soltar arquivo.
  - Enquanto a Delivery roda, a luz da borda de baixo vira a barra de progresso.
  - O vidro do sistema (macOS 26) aparece só na barra lateral, na barra de ferramentas e no inspector. O conteúdo fica em "slots" opacos rebaixados.
- **Provisório na Beta** (decisões 2 a 6 do `PLANO-V2-VISUAL.md`, que continuam do dono):
  - só tema escuro;
  - SF Pro Expanded nos títulos e SF Mono nos números, centralizados em `CryoFont`, de modo que trocar para Archivo/Geist é mexer em um arquivo só;
  - boot curto (no máximo 0,9 s, pulável);
  - sem sons;
  - sem modo "grading-safe".
- **Atalhos:** ⌘1 a ⌘4 levam aos passos e ⌘5 a ⌘7 às ferramentas. ⌘↩ só existe para o START da Delivery.

### Barra lateral

```
 WORKFLOW
  01  VIDEO       ProRes 4444 · TRANSCODE → HEVC Dolby Vision      [DV]
  02  AUDIO       2 tracks · Atmos + 5.1 · 1 decision pending       (âmbar)
  03  SUBTITLES   coming later
  04  DELIVERY    ready · ou "rendering 42 %"
 ───────────────────────────────────────────────────────
 CHECK A FILE — on its own, or after Delivery
      File Checker · Render QC · Atmos Visualizer
 [10 LEDs dos engines]                         ABDALA BROTHERS
```

Cada passo mostra o seu estado. O que está pendente aparece em âmbar e conta como decisão a tomar.

### Regra de roteamento (vale em todas as abas)

Cada arquivo vai para a aba a que pertence, com o aviso "X goes on the Y tab — added there":

| Arquivo | Destino |
|---|---|
| imagem | Video (o som que vem dentro dele vai para "FROM THE VIDEO FILE") |
| XML Dolby Vision, JSON HDR10+ | Video |
| áudio | Audio |
| SRT e outras legendas | Subtitles |
| `.bmjob` | Delivery |

- **Se já existe uma imagem:** o app pergunta "Replace the picture?". Trocar a imagem limpa o alinhamento (cortes, referência, atraso da referência) e avisa: "New picture: alignment cleared — line up again".
- **Várias imagens de uma vez na aba Video:** o app pergunta "Make one delivery per file with these settings?" e cria um job por arquivo na fila. Isso substitui o transcode em lote da antiga aba Transcode.

### 01 · VIDEO

1. **"Where will this file play?"**, escolhido logo aqui e editável depois:
   - **MOV**: Academia, Resolve.
   - **MP4**: TVs, players.
   - **MKV**: home theater, Zidoo.

   O container decide o que cabe sem transcodar. Se ele mudar depois e alguma faixa passar de COPY para TRANSCODE, um pop-up lista as faixas afetadas e o passo correspondente fica âmbar.
2. **O cartão do vídeo.**
   - Título: "You have: ProRes 4444 picture + Dolby Vision metadata (2DIE4.xml)".
   - Miniatura com entorno neutro.
   - Linha de metadados em mono: `ProRes 4444 · 12-bit · 4:4:4 · 3840×2160 · 24 fps · P3-D65 / PQ · TC 01:00:00:00 · 60:09 · 1,900 Mbps`.
   - Um chip com o logo DV ou HDR10+ fica no cartão e na barra lateral. Clicar nele reabre a análise.
   - Se o vídeo tiver som, aparece: "This file also carries 6 mono PCM streams (a 5.1). You'll decide on the Audio tab whether to use them."
3. **Pop-up dos metadados**, com o logo Dolby Vision ou HDR10+ desenhado em vetor (a arte oficial entra sozinha se `Resources/Logos/*.pdf` existir).
   - **Ele só abre depois que a imagem é conhecida.** Se o XML chegar antes, as linhas que dependem da imagem dizem "Waiting for the picture…" e nunca mostram ✓.
   - Formato de cada linha: **DETECTED → RECOMMENDED → botão**. Qualquer ✕ impede a Delivery.

   **Dolby Vision**

   | Linha | Regra | Ação |
   |---|---|---|
   | XML legível | o dovi_tool lê o arquivo | ✕ "can't be fixed here" + Copy error |
   | Frames | iguais aos da imagem | ✕ "ask the colourist for an XML of N frames at 24 fps" (Copy) |
   | Frame rate | `<Rate>` = fps da imagem | ✕ como acima |
   | Level 5 (área ativa) | igual à letterbox medida na imagem (cropdetect) | ⚠ com os dois valores |
   | Perfil e versão do CM | só informa (sai em 8.1) | — |
   | L6 MaxCLL/MaxFALL | diferentes de 0 | ⚠ + "Use the values measured from L1" |
   | Primárias do master | P3-D65 ou BT.709 em PQ vão para BT.2020 | ✓ "Will be converted to BT.2020 in the new file (recommended) — your master isn't changed" · [Keep source primaries] |
   | Primárias sem conversão | DCI-P3 (smpte431) ou HLG | ⚠ "can't be converted in this app" |
   | Piso de qualidade × teto | piso ligado com pico acima de 160 Mbps fura o HEVC Level 5.1 (medido: 274–305 Mbps) | ⚠ + [Turn the quality floor off] |

   **HDR10+**

   | Linha | Ação quando falha |
   |---|---|
   | JSON legível (SceneInfo) | ✕ |
   | Frames iguais aos da imagem | ✕ |
   | Luminância do display de referência | informa |
   | Coerência com o mastering HDR10 | ⚠ |

4. **Pop-up "a imagem não carrega isso".**
   - Texto: "ProRes 4444 can't carry Dolby Vision. To embed it, the picture must be transcoded."
   - Lista os **tipos de destino**:
     - **HEVC 10-bit · Dolby Vision 8.1 + HDR10 (x265)**: [Transcode to embed it], recomendado;
     - **Apple hardware**: desligado, com o motivo: "it can't write the HDR10 / Dolby Vision metadata";
     - "No other format can carry Dolby Vision in this app (ProRes and H.264 can't)".
   - **Deliver without Dolby Vision:** ProRes 422 HQ, HEVC HDR10 sem o DV, ou "Keep the picture as it is (COPY)". As três tiram o metadado, e o cartão diz isso.
   - **Esc deixa a decisão pendente.** O passo 01 fica âmbar e a Delivery não começa.
   - Ao escolher o transcode, os **assets de transcode** abrem dentro da aba Video:
     - preset (Streaming 4K, Blu-ray, UHD Blu-ray, Kaleidescape 4K Cinematic, Master file, Custom, todos lidos das tabelas que a "BROS-MUX Master Session" mantém);
     - modo (Quality/CRF, Average/2-pass, Constant/CBR);
     - velocidade e piso de qualidade;
     - Fonte → Destino (o que muda em âmbar, o preservado em cinza);
     - tamanho e tempo estimados.
   - Na interface não aparece número de qualidade como XPSNR, só tamanho e tempo.
5. **Imagem sem HDR.** O padrão é COPY · bit-exact. O botão "Transcode the picture…" lista os destinos legais, cada um com o motivo quando não dá:
   - ProRes 422 HQ (Academy), ProRes 422, H.264 (revisão), HEVC SDR;
   - para uma fonte HDR, também HEVC HDR10.

   Casos especiais:
   - um MXF, ou uma imagem que não cabe no container escolhido, abre o pop-up do item 4 com o motivo;
   - um IMF só pode ir para HEVC;
   - um IMF com Dolby Vision ou HDR10+ levanta o mesmo pop-up do item 3.
6. **Faixa do topo:**
   - `VIDEO · COPY · bit-exact — the picture is not touched`, em ciano; ou
   - `VIDEO · TRANSCODE → HEVC 10-bit · Dolby Vision 8.1 — you chose it because ProRes 4444 can't carry the Dolby Vision metadata (2DIE4.xml)`, em âmbar, opaco e com alto contraste.
7. **"NEXT: AUDIO →".** Nada roda aqui.

### 02 · AUDIO

1. **"FROM THE VIDEO FILE".** Cada som que veio no vídeo (faixa ou grupo de monos) **começa fora do arquivo**, acinzentado, com o pop-up ancorado na própria linha: "This audio came inside the video. Use it in the delivery?".
   - Os botões são **Use it** e **Don't use**. **Don't use** vem destacado, porque o caso comum é um som inferior.
   - Enquanto não houver resposta, o passo 02 mostra "1 decision pending" e a Delivery não começa.
   - **Don't use**: a linha ganha um cadeado e o texto "Used only to line up your mix with the picture — not in the file". "Change" volta atrás.
   - **Use it**: a faixa ganha um lugar no arquivo e continua alinhando o resto. Se a referência estiver atrasada em relação à imagem, ela é cortada junto, para sair exata.
2. **"YOUR AUDIO".** Cada linha tem só o essencial:
   - **Output: Not in the file / Audio track 1 / 2 / 3…**;
   - nome e chips de formato e canais;
   - a luz de sync: "lined up with the picture ✓" ou "not lined up yet";
   - o chip **COPY** ou **TRANSCODE**.

   Os detalhes ficam no inspector da linha selecionada: Language, Track name, Default, Head trim, Channels…, Sync Viewer, Picture check e a entrega da faixa.
   - Escolher um lugar já ocupado troca as duas linhas e destaca ambas.
   - A ordem padrão segue a Academia: Atmos = 1, 5.1 PCM = 2. Outra ordem gera ⚠.
3. **Alinhamento.** Ao soltar uma mix com uma referência presente, o app alinha sozinho. O botão "Line up with the picture" refaz o alinhamento.
4. **Transcode, no mesmo padrão da aba Video.** Quando uma faixa não pode entrar como está, abre-se na linha o pop-up DETECTED → RECOMMENDED. Exemplo: "PCM can't go in MP4 → Transcode to AAC 5.1 · 640 Kbps / Change the container to MOV / Keep".
   - As opções são **COPY**, **TRANSCODE → AAC** (640 Kbps no 5.1, 256 Kbps no estéreo) e **TRANSCODE → PCM 24-bit**.
   - Dolby (Atmos, E-AC-3, TrueHD) só sai em COPY.
   - A aba Sound Encode (TrueHD/DDP/DD/FLAC, `.wip`) fica **fora** da Beta.
   - Um áudio transcodado **nunca muda a mixagem**: nível, canais, ordem e sync continuam iguais e **são verificados** depois de escrever.
5. **Faixa do topo:** nomeia cada operação. Exemplo: `AUDIO · COPY · 1 trimmed at the head (88.7 ms) · 6 mono WAVs joined into one 5.1 · channel order changed`.
6. **"NEXT: DELIVERY →".**

### 03 · SUBTITLES

Espaço reservado: "Subtitles — coming in a later Beta". As legendas encontradas aparecem numa lista e **começam fora do arquivo**. "Include" põe cada uma dentro.

### 04 · DELIVERY

1. **"BEFORE YOU START".** Uma linha por pendência, cada uma com link para a aba dela:
   - áudio sem resposta;
   - Dolby Vision sem decisão;
   - ✕ na análise;
   - mix não alinhada;
   - conflito de container;
   - espaço livre.

   Um ✕ desliga o START. Um ⚠ pede confirmação.
2. **"THE FILE THAT WILL BE WRITTEN".**
   - Container, com "Change…" refazendo as checagens; nome; pasta.
   - O **plano de streams** com a "linha de sinal": reta para COPY, com nó âmbar para TRANSCODE.
   - O que fica de fora: "Stereo from the video · not in the file · sync reference".
   - As checagens depois de escrever: bit a bit, sync, picture check, Academy/Zidoo previstos e Render QC, que vira uma etapa de todo job.
   - Tamanho e tempo estimados.
3. **Botões.**
   - **SAVE JOB…** grava o `.bmjob` (JSON) e o `.job.txt` legível.
   - **ADD TO QUEUE** grava o `.bmjob` em `~/Library/Application Support/BROS-MUX Beta/Jobs/` e põe na fila.
   - **START DELIVERY** (⌘↩) **salva o job, e o `.job.txt` ao lado da saída, antes de começar**.
4. **O render roda solto do app.** Um processo `BROS-MUX --job-file X.bmjob` é lançado à parte (o mesmo método do encode do 2DIE4). Ele sobrevive se o app for fechado e a página acompanha o arquivo de progresso dele.
   - A fila fica salva em `Jobs/queue.json`. Ao reabrir o app, ela é restaurada e os jobs salvos aparecem com "Add to queue".
   - As abas continuam editáveis durante o render, porque o job que roda está congelado.
5. **A página de render, inspirada no Resolve.**
   - **% total**: sobe sempre, ponderado por tempo.
   - A etapa de agora e o que ela faz.
   - A **linha do tempo das etapas** com ✓/●/○ e o tempo de cada uma. Exemplo: metadados DV → Pass 1 → Pass 2 → injeção DV → Mux → Verify → Sync → Picture check → Render QC → Academy.
   - **Frames feitos / total** e o **frame atual**, com número e timecode.
   - **fps de agora** (janela de 90 s), fps típico (mediana de 20 min) e média, com a curva de fps.
   - **ETA**: uma faixa no 2-pass e o horário de término.
   - **Miniatura do frame atual**, a cada 12 s, da fonte, com entorno neutro.
   - Bitrate atual.
   - **O que ele está achando**: as linhas ✓/⚠/✕, ao vivo.
   - Tubos de CPU, GPU, RAM e disco (MB/s).
   - Cancel.
   - Num job só de mux, a página mostra MB escritos / total e MB/s.
   - Enquanto o render roda, o app não faz animação ambiente.
6. **No fim.** Selos (Academy em ouro, Zidoo em menta), mais Show in Finder, Inspect Final File, Render QC e o relatório "HOW THIS FILE WAS MADE" ao lado do arquivo, com cada etapa e cada comando.

### Ferramentas de checagem (abaixo do divisor)

- File Checker, Render QC e Atmos Visualizer continuam como estão, em Cryo, com a faixa "READ ONLY · … reads the file, never changes it".
- O "Fix → Transcode to ProRes 422 HQ" do File Checker abre o arquivo na aba Video com esse destino escolhido. Antes, pergunta se pode trocar a imagem carregada.

---

## Parte 2: como é construído

### Regras que nenhum agente pode quebrar

1. **O motor não muda de comportamento, e a saída de CLI continua byte a byte igual.**
   - Isso vale para `--job`, `--transcode`, `--qc` e `--picture`. O `qc.sh` ganha um teste de "saída dourada", que compara com o binário da base.
   - Nenhum texto literal muda em `JobRunner`, `Verifier`, `GroupSources`, `Transcode.encodeElementary/verifyElementary`, `TranscodeRunner`, `runJobCLI` ou `TranscodeModel.cli`. A interface lê os ✓/⚠/✗ desses textos e nunca os reescreve.
   - Ficam intocados: `Transcode.arguments`, o comando do encode DV (`qc/reference/dv-command.txt`), os padrões guardados de `HDRSettings` e as tabelas Quality/Speed/BitratePreset. A recomendação entra quando o usuário escolhe, nunca como padrão.
   - O motor ganha apenas acréscimos opcionais: callbacks de progresso e de achados; `plannedStages`; o construtor de argumentos do transcode de áudio; as análises de metadado; o `.lock` respeitado pela limpeza de temporários.
   - O `buildProject` (a CLI) mantém a regra de hoje: o som do vídeo fica fora e serve de referência.
   - Sem respostas guardadas, `insert`, `makeGroup` e `chooseDefaultReference` se comportam exatamente como hoje.
   - `AppInfo` continua em `Design.swift`, com a linha `static let version = "…"`.
2. **Uma fonte de verdade para o vídeo.** `hdr.encode` é a verdade do caminho HEVC HDR.
   - `VideoPlanModel.choice` é **calculada**: `hdr.encode ? .hevcHDR : (transcode != nil ? .transcode(...) : .copy)`.
   - Só `choose(_:)` escreve `hdr.encode`, `autoEnabledBy` e `autoReason`.
   - Tudo que tem metadado HDR (HDR10, DV, HDR10+) vai **só** pelo `.hevcHDR` (`JobSpec.videoEncode`).
   - Os destinos `.transcode` são só SDR: prores422HQ, prores422, h264Review, hevcSDR. Um IMF nunca vai para `.transcode`.
3. **Metadado nunca fica de fora em silêncio.** `Project.metadataNotEmbedded: String?` é diferente de nil quando há DV ou HDR10+ carregado e a escolha não é `.hevcHDR`. Nesse caso a Delivery e o `--job-file` recusam começar. A saída é "Remove the metadata" ou transcodar.
4. **A Delivery congela tudo no momento de enfileirar** (`DeliveryExecution`) e nunca mais lê o `Project`.
   - O mesmo `DeliveryEngine.prepare` serve ao START e ao `--job-file`.
   - No START, o texto canônico do projeto ao vivo tem de ser **igual** ao do job reconstruído do `.bmjob`. Se não for, o app não começa e mostra o erro.
5. **Ordem da revisão.** O `CLAUDE.md` "Regras do app" é reescrito para a Beta **antes** dos agentes. O dono pediu explicitamente para acabar com a divisão Mux/Transcode.

### Arquivo de job (`.bmjob`, JSON, `schemaVersion: 1`)

```swift
struct DeliveryJob: Codable {
    var schemaVersion = 1
    var id: UUID; var name: String; var created: Date; var app: String          // AppInfo.name
    var sources: [SourceFile]          // every input: picture, audio, IMF ASSETMAP/CPL/MXF, DV XML, HDR10+ JSON
    struct SourceFile: Codable { var path: String; var size: Int64; var modified: Date }   // fingerprint
    var tracks: [TrackIntent]          // in `project.tracks` order (= output order for included)
    struct TrackIntent: Codable {
        var key: StreamKey             // path + stream index(es); a mono group = its members, sorted
        var kind: String               // TrackKind raw
        var grouped: Bool              // made with makeGroup (members in key.streams)
        var include: Bool; var title: String; var language: String; var enabled: Bool
        var trimStart: Int; var syncApplied: Bool
        var channelMap: String?; var channelTarget: [String]?; var channelRoles: [String]?   // raw values
        var delivery: String           // AudioDelivery raw
    }
    var embeddedAudioAnswer: [StreamKey: Bool]
    var syncReference: StreamKey?
    var referenceLateFrames: Double
    var matchVideoEnd: Bool, verifyAudio: Bool, verifyVideo: Bool, fixColorTag: Bool,
        writeChannelMap: Bool, disableExtraAudio: Bool, interleaveMs: Int, pictureCheck: Bool
    var video: VideoIntent
    struct VideoIntent: Codable {
        var choice: String             // "copy" | "hevcHDR" | "transcode"
        var transcode: VideoTranscodeSettings?
        var dvSource: String?; var hdr10plusJSON: String?; var imf: String?
        var dolbyVision: Bool; var hdr10plus: Bool
        var quality: String; var speed: String; var rateMode: String; var bitratePreset: String
        var customMbps: Int?; var customMaxMbps: Int?; var qualityFloor: Bool; var convertGamut: Bool
        var mastering: String?; var maxCLL: Int; var maxFALL: Int
    }
    var container: String; var output: String
    var overwrite: String              // "keepBoth" (default) | "replace"
}
```

**Reconstrução** (`DeliveryJob.rebuild(into:) throws -> [String]`). É síncrona e nunca chama `buildProject`, `add`, `autoGroup`, `chooseDefaultReference` nem verificações assíncronas. Os passos, em ordem:

1. Confere a impressão digital de cada fonte. Se uma mudou: "SOURCE CHANGED: …", e a CLI sai com código 3.
2. `Probe.tracks` + `insert` por fonte, ou `readIMF` + `applyIMF(check: false)`.
3. Recria cada grupo com `makeGroup(memberIDs, listen: false)`. Os monos soltos ficam soltos.
4. `referenceLateFrames` pelo atalho que pula o didSet, enquanto nenhuma faixa tem `syncApplied`.
5. Aplica os campos de cada faixa, na ordem guardada, e o `syncReference`.
6. `dvSource` e `hdr10plus`, depois `checkDolbyVisionNow` (síncrono).
7. Os escalares de HDR e `hdr.encode` **a partir da escolha guardada**, nunca a partir de "existe um XML".
8. O container e depois `setOutput`.

### Vídeo e áudio na Delivery

- **COPY:** `JobRunner`, como hoje.
- **`.hevcHDR`:** `JobSpec.videoEncode`, como hoje. O comando é o do QC.
- **`.transcode` (SDR):**
  1. O `TranscodeRunner` escreve `<destino>/.BROS-MUX-tmp-<uuid>/video.mov`, sem áudio e com `runQC: false`.
  2. O `JobRunner` faz o mux com `verifyVideo = true` e `fixColorTag = false`, trocando só a faixa de vídeo (o timecode da fonte é mantido e nenhum outro é acrescentado).
  3. No arquivo final: tags de cor, contagem de frames e timecode.
  4. O resultado diz "Picture: TRANSCODED in step 1 (ProRes 4444 → Apple ProRes 422 HQ), then copied bit for bit into the final file".
  5. Os temporários são apagados em qualquer saída. O espaço é checado antes do passo 1 (temporário + 2× o final + 1 GB).
- **Áudio TRANSCODE:**
  - Os argumentos são montados por `AudioTranscode.arguments(...)` (E). A entrada são os mesmos bytes que o `JobRunner` usaria: `GroupSources.writeInterleaved` / `WavInfo.writeTrimmed`, com o corte e a permutação, e o `-channel_layout` explícito.
  - A saída vai para `.m4a`, com a edit list.
  - Depois do mux, a verificação é própria: o atraso é 0 ± 1 amostra contra o PCM cortado; o nível de cada canal fica dentro de ±0,1 dB; cada canal tem correlação > 0,9 com o mesmo canal da fonte.
  - Recusas: AAC acima de 8 canais; float acima de 0 dBFS para PCM 24-bit.
  - Para WAV acima de 4 GB, `-rf64 auto`.
  - O PCM big-endian de MOV é reembrulhado como `pcm_s24le`, sem perda.
  - A linha "bit-identical" do motor é reescrita na Delivery como "identical to the AAC made in step 1 (the AAC itself is lossy)".
  - Antes do `JobRunner.run`, todas as faixas do spec têm de ser `.copy`. A `reference` continua sendo a faixa original.
- **Pré-voo** (`DeliveryEngine.preflight`): `metadataNotEmbedded ?? hdrProblem ?? JobRunner.validate ?? TranscodeRunner.validate`, mais o espaço combinado e a política de sobrescrita. Roda ao enfileirar e de novo antes de cada job.

### Render solto e página de progresso

- **O START grava o `.bmjob` e lança à parte** `launchctl submit -l com.abdalabrothers.brosmux.beta.job.<id> -- /usr/bin/caffeinate -i <binário> --job-file <bmjob>`.
- **O worker (`DeliveryCLI`) escreve em `Jobs/<id>/`:**
  - `progress.json`, o último `DeliverySnapshot` (stage, fração, overall, frame, total, fps, bitrate, MB escritos), de 1 a 4 vezes por segundo;
  - `findings.log`, as linhas ✓/⚠/✕ à medida que surgem;
  - `result.json`, no fim;
  - `report.txt`.
- **Cancel:** o app cria `Jobs/<id>/cancel`, e o worker confere esse arquivo e cancela limpando tudo.
- **A pasta temporária ganha um `.lock`** com o pid, e `removeStaleTemps` passa a respeitá-lo.
- **O app tem um `DeliveryMonitor`** que lê esses arquivos, calcula fps de agora, fps típico e ETA, e tira a miniatura da fonte numa fila separada.
- **O % total** é ponderado por tempo a partir de `JobRunner.plannedStages(spec)`: frames ÷ fps medido em cada passada, o mux pelos bytes, e pesos fixos para as checagens. Ele nunca volta para trás.

### Fases de obra

0. **Esqueleto (o integrador, sozinho).**
   - Commit da base e merge do `plano-transcode`.
   - Troca do `AppMode`.
   - `ContentView`, `Sidebar` e `ModeToolbar` saem do `MuxUI.swift` para o `Shell.swift`.
   - `AcademySeal` e `StatuetteShape` vão para o `Cryo.swift`. `OutputSection`, `AcademySection`, `SummarySections`, `ResultBanner` e `LogSheet` vão para o `DeliveryParts.swift`.
   - `HDR.swift` se divide em motor (`HDR.swift`) e telas (`HDRViews.swift`).
   - Cada arquivo novo nasce com as **assinaturas exatas** do contrato e corpos vazios.
   - Todas as referências a `.mux`/`.transcode` são atualizadas.
   - O `CLAUDE.md` é reescrito para a Beta.
   - O `build.sh` fica verde, e o resultado vira commit.
1. **Sete agentes em paralelo, cada um no seu próprio `git worktree`** (`.agents/<X>`, branch `beta2-<X>`, saído do esqueleto):
   - E: motor e modelo;
   - C: Cryo;
   - S: casca;
   - V: Video;
   - A: Audio;
   - D: Delivery;
   - X: legendas e checagem.

   Cada um só edita os seus arquivos, confere com `nice swiftc -typecheck …` e **nunca** roda o `build.sh`.
2. **Integração.** Merge dos sete branches, `./build.sh`, e os erros de compilação são corrigidos por quem integra. Antes de qualquer coisa pesada, a guarda de máquina livre.
3. **Revisão adversarial do código:** pedido do dono × tela; regras; motor e QC; os casos do 2DIE4.
4. **QC.**
   - O `qc.sh` completo.
   - A saída dourada contra o binário da base.
   - Um XML DV válido de 120 frames.
   - Um clipe com 6 monos embutidos.
   - O `--job-file` de ida e volta, com o texto canônico igual.
   - ProRes de duas etapas com áudio externo.
   - AAC verificado.
   - Capturas novas.
   - A folha antes × depois.
5. **Entrega.**
   - `/Applications/BROS-MUX Beta 2.0.0.app` ao lado do estável.
   - CHANGELOG `## v2.0.0 — 2026-11-05 · Beta 2.0.0 (prévia, não publicada)`.
   - Commit no `beta-2.0.0`, sem `main`.

### Donos dos arquivos

| Dono | Arquivos | Não pode |
|---|---|---|
| **E · motor e modelo** | `BrosMux.swift`, `HDR.swift` (motor), `Transcode.swift` (só acréscimos) | mudar texto de resultado, `Transcode.arguments`, padrões de HDR, flags da CLI |
| **C · Cryo** | `Cryo.swift`, `Design.swift` | mudar a API de `DS`, `NoticeRow`, `Chip`, `KeyValueRow`, `TerminalBox`, `InsetGroupStyle`, `SheetHeader`, `SheetButtons`, `IconTile`; mexer em `AppInfo` |
| **S · casca** | `Shell.swift`, `Welcome.swift` | mudar a API de `EngineStatus.shared` e `WelcomeView(onStart:)`; ligar ⌘↩ |
| **V · Video** | `VideoTab.swift`, `VideoModel.swift`, `HDRViews.swift`, `TranscodeUI.swift` | usar `TranscodeModel.shared` na interface; mudar a assinatura de `RateControlRows`, `PlaybackRows`, `HDRFileCard` |
| **A · Audio** | `AudioTab.swift`, `MuxUI.swift`, `SyncViewer.swift`, `PictureSync.swift` (o `enum PictureSync` fica congelado), `ChannelOrderUI.swift` | mudar os inits de `SyncViewerModel`, `PictureSyncModel`, `SyncViewerSheet(standalone:)`, `PictureSyncSheet(standalone:)`, `ChannelOrderSheet(track:initialReport:)` |
| **D · Delivery** | `DeliveryTab.swift`, `DeliveryEngine.swift`, `DeliveryJob.swift`, `DeliveryParts.swift`, `Monitor.swift` | mudar a saída de `runJobCLI` |
| **X · legendas e checagem** | `SubtitlesTab.swift`, `CheckerUI.swift`, `RenderQC.swift`, `AtmosViz.swift`, `Zidoo.swift` (só `ZidooSeal`/`ChecksSection`) | mudar `InspectorView/AtmosView/RenderQCView(targeted:)`, a saída de `RenderQC.cli`, a semântica de `Zidoo.checks` |
| ninguém | `ABMark.swift`, `RenderQCEngine.swift`, `AtmosOAMD.swift`, `AtmosDecoder.swift`, `ChannelID.swift`, `Alignment.swift`, `ColorLUT.swift`, `MonoGroup.swift` | — |
| integrador | `qc.sh`, `build.sh`, `CHANGELOG.md`, `README.md`, `CLAUDE.md`, `tools/`, `install.sh`, planos | — |

**Nomes novos** começam pelo domínio do dono: `Video*`, `Audio*`, `Subtitles*`, `Delivery*`, `Cryo*`, `Shell*`.

**Nomes reservados**, que já existem: `OutputSection`, `ChecksSection`, `LogSheet`, `ResultBanner`, `NoticeStack`, `EmptyDropView`, `Chip`, `NoticeRow`, `KeyValueRow`, `TerminalBox`, `TabStrip`, `ReencodeBanner`, `Engine`, `EngineStatus`, `AcademySeal`, `ZidooSeal`. Antes de declarar qualquer nome, `grep -n "^\(struct\|enum\|final class\|class\) NOME\b" *.swift`.

O contrato exato (assinaturas) está em `BETA2-CONTRACT.swift.md` e é a fonte de verdade dos agentes. O esqueleto compila exatamente essas assinaturas.
