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

Regra do dono (2026-11-04): ele pede as mudanças, o Claude faz tudo de uma vez e publica, sem ficar perguntando a cada passo.

1. **Juntar tudo numa versão só** e implementar de uma vez. Perguntar só o que muda o resultado e não dá para decidir sozinho; nunca pedir confirmação para compilar, commitar, dar push ou publicar.
2. **Compilar e testar**: `./build.sh` (só Apple Silicon), os testes do que mudou, e instalar em `/Applications` (`rm -rf /Applications/BROS-MUX.app && ditto build.noindex/BROS-MUX.app /Applications/BROS-MUX.app`).
3. **Assim que a compilação terminar e os testes passarem, publicar o update no GitHub**, sem pedir autorização:
   - commit `v1.x: resumo` e push do branch de trabalho;
   - zip do app: `ditto -c -k --keepParent build.noindex/BROS-MUX.app dist/BROS-MUX-v1.x.zip`;
   - tag `v1.x` e Release "BROS-MUX v1.x" (`gh release create`) com o zip e notas em português tiradas do `CHANGELOG.md`: uma linha de resumo, os itens principais e, no fim, "Instalar: baixe o zip, descompacte e arraste o BROS-MUX.app para /Applications (ou `./install.sh` depois do `git pull`)." O `install.sh` baixa sempre o Release mais recente;
   - merge no `main` só quando o dono disser (a Release pode sair do branch de trabalho).
4. **Na resposta**, listar o que entrou, mudou e foi corrigido, igual ao `CHANGELOG.md`, com o link da Release.

## Regras do app

- **Aba Mux:** nada é recomprimido; as faixas só são juntadas. A única exceção é a recodificação automática para Dolby Vision/HDR10+, e ela tem que ser sempre anunciada com clareza, dizendo o que a ligou e mostrando fonte → destino.
- **Aba Transcode** (planejada em `PLANO-TRANSCODE.md`, implementada na v1.6): é o único lugar onde codec, qualidade, tamanho, resolução e cor podem mudar.
- Não espalhar funções entre abas. Cada aba faz uma coisa só e diz isso no topo.
- O app nunca altera a mixagem nem os arquivos de origem.
- A interface fica em inglês; a documentação (README, CHANGELOG, planos), em português.
- **Unidades:** bitrate (o que define o tamanho do arquivo final) em **Mbps** e **Kbps**; velocidade de leitura, gravação e transferência em **MB/s** e **KB/s**. Nunca "Mb/s", "kb/s" nem "MiB".
