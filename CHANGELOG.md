# Changelog

Toda atualização do BROS-MUX é registrada aqui: o que entrou, o que mudou, o que foi corrigido.

## Em desenvolvimento

(nada ainda)

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
