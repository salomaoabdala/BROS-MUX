# Revisão de código — BROS-MUX (3 nov 2026)

Base revisada: `/Users/salomaoabdala/BROS-MUX` (9.865 linhas de Swift em 15 arquivos, build via `swiftc -O *.swift`, sem Xcode, sem git). Todas as linhas citadas foram conferidas no arquivo atual nesta data. Itens marcados **(não verificado)** vieram dos revisores de área e não passaram pelo verificador; os demais foram confirmados em código e, quando indicado, reproduzidos com as ferramentas instaladas (MediaInfo 26.10, ffmpeg 9.0.2, MP4Box 26.07).

---

## 1. Resumo

1. O núcleo é sólido e cuidadoso: trims sample-exact (WAV/RF64 e E-AC-3 por frame), verificação bit-a-bit pós-mux, MoovPatcher, SyncEngine por correlação cruzada, leitura de IMF/Dolby Vision e o redesign HIG das abas principais estão coerentes.
2. O risco está concentrado em três bugs **altos** confirmados: MaxMDL lido como 2 nits em masters HDR10-only (`HDR.swift:557`), um frame extra por segmento em IMFs multi-recurso que desloca RPU e áudio (`HDR.swift:744`) e o detector de dropouts do Render QC que ignora qualquer buraco maior que ~0,3–0,6 s (`RenderQCEngine.swift:465`).
3. Em seguida, dois problemas de **confiança no resultado**: o arquivo final substitui uma entrega anterior mesmo quando a verificação falhou (`BrosMux.swift:1912` vs. a promessa em `:2713`) e o check de sync final não vê offsets acima de 2 s, rebaixando-os a aviso (`:1874`).
4. Estado de sync vaza entre projetos (`referenceLateFrames` sobrevive ao Clear All, `:2422`; o `didSet` em `:2160` desloca faixas que nunca foram alinhadas) — ambos baratos de corrigir.
5. Estrutura: `BrosMux.swift` tem 3.238 linhas com Tools, Probe, áudio, sync, patcher, verificador, Academy, JobRunner, Project, App e CLI no mesmo arquivo; não há repositório git (os `.bak_design` são o único histórico) nem testes. Dois achados foram refutados (§3).

---

## 2. Corrigir primeiro

Ordenado por severidade e impacto na entrega.

### Alta

**2.1 Luminância do mastering lida de "cd/m2" vira MaxMDL = 2 nits**
`/Users/salomaoabdala/BROS-MUX/HDR.swift:557`
O que acontece: `applySourceMastering()` quebra a string do MediaInfo com `components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)`. Reproduzido com o MediaInfo 26.10: `MasteringDisplay_Luminance` é `min: 0.0001 cd/m2, max: 1000 cd/m2`, o split dá `[0.0001, 2, 1000, 2]` e a linha 558 faz `maxNits = v[1]` = 2 (o "2" de "m2"). O valor segue para `L(20000,1)` em `:487`, é passado como `master-display=` em `:691` e o painel rotula "from the source file" (`:562`). Só `apply()` (`:588`) sobrescreve, e apenas quando há Dolby Vision; um ProRes HDR10 puro entrega um SEI ST 2086 errado, que TVs usam para tone mapping.
Como corrigir: usar `mi["MasteringDisplay_Luminance_Min"]` / `["MasteringDisplay_Luminance_Max"]` (já presentes no JSON e já usados por `HDRInfo.rows` em `:451`) e cair na string só com regex `min: ([\d.]+).*max: ([\d.]+)`.

**2.2 `outpoint` com 6 decimais deixa passar um frame extra por segmento do IMF**
`/Users/salomaoabdala/BROS-MUX/HDR.swift:744`
O que acontece: para CPLs com vários recursos a lista ffconcat é escrita com `String(format: "inpoint %.6f\noutpoint %.6f\n", …)`. A 24 fps, todo índice final k com k mod 3 == 1 arredonda para cima (4/24 → 0.166667 > 0.16666…), e o demuxer concat trata `outpoint` como DTS exclusivo comparado exatamente. Reproduzido no ffmpeg 9.0.2 com ProRes 24 fps: `inpoint 0.041667 / outpoint 0.166667` devolve os frames 1,2,3,4 (MD5 por frame) em vez de 1,2,3; `0.125 / 0.291667` devolve 5 em vez de 4. Como `-frames:v p.frames` (`:684`) corta a cauda, `guard done == p.frames` (`:767`) e a contagem do RPU passam, e todo frame depois da fronteira fica 1 frame fora do RPU Dolby Vision e do áudio.
Como corrigir: escrever `outpoint` meio frame antes (`(Double(s.start + s.count) - 0.5) / fps`) e `inpoint` um quarto depois (`(Double(s.start) + 0.25) / fps`), ou cortar por frame com `trim=start_frame:end_frame` + filtro `concat`; registrar no log quantos frames cada segmento produziu.

**2.3 Detector de dropouts não vê nenhum buraco maior que ~0,3–0,6 s**
`/Users/salomaoabdala/BROS-MUX/RenderQCEngine.swift:465`
O que acontece: a energia de 100 ms (`alpha = 1 / (0.1 * sr)`, `:446`) é atualizada para todo sample, zeros inclusive (`energy[c] = e + (Double(v * v) - e) * alpha`, `:459-460`), e decai como exp(−t/0,1 s) durante o buraco. O fechamento do run exige `zeroRun[c] >= Int(0.002 * sr), e > 3.2e-5` (−45 dBFS) com o `e` já decaído: a partir de −20 dBFS o teste falha após ≈0,57 s, a partir de −30 dBFS após ≈0,34 s. Um clipe mutado ou um buraco de 2 s nunca entra em `dropEvents` (`.audioSilent` em `:514` só dispara se o canal inteiro é silêncio), o "dBFS just before" (`:509`) imprime o valor decaído, e um run de zeros aberto no EOF (`:495-496`) nunca é fechado.
Como corrigir: congelar a energia enquanto `a < 1e-7` (pular a atualização dentro do ramo de zeros) ou guardar `preDrop[c]` no primeiro zero e testar/imprimir esse valor; após o loop, descarregar qualquer `zeroRun[c] >= limiar` como dropout ou "silêncio na cauda".

### Média

**2.4 Saída substitui o arquivo existente mesmo quando a verificação ou o sync falharam (e o alerta promete o contrário)**
`/Users/salomaoabdala/BROS-MUX/BrosMux.swift:1912` · `:2713` · `:2731`
O que acontece: todos os checks pós-mux só fazem `ok = false` (contagem de faixas `:1807`, encode `:1839`, bit-a-bit `:1848`, sync `:1872`, picture sync `:1902`); o passo 4 roda sempre: `if fm.fileExists(atPath: out.path) { _ = try fm.replaceItemAt(out, withItemAt: tmpOut) } else { try fm.moveItem(at: tmpOut, to: out) }`, sem `backupItemName`, e `:1919` devolve `state: .failed, output: out`. `Project.run()` mapeia para `.done(res.output)` porque `case .failed where res.output == nil` (`:2731`) só pega falhas precoces. O alerta em `:2713` diz "It's only replaced at the very end, if muxing succeeds." Uma entrega já verificada é destruída por um arquivo que falhou nos próprios checks. Mitigante: só ocorre quando o usuário escolheu um nome existente e clicou "Replace" (nomes padrão passam por `uniqueURL`, `:2401`), e o banner vermelho "File created, but a check failed" (`MuxUI.swift:379`) aparece.
Como corrigir: quando `!ok` e o destino existe, não chamar `replaceItemAt`; mover para `<nome>_FAILED.<ext>` via `uniqueURL` e devolver esse caminho em `output`; adicionar `.doneWithErrors(URL)` a `RunState` em vez de cruzar `resultState`; reescrever o alerta. No CLI (`:3012`) recusar `-o` existente sem `--force`.

**2.5 Check de sync pós-mux não enxerga além de ±2 s e rebaixa "sem correlação" a aviso**
`/Users/salomaoabdala/BROS-MUX/BrosMux.swift:1874` · `:1859`
O que acontece: `SyncEngine.measure(… maxLag: 2, points: 9 …)`; em `measure`, `let lagMax = min(maxLag, max(0.5, dur / 4))` (`:932`) limita a janela, e uma faixa 3 s fora cai em `guard valid.count >= 3 else { return Result(lag: nil …` (`:952`). O chamador faz `lines.append("⚠ Sync …"); warn = true` — o job termina `.warning` e o CLI devolve 0 (`:3036`), enquanto um erro de 1,5 s no mesmo run dá `ok = false` (`:1872`): o erro maior recebe o veredito mais brando. Nada mais segura: o alinhamento é opcional (botão `MuxUI.swift:564`, CLI `:2967`) e o Picture Check busca só ±0,25 s (`PictureSync.swift:38`) e também rebaixa nil a aviso (`:1904`).
Como corrigir: no check final, tratar `r.lag == nil` como falha sempre que houver referência (ou ao menos quando `t.syncLag != nil`); subir `maxLag` do passe grosso para ~10 s (roda a 1 kHz, custo baixo) e reportar o offset bruto medido.

**2.6 Clear All mantém `referenceLateFrames`; o projeto seguinte herda a correção de outro filme**
`/Users/salomaoabdala/BROS-MUX/BrosMux.swift:2422` · `:2157`
O que acontece: `clear()` zera `tracks … syncReferenceID` e chama `hdr.reset()`, mas não toca `referenceLateFrames`; `remove(_:)` (`:2417`) e `add(_:)` também não. O valor antigo (ex.: 2 frames = 83 ms) entra em `autoAlign()` (`offset: self.referenceOffset`, `:2548`), em `jobSpec` (`referenceOffset: referenceOffset`, `:2672`) e no check cruzado (`let ms = (lag + spec.referenceOffset) * 1000`, `:1865`). Mitigantes: o stepper laranja mostra o valor (`MuxUI.swift:545`), mas o painel só existe com ≥2 faixas de áudio (`:495`); o Picture Check padrão (`pictureCheck = true`, `:2170`) pegaria 83 ms.
Como corrigir: `referenceLateFrames = 0` em `clear()` (e, por coerência, `disableExtraAudio`/`matchVideoEnd` aos padrões); zerar também ao remover a última faixa de vídeo.

**2.7 `didSet` de `referenceLateFrames` desloca o trim de faixas que nunca foram alinhadas**
`/Users/salomaoabdala/BROS-MUX/BrosMux.swift:2160` · `:2593` · `:2556`
O que acontece: o `didSet` soma `d * sampleRate` a `trimStart` de toda faixa com `syncLag != nil`, assumindo `trimStart == lag + offset`. Mas `Project.align` devolve `AlignResult(… samples: nil, note: "Not aligned: " + msg, …, lag: lag …)` para E-AC-3/TrueHD adiantado (`:2593`) e `autoAlign` grava `syncLag = r.lag` (`:2556`) deixando `trimStart` em 0. Um passo do stepper — ou o botão do Picture Sync (`PictureSync.swift:470`) — dá `trimStart = 0 + delta`, fora pelo lag medido (ex.: Atmos 40 ms adiantado + 1 frame a 24 fps → 2000 samples → um corte Dolby de 1536 → ≈−30 ms vs imagem, fora da tolerância), com `syncNote` ainda dizendo "Not aligned". Mesmo padrão em `SyncViewer.swift:240` e no CLI (`:2975`).
Como corrigir: marcar na faixa se o alinhamento foi aplicado (`syncApplied: Bool`) ou limpar `syncLag` no ramo `samples == nil`, e no `didSet` só mexer em faixas aplicadas. Não recomputar a partir de `syncLag` cegamente: apagaria os nudges manuais de `SyncViewer.swift:251`.

**2.8 Saída sempre sinalizada BT.2020/PQ sem olhar transfer/primaries da fonte**
`/Users/salomaoabdala/BROS-MUX/HDR.swift:690` · `:694`
O que acontece: `ffmpegArguments()` fixa `"colorprim=bt2020", "transfer=smpte2084", "colormatrix=bt2020nc"` e `-color_primaries bt2020 -color_trc smpte2084`; a única escolha por fonte é `out_color_matrix=bt2020` para RGB (`:686`). `encodePlan` (`BrosMux.swift:2225`) lê só `ColorSpace`; `hdrProblem` (`:2237`) só checa contagens DV/HDR10+; `hdrRelevant` (`:2218`) abre o painel para HLG e para qualquer `.mxf`; soltar um XML DolbyLabsMDF força `hdr.encode = true` (`:2326`). Um ProRes HLG ou um MXF BT.709 sai rotulado PQ/BT.2020 e `verify()` (`:842`) aprova, porque só testa `hdr.contains("2086")`, escrito pelo próprio x265. O fluxo principal (IMF PQ/P3-em-2020 do 2DIE4) está correto; falta a guarda para outras fontes.
Como corrigir: ler `transfer_characteristics`/`colour_primaries` (o app já os lê em `BrosMux.swift:527/1387`) antes de montar o plano; recusar ou marcar `hdrProblem` quando não for PQ + BT.2020/P3; mostrar a cor detectada no painel ao lado de "HDR10 (always)".

**2.9 Symlinks dos inputs são criados no volume de destino: exFAT/FAT falha com qualquer caminho "não seguro"**
`/Users/salomaoabdala/BROS-MUX/BrosMux.swift:1977` · `:1736`
O que acontece: `prepare` cria `tmp.appendingPathComponent("input\(index).\(ext)")` com `createSymbolicLink`, e `tmp` é `.BROS-MUX-tmp-…` dentro da pasta de saída (`:1736`). `gpacSafe` (`:1929`) só aceita `[A-Za-z0-9 /._-()]`, então acento, vírgula, `+`, `'`, `&` ou colchete no caminho de origem (comum em nomes em português) passa por esse link, e o vídeo quase sempre passa por ele porque nunca é trimado. Volumes exFAT/MS-DOS do macOS rejeitam `symlink(2)` (EPERM): o job morre em `:1769` com um "don't have permission to save input0.mov" antes do MP4Box. O comentário de `:121` prevê destinos HFS+/exFAT, e o link `gpacTmp` já é posto corretamente em `fm.temporaryDirectory` (`:1746`). Não reproduzido em hardware (nenhum exFAT montado), comportamento conforme documentação.
Como corrigir: criar os links por input ao lado do `gpacTmp` em `fm.temporaryDirectory` (APFS) e passar esses caminhos ao MP4Box; manter no destino só as cópias trimadas e a saída.

**2.10 Picture Sync mostra offset, check verde e botão "Use N frames" para resultados não confiáveis**
`/Users/salomaoabdala/BROS-MUX/PictureSync.swift:458` · `:462` · `:643` · `:657`
O que acontece: `r.offset = lag` (`:236`) é definido assim que `guard chosen.count >= 6, chosen.windows >= 4` (`:231`) passa; `r.confident` (`:235`) só muda o texto (`:243`). `suggestedLag` exige apenas `r.offset != nil`, e o ícone (`let ok = r.offset != nil && ms >= -15 && ms <= 45`), o botão laranja e o marcador do `LagChart` (`:806`) seguem `offset`. O piso é fraco: `agreeing()` aceita qualquer um dos até 3 picos por corte (`peaks.prefix(3)`, `:174`) a ±12 ms (`:203`) num span de ±238 ms — ~10–15% dos cortes por acaso, em 30 janelas (`:424`), muito acima de 6/4. Um clique em `applySuggestion()` (`:468-470`) move todos os trims via o `didSet` de 2.7.
Como corrigir: condicionar `suggestedLag`/`suggestedFrames`, o check e o marcador a `r.confident` (mostrar cinza + "inconclusivo" caso contrário); trocar o piso absoluto por fração das janelas com curva e exigir que `value` do grupo supere a mediana por margem (`noise` é calculado em `:197` e descartado em `:224`).

**2.11 Trocar a faixa alvo ou Before/After durante a medição cola o resultado antigo na lane nova**
`/Users/salomaoabdala/BROS-MUX/PictureSync.swift:439` · `:419`
O que acontece: `measure()` copia `let laneCopies = lanes` e, ao terminar, grava por posição: `for (k, r) in results.enumerated() where k < self.lanes.count { self.lanes[k].result = r }`, guardado só por `guard !flag.isSet` (`:437`), que apenas o botão Stop seta (`:449/:607`). Os pickers continuam ativos (não há `.disabled(model.measuring)` no arquivo): `:599` e `:717` chamam `refreshTarget()` → `rebuildLanes()` incondicional (`:395-408`, `result: nil`), e o `measure()` seguinte sai em `guard !measuring` (`:414`). Minutos de decodificação depois, o cartão mostra o rótulo da faixa nova com o offset da antiga — um veredito de QC errado.
Como corrigir: capturar ids/geração das lanes em `measure()` e só escrever quando id, rótulo e `shift` ainda coincidem (ou `cancelFlag.set()` + re-medir ao mudar lanes); desabilitar ambos os pickers enquanto `measuring`.

**2.12 Render QC nunca lê o exit status do ffmpeg; decode falho ou parcial vira QC "quase limpo"**
`/Users/salomaoabdala/BROS-MUX/RenderQCEngine.swift:203` · `:496`
O que acontece: `features()` termina em `p.waitUntilExit()` e `return f` (`:209`); `audioFindings()` idem (`:496`, `:518`); `standardError = FileHandle.nullDevice` (`:120`, `:430`); `terminationStatus` não aparece no arquivo. Um decode que morre no meio gera só a nota "the container declares N frames, M were decoded" (`:562`), um `.avLength` limitado a `.warning` (`:572`), `pictureFindings` devolve `[]` por `guard n > 2` (`:217`), e `RenderQC.swift:220` imprime "No render faults found" com a nota como linha de info (`:225`).
Como corrigir: após `waitUntilExit()`, tratar `terminationStatus != 0`, `f.count == 0`, `f.count < info.frames * 0.99` (e `n == 0` no áudio) como `.error` ("decode stopped at frame N"); capturar as últimas linhas do stderr num segundo Pipe para a mensagem.

**2.13 Stop pode travar a thread do QC: pipe nunca é fechado após `terminate()`**
`/Users/salomaoabdala/BROS-MUX/RenderQCEngine.swift:154` · `:448`
O que acontece: `if cancel.isSet { p.terminate(); break }` seguido de `p.waitUntilExit()` (`:203/:496`) com `let h = pipe.fileHandleForReading` (`:145/:433`) aberto e sem leitura. O ffmpeg instala SIGTERM com SA_RESTART: um `write()` bloqueado no pipe cheio é reiniciado e o processo não sai. Reproduzido no ffmpeg 9.0.2 com os mesmos argumentos (áudio e vídeo): "STILL RUNNING 10 s after SIGTERM" com o lado de leitura aberto; saiu (rc 255) no instante em que o pipe foi fechado. `running = false` (`RenderQC.swift:46`) nunca executa, `guard let u = url, !running` (`:33`) rejeita todo `check()` e "Check Again" (`:203`) fica oculto até relançar o app.
Como corrigir: logo após `p.terminate()`, `try? h.close()` (o escritor recebe EPIPE) ou drenar até EOF antes de `waitUntilExit()`; por segurança, esperar com timeout e enviar SIGKILL.

**2.14 Campos da linha da faixa têm larguras fixas e estouram no tamanho mínimo da janela**
`/Users/salomaoabdala/BROS-MUX/MuxUI.swift:316-338` · `:320` · `:355`
O que acontece: `fields` é uma faixa fixa de 516 pt (`field("Track name", width: 170)` … `field("Default", width: 64)`, cada um em `.frame(width: width, height: 22)`; a linha de timecode usa um espaçador fantasma `Color.clear.frame(width: 150 + 96 + 64 + 24, height: 1)`), levada sem encolher nos dois ramos do `ViewThatFits` (`:251-257`, `fields.fixedSize()`). O screenshot `/tmp/claude-501/redesign_mux.png` (janela padrão 1480 pt) já mostra o ramo estreito; em `minWidth: 1180` (`BrosMux.swift:2811`) com sidebar `max: 280` (`:77`) e inspector `max: 600` (`:41`) a coluna de detalhe cai a ≈300 pt e Language/Head trim/Default são cortados sem rolagem. O botão de remover fica visível (está no `HStack` flexível, `:264`); só a faixa fixa é clipada.
Como corrigir: `Grid` (ou `Table` com colunas editáveis) com colunas flexíveis: `TextField` `.frame(minWidth: 120, maxWidth: .infinity)`, Picker `minWidth: 110`, numérico `width: 80`; remover o `Color.clear`; adicionar um terceiro ramo vertical no `ViewThatFits` ou limitar o inspector para a coluna nunca cair abaixo do ramo estreito.

---

## 3. Refutados

- **"Trocar ou remover a referência deixa trims medidos contra a referência antiga"** (`BrosMux.swift:2154`, `:2417`) — o código é como descrito, mas a premissa está errada: `trimStart` é campo do usuário ("Head trim (ms)", `MuxUI.swift:330`) que codifica o offset vs. a imagem; a referência é só instrumento ("The reference itself is not muxed", `:594`). O check pós-mux re-mede contra a referência nova (`:1852-1872`, falha fora de −15/+45 ms) e o Picture Check mede contra a imagem (`:1880-1907`). Resta só o texto de `syncNote`/`SyncLights` (`MuxUI.swift:304`, `:617`) desatualizado até novo Align.
- **"fps de `r_frame_rate` dobra em entrelaçado e inunda de falsos gaps"** (`RenderQCEngine.swift:77`) — sete arquivos 25i sintéticos (x264 MBAFF em MP4/MOV/TS, MPEG-2 ildct em TS/MXF/MPG, ProRes entrelaçado) probam `r_frame_rate=25/1` no ffmpeg 9.0.2; só VFR real deu 50/1, caso em que flagar é correto. Preferir `avg_frame_rate` pioraria um caso testado (TS 25p com SPS 50 fps → `avg_frame_rate=50/1`).

---

## 4. Qualidade e estrutura

### 4.1 O monólito `BrosMux.swift` (3.238 linhas)
Um arquivo contém, nesta ordem: `Tools` (`:31`), `Fmt` (`:129`), `MediaInfo`/`Probe*`/`Track`/`ChannelMap` (`:197-372`), `Languages` (`:630`), `WavInfo` (`:644`), `EAC3Reader`/`EAC3` (`:775-823`), `SyncEngine` (`:868`), `MoovPatcher` (`:987`), `ByteSource`/`Verifier` (`:1155-1217`), `Academy`/`Inspection` (`:1334-1505`), `JobSpec`/`JobRunner` (`:1628-1649`, ~450 linhas), `Project` (`:2139`, ~600 linhas), `Inspector` (`:2743`), `BrosMuxApp`/`AppDelegate` (`:2795-2826`), `CLIArgs`/`buildProject`/`runJobCLI` (`:2854-3036`) e `Entry` (`:3224`). O `build.sh` já compila `*.swift`, então dividir é só mover código.

### 4.2 Duplicação e divergência GUI × CLI
- `buildProject` (`:2917-2938`) exclui **todas** as faixas de áudio embutidas do `--video` e nunca chama `chooseDefaultReference()`; a GUI (`add()` `:2319-2353`, `:2390`) exclui só uma, expande pastas e avisa. `--add V.mov --add A.wav` dá referência na GUI e nenhuma no CLI. **(não verificado)**
- Montagem do relatório "HOW THIS FILE WAS MADE" só no CLI (`:3024-3027`); a GUI tem os mesmos ingredientes (`resultLines`, `alignLines`, `resultInspection`, `commandPreview`) e nenhum botão para salvá-los.
- CLI descarta o log: só `runner.onStage` é configurado (`:3007`), `onLog` fica no padrão `{ _ in }` (`:1653`); as falhas dizem "See the log" (`:1778`, `:1788`) para um log que não existe no terminal. **(não verificado)**
- Mesmo padrão de gravar `syncLag` sem aplicar `trimStart` em três lugares: `:2556`, `SyncViewer.swift:240`, `:2975`.
- Constante 1536 em `planText` (`:2525`) e `predictedOutput` (`:2636`) enquanto o trim real usa `samplesPerAU` do stream (`EAC3Reader` aceita 1/2/3/6 blocos, `:805`). **(não verificado)**
- Frame rate de três fontes: `SyncViewer.swift:130` (`mi?.d("FrameRate") ?? 24`, sem guarda contra 0 → `Int(Double.infinity)` em `:133`), `PictureSync.swift:348` (`project.videoFPS`), `Project.videoFPS` (`:2202`). **(não verificado)**
- Banda de tolerância −15/+45 ms repetida em `MuxUI.swift:632`, `SyncViewer.swift:341/381`, `PictureSync.swift:643`, `BrosMux.swift:1872`.

### 4.3 Código morto, comentários desatualizados, resíduos
- `CheckerUI.swift:9` — `var scrolls = true // kept for the command line`, sem uso.
- `PictureSync.swift:197/224` — `noise` calculado e jogado fora (`_ = noise`).
- `PictureSync.swift:153` diz "±4 ms" mas `:180` usa `-15...15`; `:168` diz "110–190 ms" mas `:170` percorre 136–172 ms.
- `HDR.swift:224` — `EditRate` por recurso é parseado e nunca validado contra o CPL; `:211` — `TimecodeStartAddress` parseado e nunca usado.
- Cinco `*.swift.bak_design` e `AppIcon_old.icns` na pasta de fontes; sem git, são o único histórico. Criar o repositório antes de apagá-los.
- `AtmosOAMD.swift:135` declara que máscaras de bed e updates mistos "are NOT verified on real data"; o erro que isso gera chega ao usuário como a frase fixa de `AtmosDecoder.swift:22`.

### 4.4 Diagnóstico perdido (erros mascarados)
- `BrosMux.swift:1251` — hash de vídeo que falhou (`runCancellable` devolve nil, `:64`) vira "DIFFERENT from the source ✗". **(não verificado)**
- `BrosMux.swift:1826` — notas "channel labels not written" / "Dolby header not changed" (`:1082`, `:1101`, `:1110`) e "verification unavailable / not available / not verified" (`:1240`, `:1253`, `:1258`, `:1265`) não setam `warn`; o job termina `.ok`. **(não verificado)**
- `HDR.swift:852` — falha ao reler o RPU vira "DIFFERENT from the generated RPU ✗" e `r.text` é descartado (verify não recebe `log:`); idem HDR10+. **(não verificado)**
- `HDR.swift:842` — `verify()` só testa substrings de `HDR_Format`; nunca compara primaries/transfer/matrix, MasteringDisplay, MaxCLL/MaxFALL, perfil DV com o plano. **(não verificado)**
- `HDR.swift:575/568` — `inspect()` chama `xmlFromISXD` sem `log:` e cria uma pasta `BROS-MUX-DV-<UUID>` por verificação que nunca é removida. **(não verificado)**
- `HDR.swift:303/306` — a caminhada KLV sai com `break` silencioso e aceita qualquer valor que comece com `<` como frame. **(não verificado)**
- `AtmosDecoder.swift:22/44` — `.first` da descrição é sempre a mesma frase; `parsed.summary` (CRC, AUs perdidas, cobertura OAMD) é descartado. **(não verificado)**
- `RenderQC.swift:43` — "Stopped." nunca é exibido (`:146` só mostra `stage` enquanto `running`; `:200` mostra "Not checked yet."). **(não verificado)**

### 4.5 Robustez (baixa severidade)
Confirmados:
- `BrosMux.swift:1269` — o bit-a-bit compara só bytes armazenados (`-c copy` → muxer raw); `outStream` só é usado para `index` e `codec_name` (`:1237`), casado por ordinal (`:1797`); um stsd mal etiquetado (endianness/codec de mesmo tamanho) passaria como "bit-identical ✓". Mitigantes: `MoovPatcher` recusa canais errados (`:1083`), `Inspection.analyze` falha PCM fora de 16/24-bit 48 kHz. Fix barato: assert `codec_name`, `sample_rate`, `channels` vs `t` antes do loop.
- `HDR.swift:227` — durações do CPL são confiadas (`entry + duration <= intrinsic` nunca é checado); `videoFrames` (`BrosMux.swift:2208`) ignora o `FrameCount` que `readIMF` já lê; a inconsistência só aparece após o encode inteiro (`:767`). Checar em `IMF.load`/`readIMF`.
- `PictureSync.swift:138` — a curva de mudança sonora é posicionada 3 ms cedo (frame cobre `[f*hop, f*hop+win)`, `:110`; fronteira antes/depois em `f*hop + 48`, `:132-133`); uma faixa perfeita lê "3.0 ms EARLY" e o ramo `abs(ms) < 1` (`:239`) é inalcançável. Reproduzido em Python: −4/−6/−2/0 ms vira ±1/±3 ms com `start + 0.003`.
- `PictureSync.swift:134` — novelty de 150/150 ms transforma hits curtos (<150 ms) em platôs; o picker (`:165`) aceita qualquer bin do platô, `:170` remove só o platô traseiro e `:173` escolhe arbitrariamente → hits secos votam 20–130 ms cedo e espalhados. Afeta sensibilidade, não o offset global.

Não verificados (vale conferir):
- `BrosMux.swift:2105` — `removeStaleTemps` apaga `.BROS-MUX-tmp-*` com mtime > 24 h; o mtime de uma pasta não muda enquanto o x265 escreve num arquivo dentro dela, então um segundo mux na mesma pasta pode apagar o encode em andamento. Heartbeat/PID dentro do tmp.
- `BrosMux.swift:1997` — `lang=\(t.language)` não é sanitizado (`:` ou `+` corrompem as opções do MP4Box); extensão do link (`:1976`) idem.
- `BrosMux.swift:859` — contagem da cauda E-AC-3 sem `cancel` e qualquer erro de stream no trecho descartado aborta o trim.
- `BrosMux.swift:64` — `runCancellable` nunca escala para SIGKILL; `runSync` não é cancelável (usado por `SyncEngine.decode`, `Probe`, `MediaInfo`).
- `BrosMux.swift:2548` — `autoAlign` lê `self.referenceOffset` (que lê `tracks`, `hdr.imf`) na thread de fundo; capturar antes do `async`. `@MainActor` em `Project` pegaria isso em compilação.
- `BrosMux.swift:2829` — arquivos abertos pelo Finder no lançamento são perdidos porque `delegate.project` só é setado em `.onAppear` (`:2812`); bufferizar URLs.
- `HDR.swift:190` — `Path` do ASSETMAP sem `removingPercentEncoding` (`My%20Film.mxf` → "missing from the package"); só o primeiro `<Chunk>`.
- `HDR.swift:367` — heurística `byUID` funde shots adjacentes com XML idêntico (sem `scene_refresh_flag` nesse corte) e divide por whitespace, sem aviso.
- `PictureSync.swift:515` — `buildPlayer()` sem contador de geração: dois builds sobrepostos vazam `AVQueuePlayer` com observer vivo (`:557-564`); `.onDisappear` (`:632`) tem o mesmo furo.
- `PictureSync.swift:49` — janelas sobrepõem em filmes < ~20 min (`points: 30, window: 30`, `:424`); cortes na sobreposição contam duas vezes e como duas janelas (`:215`).
- `PictureSync.swift:530` — seleção de lane por `loadMediaSelectionGroup` pode tocar a faixa errada; `AVPlayerItem.status` nunca é observado (`:574` marca `playing = true` mesmo sem reprodução).
- `SyncViewer.swift:198/210/191` — lista de hits mantém mapeamento antigo após "Measure Again"; fallback por `trimStart` fica em tempo de imagem, não de referência.
- `RenderQCEngine.swift:288` — detector de frame repetido sem teto nem cadência: conform 24→25, animação "on twos" ou pulldown gera milhares de achados.
- `RenderQCEngine.swift:549-554` — cartão vermelho cujo OCR falha (`:528` bytes insuficientes, `:533` `try?`) é rebaixado a nota `.info`, exit code 0.
- `RenderQCEngine.swift:232/236/247` — limiares SDR em masters PQ/HLG (branco difuso ≈148/255 nunca dispara `m > 246`).
- `SyncViewer.swift:341` / `PictureSync.swift:643` — +45 ms (1,06 frame a 24 fps) recebe check verde; usar meio frame como verde, BT.1359 como âmbar.

### 4.6 Plano de refatoração (em passos)
1. `git init` + `.gitignore` (`build/`, `*.bak_design`); commit do estado atual. Sem isso, nenhum passo abaixo é reversível.
2. Dividir `BrosMux.swift` por tipo já existente, sem mudar comportamento: `Tools.swift` (Tools, Fmt, CancelFlag, Data), `Probe.swift` (MediaInfo, Probe*, Track, ChannelMap, Languages), `Audio.swift` (WavInfo, EAC3Reader, EAC3), `SyncEngine.swift`, `MoovPatcher.swift`, `Verifier.swift`, `Academy.swift` (Check, Academy, Inspection), `JobRunner.swift` (TrimPlan, JobSpec, JobRunner), `Project.swift`, `Inspector.swift`, `App.swift`, `CLI.swift`. O `build.sh` não muda.
3. Constantes compartilhadas: `SyncTolerance` (−15/+45 ms, meio frame) e `Dolby.samplesPerAU` lido do stream e guardado em `Track`, substituindo as cópias de §4.2.
4. `DeliveryReport` único para `runJobCLI` e um `Project.saveRunReport()`; dar ao CLI um `onLog` que imprime.
5. `ProjectLoader` compartilhado (classificação/expansão de URLs + `chooseDefaultReference`) usado por `add()` e `buildProject`.
6. Resultados tri-estado (ok / pulado / falhou) em `MoovPatcher.patch` e `Verifier.compare`; `.failed` nunca substitui arquivo existente (§2.4).
7. `@MainActor` em `Project`; capturar valores antes de todo closure de fundo.
8. Um modo `--selftest` no CLI com casos sintéticos (o verificador já reproduziu 2.1, 2.2 e 2.13 com clipes gerados): WAV/RF64, E-AC-3 de 1536 e 256 samples, ffconcat a 24 fps, string "cd/m2", pipe + SIGTERM.

---

## 5. Desempenho

- `BrosMux.swift:2699` `estimatedSize`, `:2703` `freeSpace` e `:2656` `predictedLevel` reconstroem `jobSpec` (`:2664`, com `plan(for:)` por faixa e regex de `Academy.checks`) e fazem `stat()`/`statfs()` a cada avaliação de body; `predictedLevel` monta o spec ~4×. A UI lê em `MuxUI.swift:679`, `:726-727` (predictedLevel e predictedChecks na sequência), `:774`, `:912-915`, e `ForEach($project.tracks)` (`:229`) re-renderiza tudo a cada tecla num nome de faixa. Em disco de rede ou externo dormindo isso trava a interface. Cachear em propriedades e invalidar nos `didSet` de `tracks`/`container`/`outputURL`/opções; `freeSpace` só ao trocar a pasta.
- `BrosMux.swift:2319/2325/2328` — `add()` detecta IMF, XML DolbyLabsMDF e JSON HDR10+ na main thread; `HDR10Plus.frames` (`HDR.swift:466-468`) faz `Data(contentsOf:)` + `JSONSerialization` do arquivo inteiro (dezenas a centenas de MB). Só o `Probe` (`:2346`) está em fundo. Mover a classificação para o mesmo bloco e contar `SceneInfo` em streaming.
- `BrosMux.swift:2346` — probing de todos os arquivos num bloco único, sem cancelamento nem progresso; inserir por arquivo com `CancelFlag`.
- `PictureSync.swift:58/65` — `detectCuts` decodifica 30 janelas de 4K em série num core; `curvesFor` já paraleliza com `concurrentPerform` + semáforo 4 (`:260-261`). Cortes não são cacheados (`:337`) e `refreshTarget()` re-mede a lane de referência, que não muda. Paralelizar, `-hwaccel videotoolbox` com fallback, cache por `(path, index, fps, grid)`.
- `AtmosDecoder.swift:16/21/24` — stream E-AC-3 inteiro em memória (`runSync` → ~700 MB para 2 h a 768 kb/s), parseado em `[AtmosFrame]` (~290 MB) e copiado para `[VizFrame]` com `parsed` ainda vivo: > 1,2 GB. Alimentar o parser por chunks e emitir `VizFrame` direto.
- `RenderQCEngine.swift:188/195` — arrays por frame (180 rows + 180 rstd + 144 tiles + 144 tstd em Float) ≈ 2,6 KB/frame → ~450 MB para 2 h; `reserveCapacity(100_000)` (`:148`) só cobre r/g/b/std; os detectores só olham i−1..i+1. Janela deslizante de três frames ou UInt8/Float16.
- `RenderQCEngine.swift:563` — passagens de áudio rodam em série depois da imagem, num loop Swift por sample. Rodar em paralelo à `features()` (DispatchGroup) e usar vDSP para pico/zero/clip.
- `AtmosViz.swift:376/307/316` — o slider faz `seek` exato a cada tick e briga com o observer de 30 Hz durante a reprodução; usar `onEditingChanged` (pausar, só `setTime()` durante o arrasto, um seek no fim).
- `HDR.swift:513` — Draft = x265 `ultrafast`; um "Draft (hardware)" com `hevc_videotoolbox` Main10 manteria a mesma injeção e verificação (ver §7).

---

## 6. UX / HIG — o que ainda destoa após o redesign

- **Linha da faixa com larguras fixas** (`MuxUI.swift:316-338`, `:320`, `:355`) — já em §2.14; é o item visível no screenshot.
- **Edição inline em cada linha** (`MuxUI.swift:244-345`): quatro editores com legenda por faixa dentro de um `List` sem `selection:` (`:228`); a referência aparece esmaecida com campos desabilitados (`.opacity(track.include ? 1 : 0.55)` / `.disabled`); o cabeçalho diz "3 of 4 selected" (`:213`) para a caixa de inclusão. É o que mais parece "formulário web". Alternativa nativa: lista selecionável + seção "Track" no `MuxInspector` (`:490`), ou `Table` com colunas editáveis; "3 of 4 included".
- **Sheets de tamanho fixo maiores que a tela de um laptop**: `PictureSync.swift:630` (`1280×980`, 1060 standalone, altura da faixa de frames derivada de constante 1200), `MuxUI.swift:925` (`900×760`), `:826` (`760×480`); janela mínima `1180×720` (`BrosMux.swift:2811`). Num MacBook Air 13" (~900 pt úteis) o botão Done e as lanes somem. Usar `min/ideal` relativos ao `visibleFrame` e deixar o `ScrollView` absorver a altura.
- **Rodapé do Sync em dois parágrafos** (`MuxUI.swift:594-596`, ~13 linhas de caption, ≈260 px do inspector no screenshot), repetindo as tooltips de `:532/:543/:567/:573`, com convenção de asterisco (`:632`). Uma linha + botão de ajuda com popover; tolerância como caption sob os `SyncLights`. (A alegação de que empurra o Output para fora da tela não se confirma: Format/Destination/Estimated size/comando estão visíveis.)
- **`SyncLights` "not measured" antes de alinhar** (`MuxUI.swift:604`, `:630`; aparece a partir de `:589`): lê como estado pendente/falho. Mostrar só quando `syncLag != nil`.
- **Verdict card do File Checker não lista as falhas** (`CheckerUI.swift:69`; cabeçalho "2 failing" em `:120`): onze linhas verdes acima da dobra, as duas falhas abaixo. O Mux já lista `fails.prefix(3)` (`MuxUI.swift:727`). Listar falhas/avisos sob o selo, filtro "Problems only", falhas primeiro; mesmo tratamento no `ResultBanner` (`:368`).
- **Estatueta + título em caixa alta** (`MuxUI.swift:440` `StatuetteShape`, `:472` ouro fixo `Color(red: 0.85, green: 0.66, blue: 0.22)`, `:478` `level?.title` em `.title3`; títulos "NOT APPROVED BY THE ACADEMY" etc. em `BrosMux.swift:1321`). Semelhança com a estatueta e as marcas "Academy/Oscar" são restritas pela AMPAS; o ouro não adapta ao dark mode; HIG pede sentence case e cor semântica. SF Symbol `seal` por nível, títulos em sentence case, manter o disclaimer. **(não verificado)**
- **Acessibilidade**: `Toggle("", …)` (`MuxUI.swift:276`), `Picker("", …)` (`:323`), `TextField("0", …)` (`:330`), `Toggle("On", …)` sob legenda solta (`:338`), botão só-ícone (`:348`) e `Slider` sem rótulo (`AtmosViz.swift:376`) não têm nome para VoiceOver; `.help` vira hint, não nome. O picker Format (`:647-650`) está correto e é o padrão a copiar.
- **Ação primária só na toolbar, sem item de menu**: "Mux" com `⌘↩` em `MuxUI.swift:105-116`; o único `.commands` é `CommandGroup(replacing: .newItem)` com ⌘O/⌘N (`BrosMux.swift:2818`). HIG: todo atalho tem item de menu. Um `CommandMenu("Mux")` com Mux, Align, Sync Viewer, Picture Check, Quality, Save Report.
- **Toolbar e resíduos ad hoc** (`MuxUI.swift:100` Clear All sem confirmação descarta trims/alinhamentos; `:96` "Open File" com ícone `plus`; `:398` bullets "• "; `:632` ✓/✗ em string de formato; `:703` `TerminalBox` com `.frame(height: 110)` e `CheckerUI.swift:31` `minHeight: 320` dentro de Form rolável). **(não verificado)**
- **Três idiomas de empty state / dois de inspector**: `EmptyDropView` (`MuxUI.swift:179`) vs. `Text("No Atmos File")` (`AtmosViz.swift:391`) vs. VStack com borda tracejada (`RenderQC.swift:136`); `Form.grouped` (`MuxUI.swift:503`, `AtmosViz.swift:425`) vs. `GroupBox.inset` (`RenderQC.swift:200-229`). **(não verificado)**
- **Linhas das checks com coluna de 230 pt feita à mão** (`CheckerUI.swift:112`) ao lado de `LabeledContent` (`:86-95`, `:223`): duas gramáticas no mesmo Form. **(não verificado)**
- **`QualitySheet` com `Grid` de 7 colunas** (`MuxUI.swift:849-856`) no lugar de `Table`. **(não verificado)**
- **Layout e opções não persistem** (`MuxUI.swift:12-13`, `:639-640`; `CheckerUI.swift:11`; opções de entrega em `Project`): `@SceneStorage`/`@AppStorage`. **(não verificado)**
- **CLI**: `--job` sobrescreve `-o` existente sem confirmação (`BrosMux.swift:3012`) e descarta o log (`:3007`, `:1653`) enquanto manda "See the log" (`:1778`, `:1788`). **(não verificado)**
- **Render QC**: após Stop a coluna fica em branco e o inspector diz "Not checked yet." (`RenderQC.swift:43`, `:146`, `:200`). **(não verificado)**

---

## 7. Ideias de recursos

Classificadas por valor para uma produtora pequena entregando a Academy/festivais/streamers. Esforço: P (pequeno) / M (médio) / G (grande).

1. **Relatório de entrega + checksums ao lado do arquivo** — P–M. Após o move em `JobRunner.run` (`BrosMux.swift:1918`), escrever `<saida>_DELIVERY.txt` (fontes, trims, hashes bit-a-bit de `:1251`, vereditos de sync/picture, checks Academy, versões das ferramentas) e `<saida>.md5/.sha256` calculados em streaming; reutilizar o builder do CLI (`:3024`); botão "Save Delivery Report…" no `ResultBanner` (`MuxUI.swift:368`). Para HDR, copiar `DolbyVision_from_IMF.xml`, o RPU e um `dovi_tool plot` L1. Prova do que foi entregue, pedido por intakes Aspera/streamers.
2. **Receita de projeto (`.brosmux`) e Open Recent** — M. `Project` (`:2139`) → JSON Codable (bookmarks das fontes, título/idioma/include/enabled/trimStart/channelMap por faixa, referência por caminho+stream, `referenceLateFrames`, container, opções, HDR); File > Save/Open ao lado de `:2818`; auto-save junto da saída; `--recipe` no CLI; `@SceneStorage` para layout. Re-probar ao abrir e avisar se tamanho/mtime mudaram. Elimina re-digitar a correção de 2 frames a cada re-export.
3. **Identidade dos canais 5.1 e consistência Atmos-core × PCM** — M. Após alinhar, usar janelas do `SyncEngine` para inferir LFE (energia < 120 Hz), C (correlação com o mid da referência + banda de fala), L/R, Ls/Rs; sugerir relabel (só rótulos, mix intocado) no `QualitySheet`; decodificar o bed JOC e correlacionar canal a canal com o PCM (correlação, polaridade, nível). Um 5.1 em ordem de cinema passa hoje em todos os checks.
4. **Importar o PCM do IMF sem perdas** — M. `IMF.kind` já reconhece `mainaudio` (`HDR.swift:175`) mas só gera o aviso de `BrosMux.swift:2276`; extrair cada recurso com `-c:a copy` para WAV honrando entry/duration e passar pelo caminho WAV existente.
5. **Loudness dialogue-gated, timeline e medição após o mux (report-only)** — M. `Inspection.loudness` (`:1569`) mede programa inteiro; adicionar passe gated por fala (VAD ou detector espectral no C), curva momentânea/short-term com eventos de true-peak clicáveis, toggle "Measure loudness after muxing" e o mesmo por faixa no Render QC (`RenderQCEngine.swift:425`). Nunca altera o mix.
6. **Perfis de spec além da Academy** — M–G. `Academy.checks` (`:1340`) data-driven sobre um `DeliverySpec` (codecs, resoluções, fps, cor, layouts, bit depth, TC inicial, loudness, regex de nome); built-ins Academy / Festival ProRes / Netflix mezzanine / Apple TV / broadcast + JSON do usuário; picker em `AcademySection` (`MuxUI.swift:714`) e no Checker.
7. **2-pop/leader como âncora absoluta + FFOA/LFOA** — M. Goertzel a 1 kHz nos primeiros/últimos 15 s de cada lane do `PictureSync`, localizar o frame "2" ou a borda preto→conteúdo, reportar pop-vs-frame ao lado do resultado por cortes; FFOA/LFOA no inspector e no relatório.
8. **Ergonomia de jobs longos** — P. ETA por EMA do progresso, progresso no Dock, `UNUserNotification` com "Show in Finder"/"Open Report", `beginActivity` em todo `JobRunner.run` e `autoAlign` (hoje só em encode, `:1730`), som ao terminar.
9. **Alinhamento sub-frame de E-AC-3/TrueHD via edit list (`:delay`)** — M. Hoje faixa Dolby adiantada é recusada (`:1700`, `:2593`) e a atrasada fica até 32 ms tarde; passar o resíduo como `:delay=` em `arguments` (`:1997`) e verificar o `elst` no check pós-mux. Opt-in, pois alguns players ignoram edit lists de áudio.
10. **Picture Sync: intervalo de incerteza e offset exato** — P–M. Bootstrap sobre os `hits` (`PictureSync.swift:227`) → faixa 5–95% desenhada no `LagChart` e habilitar "Use" só com intervalo < meio frame; segundo botão "Use exact +22.4 ms" ao lado do arredondado (`:462-464`, `:657`), com o resíduo que o arredondamento deixa.
11. **Checker de pacote IMF (PKL hashes, consistência CPL/ASSETMAP, Photon opcional)** — M. File Checker aceita pasta IMF (`IMF.packageFolder`), verifica SHA-1 do PKL em streaming, UUIDs, edit rate vs. descritores; `--imf-check` no CLI. Evita rejeição após upload de 200 GB.
12. **Render QC: overlay fixo, níveis legais, área ativa, MaxCLL/MaxFALL medidos** — M. Novos `Finding.kind` em `pictureFindings` (`RenderQCEngine.swift:214`): região idêntica através de ≥3 cortes, `signalstats` BRNG > 1% por > 1 s, `cropdetect` variando entre planos, MaxCLL/MaxFALL medidos vs. tags; chips em `RenderQC.swift:153`.
13. **Fila de entregas (variantes de um mesmo conjunto de fontes)** — G. `DeliveryQueue` de `JobSpec` sequencial com estado por item, reaproveitando temporários trimados; hoje `run()` (`:2705`) roda um `JobRunner` e trava a UI.
14. **Loop audível no Sync Viewer** — P. Play/Loop ±1 s ao redor de `center` com imagem + referência ou faixa alinhada; `PictureSyncModel.buildPlayer` (`PictureSync.swift:515`) já monta a composição. Hoje o viewer (`SyncViewer.swift:302`) é só visual.
15. **Comparar dois arquivos** — P–M. "Compare with…" no Checker: diff de MediaInfo em duas colunas, igualdade de hash por stream (`Verifier`, `:1217`), offset medido quando o áudio difere; `--compare A B`.
16. **Legendas sidecar: converter, retimar pelo trim, QC, exportar** — P–M. SRT↔VTT (TTML básico), deslocar pelo mesmo offset do áudio, QC de texto (sobreposição, >2 linhas, >42 cpl, >20 cps), gravar `<AcademyName>.<lang>.vtt` junto da saída; hoje o check `:1477` só manda entregar VTT separado.
17. **WAV com `data` size errado passa pelo escritor RF64** — P. `headerSizeIgnored` (`:574`, `:650`) só avisa; o WAV vai ao MP4Box como está (`:1983`). Rotear por `WavInfo.writeTrimmed` (`:726`) com plano identidade; MP4Box 26.07 importa esse layout bit-exato.
18. **Carregamento incremental e cancelável** — P. `add()` (`:2346`) um arquivo por vez, `CancelFlag`, "Reading N of M…".
19. **Draft por VideoToolbox** — P. `hevc_videotoolbox -profile:v main10 -tag:v hvc1` com as mesmas tags e injeção/verificação; manter x265 para Slow/Medium (`HDR.swift:513`).
20. **Saúde do stream JOC no visualizador** — P. Disclosure "Stream details" com `parsed.summary` (`AtmosDecoder.swift:44`) e avisos para CRC > 0, AUs perdidas, cobertura OAMD < 100%.

---

## 8. Próximos passos sugeridos

1. `git init` na pasta, commit do estado atual, mover `*.bak_design` e `AppIcon_old.icns` para fora de `*.swift`/da pasta (hoje são o único histórico).
2. Corrigir os três altos e testar com clipes sintéticos: `HDR.swift:557` (chaves `_Min/_Max`), `HDR.swift:744` (outpoint −½ frame / inpoint +¼), `RenderQCEngine.swift:459-465` (congelar energia + flush no EOF).
3. Nunca substituir um arquivo existente quando `!ok` (`BrosMux.swift:1912` → `<nome>_FAILED`), `.doneWithErrors` em `RunState`, reescrever o alerta de `:2713`, `--force` no CLI (`:3012`).
4. Sync: `r.lag == nil` → falha no check final e `maxLag` maior (`:1874`, `:1859`); `referenceLateFrames = 0` em `clear()` (`:2422`); `didSet` só para faixas com trim aplicado (`:2160`, `:2593`).
5. HDR: guarda de transfer/primaries antes do plano (`HDR.swift:690`) e `verify()` comparando valores com o plano (`:842`); links de input em `temporaryDirectory` (`BrosMux.swift:1977`).
6. Render QC: `terminationStatus` + stderr (`RenderQCEngine.swift:203/496`) e fechar o pipe após `terminate()` (`:154/:448`).
7. Picture Sync: gating por `confident` (`PictureSync.swift:458/643/657`), ids de lane no completion (`:439`), pickers desabilitados durante a medição, `start + 0.003` (`:138`).
8. UI: linha da faixa em `Grid` flexível ou seleção + inspector (`MuxUI.swift:316-338`); sheets redimensionáveis (`PictureSync.swift:630`, `MuxUI.swift:925`); rodapé do Sync em uma linha (`:594`); falhas listadas sob o selo do Checker (`CheckerUI.swift:69`); `CommandMenu` com ⌘↩.
9. Dividir `BrosMux.swift` em ~12 arquivos por tipo (movimentos puros) e consolidar as constantes de tolerância/1536/fps.
10. Primeiro recurso novo: relatório de entrega + checksums (§7.1), depois a receita `.brosmux` (§7.2).
