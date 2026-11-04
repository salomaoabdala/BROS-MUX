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

## Regras do app

- **Aba Mux:** nada é recomprimido; as faixas só são juntadas. A única exceção é a recodificação automática para Dolby Vision/HDR10+, e ela tem que ser sempre anunciada com clareza, dizendo o que a ligou e mostrando fonte → destino.
- **Aba Transcode** (planejada em `PLANO-TRANSCODE.md`): é o único lugar onde codec, qualidade, tamanho, resolução e cor podem mudar.
- Não espalhar funções entre abas. Cada aba faz uma coisa só e diz isso no topo.
- O app nunca altera a mixagem nem os arquivos de origem.
- A interface fica em inglês; a documentação (README, CHANGELOG, planos), em português.
