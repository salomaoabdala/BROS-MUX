# BROS-MUX: instruções para o Claude

## Toda atualização documenta exatamente o que fez

Regra fixa do projeto, pedida pelo dono. Vale para toda versão nova, sem exceção.

1. **`CHANGELOG.md` sempre atualizado.** Toda versão ganha uma entrada no topo do `CHANGELOG.md`, com a data (AAAA-MM-DD) e as subseções **Adicionado**, **Mudado** e **Corrigido** (as vazias são omitidas). Cada item diz, de forma concreta, o que o usuário vê ou o que muda no comportamento, e em qual aba ou tela. Não inventar nada: tudo tem que corresponder ao diff.
2. **Uma atualização é uma versão só.** Quando o dono pedir várias mudanças juntas, todas saem numa única versão, que lista cada mudança. Não dividir em v1.x, v1.y, v1.z sem ele pedir.
3. **Durante o trabalho**, o que ainda não foi lançado fica na seção "Em desenvolvimento" do `CHANGELOG.md`. No lançamento, ela vira a entrada da versão nova.
4. **No lançamento:**
   - subir o número em `VERSION`, no `build.sh`, e em `AppInfo.version`, no `Design.swift`;
   - atualizar o título e as funções no `README.md`, com "(v1.x)" ao lado do que é novo;
   - escrever a mensagem de commit no formato `v1.x: resumo`;
   - na resposta ao dono, listar exatamente o que entrou, mudou e foi corrigido, igual ao `CHANGELOG.md`.

## Como uma atualização é feita e publicada

Regra do dono (2026-11-04): ele pede as mudanças, o Claude faz tudo de uma vez, roda o controle de qualidade (QC) e, só se ele passar, publica no GitHub e no `main`, sem ficar perguntando a cada passo.

1. **Juntar tudo numa versão só** e implementar de uma vez. Perguntar só o que muda o resultado e não dá para decidir sozinho; nunca pedir confirmação para compilar, testar, commitar, dar push ou publicar.
2. **Compilar**: `./build.sh` (só Apple Silicon).
3. **QC antes de publicar, sempre.** A parte automática é `./qc.sh` (compila, roda os testes abaixo e escreve `qc/out/QC-REPORT.txt`); a parte manual é olhar. Nada novo pode ter quebrado o que funcionava, e nada pode ter piorado:
   - o app compila; `VERSION` (build.sh), `AppInfo.version` (Design.swift) e a entrada do CHANGELOG batem;
   - Mux: mux de teste com a verificação bit a bit passando (áudio solto, grupo de monos, encode HDR), e o comando ffmpeg/x265 do encode Dolby Vision de uma fonte PQ/BT.2020 idêntico à referência `qc/reference/dv-command.txt`;
   - Transcode: cada preset em cada clipe de teste (ProRes 4444 com alfa, HEVC 10-bit PQ/BT.2020, H.264 Rec.709), conferido com ffprobe (codec, frames, fps, tags de cor);
   - capturas (`--snapshot`) de cada aba, olhadas uma a uma e comparadas com as da versão anterior (`qc/out/previous/`): nada cortado, sumido, sobreposto ou pior;
   - abrir o app instalado e passar pelos fluxos que a versão tocou (abrir arquivos, botões e painéis novos), conferindo usabilidade e textos;
   - no que mudou, comparar antes e depois com dados reais, nunca por inferência.
   Um item falhou → corrigir e rodar o QC de novo. Nada é publicado com QC reprovado; se não der para corrigir, dizer ao dono o que falhou e não publicar.
4. **Instalar** em `/Applications` (`rm -rf /Applications/BROS-MUX.app && ditto build.noindex/BROS-MUX.app /Applications/BROS-MUX.app`).
5. **Publicar no GitHub e no `main`**, só com o QC aprovado e sem pedir autorização:
   - commit `v1.x: resumo` e push do branch de trabalho;
   - `main` na versão publicada: `git push origin <branch>:main` (fast-forward; se não der, merge e push), para a página inicial do repositório mostrar a versão nova;
   - zip do app: `ditto -c -k --keepParent build.noindex/BROS-MUX.app dist/BROS-MUX-v1.x.zip`;
   - tag `v1.x` e Release "BROS-MUX v1.x" (`gh release create`) com o zip e notas em português tiradas do `CHANGELOG.md`: uma linha de resumo, os itens principais, "Requer um Mac com Apple Silicon…" e, no fim, "Instalar: baixe o zip, descompacte e arraste o BROS-MUX.app para /Applications (ou `./install.sh` depois do `git pull`)." O `install.sh` baixa sempre o Release mais recente.
6. **Na resposta**, listar o que entrou, mudou e foi corrigido, igual ao `CHANGELOG.md`, o resultado do QC e o link da Release.

## Quem mexe no monitor de render

Combinado em 2026-11-04, com o dono: o `tools/render-monitor/` (mais o `monitor.command` e o `.claude/launch.json`) é da **sessão master**, que é quem reporta o andamento dos encodes para o dono e precisa responder pelos números que aparecem na tela. Outra sessão que for mexer ali avisa a master no mesmo minuto, para ela revisar antes de o dono olhar.

Duas coisas que já custaram caro:

- O frame mostrado vem do **log do job**, que é ao vivo. O `x265.stats` é gravado em blocos de 4 MiB e fica até ~3.000 frames (2 min) atrás: serve para o bitrate por cena, não para dizer onde o encode está.
- Nada no monitor pode disputar com o encode: contas caras levam cache (o `cumulative_bits` custa 0,4 s por chamada com um filme inteiro, e a página pede status a cada 3 s) e a leitura do disco de trabalho é esporádica.

O servidor não sobe pelo painel de preview do Claude: ali ele perde a permissão do macOS para ler `/Volumes` e o gráfico de cenas morre com "Operation not permitted". Use o `monitor.command` ou `nohup python3 tools/render-monitor/monitor.py &` pelo terminal.

## O app tem que funcionar sozinho, sem o Claude

Regra do dono (2026-11-04). O BROS-MUX vai ser operado por gente sem o Claude e sem agentes, e tem que ser "bulletproof" assim mesmo. Por isso:

1. **Todo erro corrigido vira também um aviso dentro do app.** Quando um erro é encontrado e consertado, a correção inclui um jeito de o programa reconhecer a situação sozinho e guiar quem opera — "isto chegou em P3-D65, o recomendado é BT.2020, quer converter?" —, com a recomendação certa e um botão para aceitar. Pop-up, painel ou item do Render QC: o que couber, mas nunca assumir em silêncio.
2. Em toda correção, perguntar "como o app teria evitado isso sem mim?" e implementar a resposta junto com o conserto.
3. **Atualizações saem na hora em que forem necessárias**, sem esperar a rotina da 01:00.

## Regras do app

Na Beta 2.0.0 (branch `beta-2.0.0`), estas regras substituem as antigas ("Aba Mux" e "Aba Transcode"), a pedido do dono em 2026-11-05. Detalhes em `PLANO-BETA-2.0.0.md`.

- **O caminho em passos:** 01 Video → 02 Audio → 03 Subtitles → 04 Delivery. Depois de um divisor visual vêm as ferramentas de checagem (File Checker, Render QC, Atmos Visualizer), que só leem arquivos. Cada aba faz uma coisa só e diz isso no topo.
- **Toda aba diz sempre se mexe no arquivo**, com uma palavra só para cada coisa: COPY · bit-exact (os bits não mudam), MUX (juntar faixas copiadas), TRANSCODE (recomprimir; os bits mudam) e READ ONLY (ferramentas).
- **Video e Audio copiam bit a bit por padrão.** Transcodar é sempre uma escolha explícita do dono, anunciada em âmbar, com fonte → destino e o motivo (por exemplo: "ProRes 4444 can't carry the Dolby Vision metadata").
- **O app nunca decide em silêncio.** Uma decisão sem resposta fica pendente e impede o Start, com o motivo à vista: o som que veio no vídeo sem resposta, metadado Dolby Vision ou HDR10+ sem decisão, um ✕ na análise.
- **Áudio transcodado** (AAC ou PCM 24-bit) muda o codec, nunca o nível, os canais, a ordem ou o sync, e isso é verificado depois de escrever. Dolby (Atmos, E-AC-3, TrueHD) só sai em cópia. A exceção (Beta 2.0.1) é um master Dolby Atmos ADM BWF: quando o dono escolhe, o Dolby Media Encoder instalado no Mac o encoda em DD+ Atmos ou TrueHD Atmos, anunciado em âmbar ("DOLBY ENCODE"). O BROS-MUX nunca codifica Dolby sozinho nem contorna a licença do DME: ele só manda o trabalho pelo servidor local que a própria janela do DME usa (`DolbyEncode.swift`).
- **O app nunca altera a mixagem nem os arquivos de origem.**
- **O motor não muda de comportamento por causa da interface.** A saída de `--job`, `--transcode`, `--qc` e `--picture` e o comando x265 do encode Dolby Vision (`qc/reference/dv-command.txt`) continuam idênticos.
- A interface fica em inglês; a documentação (README, CHANGELOG, planos), em português.
- **Unidades:** bitrate (o que define o tamanho do arquivo final) em **Mbps** e **Kbps**; velocidade de leitura, gravação e transferência em **MB/s** e **KB/s**. Nunca "Mb/s", "kb/s" nem "MiB".
