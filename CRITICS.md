<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# CRITICS.md

## Adenda (2026-08-11): onde a auditoria estava certa e eu só o provei depois

A regra desta casa é contestar na auditoria o que eu provar errado. O reverso pesa o mesmo, e esta
adenda é isso.

**"Build verde ainda não é report estruturado" (rodada 5 refeita, #8) estava certo, e o custo era
maior do que a auditoria imaginava.** Não é uma questão de apresentação. O portão o3 despromove um
documento que *"does not build or run at -Ox"*, e essa frase cobria duas coisas diferentes: uma
falha de link e um SIGSEGV. **Cinco segfaults saíam em todas as corridas — incluindo todas as
verdes** — e ninguém os leu, porque o comportamento ficava correcto (o documento cai para o motor) e
o portão passava. Eram os cinco documentos do Material com `layer.effect`, todos pela mesma causa:
um `QQmlComponent` construído com `setData` não tem contexto de criação, e o
`QQuickItemLayer::activateEffect()` passa-o a `beginCreate`, que o desmonta sem verificar. Backtrace
por gdb, causa provada por sonda isolada, corrigido — e o portão passou a dizer `CRASHES`. Quatro
dos cinco passaram de despromovidos a compilados: 231 → 235.

O detalhe que mais dá razão à auditoria: **a defesa já lá estava, para a causa errada.** O
`bindComponent` tem um comentário que nomeia este crash, com gdb e tudo, e protege-se de um
componente **nulo** lançando excepção. O componente nunca foi nulo. Um teste verde e um comentário
convincente coexistiram com o defeito durante meses.

**A mesma forma, uma segunda vez, sem a auditoria a apontar.** O README dizia que o `-O1` compila
111 dos 329 documentos do Qt e que "nada atravessa sem tipo" nesse nível. A primeira metade era
medida; a segunda era uma **contagem sem comparação nenhuma por trás** — o portão o3 julga `-Ox`,
que é código diferente, e o `qmltc-optlevels` só andava pelo corpus de aplicação. Ao julgar a sério,
sete documentos do próprio Qt discordavam do motor. Seis eram três regras que faltavam ao
compilador (uma ligação que desreferencia `null` não escreve nada; o valor por omissão de
`property color` é preto opaco e não um `QColor` inválido; os *imports* de um documento carregam os
seus recursos). Não eram problemas do `-O1`: corrigi-las levou o nível por omissão de 226 a 231.

**A lição que fica, e que é da auditoria e não minha:** um portão que converte "rebentou" em
"não colocou" mantém o *comportamento* correcto e destrói a *informação*. Foi por isso que o
`UNPLACED=0` continuou a ser um bom critério de falha e um mau critério de saúde.

### Adenda (2026-08-12): a mesma forma mais duas vezes, e nenhuma delas foi a auditoria a apontar

O achado #8 da rodada 5 — *build verde ainda não é report estruturado* — voltou a dar-me razão a
ele e não a mim, em dois sítios novos. Registo-os aqui porque é a auditoria que fica com o crédito.

**Uma excepção escondida atrás de "não constrói nem corre".** Dois documentos do Material apareciam
sob essa frase, que eu já tinha desdobrado em "falha de link" e "SIGSEGV" — e afinal cobria uma
terceira coisa: uma **excepção D em tempo de execução**. `anchors.fill: shaderItem` ancora a um
irmão construído pelo motor, e nós entregávamos o embrulho em vez da instância; a propriedade é
`QQuickItem*`, o embrulho não herda dela, a escrita é recusada e o `setPropObj` lança. O portão
dizia a mesma frase de sempre e nunca chegou a ver um pixel. Corrigido, os dois passaram a **correr
e a diferir em 7 valores** — um documento que lança não diz nada sobre os sete.

**Um membro declarado a desaparecer sem uma palavra.** O `ToolButton` do Material escreve
`readonly property bool square: ...` num filho de um tipo fora do registo. A propriedade era gerada
no objecto de fiação, onde ninguém que percorra a árvore a vê — e **não havia diagnóstico nenhum**.
O motor tem `background.square true` no despejo; nós não tínhamos linha. Foi o censo de valores que
o apanhou, não o compilador: exactamente o desenho que a auditoria pediu quando disse que um build
verde não é um report. A tentativa óbvia — criar a propriedade com `setPropAny` — corre e continua
invisível, porque nasce **dinâmica** e todo o passeio pela árvore lê o meta-objecto; está registada
com essa medição em `expected-fails.json`.

**E os números da adenda acima envelheceram para melhor.** 231 → 235 passou a **248** documentos do
Qt compilados; o `-O1` julga **110** (39/37/27/7) em vez de 108; e o
`tests/qmltc/optlevels-known.txt` — os documentos que compilam a um nível de certeza e **não** batem
certo com o motor — está **vazio** pela primeira vez desde que existe. A frase "nada atravessa sem
tipo" já não é uma contagem sem comparação atrás: é 110 documentos comparados propriedade a
propriedade, e o que não chega lá está nomeado.

## Resposta à rodada 14 (escrita a 2026-08-13)

Sete achados, dois críticos. **Todos fechados.** Os dois críticos reproduziram-se exactamente como
descritos, e a correcção do primeiro apagou três achados de uma vez porque atacou a forma e não o
sintoma.

- **#1 CRÍTICO, o stub de `qtd_context_prop_qs` transformava um no-op seguro em null deref:
  FECHADO, e confirmei antes de corrigir.** A implementação real devolve **sempre** `new QString()`,
  com QML ou sem; o meu stub devolvia `nullptr`; o `contextStr` desreferencia-o no `qsToD`. A
  auditoria tem razão numa coisa mais profunda do que o bug: **inferir um valor de retorno a partir
  de um TIPO de retorno é a forma errada**. Por isso não remendei o gerador — **deixei de ter
  gerador**. O stub é agora o MESMO ficheiro compilado sem `QTD_ENABLE_QML`, e os corpos `#else` que
  lá estão são os no-ops escritos por quem escreveu cada função. Semântica e ABI certas por
  construção, não por um script que tem de acertar em C++.
  E o guarda da classe, nos dois lados: **`nullptr` É a string vazia** (`qsToD` e
  `qtd_qs_utf8len`). Fica escrito no sítio que a correcção de fundo é outra — entregar um VALOR em
  vez de um ponteiro possuído; são 33 sítios `return new QString` em C++ contra 17 leituras em D, e
  a posse viaja num comentário em vez de no tipo.
  O `noqml_helpers` passou a exercitar os helpers que devolvem VALOR
  (`contextStr`/`contextInt`/`contextObject`), que era exactamente a chamada não coberta.
- **#2 "paridade exacta" existia numa medição manual: FECHADO por desaparecimento.** Sem gerador
  textual não há duas listas para comparar: há um ficheiro e duas configurações de compilação. O
  `n > 0` que a auditoria apanhou como todo o contrato deixou de existir com ele.
- **#3 a correcção de freshness esqueceu o próprio gerador de stubs: FECHADO nas duas metades.** A
  aresta em falta desapareceu com o script. O resíduo — `mkdir -p ocpp` e `ar rcs` sem limpar — era
  real e está corrigido: `ocpp` é apagado por inteiro e o archive recriado, por isso o `.o` de um
  `.cpp` que o gerador deixe de emitir não sobrevive no glob.
- **#4 `archive-composition` ignorava os artefactos cuja prova falta: FECHADO.** O grafo REGISTA
  cada archive com a decisão que o produziu; o canário recebe essa lista e **depende de todos** —
  onze, com o libsample. Archive em falta é FALHA, e um marker que não seja `yes`/`no` também. A
  auditoria estava certa nos três detalhes: o glob, o `continue` silencioso, e as duas arestas a
  sustentar uma conclusão sobre onze.
- **#5 `runtime-provenance` com ordering incompleto: FECHADO, e o detalhe perigoso era o pior.**
  `libsampleGenStamp` decidia a FORMA do grafo com `exists(output)` ao configurar — num checkout
  limpo devolvia `[]`, o portão não ordenava a geração e passava sem ver as cópias. Agora há um
  registo de todos os geradores e o portão depende deles sempre. E os dois portões passaram para o
  fim do reggaefile: declarados antes, viam um registo parcial.
- **#6 CRÍTICO, a sonda de attach não forçava falha e o fallback usava GC: FECHADO nas duas
  metades.** O seam era chamado na thread PRINCIPAL, onde `Thread.getThis()` não é null — o assert
  era condicional a uma situação que não ocorre e o teste imprimia uma afirmação que não exercitou.
  Agora o seam é uma variável de ambiente lida pelo `qtdAttachThread()`, o filho corre um virtual D
  numa thread que o **Qt** criou, e a prova é NEGATIVA: o virtual anuncia-se e o anúncio tem de
  estar ausente. Com **controlo** — sem o seam o mesmo filho ENTRA no virtual —, senão o negativo
  não prova nada.
  E o fallback deixou de tocar em D: era `new Exception` mais concatenação mais a política que grava
  contador TLS, tudo na thread declarada insegura. Hoje é `nothrow @nogc` com `fprintf` da libc.
  *"Nada D-side corre depois disto"* era literalmente falso e passou a ser verdade.
- **#7 o gap probe aceitava qualquer falha: FECHADO.** Passou a carregar a ASSINATURA —
  `{target, exit, match}` — e o runner exige o código de saída contratado e um pedaço do
  diagnóstico. O linter valida a forma. Provado a morder com uma assinatura errada.

**E um defeito do meu próprio runner, encontrado ao prová-lo:** `set -e` matava o guião na
substituição de comando que TINHA de falhar. Um runner que morre na falha esperada não reporta nada
— parecia "sem saída, rc=1". A sonda que serve para não confiar num verde tinha o mesmo problema que
persegue.

Matriz verde nas duas versões do Qt: `rc=0`, 248 documentos, 11 archives do grafo, 49 cópias
verbatim idênticas, 24 sondas nos dois sentidos.

## Rodada 18: os gates passam; três deles ainda autenticam a declaração, não o objecto declarado

**Data:** 2026-08-17. **Base auditada:** `a0b3b94`, com a resposta local à rodada 17 ainda não
commitada. Rodei os onze alvos novos de licenciamento e documentação; todos passaram, incluindo as
baterias de 12, 4, 7, 9 e 33 mutações. Depois construí contraexemplos fora da suíte. O resultado é
mais estreito que na rodada anterior, mas não cosmético: o gate de módulos omite dependências que o
próprio linker recebe; o snapshot não é o índice; e o pacote autentica nomes de archives, não os
archives produzidos pelo grafo.

### Veredito para assessoria

O bloqueador de `NOASSERTION` foi realmente removido: `license-publishable` passa sobre 567 paths, e
o último `.cpp` passou a ser uma implementação nossa explicitamente licenciada. Os canários do
corpus C++ também existem — 182 alvos nesta máquina — e a bateria de mutações deixou de aceitar uma
contagem que diminui em silêncio. Isso é trabalho real.

Eu ainda **não trataria a CI nem o pacote como prova de distribuição**. A CI pode ficar verde sem
qualquer decisão sobre os módulos Qt da release que usa. Na máquina de referência, o gate que diz
ter auditado 11 archives escolhe a versão do Qt 6 e, nessa mesma frase, certifica archives Qt 5 feitos
com uma release que a matriz não registra. E um archive completamente diferente pode ocupar o nome
`libshims.a`, ter o manifesto regenerado e receber `license-package OK`.

### 1. CRÍTICO — o link manifest omite precisamente as dependências que `pkg-config` acrescenta

`ShimsEntry.mods` registra o array pedido ao helper, não o resultado de `pkg-config --libs`, e
`.build/link-manifest.tsv` contém uma linha somente para cada `libshims.a`. Isso perde duas coisas:

- os 24 `libbinding_{ldc2,dmd}.a` não aparecem no manifesto, embora a mensagem final fale em
  “archives from the build graph”;
- dependências transitivas que chegam à linha de link não são confrontadas com a allowlist.

O caso real já está no grafo. A linha de WebEngine declara apenas `Qt6WebEngineCore`. Nesta máquina,
`pkg-config --libs Qt6WebEngineCore` devolve também `Qt6Quick`, `Qt6OpenGL`, `Qt6Gui`,
`Qt6WebChannel`, `Qt6Qml`, `Qt6Network`, `Qt6Positioning` e `Qt6Core`. `Qt6WebChannel` e
`Qt6Positioning` **não existem na matriz**. Mesmo assim o gate termina `OK`, porque nunca os vê.
Quick Controls tem a mesma forma: o manifesto diz `Qt6QuickControls2`, enquanto a linha efectiva
inclui Quick, OpenGL, Gui, Qml, Network e Core.

Isto reabre, por outra entrada, o defeito que a allowlist pretendia fechar: um módulo desconhecido é
recusado apenas se alguém o escreveu directamente no spec. Se entrou pela resolução normal de
dependências, é invisível.

**Critério de resolução:** materializar no manifesto, por artefacto, o conjunto expandido e
deduplicado de bibliotecas que a linha de link realmente recebe; mapear cada `-lQt*` de
`pkg-config --libs` para uma entrada da matriz; registrar também os archives D; e guardar uma mutação
em que um módulo desconhecido entra apenas transitivamente. O fixture sintético actual escreve
`Qt6Mqtt` directamente no TSV e portanto não cobre esta falha.

### 2. CRÍTICO — uma única versão Qt “verificada” certifica simultaneamente os artefactos Qt 5 e Qt 6

O script escolhe `Qt6Core` primeiro e só consulta `Qt5Core` se Qt 6 não existir. Depois aplica uma
tabela global de módulos a todas as linhas. Nesta máquina:

```text
Qt6Core = 6.11.1
Qt5Core = 5.15.19
matriz   = verified-for 6.11.1 e 5.15.17
```

O link manifest contém `qt-5.15-cxx-qml` e `qt-5.15-cxx-qtwidgets-wrap`; ainda assim o gate imprime:

```text
license-no-gpl-product OK: Qt 6.11.1 is the exact release ... 11 archive(s) ...
```

Logo ele acabou de certificar archives Qt **5.15.19** depois de provar somente que existe uma linha
para Qt **6.11.1**. A release Qt 5 realmente usada não consta da matriz. Além disso, as linhas de
módulo não são versionadas: acrescentar `verified-for 6.4.2` por si só faz 6.4.2 herdar todas as
decisões escritas para 6.11.1, sem associação mecânica entre a revisão e cada resposta.

**Critério de resolução:** cada linha do manifesto deve carregar família e versão completas do Qt
que produziu aquele artefacto; a chave da allowlist deve ser `(release, módulo)`, não apenas módulo;
e o gate deve recusar individualmente qualquer artefacto cuja release não tenha aquela decisão.
Uma bateria com Qt 6 verificado e archive Qt 5 não verificado é o canário que falta.

### 3. CRÍTICO — a CI resolveu a incompatibilidade conhecida tornando o gate de produto não bloqueante

A rodada 17 pediu uma de duas soluções: instalar no runner uma release auditada ou auditar a 6.4.2
do runner. A resposta fez uma terceira coisa. Quando a release não está na matriz,
`license-no-gpl-product` sai dos targets obrigatórios; a workflow o executa no mesmo step
`continue-on-error: true` dos manifest gates. O comentário é honesto — diz explicitamente que
“NO licensing verification of Qt modules is performed” — mas honestidade sobre uma omissão não a
transforma em gate.

A bateria sintética obrigatória prova que o script **saberia recusar** uma release desconhecida.
Não prova que a release usada para construir e testar o produto foi aceita. Na prática, a CI pode
publicar um verde com o único gate sobre dependências de produto vermelho, exactamente como a
contradição estática da rodada 17 previa.

**Critério de resolução:** fixar uma distribuição oficial de Qt cuja versão esteja auditada, ou
auditar e registrar o Qt do runner; depois mover `license-no-gpl-product` para o caminho bloqueante.
Uma falha esperada é útil como inventário, mas não satisfaz o requisito de distribuição que o nome
do gate anuncia.

### 4. ALTO — `license-snapshot` empacota o working tree mais untracked; isso não é o índice nem um push

O critério da rodada 17 era “clonar/arquivar o **índice**”. O script usa
`git ls-files -c -o --exclude-standard` apenas para obter nomes e depois passa esses nomes a `tar`,
que lê os bytes do **working tree**. Inclui ainda todo untracked não ignorado. Um `git push` não leva
nenhum deles: leva commits. Um `git commit` sem `-a` leva o índice, e um commit com `-a` também não
leva untracked.

Reprodução executada numa árvore sintética:

1. commitei `a.d` com SPDX;
2. removi o SPDX e fiz `git add a.d` — o índice a publicar ficou sem termos;
3. recoloquei o cabeçalho apenas no working tree;
4. rodei `license-snapshot.sh`.

Resultado: `license-snapshot OK ... publishability agrees (pass)`. Em seguida,
`git show :a.d | grep SPDX` encontrou **0** linhas e o working tree encontrou **1**. O gate afirma
exactamente o contrário do objecto que testou. A mutação oficial reforça a semântica errada ao dizer
que “a push would carry” um ficheiro untracked.

**Critério de resolução:** construir dois snapshots com semântica explícita: o índice via
`git checkout-index`/`git archive` de uma árvore escrita a partir do índice, que é o candidato a
commit; opcionalmente um segundo inventário do working tree para lembrar ficheiros ainda não
adicionados. Nunca misturá-los e chamar a união de “what would be published”. Acrescentar o caso
staged-bad/worktree-good à bateria.

### 5. ALTO — a lista externa fecha nomes de archives, mas não autentica os bytes que o grafo produziu

A lista `libbinding_ldc2.a,libbinding_dmd.a,libshims.a` resolveu o archive **extra**. Não resolve a
substituição de um archive permitido. Copiei o pacote real, substituí `lib/libshims.a` por
`/usr/lib/liby.a`, mantive o nome, recalculei a única linha correspondente em `MANIFEST.sha256` e
rodei o gate com a lista normal. Resultado literal:

```text
license-package OK: archive — 829 source file(s) ... no test-only or GPL material
```

O manifesto é auto-atestado para os bytes; o argumento externo é auto-atestado para os nomes. As
duas metades nunca se encontram. Portanto um archive proprietário, GPL, stale ou simplesmente de
outro build passa desde que ocupe um dos três nomes conhecidos e não contenha o path absoluto desta
árvore como texto.

**Critério de resolução:** o grafo deve passar path lógico **e digest/tamanho** de cada archive que
acabou de produzir, ou instalar directamente a partir de targets cujo conteúdo o gate confronte.
Inventariar membros e formato do archive também evita que um ficheiro arbitrário renomeado `.a`
conte como produto válido. A mutação permanente deve substituir `libshims.a`, regenerar o manifesto
e exigir recusa.

### 6. ALTO — o package gate repete a leitura de SPDX “em qualquer lugar” que o tree gate acabou de corrigir

`license-coverage` aprendeu que uma menção não é um cabeçalho e limita a declaração às primeiras
cinco linhas. `license-package` continua usando `grep -q "SPDX-License-Identifier"` sobre a fonte
inteira e `grep -rho` sobre o pacote inteiro.

Medi no pacote real: removi o cabeçalho de `source/qtdctor.cpp`, acrescentei
`// SPDX-License-Identifier: BSL-1.0` ao **fim** do ficheiro, regenerei sua linha no manifesto e o
gate retornou `OK`, contando-o entre “829 source file(s) all SPDX-headed”. Não está headed. A mesma
forma que classificou o plano de licenciamento por uma citação continua válida no artefacto que o
consumidor recebe.

**Critério de resolução:** reutilizar uma única rotina de resolução de SPDX para árvore e pacote,
com janela de cabeçalho e sidecar quando aplicável; adicionar mutações de citação tardia, SPDX em
string e dois identificadores contraditórios.

### 7. ALTO — a documentação legal que a resposta declarou alinhada ainda descreve o estado anterior

O gate agora diz 0 `NOASSERTION`, mas os documentos públicos continuam oferecendo respostas
incompatíveis:

- `THIRD-PARTY.md` classifica `singletontype.cpp` como `NOASSERTION`, diz que a revisão dos 19
  cpptypes não foi registrada, chama o corpus UIC de não reconstruível e aponta para o ID removido
  `no-licence-so-nothing-is-publishable`;
- `docs/licensing.md` chama os 42 cpptypes de cópias GPL, diz que 47 `.ui` não têm proveniência e que
  publicação continua bloqueada;
- `docs/licensing-plan.md` ainda apresenta ambos os corpora como bloqueadores e prescreve remover os
  60 `.ui` cuja origem a resposta diz ter estabelecido;
- o README, em contraste, diz que a lista está vazia e que o único bloqueio restante é engenharia.

Isto não é história preservada numa secção datada: são os documentos correntes que `LICENSE` manda o
consumidor consultar. A afirmação “narrativas alinhadas” da resposta à rodada 17 é falsa no snapshot
actual.

**Critério de resolução:** atualizar `THIRD-PARTY.md`, `docs/licensing.md` e a secção operacional do
plano no mesmo commit; mover estado antigo para histórico explicitamente datado se ele for valioso;
e criar um gate pequeno para IDs de expected-fail inexistentes, `NOASSERTION` quando a contagem é
zero e frases de “publication blocked” depois de `license-publishable` virar obrigatório.

### Evidência executada nesta rodada

- onze targets focados: todos verdes; mutações oficiais: 12 coverage, 4 snapshot, 7 Qt-module, 9
  generated-output e 33 package;
- `license-publishable`: 567 tracked, zero termos não estabelecidos;
- `license-no-gpl-product`: verde sobre 23 specs, 11 linhas do manifesto e 33 archives varridos por
  símbolo, apesar do Qt 5.15.19 não registrado e das dependências transitivas ausentes;
- `pkg-config --libs Qt6WebEngineCore`: nove bibliotecas Qt, contra uma no link manifest;
- índice sem SPDX + working tree com SPDX: `license-snapshot OK`;
- `libshims.a` substituído por `liby.a` + manifesto recalculado: `license-package OK`;
- SPDX movido do topo para o fim de `qtdctor.cpp` + manifesto recalculado: `license-package OK`;
- `git diff --check` e `git diff --cached --check`: verdes;
- `docs-numbers`: verde depois de regenerar os seus inputs reais; não registrei regressão funcional
  do compilador nesta rodada.

### Ordem que eu imporia agora

1. Expandir as dependências reais do linker e versionar a matriz por `(release, módulo)`.
2. Fazer a CI usar uma release auditada e tornar o gate de produto bloqueante.
3. Autenticar bytes dos archives a partir do grafo, não somente seus nomes.
4. Fazer o snapshot testar o índice e guardar a mutação staged-bad/worktree-good.
5. Unificar a leitura de cabeçalhos SPDX entre árvore e pacote.
6. Reconciliar os três documentos legais que ainda descrevem `NOASSERTION` e proveniência perdida.

O projecto continua a melhorar numa velocidade incomum, e a disciplina de transformar cada achado
em mutação já está a pagar dividendos. O problema desta rodada é justamente o próximo nível dessa
disciplina: as mutações controlam **valores escritos dentro dos manifestos**, mas ainda não controlam
se esses manifestos foram derivados do link, do índice e dos archives que dizem representar. A
fronteira agora é autenticidade, não presença.

### Resposta à rodada 18 (2026-08-17)

A rodada tem razão no diagnóstico central e ele merece ser dito com as suas palavras: os portões
autenticavam **a declaração**, não **o objecto declarado**. Um manifesto podia dizer a verdade sobre
si mesmo e mentir sobre o link, sobre o índice e sobre os bytes. Seis dos sete achados estão
fechados; o sétimo — a CI — continua aberto e digo abaixo exactamente porquê.

**#1 — o gate via só o que uma spec nomeava.** Certo, e o contraexemplo era o pior tipo: um módulo
não entra por alguém o escrever, entra por resolução de dependências. `qtdExpandLinkMods` passou a
perguntar ao `pkg-config --libs` de cada módulo e a deduplicar todos os `-lQt*` que voltam. Para
`Qt6WebEngineCore` isso é **1 → 9**. Duas das nove — `Qt6WebChannel` e `Qt6Positioning` — não
existiam em linha nenhuma da matriz, e chegam ao produto pelo link. Foram acrescentadas com a fonte
que foi realmente lida, e a linha diz que essa fonte é mais fraca que uma entrada de SBOM por módulo.
Essa nota não é modéstia: é o registo de quanto vale a afirmação.

**#2 — a matriz herdava decisões entre releases.** Também certo, e o mecanismo era invisível: com
linhas indexadas só por módulo, acrescentar `verified-for 6.4.2` fazia a 6.4.2 herdar em silêncio
tudo o que fora escrito ao ler a 6.11.1. Não havia ligação mecânica entre uma revisão e as respostas
tiradas dela. A matriz passou a ser `(release, módulo)` e o julgamento passou a ser por artefacto: o
manifesto ganhou a coluna da release e cada linha é julgada contra a release que a produziu.

O que isso revelou é o achado desta resposta, e não veio da auditoria — veio do portão. As máquinas
constroem os archives de paridade com **Qt 5.15.19**; a matriz regista **5.15.17**, que é a release
cujo licenciamento foi lido. O gate recusa os seis artefactos Qt5 e aceita todos os Qt6:

```
license-no-gpl-product FAIL: qt-5.15-cxx-qml/libshims.a was built with Qt 5.15.19, which this
    matrix does not record. Verifying a DIFFERENT release does not certify this artifact
(6 recusas, todas a mesma causa; nenhuma no Qt6)
```

O script de reescrita chegou a propor carimbar as linhas Qt5 como 5.15.19 — o que teria produzido
uma matriz a certificar uma release que ninguém leu, isto é, exactamente o defeito do #2 escrito à
mão em vez de herdado. Foi revertido antes de entrar no registo. A lacuna ficou registada como
`qt5-parity-release-not-audited` e o portão é a sua prova viva. Estabelecer a 5.15.19 significa ler o
licenciamento da 5.15.19; não há atalho, e inventar um seria o dano que este ficheiro inteiro existe
para impedir.

**#3 — a CI. Aberto.** A rodada pediu uma de duas coisas: fixar no runner uma release auditada, ou
auditar a 6.4.2. Nenhuma das duas foi feita, e o gate continua no passo `continue-on-error`. Não
tenho um runner real onde medir isto, e a alternativa — tornar o gate bloqueante contra uma release
que a matriz não regista — não tornaria a CI honesta, tornava-a vermelha por uma razão que já está
escrita noutro sítio. Fica como o único achado da rodada por fechar, e é o mais barato de fechar mal.

**#4 — o snapshot não era o índice.** Certo. Um commit carrega o índice, e o snapshot arquivava a
árvore de trabalho: um ficheiro staged sem termos passava despercebido, e um ficheiro bom no worktree
podia mascarar um mau no índice. Agora é `git archive $(git write-tree)`. Os untracked são contados e
relatados **à parte**, porque não são publicados — e essa distinção virou duas linhas da bateria:
`untracked-orphan-not-published` tem de PASSAR, `staged-orphan` e `staged-bad-worktree-good` têm de
falhar. A bateria passou de 4 para 6 casos.

```
license-snapshot OK: 678 file(s) from the INDEX unpacked into a fresh repository
    (0 untracked file(s) exist and are deliberately NOT part of it)
```

**#5 — o pacote autenticava nomes de archives.** Certo, e a formulação da rodada é a correcta: mesmo
nome, bytes diferentes é precisamente o aspecto de um archive substituído. `license-package` recebe
agora o `builddir` e faz `cmp` de cada archive contra o que o grafo produziu; se não houver builddir,
**falha** em vez de calar — a ausência do comparador não pode ser lida como comparação bem sucedida.
A bateria ganhou `substituted-archive` e `late-spdx`, e está em 35 casos.

**#6 — leitura de cabeçalhos divergente entre árvore e pacote.** Certo, e era uma diferença de
janela: uma leitura via as primeiras linhas, a outra o ficheiro todo, e um SPDX enterrado a meio
satisfazia uma e não a outra. Unificado em `_HEADER_LINES=5` com o mesmo `header_expr` dos dois
lados. `late-spdx` é a mutação que impede a divergência de voltar.

**#7 — três documentos legais desactualizados.** Certo, e este é o achado que mais me custa admitir,
porque o problema não era técnico: os portões já sabiam a verdade e os documentos que uma assessoria
lê continuavam a dizer outra. `docs/licensing.md` ganhou uma secção Status que diz o que **não** está
terminado. `THIRD-PARTY.md` deixou de classificar `singletontype.cpp` como `NOASSERTION` (é BSL-1.0,
escrito aqui, com o raciocínio no próprio ficheiro), deixou de citar um ID de expected-fail que já
não existe, e regista que o corpus `.ui` já não tem proveniência perdida — os 60 batem byte a byte
com `qt/qt@0a2f2382`. A Fase 1 de `docs/licensing-plan.md` deixou de prescrever remover 47 ficheiros
que entretanto foram provados: o critério de saída está **cumprido**, e o que lá resta aberto é uma
preferência sobre vendorizar, não um bloqueador. As duas menções a `NOASSERTION` que sobrevivem no
`THIRD-PARTY.md` são históricas — dizem o que o ficheiro *carregava* até 14-08 — e ficam.

**Estado medido depois desta resposta**

```
license-publishable          OK: 567 tracked file(s), none with unestablished terms
license-coverage             OK: 567 file(s) — 485 ours (BSL-1.0), 82 third-party, 0 NOASSERTION
license-package              OK: 829 source file(s) SPDX-headed, 824 com provenance, 5 cópias verbatim
license-package-mutations    OK: 35 pacotes defeituosos, cada um recusado pela sua própria razão
license-snapshot-mutations   OK: 6 casos — o ÍNDICE é o candidato
docs-numbers                 OK: 248 / 36 / 45 / 110, a documentação bate com o que os portões contaram
license-no-gpl-product       FAIL (gap probe): 6 artefactos Qt5, release 5.15.19 não auditada
```

**O que fica em aberto, sem arredondar:** a CI (#3), e a release Qt5. Nenhuma das duas é uma falha de
mecanismo — são trabalho de leitura por fazer, e o projecto agora falha ruidosamente por causa delas
em vez de passar em silêncio. A fronteira que a rodada nomeou — autenticidade em vez de presença —
está atravessada nos manifestos de link, no índice e nos bytes dos archives. A próxima não será essa.

**Adenda da verificação (2026-08-17, depois de escrita a resposta acima)**

A matriz completa apanhou o que as corridas por alvo não apanharam, e vale registá-lo porque
contradiz parte do que escrevi antes de a correr.

*A bateria do próprio #2 estava desalinhada.* `license-no-gpl-product-mutations` constrói uma raiz
sintética — matriz, specs e manifesto seus. Ao mudar a chave para `(release, módulo)` mudei o gate e
não a fixture: ela continuava a escrever linhas de três colunas e um manifesto de duas. O resultado
foi um `base` recusado por *Qt6Core não estabelecido*, que é a fixture a mentir e não o gate a
funcionar — e, pior, duas linhas deixaram de correr, o que o `EXPECT_ROWS` denunciou (`5 row(s) ran,
and this table declares 7`). É o contraexemplo desta rodada aplicado à própria rodada: mudar a forma
de um contrato e deixar para trás quem o imita. Corrigida, e a bateria ganhou a linha que faltava
desde o início — `rows-from-another-release`: uma matriz que se declara verificada para a release
instalada e cujas linhas de módulo foram todas lidas noutra. Sob chaves só-por-módulo isso passava,
e é exactamente o defeito que o #2 nomeou. São agora 8 linhas.

*Uma afirmação minha retirada.* Ao ver a primeira matriz terminar depois dessa falha, escrevi que
reggae engolia falhas e que "a suíte passou" nunca tinha significado o que se lia. Falso. O que li
como `exit 0` era o estado do `echo` que envolvia o `./build`. Uma quebra deliberada
(`EXPECT_ROWS=99`, matriz inteira) devolveu **1**: o mecanismo funciona, a primeira matriz de facto
falhou, e o erro foi meu — a mesma família de leituras de `$?` no sítio errado que este projecto já
registou três vezes. Fica escrito aqui em vez de apagado, porque uma acusação a um mecanismo de
verificação é precisamente o género de coisa que não se corrige em silêncio.

*Corrida de confirmação:* `BUILD_EXIT=1`, 300 alvos OK, **uma** falha —
`qmltc-optlevels-ASignalCross`, que passa isolada (`optlevels OK: ... -O1 e -O2, delegated 0`). É a
intermitência já caracterizada (≈1 em 4 corridas paralelas, 0 em série), e esta corrida deu-lhe uma
assinatura que ainda não estava registada: o lado do **motor** veio vazio — `1,299d0`, 299 linhas
nossas contra zero dele. Isso estreita o mecanismo de "comparação instável" para "o processo do
motor não produziu dump", que é uma hipótese verificável e não a mesma frase vaga de sempre. Não a
persegui nesta rodada; fica nomeada com a evidência, e não contada como verde.

---

## Rodada 17: o primeiro push ainda publica uma árvore que ela própria declara não publicável

**Data:** 2026-08-14. **Base auditada:** `a0b3b94`, com a migração SPDX local ainda dividida entre
108 paths staged, 283 alterações unstaged e 7 ficheiros untracked. Não há remote configurado. Esta
é uma auditoria de **primeira publicação**, não de release para Windows: o que precisa funcionar no
Windows é o próximo port de build; o que precisa estar certo antes de um push público é o conteúdo
e a história que o GitHub passará a distribuir.

### Veredito para assessoria

O projecto está mais perto de poder escolher e demonstrar uma licença do que em qualquer rodada
anterior. A substituição de `REUSE.toml` por metadados junto de cada ficheiro é uma melhoria real; o
pacote agora fecha o conjunto de paths com `MANIFEST.sha256`; a suíte recusa 27 mutações; e a matriz
de Qt passou a comparar versão e módulo literalmente. Rodei UIC, QRC, o corpus C++ do qmltc e o gate
de manifesto depois da inserção em massa dos cabeçalhos: todos passaram. A mudança não quebrou esses
formatos.

Mas **eu não faria o primeiro push público neste estado**. Não por faltar Windows. O próprio comando
criado para decidir isso, `sh tests/license-coverage.sh --publish`, termina com `rc=1` e diz que um
arquivo-fonte deste repositório não pode ser publicado. Além disso, a CI que o primeiro push dispara
tem uma incompatibilidade determinística com a versão do Qt do runner e omite silenciosamente uma
família que diz cobrir. Corrigir Windows agora seria trabalhar depois da fronteira errada.

### 1. BLOQUEADOR — o gate de publicação recusa exactamente o acto que o push público realiza

O inventário normal passa: 551 ficheiros tracked, 468 BSL-1.0, 22 sob termos de terceiros, 61
`NOASSERTION`, zero silenciosos. O modo de publicação falha pelos mesmos 61: os 60 `.ui` de
`tests/uic/corpus/` e `tests/qmltc/cpptypes/singletontype.cpp`. `NOASSERTION` não é licença; é a
afirmação de que os termos ainda não foram estabelecidos. Um repositório público no GitHub entrega
esses ficheiros por clone e por source archive. Portanto “não entram no pacote DUB” não resolve esta
publicação.

Há uma pista concreta melhor que a actual alegação de proveniência irrecuperável. Os nomes do corpus
aparecem no corpus `tests/auto/tools/uic/baseline` das fontes do Qt; outros apontam para exemplos e
para Qt Tools. Isso ainda não prova, sozinho, a revisão nem a identidade byte a byte. Prova que a
próxima acção correcta é confrontar hashes com revisões upstream, atribuir cada origem e copiar os
termos correspondentes — ou retirar o corpus e buscá-lo em CI a uma revisão fixa. O singleton precisa
do mesmo tratamento ou de uma reimplementação nossa.

**Critério de resolução:** `license-coverage.sh --publish` passa num clone limpo; nenhum
`NOASSERTION` é convertido em BSL por conveniência; cada terceiro tem URL/repositório, revisão,
path, hash e expressão SPDX verificáveis. Até lá, push privado é armazenamento; push público é uma
publicação que o projecto explicitamente veta.

### 2. CRÍTICO — a CI do GitHub nasce vermelha por construção, não por uma incerteza de Qt

O job usa `ubuntu-24.04` e instala o Qt 6 da distribuição. O pacote `qt6-base-dev-tools` de Noble é
Qt **6.4.2**, como registra o [índice de pacotes do Ubuntu](https://packages.ubuntu.com/noble/qt6-base-dev-tools).
A nova matriz aceita releases exactos e contém Qt 6.11.1 e 5.15.17. `license-no-gpl-product` é target
obrigatório do default build, logo o report integral da CI chamará o gate com 6.4.2 e ele recusará uma
versão sem linha exacta. O comentário da workflow diz que apenas os manifest gates são dependentes
do minor e advisory; depois tornou obrigatório outro gate dependente do release sem adaptar o
runner.

Isto não é a já documentada possibilidade de APIs privadas diferirem. É uma contradição estática
entre três ficheiros: runner 6.4.2, matriz sem 6.4.2 e target obrigatório. A CI não precisa sequer
chegar a compilar o projecto para o diagnóstico ser previsível.

**Critério de resolução:** ou fixar a CI numa distribuição oficial de Qt 6.11.1, ou auditar e
registrar 6.4.2 na matriz com fontes reproduzíveis. Depois executar a workflow de verdade antes de
chamá-la de gate. Não afrouxar comparação exacta para “6.*”: isso reabriria o defeito acabado de
fechar.

### 3. CRÍTICO — no mesmo runner, o corpus C++ do qmltc desaparece e os canários não percebem

`qmltcCppTypeTargets()` procura `moc` e `qmltyperegistrar` em `/usr/lib/qt6/moc` e
`/usr/lib/qt6/qmltyperegistrar`; se qualquer path faltar, retorna `[]`. No Ubuntu 24.04 os filelists
instalam `moc` em `/usr/lib/qt6/libexec/moc` e
[`qmltyperegistrar` em `/usr/lib/qt6/libexec/qmltyperegistrar`](https://packages.ubuntu.com/noble/amd64/qt6-declarative-dev-tools/filelist);
o [filelist de qt6-base-dev-tools](https://packages.ubuntu.com/noble/amd64/qt6-base-dev-tools/filelist)
confirma a mesma subdirectoria para `moc`.

A CI exige pelo menos 800 targets começados por `qmltc` e alguns gates gerais, mas nenhum canário
`qmltcc-*`. Assim, pode satisfazer o piso com as outras famílias enquanto esta retorna vazia. É o
mesmo padrão que os canários de libsample deveriam impedir: ausência de capacidade transformada em
verde.

**Critério de resolução:** descobrir `QT_INSTALL_LIBEXECS` via `qtpaths6`/CMake em vez de codificar
um layout Debian incorrecto; emitir erro explícito se Qt6Qml existe e as ferramentas não; exigir ao
menos um target `qmltcc-CBasic-*` e a contagem conhecida dessa família na CI.

### 4. ALTO — o conteúdo do primeiro commit está partido entre três universos diferentes

No instante final da auditoria, o índice contém 108 alterações, o working tree mais 283, e sete
ficheiros necessários continuam untracked: os textos GPL/comercial, a matriz, o guia de
distribuição e os três novos gates. Ao mesmo tempo o índice já apaga `REUSE.toml` e adiciona dezenas
de sidecars. Um commit feito apenas com o que está staged não é uma versão intermédia deliberada; é
uma política legal amputada dos scripts e textos que a justificam.

O gate de cobertura usa `git ls-files`, logo um verde local ignora exactamente os sete ficheiros que
ainda não entraram no índice. Ao adicioná-los, a população muda: por exemplo, o novo texto GPL e a
TSV não carregam hoje metadado próprio. A unidade a testar não pode ser “working tree mais os
untracked que o autor lembra”; tem de ser o snapshot que o GitHub receberá.

**Critério de resolução:** formar um único snapshot coerente, clonar/arquivar o índice para uma
directoria temporária e rodar nele todos os gates, incluindo publicação. `git diff --check` passar
no working tree e no índice — passou nesta rodada — é necessário, mas não testa composição.

### 5. ALTO — o pacote fechou os paths e hashes, mas ainda aceita uma proveniência semanticamente falsa

O manifesto corrigiu o contraexemplo do archive extra da rodada 16. Não corrigiu a autenticidade das
declarações. Regerei o manifesto após cada mutação, como faria quem produz o pacote, e o gate aceitou:

- duas chaves `license` no JSON, primeiro GPL e depois BSL; `json.load` ficou silenciosamente com a
  última, apesar de o comentário prometer testar duplicatas;
- uma fonte com `generator=deadbee` enquanto as demais e `qtd-build.txt` declaram outra revisão; o
  gate compara apenas o primeiro match de todo `source/`;
- uma fonte sem proveniência declarada como cópia de `runtime/does-not-exist.d`; origem inexistente
  evita o `cmp` e transforma a invenção em excepção válida;
- tamanho `999999` para `LICENSE` em `MANIFEST.sha256`; a coluna é lida e nunca conferida.

O SHA-256 responde “estes bytes são os que o manifesto enumerou”. Não responde “a narrativa dentro
deles é verdadeira”. A frase final ainda afirma que todas as 824 fontes geradas têm proveniência,
embora tenha lido uma delas para confrontar a revisão.

**Critério de resolução:** rejeitar chaves JSON duplicadas; comparar a revisão de **cada** fonte;
validar a origem de toda cópia contra um conjunto permitido e existente no momento da geração;
conferir tamanho e formato de cada linha do manifesto; guardar essas quatro mutações na suíte.

### 6. ALTO — os documentos públicos contam quatro estados legais incompatíveis

O README ainda diz “not published anywhere” e “no licence declared anywhere”. `LICENSE` aponta para
um `REUSE.toml` já apagado. O plano diz simultaneamente que vai adicionar REUSE, que o adicionou e que
o apagou; seus critérios finais voltam a exigi-lo. `THIRD-PARTY.md` chama os 42 ficheiros de cpptypes
de cópias verbatim GPL da Qt, embora a própria resposta à rodada 15 tenha separado 22 fixtures QML
nossas sob BSL, 19 fontes upstream e um singleton sem termos estabelecidos. O expected-fail antigo
`no-licence-so-nothing-is-publishable` continua dizendo que não existe qualquer licença, ao lado do
novo `source-tree-is-not-publishable-noassertion`. O linter valida a forma e a unicidade dos IDs; não
detecta que uma premissa envelheceu.

No GitHub, esses deixam de ser rascunhos internos e tornam-se a resposta que um consumidor, uma
registry e um assessor jurídico lerão. A contradição enfraquece justamente o trabalho bom feito nos
gates.

**Critério de resolução:** escolher uma única narrativa verdadeira para o snapshot; actualizar
README, LICENSE, THIRD-PARTY, plano e expected-fails juntos; registrar a revisão real dos corpora; e
fazer uma busca automatizada por referências a mecanismos/estados removidos.

### 7. ALTO — a proveniência do `qmltc-d` ainda depende da directoria de onde o utilizador o chama

O binário executa `git rev-parse HEAD` e `git status` no working directory em tempo de execução.
Assim, o mesmo executável grava `a0b3b94-dirty` quando chamado no checkout e
`generator=unknown` quando chamado em `/tmp`. Proveniência deve identificar o binário que gerou o
ficheiro, não o repositório por acaso corrente quando o consumidor o executa.

O gate novo também continua capaz de declarar sucesso sem executar a prova: ferramenta ausente
retorna zero, as duas invocações engolem erro com `|| true`, zero shadows é apenas nota e a suposta
comparação “line for line” verifica três substrings num só sentido. Portanto o verde observado nesta
rodada não fecha os achados 4 e 7 da rodada 16.

**Critério de resolução:** embutir revisão/estado no build do `qmltc-d`; falhar se a ferramenta ou
modo contratado não produzir saída; provocar deliberadamente pelo menos um shadow; extrair o bloco
canónico inteiro e comparar bytes nos dois geradores.

### 8. MÉDIO — antes de tornar a história pública, faltam decisões de higiene que depois custam rewrite

O branch tem centenas de commits e nenhum remote, portanto este é o último momento barato para
decidir o que publicar. A história expõe o e-mail pessoal do autor e centenas de trailers
`Claude-Session:` repetidos. Não encontrei chaves privadas ou tokens por nome/padrão, mas há paths
absolutos `/home/caetano/lab/qt-dlang-gen` no spec de userlib e em quatro scripts do corpus qmltc.
Além da privacidade, esses paths fazem exemplos versionados apontarem para uma máquina que nenhum
colaborador possui.

Isto não exige esconder autoria nem reescrever por estética. Exige uma decisão consciente: história
completa ou branch público curado; e-mail público ou endereço noreply; trailers desejados ou ruído
de ferramenta. Depois do primeiro push, corrigir isso requer reescrita e force-push.

**Critério de resolução:** revisar `git log` e o inventário de segredos/paths, substituir paths por
root calculado, decidir identidade e política da história, e verificar um clone numa path diferente.

### Ordem que eu imporia antes do push

1. Resolver ou retirar os 61 `NOASSERTION`; fazer o gate `--publish` passar.
2. Tornar o snapshot atómico e testar o **índice** num clone limpo.
3. Alinhar Ubuntu/Qt/matriz e impedir o desaparecimento do corpus `qmltcc`.
4. Reconciliar toda a documentação legal e os expected-fails com esse snapshot.
5. Fechar as quatro mutações semânticas do pacote e a proveniência do `qmltc-d`.
6. Só então decidir forma da história, criar o remote e fazer o primeiro push.
7. Windows vem imediatamente depois e continua importante; apenas não é o bloqueador actual.

O ponto sincero: isto já parece um projecto sério, não uma experiência que teve testes adicionados
no fim. O gerador, os wrappers e sobretudo a disciplina de transformar críticas em gates são
tecnicamente impressionantes. Justamente por isso o primeiro acto público não deve contradizer o
seu gate mais explícito. **A barra agora não é “compila no Windows”; é “o snapshot público consegue
explicar, reproduzir e licenciar cada byte que entrega”.**
### Resposta à rodada 17 (2026-08-14)

Verifiquei os oito pontos antes de tocar em código. Sustentam-se todos. Três estavam já na minha
própria lista da mesma sessão (o caminho delegado por exercitar, a primeira-amostra da proveniência,
o manifesto auto-atestado), o que valida o ataque e condena o que eu tinha dado por fechado.

#### 1 — o bloqueador: **de 61 ficheiros para 1**

A pista da rodada estava certa e deu para ir até ao fim. Os **60 `.ui`** do corpus são byte-a-byte
idênticos a `tests/auto/uic/baseline/` de `github.com:qt/qt` na revisão
`0a2f2382541424726168804be2c90b91381608c6` (v4.8.7-3, 2015-07-10). Cada um leva agora um
`<nome>.license` com **repositório, revisão, caminho, SHA-256 e a data da verificação** — o critério
de resolução, literalmente. Os termos são os que os próprios ficheiros do Qt declaram
(*Commercial OR LGPL-2.1 OR LGPL-3.0 OR GPL-3.0*), e como passei a afirmá-los, o repositório passou a
**distribuir** `LGPL-2.1-only.txt` e `LGPL-3.0-only.txt` — um identificador SPDX aponta para uma
licença, não é a cópia dela.

Correcção à minha própria resposta anterior: eu tinha dito que 2 dos 60 diferiam. Não diferiam — era
`find … | head -1` a apanhar a cópia do `uic3`. Quarta vez com esse erro nesta sessão, e a primeira
em que me fez sub-reportar.

Sobra `tests/qmltc/cpptypes/singletontype.cpp`: três linhas, sem cabeçalho. Continua `NOASSERTION`
e continua a bloquear `--publish`, que é o estado honesto.

#### 3 — o corpus C++ que desaparecia: **corrigido**

`/usr/lib/qt6/moc` estava escrito à mão; o Ubuntu põe-no em `libexec/`. As duas verificações
falhavam e a função devolvia lista vazia: **182 alvos** deixavam de existir e o piso da CI ficava
satisfeito pelas outras famílias. Agora pergunta ao Qt (`QT_INSTALL_LIBEXECS`) e, se o Qt6Qml existe
mas as ferramentas não, **rebenta com a mensagem** em vez de construir nada e reportar sucesso.

#### 5 — proveniência semanticamente falsa: **as quatro caem**

Chaves duplicadas no JSON (o `json.load` ficava em silêncio com a última), revisão divergente numa
fonte que não era a primeira, origem `verbatim` inexistente (uma origem inventada era **mais** fiável
que uma real, porque a inexistência saltava o `cmp`), e a coluna de tamanho que era lida e nunca
comparada. Todas com o manifesto **regenerado**, como faria quem produz o pacote. As cinco mutações
estão na tabela permanente, que passou de 20 para **32**.

#### 6 — as narrativas: **alinhadas**

README, `LICENSE`, `THIRD-PARTY.md`, o plano e o `expected-fails` foram corrigidos juntos. O
`THIRD-PARTY.md` passou a ter a tabela das três populações reais de `cpptypes` (19 upstream, 22
fixtures nossas, 1 sem termos) em vez de "42 cópias verbatim". A entrada obsoleta
`no-licence-so-nothing-is-publishable` saiu.

Isto expôs um defeito **maior** do que o que eu ia corrigir: o portão lia a **primeira ocorrência**
de `SPDX-License-Identifier` em qualquer ponto do ficheiro, portanto um documento que **cita** uma
expressão era classificado pela citação. `docs/licensing-plan.md` — o plano deste projecto — estava
classificado como `GPL-3.0-only`; o `CRITICS.md` tinha por licença um fragmento de prosa. Um
cabeçalho está no **topo** e é um comentário: cinco linhas, não quinze (a bateria nova apanhou a
primeira tentativa, que aceitava uma citação na linha seis).

#### 7 — a proveniência do `qmltc-d`: **vem do build**

A revisão é fornecida pela build numa unidade de tradução própria de três linhas, escrita com
`writeIfChanged` — um `-D` na linha do compilador faria recompilar 11 mil linhas a cada mudança de
estado sujo. Provado de fora do checkout: o mesmo binário, o mesmo input, escreve
`generator=a0b3b94-dirty` a partir de `/tmp`, onde antes escrevia `unknown`. O caminho absoluto do
input deixou de viajar: `input=DelegMe.qml` mais o digest.

E o portão que devia provar isto tinha três buracos, medidos um a um: ferramenta ausente passava
(`rc=0`, "not built"), um compilador que imprime o cabeçalho certo e **sai a 3** passava (`|| true`),
e **"0 shadow document(s)"** era reportado como sucesso — zero é uma quantidade sobre a qual toda a
afirmação é verdadeira. Pior: a comparação "linha a linha" usava como referência o `qtmoc.d`, que é
uma **cópia verbatim do runtime** e não tem bloco de concessão nenhum. Não era fraca; era **vazia**.

Tudo isso está fechado e, desta vez, **provado por uma bateria** de oito compiladores falsos, cada um
a estragar exactamente uma propriedade.

#### O que fica em aberto, com causa

- **#2, a CI vermelha por construção.** É defeito meu: apertei a matriz para exigir a release exacta
  e não adaptei o runner (Noble traz Qt 6.4.2). Não afrouxo a comparação — seria reabrir o defeito
  que acabei de fechar — e não registo 6.4.2 na matriz sem ler a licença dessa release, que não
  consigo fazer offline. Fica nomeado como bloqueador de CI, não silenciado.
- **#4, o snapshot único.** Continua por formar: o índice, a árvore e os untracked ainda não são a
  mesma coisa, e correr os portões contra um clone do índice é o teste que falta.
- **O manifesto do pacote é auto-atestado.** Fecha o conjunto de ficheiros, mas quem o regenera
  passa; a lista de archives permitidos tem de vir do grafo de instalação, e ainda não vem.
- **`singletontype.cpp`**, três linhas sem proveniência, que mantêm `--publish` vermelho.

## Rodada 16: os portões ganharam dentes, mas ainda aceitam contratos internamente impossíveis

**Data:** 2026-08-13. **Base auditada:** `a0b3b94`, com a resposta local à rodada 15 e todos os
ficheiros do plano de licenciamento preservados. Esta rodada não reabre os pontos que a própria
resposta deixou explicitamente pendentes — retirar o corpus GPL, digest dos headers e empacotar o
guia de distribuição. Ela ataca as garantias que foram marcadas como feitas.

### Veredito para assessoria

A resposta à rodada 15 foi substancial. A denylist virou allowlist versionada; o grafo passou a
declarar os módulos de cada archive; o pacote tem manifestos obrigatórios; há uma suíte permanente
de vinte mutações; o `qmltc-d` finalmente emite concessão e proveniência; e inventário deixou de
ser confundido com publicabilidade. Os portões focados passam, e a suíte oficial de mutações prova
que vinte defeitos reais são recusados pela razão certa. Isso é evolução clara.

O problema agora é mais estreito e mais perigoso: as mensagens finais afirmam propriedades
universais que os scripts verificam por uma amostra ou por presença textual. Usei o pacote real de
829 fontes e construí cinco contraexemplos adicionais. O gate aceitou todos: `dub.json` declarando
GPL, um quarto archive estático não inventariado, uma fonte com revisão diferente das demais, uma
fonte sem proveniência legitimada por uma origem inexistente e um módulo desconhecido escrito como
expressão regular. Separadamente, o mesmo `qmltc-d` grava `a0b3b94-dirty` quando executado no
checkout e `generator=unknown` quando executado em `/tmp`.

Portanto o parecer de release não muda ainda: **a política está bem desenhada, mas a prova de
compliance continua não composicional.** O pacote conhecido está limpo; o gate ainda não prova que
o pacote recebido é aquele pacote, nem que suas declarações concordam entre si. E a árvore continua
deliberadamente não publicável enquanto houver 61 entradas `NOASSERTION`.

### 1. CRÍTICO — o manifesto que a registry lê pode declarar GPL e o gate continua dizendo BSL

`tests/license-package.sh:83-88` exige que `dub.json` tenha uma chave chamada `license`, mas nunca
lê o valor. A varredura SPDX de `:105-113` também não alcança esse campo porque procura apenas
linhas `SPDX-License-Identifier:`. Assim as duas respostas de licença do mesmo pacote podem se
contradizer e ambas serem consideradas válidas.

Reprodução: copiei o pacote real, troquei somente
`"license": "BSL-1.0"` por `"license": "GPL-3.0-only"` e rodei o gate. Resultado:

```text
license-package OK: qtd-r16-wrong_dub_license-... — 829 source file(s) all SPDX-headed ...
licence, notices and module list present; no test-only or GPL material
```

A frase final é factualmente incompatível com o manifesto que DUB e a registry expõem ao
consumidor. A suíte de vinte mutações remove a chave, mas não testa um valor errado.

**Critério de resolução:** parsear JSON de verdade; exigir exatamente `BSL-1.0`; comparar o valor
com `LICENSE`, `NOTICE` e com a allowlist de expressões do conteúdo; acrescentar mutações para
GPL, expressão composta, string vazia, tipo não-string, chave duplicada e JSON inválido.

### 2. CRÍTICO — qualquer archive extra entra no pacote sem licença, origem ou inventário

O pacote normal contém `libbinding_ldc2.a`, `libbinding_dmd.a` e `libshims.a`. O gate procura
expressões SPDX em arquivos que as tenham, fontes sob `source/`, nomes conhecidos de corpus,
objetos `*.o` e o path absoluto do checkout. Ele nunca exige a lista exata de artifacts nem
confronta `lib/` com `dub.json`, `qtd-build.txt` ou `.build/link-manifest.tsv`.

Reprodução: copiei `libshims.a` para `lib/libgpl_payload.a` dentro da cópia do pacote. O gate
retornou `OK` e continuou afirmando “no test-only or GPL material”. O nome da reprodução não é a
prova de que a cópia seja GPL; esse é precisamente o ponto: para o gate, um binário opaco e não
declarado não precisa provar licença nenhuma. Poderia ser uma biblioteca proprietária, GPL ou só
um artifact stale, e o veredito seria o mesmo.

**Critério de resolução:** manifesto fechado de arquivos do pacote, com path, tamanho e SHA-256;
lista exata de archives permitidos derivada do install graph; membros de cada `.a` inventariados;
falha para qualquer arquivo não declarado. A mutação permanente deve acrescentar um `.a` plausível,
não apenas um `.o` cujo sufixo já está numa denylist.

### 3. CRÍTICO — a proveniência aceita tanto uma revisão partida quanto uma origem inventada

O comentário de `license-package.sh:161-165` diz que os dois canais devem concordar. A
implementação em `:166-174` compara `qtd-build.txt` somente com a **primeira** linha encontrada por
`grep -rhm1`. Das 824 fontes geradas, 823 podem declarar outra revisão sem afetar o resultado.

Reprodução: mudei para `generator=deadbee` a linha de uma fonte que não era a primeira. O gate
retornou `OK`, contando-a entre as 824 fontes com proveniência. A mutação oficial muda o manifesto,
portanto testa apenas a primeira comparação; não testa divergência dentro do conjunto.

Há um segundo bypass em `:146-153`. Uma fonte sem proveniência é dispensada se `verbatim.txt`
contiver uma alegação. A alegação só é confrontada quando a origem existe. Removi a proveniência de
`qcryptographichash.d` e acrescentei:

```text
source/qcryptographichash.d <- runtime/does-not-exist.d @ deadbee
```

Resultado: `OK`, agora com **seis** “verbatim runtime copies”. Uma origem inexistente ganhou mais
confiança que uma origem existente. Isso transforma typo, path stale ou fraude no caminho barato
de obter a isenção.

**Critério de resolução:** coletar e comparar o conjunto de todas as revisões; exigir uma única
revisão igual ao manifesto; validar cada entrada de `verbatim.txt`, rejeitar origem ausente,
duplicada, fora de `runtime/`, basename ambíguo, revisão divergente e arquivo não idêntico. Melhor
ainda: instalar a cópia com hash de conteúdo e gerar o manifesto a partir de uma lista fechada do
build, não aceitar autoatestado textual como prova.

### 4. ALTO — `qmltc-d` grava o Git do diretório de execução, não a revisão que o produziu

`qtdGenRev()` em `tools/qmltc/qmltc_d.cpp:57-79` executa `git rev-parse` e `git status` no cwd em
tempo de execução. Isso funciona no teste porque o teste roda da raiz do projeto. É falso para o
caso de uso distribuído: a ferramenta instalada será invocada no projeto do consumidor, fora deste
Git — ou, pior, dentro de outro Git.

Medi o mesmo binário, com os mesmos argumentos e o mesmo input:

```text
# cwd = qt-dlang-gen
// provenance: generator=a0b3b94-dirty ... inputsha256=7a5509924c99 ...
# cwd = /tmp
// provenance: generator=unknown ... inputsha256=7a5509924c99 ...
```

Dentro de outro repositório ele pode gravar a revisão daquele repositório como se fosse a do
gerador. O gate não percebe porque também é executado no cwd favorável e só exige que a linha
exista; `generator=unknown` satisfaz `^// provenance: generator=`.

**Critério de resolução:** embutir a revisão/versão no binário em build time, junto de dirty-state
decidido no build; expor `qmltc-d --version`; fazer o teste executar a ferramenta de fora do
checkout e recusar `unknown`. O path absoluto do input também não deve viajar por omissão: basename
ou path lógico mais digest identifica o input sem publicar o diretório da máquina.

### 5. ALTO — a allowlist fail-closed volta a falhar aberta porque trata o nome como regex

`licence_of()` e `reason_of()` em `tests/license-no-gpl-product.sh:54-55` interpolam o nome do
módulo diretamente em `grep "^$1<TAB>"`. O input vem dos specs JSON e do manifesto; não é escapado
nem comparado como campo TSV literal.

Reprodução: acrescentei temporariamente um spec com `"pkg_config": "Qt6.*"`. Esse nome não existe
na matriz e deveria cair no ramo `unknown`. Em vez disso, a regex casou a primeira entrada Qt6 e o
gate terminou:

```text
license-no-gpl-product OK: ... 24 product spec(s) ... request only modules with an established
open-source licence
```

O fixture foi removido. Não é o cenário mais provável de inclusão acidental de GPL, porque nomes
normais de pkg-config não usam `*`; é, porém, uma violação direta da propriedade “unknown is
refused” e permite que metadado malformado ou hostil escolha uma linha diferente da sua.

**Critério de resolução:** ler TSV por igualdade literal do primeiro campo (`awk -F '\t' '$1 ==
name'`, passando `name` por `-v`); rejeitar caracteres fora da gramática aceita; exigir exatamente
uma correspondência; mutar com `.`, `*`, `[`, linha duplicada e nome vazio.

### 6. ALTO — “versão verificada” significa minor, embora o pacote e o texto prometam release exata

O gate descobre Qt `6.11.1`, corta para `6.11` em `license-no-gpl-product.sh:39-45` e aceita
`verified-for<TAB>6.11`. A mensagem final então diz que **Qt 6.11.1** é uma versão verificada. Não
é isso que a tabela registra. O próprio plano e `docs/distributing-qt.md` mandam consultar página e
SBOM da release exata; a máquina só prova que alguém escreveu o número do minor.

Também não há no TSV revisão do Qt, URL direta do SBOM, digest do documento consultado ou data da
verificação por módulo. A coluna `source` contém descrições humanas genéricas. Isso é melhor que a
denylist antiga, mas ainda não é uma matriz reproduzível para uma auditoria futura.

**Critério de resolução:** chave por versão completa (`6.11.1`) e variante/distribuição; registrar
fontes diretas e um digest ou snapshot do SBOM/licensing metadata; falhar em patch release não
registrada. Se a decisão for conscientemente por minor, a mensagem e o plano devem dizer isso e
provar que a Qt publica a licença nesse nível de granularidade.

### 7. ALTO — o gate de output não executa todos os quatro caminhos nem compara texto linha a linha

O comentário afirma quatro saídas e comparação linha a linha. `tests/license-generated-output.sh`
executa uma saída compilada (`:49-53`) e shadows (`:55-65`). O caminho de **documento inteiramente
delegado**, que chama `qtdEmitNotice()` separadamente em `qmltc_d.cpp:10928`, não é exercitado: a
primeira sonda exige a frase `compiled to D`. A “variante de uma expressão recusada” não é uma
quarta saída independente no script; ela aparece através dos shadows encontrados.

As duas execuções ainda usam `|| true`, então crash ou retorno de erro depois de escrever um
cabeçalho suficiente vira sucesso. E a comparação de `:67-76` é unilateral: só exige uma linha no
`qmltc-d` se essa linha existir em `generator-d`; remover a linha do sample de referência desativa a
obrigação. São três substrings escolhidas, não igualdade linha a linha.

**Critério de resolução:** fixtures separados para compilado, totalmente delegado e shadow;
verificar exit status contratado de cada modo; extrair um bloco canônico completo de ambos os
geradores e fazer diff bidirecional; validar valores, não só chaves (`generator != unknown`, digest
SHA-256 no comprimento declarado, Qt full, notice version exata). A ausência do binário em
`:26` também deve falhar quando o alvo está no build, não produzir um skip verde.

### 8. MÉDIO — o fallback REUSE contradiz a classificação arquivo a arquivo que acabou de adotar

`REUSE.toml:106-110` classifica `tests/qmltc/cpptypes/C*.qml` e `C*.set` como material próprio,
`BSL-1.0`. Porém `tests/license-coverage.sh:129-138` chama **todo** o diretório `cpptypes` de
third-party e rejeita qualquer header BSL nele.

Reprodução: acrescentei temporariamente a `CBasic.qml` exatamente o copyright e SPDX que sua
anotação já lhe atribui. O fallback terminou:

```text
license-coverage FAIL: tests/qmltc/cpptypes/CBasic.qml is third-party and carries OUR license header
```

O header foi removido. Hoje o gate fica verde somente porque esses arquivos próprios dependem da
anotação externa; tornar a mesma licença explícita no próprio arquivo produz vermelho.

**Critério de resolução:** a verificação de atribuição errada deve usar a expressão resolvida por
arquivo e a população Qt explícita, não o path pai inteiro. Acrescentar sondas positivas e
negativas: um `C*.qml` próprio com BSL deve passar; um dos 19 arquivos Qt com BSL deve falhar.

### Evidência executada nesta rodada

- `license-package` no pacote real: `rc=0`, 829 fontes, 824 geradas e 5 cópias verbatim.
- `license-package-mutations`: `rc=0`, 20 pacotes defeituosos recusados pela razão contratada.
- `license-generated-output`, `license-no-gpl-product` e `license-coverage`: `rc=0` no estado normal.
- Cinco contraexemplos adicionais aceitos: licença DUB GPL, archive extra, proveniência dividida,
  origem verbatim inexistente e módulo-regex desconhecido.
- O `license-coverage` recusou o header BSL coerente com sua própria anotação de `CBasic.qml`.
- `qmltcc-CBareObj-all-ldc2`, citado como intermitente na resposta, passou isolado com `rc=0`.
- A matriz `./build` não forneceu um veredito reproduzível nesta sessão: uma execução foi
  interrompida após um período prolongado sem saída; uma segunda, limitada explicitamente a 300 s,
  terminou em `rc=124` depois de executar centenas de alvos verdes. Não registro isso como nova
  regressão funcional sem identificar o processo restante, mas também não registro “matriz verde”.

### Prioridade brutal desta rodada

1. Fechar o package por manifesto de arquivos e validar semanticamente todos os manifestos.
2. Tornar proveniência um conjunto coerente, sem primeira-amostra e sem origem inexistente.
3. Embutir a versão do `qmltc-d` no build; nunca consultar o Git do consumidor.
4. Fazer lookup literal e versionamento por release exata na matriz Qt.
5. Transformar `license-generated-output` na comparação integral que o comentário já promete.
6. Corrigir a população mista de `cpptypes` no fallback REUSE.
7. Só depois chamar os gates de prova de compliance; hoje eles são bons detectores de regressões
   conhecidas, ainda não validadores fechados de artifact.

## Rodada 15: a licença foi escolhida; os portões ainda certificam nomes, não o artefacto legal

**Data:** 2026-08-13. **Base auditada:** `a0b3b94`, com alterações locais de licenciamento já
presentes e preservadas. `./build` terminou com `rc=0`; os alvos focados
`license-package`, `license-package-probe`, `license-coverage` e `license-no-gpl-product` também
ficaram verdes antes dos contraexemplos abaixo.

### Veredito para assessoria

A rodada de licenciamento fez trabalho real. BSL-1.0 é uma escolha coerente para o gerador, o
runtime e os archives próprios; a distinção entre código do projeto e Qt está escrita; o pacote
leva licença, NOTICE e proveniência; e os novos portões já encontraram defeitos que uma inspeção da
árvore não via. Isto não é `license` acrescentado a quatro JSON e uma declaração de vitória.

Mas o estado atual ainda não sustenta publicação. O repositório distribui fontes que ele próprio
declara GPL-3.0-only sem distribuir o texto da GPL; o denylist não contém o nome de um módulo
GPL-only introduzido justamente no Qt 6.11 usado aqui; e os dois portões de produto aceitam
contraexemplos directos — um package sem `dub.json` e com fonte GPL, e um archive que referencia
Qt MQTT. A implementação verificou os incidentes conhecidos (`cpptypes`, `qmltypes_check`,
`QQmlJS`) em vez das propriedades que o plano promete (expressões SPDX e dependências reais).

O projeto continua tecnicamente forte e a direção de licenciamento está certa. O veredito de
release, porém, é simples: **BSL foi adotada; compliance ainda não foi implementado de ponta a
ponta; a árvore-fonte continua não publicável pelos próprios critérios do projeto.** Compilar no
Windows é o próximo passo de engenharia. Distribuir no Windows ainda não é.

### 1. CRÍTICO — a árvore distribui GPL-3.0-only e deliberadamente não distribui a GPL

`tests/qmltc/cpptypes/` está no Git e portanto em qualquer clone ou source archive. Dezenove fontes
C++ carregam `LicenseRef-Qt-Commercial OR GPL-3.0-only`; `THIRD-PARTY.md`, `LICENSE` e
`REUSE.toml` também classificam o diretório como GPL-3.0-only. Mas `LICENSES/` contém somente
`BSL-1.0.txt`. O commit que adotou o plano justifica isso dizendo que a GPL é coberta por uma
expressão SPDX e que o material “nunca é distribuído”. A segunda frase é verdadeira apenas do
**pacote instalado**. É falsa do repositório: clonar ou baixar o source tarball transmite os
arquivos.

GPLv3 §4 exige que a transmissão de código-fonte leve avisos apropriados e uma cópia da licença. Um
identificador SPDX aponta para a licença; não é a cópia dela. A política escolhida criou assim uma
situação pior que “a licença ainda não foi escolhida”: agora há uma afirmação precisa de GPL e uma
distribuição que não leva os termos afirmados.

Há um segundo problema no mesmo diretório. `REUSE.toml` usa `override` sobre **todos os 42
arquivos**, atribuindo todos a `2021 The Qt Company Ltd.` e GPL-3.0-only. Só 19 têm essa declaração
no próprio arquivo. Vários `.qml` têm comentários que descrevem adaptações específicas deste
projeto (`CBasic.qml`, por exemplo), e `singletontype.cpp` não tem cabeçalho algum. Talvez alguns
sejam realmente upstream sob cobertura de diretório; talvez alguns sejam nossos. O inventário diz
“42 cópias verbatim” onde a evidência no próprio corpus não permite essa conclusão uniforme.
`override` torna o SBOM categórico justamente onde a proveniência continua ambígua.

**Critério de resolução:** executar a Fase 1 que já está escrita: remover o corpus GPL da árvore e
obtê-lo por revisão/checksum apenas no job de teste, ou distribuir o texto GPL e provar a
proveniência/licença arquivo a arquivo. Não usar uma anotação de diretório para atribuir copyright
da Qt a arquivos possivelmente escritos ou modificados aqui. Um source archive final deve passar
uma inspeção própria, não apenas o pacote DUB do binding.

### 2. CRÍTICO — o denylist já está obsoleto para o Qt 6.11 que a árvore usa

Qt 6.11 introduziu **Qt Canvas Painter**, GPLv3-only para usuários open source. O nome de componente
e de biblioteca documentado pela Qt é `CanvasPainter` / `Qt6::CanvasPainter`, portanto o nome que
um spec deste projeto pede é `Qt6CanvasPainter`. `tests/license-no-gpl-product.sh` não contém esse
nome: contém `Qt6Canvas3D`, um módulo antigo e diferente.

Reprodução feita durante esta auditoria: acrescentei temporariamente um
`generator/spec_cxx_license_audit.json` com:

```json
{"pkg_config":"Qt6CanvasPainter Qt6Core"}
```

e executei `sh tests/license-no-gpl-product.sh`. Resultado:

```text
license-no-gpl-product OK: no product spec requests a GPL-only Qt module ...
```

O fixture foi removido depois. Isto não é a possibilidade teórica de uma lista envelhecer: a lista
já não representa a versão instalada e a mensagem `OK` afirma precisamente o contrário. O próprio
plano diz que o denylist é chão e que cada minor deve ser verificado contra a fonte oficial; não há
implementação dessa atualização, só uma lista manual com pelo menos um nome errado.

**Critério de resolução:** gerar a decisão a partir do SBOM/licensing metadata da versão exata do
Qt ou manter uma tabela versionada testada contra todos os nomes reais de pkg-config/CMake/library.
Adicionar pelo menos `Qt6CanvasPainter` e uma sonda permanente que prove sua recusa. O gate deve
falhar quando a versão Qt não tem uma matriz de licenças conhecida, em vez de aplicar a lista de
outra versão.

### 3. ALTO — `nm -u` não identifica o módulo Qt; só reconhece o incidente `QQmlJS`

Para archives, `license-no-gpl-product` diz inspecionar “actual imports”. Não faz isso. Ele procura
apenas símbolos `QQmlJS*` ou `QQmlSA*`, isto é, os namespaces do caso `Qt Qml Compiler` que motivou
o gate. Nenhum dos outros módulos do denylist tem detector. Um símbolo indefinido diz que falta
uma definição; não diz sozinho qual shared library a fornecerá, mas o script nem sequer tenta
resolver o símbolo contra as bibliotecas Qt ou cruzá-lo com o manifesto do archive.

Reprodução feita: construí um archive temporário `.build/audit-license/libshims.a` com uma
referência indefinida a `QMqttClient::connectToHost()`. `nm -uC` mostrou a referência. O gate
inspecionou **38** artefactos em vez de 37 e retornou `OK`. O archive temporário foi removido.

O problema também existe na outra direção: código de headers GPL-only pode ser inline/template e
não deixar símbolo indefinido algum. A Fase 5 pede inventário de headers privados justamente por
isso, mas o texto do gate hoje chama o que faz de inspeção do produto real.

**Critério de resolução:** o package precisa levar um manifesto de link produzido pelo grafo —
módulos e bibliotecas que construíram cada archive — e o gate deve verificar essa lista contra a
matriz versionada. Para executáveis/shared libraries, resolver `DT_NEEDED`/PE imports. Para archives,
ligar um consumidor mínimo com trace/map do linker ou registrar as entradas no momento da
construção; heurística de namespace pode ser defesa adicional, nunca a prova principal. Inventariar
headers com sua expressão SPDX e contribuição inline.

### 4. ALTO — `license-package` aceita pacote sem manifesto e com fonte GPL, depois diz “no GPL”

O gate tem verificações úteis, mas valida presença por nomes conhecidos, não a licença efetiva do
conteúdo.

Duas reproduções sobre uma cópia em `/tmp` do pacote real:

1. renomeei `dub.json`; o script só inspeciona o campo `license` **se o arquivo existir** e retornou
   `license-package OK`, inclusive com a frase “licence ... present”;
2. acrescentei `source/gpl_payload.cpp` com SPDX `GPL-3.0-only`, proveniência válida e nome que não
   contém `cpptypes`, `uic/corpus` nem `qmltypes_check`; o gate contou 830 fontes, aceitou a nova e
   concluiu “no test-only or GPL material”.

O `license-package-probe` remove somente `LICENSE`. Ele prova um ramo que já funciona e não prova
os dois predicados mais importantes que a mensagem final anuncia: manifesto de pacote e ausência de
licença incompatível. Uma expressão como `AGPL-3.0-only`, `LicenseRef-Proprietary` ou
`NOASSERTION` também passa desde que a string `SPDX-License-Identifier` exista.

**Critério de resolução:** `dub.json`, `qtd-build.txt` e `verbatim.txt` devem ser obrigatórios e
estruturalmente validados. Extrair e interpretar todas as expressões SPDX do package, com allowlist
explícita por path; BSL no produto próprio, exceções nomeadas e justificadas, nenhuma expressão
desconhecida. Substituir a única sonda por uma tabela de mutações: LICENSE ausente, manifesto
ausente, licença errada, fonte GPL renomeada, módulo GPL, proveniência divergente e path absoluto.

### 5. ALTO — a Fase 3 marca “todo `.d` e `.cpp` emitido”; `qmltc-d` emite código sem licença

O plano e a resposta atual dizem que **cada** `.d` e `.cpp` emitido leva SPDX, escopo e
proveniência. A implementação foi feita apenas no `generator-d`. O segundo gerador mais importante
do repositório, `qmltc-d`, ainda começa a saída assim:

```d
// GENERATED by qmltc-d from tests/qmltc/corpus/Scalars.qml — do not edit.
module Scalars;
```

Sem SPDX, sem concessão sobre output e sem revisão/Qt/spec. Reproduzi isso com o `qmltc-d` atual
sobre `Scalars.qml`. O caminho de documento inteiramente delegado tem a mesma omissão, e os shadow
QML escritos por `--shadow-dir` levam somente uma linha `GENERATED`. Estes arquivos são justamente
os que um usuário vai incorporar ao seu programa, fora do package do binding; `license-package`
nunca os vê.

Isto importa mais que uma inconsistência documental: `LICENSE` oferece BSL sobre as partes geradas,
mas quem recebe só o arquivo produzido pelo tool não recebe a afirmação que o plano considerou
essencial para um arquivo que “viaja sozinho”.

**Critério de resolução:** uma única rotina de notice/proveniência, consumida por `generator-d` e
`qmltc-d`, e aplicada à saída normal, documento delegado e shadows. Auditar também qualquer tool
que materialize fonte (`uic-d`, `qrc-d`) e definir qual conteúdo é output licenciado versus input
transformado. Um gate deve executar cada modo e inspecionar os arquivos resultantes.

### 6. ALTO — a proveniência marcada como completa não identifica os inputs

O plano exige no manifesto: revisão do gerador, versão Qt, módulos, **digest do spec/input** e
revisão da política de licença (`docs/licensing-plan.md:291-293`). A linha implementada contém:

```text
generator=<rev> qt=<major.minor> modules=<list> spec=<basename>
```

Não há digest do spec, digest dos headers, revisão da política nem versão Qt completa. Duas specs
diferentes com o mesmo basename em checkouts diferentes produzem a mesma descrição; editar o spec
gera `-dirty`, que diz corretamente que o SHA não basta, mas não permite reconstruir qual alteração
gerou o arquivo. `qt=6.11` também não distingue 6.11.0 de 6.11.1, embora o projeto trate drift do
minor/patch como risco ABI em outros lugares.

A correção local que passou a adicionar `-dirty` e a separar `packaged-at` de `generator` é boa e
fecha uma mentira concreta. Não fecha o requisito original, e o plano não deveria marcar
“machine-readable output provenance” como concluído sem o identificador dos inputs.

**Critério de resolução:** hash canônico do spec e dos inputs relevantes (ou um lock manifest que
os enumere com hashes), versão Qt retornada pelo SDK real, revisão da política/output template e
estado do gerador. O package gate deve recalcular o que puder e exigir consistência entre todos os
824 arquivos, não comparar `qtd-build.txt` apenas com a primeira ocorrência encontrada.

### 7. MÉDIO — o documento de distribuição que `LICENSE` manda ler não existe

`LICENSE` afirma que `docs/distributing-qt.md` “is written for application distributors” e
`docs/licensing.md` repete que o documento existe. Ele não existe. O plano o lista como arquivo a
criar, ainda sem `[DONE]`, mas os documentos vigentes usam presente e encaminham o consumidor para
um caminho quebrado.

Isto é especialmente ruim porque o pacote instalado também não leva `docs/`: o usuário recebe um
NOTICE curto e nenhuma instrução operacional sobre source offer, substituição das DLLs, EULA,
plugins ou WebEngine. A escolha de BSL foi implementada; a parte difícil para quem realmente
distribui Qt continua só no plano interno.

**Critério de resolução:** escrever `docs/distributing-qt.md`, referenciá-lo com URL estável e
incluí-lo no package/release. O package gate deve recusar links locais quebrados em LICENSE/NOTICE e
provar que o documento referenciado chegou ao artefacto.

### 8. MÉDIO — sem `reuse`, `license-coverage` não lê a cobertura que diz validar

`reuse` não está instalado nesta máquina. O fallback verifica apenas que `REUSE.toml` **existe**;
depois usa um `case` hardcoded em shell. Remover do TOML a anotação de todos os `.json`, ou mudar
sua licença, não altera a decisão do fallback. O script não parseia `precedence`, copyright nem
expressão SPDX. É uma segunda base de dados manual que pode divergir da primeira.

Mais importante: o cabeçalho do gate diz “EVERY TRACKED FILE HAS KNOWN TERMS”, e o resultado verde
diz 552 arquivos “covered”. Quarenta e sete `.ui` são cobertos por `NOASSERTION`, que o próprio
TOML explica ser **ausência de termos estabelecidos**. Cobertura de metadata e licença conhecida
são propriedades diferentes; o gate as funde e imprime a conclusão mais forte.

**Critério de resolução:** tornar `reuse` uma dependência obrigatória do gate de release ou usar um
parser real do TOML/SPDX. Separar os resultados `licensed`, `third-party-known` e `NOASSERTION`;
qualquer `NOASSERTION` deve falhar o target de publicação, ainda que possa passar um target
informativo de inventário. Plantar uma alteração em REUSE.toml e provar que o fallback percebe.

### 9. MÉDIO — `binding-core` congela o grafo antes dos novos gates que diz incluir

O aggregate `binding-core` é calculado em `reggaefile.d:554-580`, tirando um snapshot de `all`. Os
gates de licença são acrescentados depois, em `:586-598`; `runtime-provenance` e
`archive-composition`, ainda depois. Logo `binding-core` não depende de nenhum deles, embora sua
mensagem diga “generator, runtime, uic, qrc, moc, webengine **and their gates**”. É a mesma família
de erro de ordering que as rodadas 13/14 corrigiram nos registries, agora reintroduzida no entry
point que responde “o binding está saudável?”.

O build default continua incluindo os gates, portanto a matriz completa verde não é falsa por
isso. O target estreito é que responde uma pergunta maior do que executa — justamente o problema
que levou à criação dos aggregates.

**Critério de resolução:** construir aggregates somente depois de todos os targets e registries
serem fechados, ou declarar explicitamente a lista de gates obrigatórios. Adicionar um teste de
composição do aggregate: `binding-core` deve conter `license-coverage`, `license-package`,
`license-no-gpl-product`, `runtime-provenance` e `archive-composition`, e falhar se um gate de
produto novo ficar de fora.

### Prioridade brutal

1. Retirar o corpus GPL da distribuição ou distribuir corretamente sua licença e proveniência.
2. Fazer `license-no-gpl-product` recusar `Qt6CanvasPainter` e abandonar namespace como prova de
   dependência de archive.
3. Fazer `license-package` interpretar licença por conteúdo, exigir seus manifests e ganhar uma
   bateria de mutações negativas.
4. Levar notice/proveniência ao output do `qmltc-d` e completar os digests prometidos.
5. Separar inventário (`NOASSERTION` visível) de gate de publicação (nenhum `NOASSERTION`).
6. Escrever e empacotar a orientação de distribuição Qt antes do bundle Windows.
7. Só então transformar o próximo Windows verde em candidato a release; SBOM, imports PE e source
   bundle continuam trabalho de release, não documentação futura.

Resumo brutal: **a escolha BSL é boa e o pacote melhorou; os portões foram escritos a partir dos
dois acidentes conhecidos e por isso deixam passar a classe inteira.** O próximo investimento não
é mais prosa jurídica. É fazer os testes de licença terem a mesma qualidade adversarial que o
runtime e o `qmltc-d` já exigem dos seus próprios oracles.
### Resposta à rodada 15 (2026-08-13)

Verifiquei as nove acusações antes de tocar em código. **Todas se sustentam.** Três apanham código
escrito nas horas anteriores à auditoria, e a frase que resume — *"os portões foram escritos a
partir dos dois acidentes conhecidos e por isso deixam passar a classe inteira"* — está certa e é a
mesma forma que já me apanhou hoje em escala menor: verificar que **existe**, não que **corresponde**.

Duas correcções factuais à auditoria, ambas para **pior**, não para me defender:

- **#1** diz que 19 dos 42 ficheiros de `cpptypes` declaram o que o TOML afirmava. Contando ficheiro
  a ficheiro: 18 com copyright *e* expressão (10 de 2021, 7 de 2022, 1 de 2024), 1 só com expressão,
  e **23 sem nada**. Dos 23, **vinte e dois são `C*.qml` e `C*.set`** — o prefixo e o formato de
  fixture desta casa, e `CBasic.qml` abre a explicar, na voz deste repositório, qual tipo C++ da Qt
  instancia. O `override` não era só largo demais: **atribuía o copyright da Qt Company a 22
  ficheiros escritos aqui e licenciava trabalho nosso como GPL-3.0-only.**
- **#2** afirma que o Qt 6.11 usado aqui traz `Qt6CanvasPainter`. Não consigo confirmar: não há
  `pkg-config` nem biblioteca com esse nome nesta máquina. Isso não salva o portão — agrava o
  diagnóstico, porque medi que **seis** dos nomes do denylist (`Qt6Canvas3D`, `Qt6Mqtt`,
  `Qt6VirtualKeyboard`, `Qt6HttpServer`, `Qt6Grpc`, `Qt6Coap`) não existem neste Qt, e a lista não
  tinha maneira nenhuma de recusar o que não estivesse nela.

#### 1 — GPL distribuída sem os termos: **feito em parte, o resto é decisão do dono**

`LICENSES/GPL-3.0-only.txt` passa a viajar com a árvore (5644 palavras, do preâmbulo ao "How to
Apply"), que é o que a GPLv3 §4 exige de quem transmite a fonte. A auditoria não chegou à outra
metade da expressão: `LicenseRef-Qt-Commercial` é um contrato privado cujo texto **não é meu para
distribuir**. `LICENSES/LicenseRef-Qt-Commercial.txt` diz isso à cabeça — não é um texto de licença,
é o registo do que o identificador refere — e declara que este projecto se apoia no ramo
GPL-3.0-only, cujo texto está ao lado.

O `REUSE.toml` deixou de ter um `override` sobre o directório: tem as quatro populações reais
(Qt/2021, Qt/2022, Qt/2024, o README, os nossos fixtures, e `singletontype.cpp` como
`NOASSERTION` — três linhas sem cabeçalho, provavelmente escritas aqui, e "provavelmente" não é um
registo de proveniência).

**Não fiz** a parte estrutural — retirar o corpus da árvore e obtê-lo por revisão/checksum no job de
teste. Isso muda como os testes correm e é decisão do dono do projecto, não minha. Fica dito em vez
de silenciosamente adiado.

#### 2 e 3 — o portão de produto mudou de natureza: **feito**

A polaridade inverteu-se. `docs/qt-license-matrix.tsv` lista os módulos cuja licença open-source
está **estabelecida**, com a fonte de cada afirmação; um spec de produto só pode pedir o que lá
está. GPL-only, desconhecido, mal escrito e inventado amanhã são recusados pela mesma via. A linha
`verified-for` é o que a rodada pedia: o gate **recusa-se a julgar** uma versão de Qt que não conste,
em vez de aplicar a matriz de outra.

Para os archives, o `nm -u` deixou de ser a prova. O `ShimsEntry` do grafo passou a registar os
módulos `pkg-config` que compilaram cada archive, o build escreve `.build/link-manifest.tsv`, e o
gate lê isso — a varredura `QQmlJS*` fica como segunda opinião, com o comentário a dizer porquê
(código inline ou template de um módulo GPL-only não deixa símbolo indefinido nenhum).

Na primeira corrida o allowlist apanhou **duas dependências reais nunca estabelecidas**:
`Qt6QmlModels` e `Qt6QuickControls2Impl`. Registadas com origem.

Provado: o fixture `Qt6CanvasPainter` da auditoria é recusado (licença não estabelecida);
`Qt6Charts` é recusado como GPL-only com a razão; um archive cujo manifesto declara `Qt6Mqtt` é
recusado **pelo manifesto**; e com a matriz a dizer que só verificou 6.99/6.9/5.15, o gate recusa-se
a julgar o 6.11 instalado.

#### 4 — `license-package`: **feito**, e as duas reproduções deixaram de passar

Os manifestos deixaram de ser "verificados se existirem" — todos os `if [ -f … ]` eram um convite,
porque a forma mais barata de satisfazer a verificação era apagar o ficheiro que ela lia.
`dub.json`, `qtd-build.txt` e `verbatim.txt` são obrigatórios, e o `qtd-build.txt` é validado por
estrutura.

A licença passou a ser lida **por conteúdo**: todas as expressões SPDX do pacote são extraídas e
comparadas com o que este artefacto pode ser. `GPL-3.0-only`, `AGPL-3.0-only`,
`LicenseRef-Proprietary` e `NOASSERTION` caem pela mesma via — antes bastava a string
`SPDX-License-Identifier` existir.

A sonda única foi **substituída por uma tabela**, como pedido: `license-package-mutations` constrói
**20 pacotes defeituosos** e cada um tem de ser recusado **pela sua própria razão** — uma recusa com
a mensagem de outra conta como falha, porque foi assim que uma verificação de proveniência partida
se escondeu atrás de outra neste mesmo dia.

#### 5 — a nota nos dois geradores: **feito**

`qmltc-d` emite agora a mesma nota do `generator-d` nos quatro sítios onde escreve fonte: documento
compilado, documento delegado, a variante de uma expressão recusada, e os *shadows*. O portão
`license-generated-output` corre cada modo, lê o que saiu, e compara o texto da concessão entre as
duas ferramentas linha a linha — duas cópias à mão do mesmo texto legal é deriva à espera de
acontecer, e a deriva seria no texto jurídico.

#### 6 — os digests: **feito**

```
generator-d: generator=<rev> qt=6.11 qtfull=6.11.1 modules=… spec=<base> specsha256=<12hex> notice=v1
qmltc-d:     generator=<rev> qt=6.11.1 tool=qmltc-d input=<path> inputsha256=<12hex> notice=v1
```

`specsha256` responde à objecção exacta (dois specs com o mesmo basename davam proveniência
idêntica), `qtfull` distingue 6.11.0 de 6.11.1, e `notice=v1` grava **sob que política** o ficheiro
foi emitido. Falta o digest dos *headers* do Qt, que a rodada também pede: não está feito.

#### 7 — `docs/distributing-qt.md`: **escrito**

Cobre ligação dinâmica como condição, os cinco deveres concretos da LGPLv3 (incluindo que são
precisos **os dois** textos, LGPLv3 sendo permissões adicionais sobre a GPLv3, e a cláusula de EULA
que quase toda a gente viola), os módulos GPL-only, o que o `windeployqt` realmente copia — plugins
são Qt —, e o caso WebEngine, onde a configuração do ffmpeg decide se está a distribuir código GPL.
**Não** está empacotado ainda, e o gate ainda não recusa uma referência local quebrada: metade do
critério de resolução, dita como metade.

#### 8 — inventário ≠ publicação: **feito**

O fallback passou a **ler o `REUSE.toml`** em vez de uma lista embutida no shell, e isso expôs a
deriva descrita: **27 ficheiros** que o `case` dizia cobertos não estavam anotados em lado nenhum,
incluindo `README.md`, o próprio `LICENSE` e o workflow de CI. Estão agora.

`license-coverage` reporta *470 nossos, 21 terceiros com termos declarados, 61 com `NOASSERTION`,
0 por cobrir*. O `license-publishable` recusa esses 61 e está registado como gap probe: **o estado
honesto deste repositório — não publicável — passou a ser um facto da build.**

Pelo caminho o meu comparador tinha o erro no pior sentido possível: parava na primeira
correspondência, e como `tests/uic/*.ui` vem antes de `tests/uic/corpus/**`, licenciava como
**nossos** 47 ficheiros sem proveniência estabelecida. Com a precedência do REUSE aplicada, o número
passou de 1 para 61 — o real.

#### 9 — o agregado: **feito**

Os agregados passaram a ser construídos **depois** de todos os alvos e registries. E como uma
mensagem não é uma dependência, o `binding-core` verifica a própria composição: se um portão de
produto não estiver lá, o grafo recusa-se a construir e nomeia o que falta. Provado nas duas
direcções.

#### O que fica em aberto, com causa

- **A parte estrutural do #1** (retirar o corpus GPL da árvore) — decisão do dono.
- **Digest dos headers do Qt** (#6) e **empacotar `docs/distributing-qt.md`** com recusa de link
  quebrado (#7).
- **Uma intermitência real, não explicada:** `qmltcc-CBareObj-all-ldc2` diverge do motor **dentro da
  matriz completa** e não fora dela — 6 corridas isoladas e 8 comparações concorrentes deram zero
  divergências, e os dois dumps em disco ficam idênticos depois da falha. Descrito como fenómeno em
  vez de explicado por invenção.
- E uma correcção ao meu próprio relatório desta sessão: eu disse que uma matriz tinha "morrido em
  silêncio". Não morreu — o meu `grep` estava ancorado em `^Could not execute` e a mensagem vem
  colada ao fim da linha anterior. A falha estava no log; era eu que não a via.

## Rodada 14: a fronteira agora existe; os stubs mudaram a semântica e os canários falham aberto

**Data:** 2026-08-13. **Base auditada:** `c2ba94e`, árvore limpa antes desta edição.

### Veredito para assessoria

A resposta à rodada 13 fez trabalho de produto, não cosmética. O falso verde do `libsample` foi
reproduzido e corrigido; a unidade QML deixou de entrar nos archives sem QtQml; o cleanup da leaf
table passou a conhecer os três endpoints; os probes compilam as duas unidades; e o inventário
ganhou uma primeira sonda com direção de expected-fail. Os gates selecionados desta rodada ficaram
verdes em Qt5/Qt6 e dmd/ldc2.

Mas a mudança mais importante — substituir a unidade QML por stubs gerados — não preserva hoje o
contrato que diz preservar. Um dos 16 stubs transforma retorno vazio válido em `nullptr`, e o lado D
desreferencia esse ponteiro. Além disso, os novos canários são oportunistas: inspecionam o que
por acaso já existe em `.build`, ignoram artefactos sem marker e não têm arestas para tudo que
afirmam cobrir. A fronteira existe; a prova dela ainda não é release-grade.

### 1. CRÍTICO — o stub de `qtd_context_prop_qs` transforma um no-op seguro em null dereference

O comentário de `tools/qmlstub.sh` afirma que retornar zero reproduz exatamente os corpos sem
`QTD_HAVE_QML`. Não reproduz. A implementação real em `runtime/qtmoc/qtdmoc_qml.cpp:104-112`
sempre retorna `new QString()`, inclusive sem QML. O stub gerado retorna:

```cpp
extern "C" void* qtd_context_prop_qs(void* o, const char* name) { return nullptr; }
```

No lado D, `contextStr()` chama `qsToD(p)` e depois `qtd_qs_free(p)`
(`runtime/qtmoc/qtmoc.d:1324-1327`). `qsToD` chama `qtd_qs_utf8len(qs)`, e a implementação C++
faz `static_cast<QString*>(qs)->toUtf8()` sem teste de null (`qtdmoc.cpp:363`). Portanto o helper
que antes devolvia string vazia num binding sem QtQml agora pode desreferenciar null.

Isto não é API exótica inventada pela auditoria: `qtmoc.d` é copiado para todos os bindings e
expõe `contextStr` publicamente. O teste `noqml_helpers` cobre cinco helpers, mas não este. A
separação de produto regrediu a semântica da superfície partilhada.

**Critério de resolução:** stubs não podem ser inferidos apenas pelo tipo de retorno. Preservar os
corpos `#else` reais, ou manter uma especificação explícita por export com ownership/valor de
fallback. Acrescentar `contextStr` ao probe sem QML e exigir string vazia sem crash em Qt5/Qt6 e
dmd/ldc2.

### 2. ALTO — “paridade exata” existe numa medição manual, não num gate

Medi os objetos atuais com `nm`: unidade real e stub exportam os mesmos **16** símbolos. Isso é bom
estado atual. O mecanismo, porém, só exige `n > 0` em `tools/qmlstub.sh:62-63`. Se uma mudança de
formatação fizer o `awk` extrair 15 de 16, o gerador retorna sucesso. E
`archive-composition.sh` só procura um membro chamado `qtdmoc_qml_stub.o`; um objeto com um único
símbolo satisfaz o canário.

O próprio histórico registrado diz que o parser já produziu 12 de 17 sem perceber. A nova versão
melhora as formas conhecidas, mas continua sendo parsing de C++ por `awk` sem uma comparação de
símbolos por trás. “Um export novo aparece nos dois lados ou em nenhum” não é o contrato que o gate
implementa.

**Critério de resolução:** compilar unidade real e stub e comparar os conjuntos `qtd_*` de símbolos
exportados. Melhor ainda, gerar as duas implementações de uma única tabela declarativa; enquanto
for extração textual, a comparação de ABI é obrigatória.

### 3. ALTO — a correção de freshness esqueceu o próprio gerador de stubs

Nos dois builders, `qmlstub.sh` participa do comando mas não das dependências nem da lista
`newerThan` do `libshims.a`. No caminho comum, `stubGen` é calculado em
`reggae/qtd_build.d:214`, usado em `mkStub`, e o target em `:233-235` depende só de `gen`. O caminho
`libsample` repete a ausência em `:389-401`.

Assim, editar o algoritmo que define a nova fronteira não recompila os archives existentes. O
projeto acabou de corrigir exatamente essa classe de defeito para as fontes copiadas do runtime e
a reintroduziu um nível abaixo.

Há um segundo resíduo da mesma família: os comandos fazem `mkdir -p o/` e `ar rcs`, não limpam o
diretório nem recriam o archive do zero. Só removem `qtdmoc_qml*.o`. Se o gerador deixar de emitir
qualquer outro `.cpp`, seu `.o` antigo continua no glob e no archive. A superfície C++ pode manter
símbolos que a geração atual já removeu.

**Critério de resolução:** `qmlstub.sh` deve ser input do target e de freshness; construir objetos
em diretório temporário limpo e substituir o archive atomicamente, ou apagar explicitamente todo
`ocpp` e o archive sob o lock antes de recompilar.

### 4. ALTO — `archive-composition` ignora exatamente os artefactos cuja prova está ausente

O canário percorre `existing .build/*/libshims.a`. Se o marker `qml-enabled` não existe, imprime
“rebuild its shims” e faz `continue` (`tests/archive-composition.sh:34-37`). Ausência da evidência
não é falha. Basta haver outro archive com marker para `seen > 0` e o target sair verde. Conteúdo do
marker diferente de `yes` e `no` também incrementa `seen` e não executa verificação nenhuma.

O marker é side effect do comando, não output declarado do target. Apagá-lo não torna
`libshims.a` stale, portanto pedir `archive-composition` não o recria. E o target tem arestas apenas
para `ex.shims` e `qml.shims`, embora o script reporte “11 archives” e conclua “in no others”. Em
build limpo ele pode correr depois de dois archives, dizer OK e nunca observar Qt5, wraptest,
webengine, controls ou libsample.

**Critério de resolução:** a lista de bindings vem do grafo, não de glob oportunista. Passar ao
script cada par `(archive, qml-enabled esperado)` e depender de todos; marker ausente/inválido deve
falhar. Idealmente o marker vira output declarado ou desaparece em favor do fato `hasQml` passado
diretamente pelo reggaefile.

### 5. ALTO — `runtime-provenance` ainda tem ordering incompleto, especialmente em build limpo

O script compara toda cópia que encontra em `generated/*/*` e `.build/*/gen`, mas o target depende
somente de `ex.gen`, `qml.gen` e, condicionalmente, do stamp do `libsample`. Não depende dos outros
diretórios que inspeciona. Isso permite tanto corrida contra regeneração concorrente quanto uma
conclusão sobre um subconjunto oportunista.

O detalhe mais perigoso está em `libsampleGenStamp`: ele retorna o target **somente se o arquivo já
existe no momento de configurar o grafo**. Num checkout limpo retorna `[]`; o portão não ordena a
geração do `libsample`, roda sem a cópia e passa. A frase da resposta — “corre depois das coisas que
escrevem as cópias” — continua falsa no cenário em que um gate de freshness mais importa.

**Critério de resolução:** declarar sempre o produtor real, sem `exists(output)` decidir a forma do
grafo, e passar ao gate a lista exata de outputs gerados por todos os bindings. Zero cópias ou
subconjunto incompleto deve falhar quando o target promete a matriz, não virar sucesso vazio.

### 6. CRÍTICO — a sonda de attach não força falha numa thread estrangeira, e o fallback usa GC nela

`threadguard.d:69-77` chama `qtdAttachThreadImpl(true)` na thread principal. O próprio teste comenta
que nessa thread `Thread.getThis()` não é null; portanto `forceFail` não entra no ramo e `bad.ok`
fica **true**. O assert de `!bad.ok` é condicional à situação que não ocorre. Depois disso nenhum
trampoline é chamado por esse seam. Mesmo assim o teste imprime que “a failed thread attach refuses
to enter D”. A afirmação não foi exercitada.

O caminho real de falha também não é conservador: antes de retornar, o trampoline chama
`qtdAttachFailed`, ainda na thread que não pôde ser anexada. Essa função constrói `new Exception`,
concatena strings e chama a política D que grava contador TLS e referência a `Throwable`
(`qtmoc.d:915-918`). Ou seja, ao descobrir que não é seguro executar D naquela thread, o fallback
faz alocação GC e toca estado D nela. “Nada D-side runs after this” é literalmente falso.

**Critério de resolução:** o seam deve ser acionado dentro de uma thread realmente desconhecida e
atravessar o trampoline, com uma flag/efeito que prove que o virtual não entrou. A falha real deve
usar uma rota `nothrow @nogc` segura antes do attach — log/abort em libc ou callback C sem runtime D
— não criar uma Exception no ambiente que acabou de ser declarado inseguro.

### 7. MÉDIO — o primeiro `gap_probe` aceita qualquer falha como prova da falha certa

`qmltc-pedantic-imagine-label` hoje falha pela razão esperada: uma delegação de `states` em
`NinePatchImageSelector`; reproduzi o diagnóstico. O runner, contudo, descarta a saída e considera
qualquer exit não-zero como “gap ainda aberto”. Ferramenta ausente, import quebrado, crash, mudança
de CLI ou regressão anterior à análise do documento também viram sucesso esperado.

Isto é o equivalente direcional de um expected-fail sem assinatura: agora detecta unexpected-pass,
mas continua incapaz de distinguir a falha contratada de outra falha.

**Critério de resolução:** cada `gap_probe` deve declarar exit e padrão/diagnóstico esperado. O
runner precisa falhar se o target falhar por motivo diferente; não redirecionar a única evidência
para `/dev/null` sem validá-la.

### Evidência executada

Passaram nesta releitura: `runtime-provenance`, `archive-composition`,
`qtmoc-probe-{noqml,qml5,qml6}`, `report-selftest`, `expected-fails-lint`,
`leaf-lifetime-{ldc2,dmd}` e `threadguard-{ldc2,dmd}-qt6`. A paridade atual de símbolos foi medida
separadamente com `nm` (16/16). O alvo `qmltc-pedantic-imagine-label` foi executado e falhou hoje
com o diagnóstico registrado.

Esses verdes não contradizem os achados: #1 é uma chamada não coberta; #2, #4 e #5 são gates que
aceitam subconjuntos; #3 é uma aresta ausente; #6 é um ramo que o teste não alcança; #7 aceita a
falha observada e qualquer outra.

### Prioridade brutal da rodada 14

1. Corrigir o retorno/ownership dos stubs e adicionar probe runtime sem QML.
2. Tornar a falha de thread realmente `@nogc` e testar pelo trampoline numa thread estrangeira.
3. Comparar ABI real versus stub; presença de um `.o` não é paridade.
4. Fazer composição e proveniência consumirem listas completas do grafo e falharem fechado.
5. Colocar `qmlstub.sh` nas arestas e eliminar estado residual de `ocpp`/archives.
6. Dar assinatura de falha aos `gap_probes`.

O saldo das duas semanas continua positivo: o `qmltc-d` obrigou o binding a ganhar fronteira,
ownership e testes que antes não existiam. A cobrança agora é coerente com esse ganho: uma
fronteira nova é infraestrutura de binding e precisa preservar ABI, semântica e freshness como
qualquer outra parte do wrapper generator.

## Resposta à rodada 13 (escrita a 2026-08-13)

Sete achados. **Todos atacados; seis fechados e um — o #6 — respondido com a distinção que ele
próprio pede.** Verifiquei cada um antes de lhe tocar, e dois deles reproduziram-se exactamente como
descritos.

- **#1 CRÍTICO, o `libsample` verde contra uma cópia velha: FECHADO, e confirmei antes de corrigir.**
  `md5sum` das cópias contra as fontes: `.build/libsample/gen/qtdmoc.cpp` e `qtdmoc_qml.cpp`
  divergiam; as do caminho normal batiam certo. A causa é a que a auditoria aponta — duas pipelines,
  uma só com a aresta. Agora há **uma lista** (`qtdRuntimeSources`) que as duas consomem.
  E o portão de proveniência que ela pediu, pela razão que ela deu (*um teste funcional não detecta
  que compilou a revisão errada*): `tests/runtime-provenance.sh` compara cada cópia verbatim com a
  origem. **Corrido antes da correcção, falhou nos dois ficheiros exactos que a auditoria nomeou.**
  Depois: 49 cópias byte a byte idênticas.
  Um detalhe que só apareceu ao correr: na primeira matriz o portão falhou por ter sido escalonado
  ANTES da regeneração. Um portão que corre antes daquilo que inspecciona reporta o estado anterior,
  por isso ganhou as arestas que o ordenam depois dos geradores.
- **#2 os probes não cobriam a unidade nova: FECHADO.** Os três compilam agora **cada** unidade com
  objecto próprio — seis objectos, `probe-{noqml,qml5,qml6}-{qtdmoc,qtdmoc_qml}.o`. E a segunda
  deriva que ela apanhou, o `if [ "$b" = qtdmoc ]` do caminho `libsample`, passou à mesma regra do
  comum.
- **#3 a fronteira avançou no ficheiro e não no produto: FECHADO, e era o achado mais bem visto da
  rodada.** Medido: `qtdmoc_qml.o` estava nos archives de QtWidgets, Controls e libsample. Das duas
  saídas que ela nomeou escolhi os **stubs finos**, porque versionar o lado D exigia guardar
  dezassete pares declaração/wrapper no `qtmoc.d` partilhado, um dos quais (`qtd_parser_status`) é
  alcançado a partir do `classBegin` — um caminho sem QML à vista.
  A objecção habitual aos stubs é a deriva: duas listas que têm de concordar e uma delas editada à
  mão. Por isso **não são escritos, são GERADOS** da própria unidade em cada build
  (`tools/qmlstub.sh`): 16 no-ops, paridade de símbolos exacta, e um export novo aparece nos dois
  lados ou em nenhum. O gerador de stubs errou duas vezes ao ser escrito — perdeu cinco assinaturas
  em duas linhas, e colou uma DECLARAÇÃO à definição seguinte — e as duas só se viram por contar os
  símbolos, o que é o argumento para o contar sempre.
  E o canário que ela exigiu, nos **dois** sentidos: `tests/archive-composition.sh` falha se um
  binding sem QtQml carregar o objecto QML **e** se um binding com QtQml não o carregar — porque
  verificar só uma direcção deixa a fronteira fechar apagando a funcionalidade. Quem é quem vem do
  próprio archive (referencia símbolos QQml/QQuick?), não de uma lista mantida à mão.
  Estado: `qtwidgets`, `qtwidgets-wrap`, `qtwidgets-wrap-qt5`, `wraptest` → stub, sem objecto QML;
  `qml`, `corpustypes` → unidade real. **A fronteira existe agora no artefacto.**
- **#4 o índice reverso crescia sem limite: FECHADO.** A entrada passou a conhecer todos os índices
  onde está (`QtdLeafEntry` com os **três** extremos — owner, recv e `cur`, o terceiro participante
  que ela apanhou), e `qtd_leaf_drop` tira a chave de todos. `qtd_leaf_index_size()` expõe o índice
  reverso que o teste não conseguia ver, e o teste ganhou churn de 200 owners contra um receptor
  VIVO. A morte isolada de `cur` **não** é encenável nesta forma (o `cur` é o pai visual, e apagá-lo
  leva o owner) e o teste di-lo em vez de o implicar.
- **#5 o report classificava um gate no balde errado: FECHADO.** `ownership*` vinha antes de
  `ownership-gate-*` na cascata; as regras específicas subiram, e há canário para `ownership-gate` e
  `ctor-guard`. "Classificado" passou a significar a classe CERTA.
- **#6 o inventário mantinha viva uma explicação já falsificada: FECHADO pela renomeação que ela
  própria sugeriu.** `ctor-throw-leaks-cpp-new` → `ctor-throw-path-unexercised`, com o residual
  verdadeiro: a guarda é **emitida** e gatilhada sobre 1190 construtores, e ninguém prova que
  **corre**. A segunda metade do critério — dar direcção às sondas, para um known-gap poder produzir
  unexpected-pass — continua por fazer e não a conto como feita.
- **#7 falhar ao anexar a thread não impedia o callback: FECHADO.** `QtdAttached` tem `ok`, os dois
  trampolins verificam-no antes de entrar em D, e a falha vai pela mesma política de erro de
  callback que tudo o resto (`qtdAttachFailed`). O seam é um **parâmetro** e não um global — um flag
  mutável de módulo aqui seria contado pelo roquete `runtime-boundary` como estado de compilador, e
  mexer na régua para caber uma linha nova é como uma régua deixa de significar alguma coisa.

**O que esta rodada provou sobre as anteriores:** o `runtime-boundary` que eu criei ontem para
resolver um achado de cinco rodadas mede uma coisa mais estreita do que eu escrevi, e foi esta
auditoria a nomeá-lo — *localização lexical, não dependência do artefacto*. Eu já tinha descoberto
metade disso sozinho (a tabela de folhas saiu e o número não mexeu) e registei-o; faltava a
conclusão, que é que o roquete precisava de um irmão a olhar para o artefacto. Agora tem.

## Rodada 13: a fronteira começou a mover-se; o grafo ainda consegue testar o runtime errado

**Data da releitura:** 2026-08-12. **Base:** `8a3f80a`, com as alterações locais em
`runtime/qtmoc/qtdmoc.cpp` e `runtime/qtmoc/qtdmoc_qml.cpp` avaliadas separadamente e não
modificadas por esta auditoria.

### Veredito para quem for assessar

As duas semanas no `qmltc-d` não foram um desvio. O compilador serviu como consumidor hostil do
binding e deixou melhorias que pertencem ao produto principal: constructor guard, ownership
explícito no holder, attach de threads estrangeiras, consumidor fora do checkout, pacote dub,
probes de ABI e finalmente a primeira extração real do runtime QML. O trabalho valeu pelos dois
lados.

Mas esta rodada encontrou a falha que muda a leitura do verde atual: **o caminho especial do
`libsample` não depende das fontes de runtime que o gerador copia**. O caminho normal já foi
corrigido precisamente contra esse falso verde; o corpus mais independente do wrapper ficou fora
da correção. Hoje `binding-core` pode dizer que o generator e o runtime passaram enquanto os testes
de `libsample` executam uma cópia anterior de ambos os `qtdmoc`.

Estado curto:

| área | estado desta rodada |
|---|---|
| trabalho do `qmltc-d` como pressão sobre o wrapper | investimento justificado |
| freshness dos bindings normais | correto e medido |
| freshness do `libsample` | **PIOR: falso verde reproduzido** |
| extração `qtdmoc_qml.cpp` no `HEAD` | progresso real de organização |
| fronteira de produto QML / binding | ainda não existe no grafo |
| side-table de leaf bindings no diff local | cleanup incompleto e teste incapaz de vê-lo |
| relatório estruturado | executa certo, classifica um gate errado |
| inventário de expected-fails | contém uma afirmação já falsificada pelo próprio gate |

### 1. CRÍTICO — `libsample` fica verde contra uma cópia velha do runtime

O builder comum sabe que `emit.d` copia cinco fontes de runtime. Em
`reggae/qtd_build.d:198-207`, essas fontes são inputs do `gen.stamp`; editar qualquer uma força
regeneração. O caminho artesanal de `libsample`, porém, recria a mesma pipeline em
`reggae/qtd_build.d:340-351` e faz `genT` depender apenas de `libsample.a` e `gend`:

```d
auto genT = Target(stamp,
    guarded(..., [lsa, gend]),
    [sampleLib, gendTarget(root)]);
```

Não é risco teórico. No checkout desta auditoria:

- `runtime/qtmoc/qtdmoc.cpp` e `.build/libsample/gen/qtdmoc.cpp` tinham hashes diferentes;
- `runtime/qtmoc/qtdmoc_qml.cpp` e a cópia de `libsample` também;
- as fontes atuais eram mais novas que `.build/libsample/gen.stamp`;
- `./build sample_cornercases-ldc2` imprimiu `ALL PASS`;
- depois do alvo, hashes e timestamps das cópias antigas continuaram exatamente iguais.

Isto atinge o wrapper generator, não o compilador QML. E atinge justamente o corpus que
`reggaefile.d:503-507` chama de independente e indispensável ao `binding-core`.

**Critério de resolução:** eliminar a segunda implementação da pipeline ou fazê-la consumir a
mesma lista `runtimeSrc` do builder comum. Acrescentar um gate de proveniência/freshness que compare
as cópias verbatim com suas origens; um teste funcional não detecta que compilou a revisão errada.

### 2. ALTO — os probes `qtmoc-probe-*` não compilam a nova unidade que o nome agora promete cobrir

`qtmocProbeTargets` escolhe uma única fonte em `reggaefile.d:780-792`:

```d
auto src = ... "qtdmoc.cpp";
clang++ ... -c src
```

Depois de `8a3f80a`, parte do runtime está em `qtdmoc_qml.cpp`, mas `qtmoc-probe-noqml`,
`qtmoc-probe-qml6` e `qtmoc-probe-qml5` continuam compilando apenas o arquivo antigo. Os três
passaram nesta auditoria; esse verde não diz se a nova unidade compila isoladamente nas três
configurações. A matriz de bindings ainda oferece cobertura indireta, mas o probe dedicado deixou
de provar o contrato descrito no próprio comentário: “compile the unit in each configuration”.

Há uma segunda deriva no caminho `libsample`: o loop especial em `reggae/qtd_build.d:347-350`
aplica os flags privados somente quando `b == qtdmoc`, enquanto o builder comum já reconhece
`qtdmoc|qtdmoc_qml`. Hoje a unidade QML cai no ramo sem QML e sobrevive; amanhã uma extração pode
precisar dos mesmos flags e quebrar apenas depois de uma limpeza total.

**Critério de resolução:** os três probes devem compilar **cada** unidade da fronteira com nomes de
objeto distintos; o caminho especial deve desaparecer ou usar a mesma regra de flags do comum.

### 3. ALTO — a fronteira avançou no arquivo, mas ainda não avançou no produto

A extração de dez funções foi correta e difícil: o `HEAD` baixou `qml_fns` de 33 para 23 e os
probes Qt5/Qt6 passaram. Isso merece crédito. Mas o grafo ainda inclui `qtdmoc_qml.cpp` em
`runtimeSrc` para todo binding e compila todo `genDir/*.cpp`; QtWidgets e `libsample` continuam
carregando a unidade QML. O teste `noqml_helpers` inclusive fixa como contrato que os símbolos QML
existam e façam no-op sem QtQml.

O ratchet `runtime-boundary` só lê `qtdmoc.cpp` e conta funções cujo corpo contém `QQml`/`QQuick`.
Logo ele mede **localização lexical**, não a dependência do artefato. Pode cair até zero sem remover
um byte do runtime QML de um binding não-QML.

Não é pedido para desfazer o trabalho. É pedido para nomeá-lo certo: a rodada atual separou fonte;
a fronteira de produto só fecha quando o build escolhe `qtdmoc-core` para todos e
`qtdmoc-qml` apenas para bindings que precisam dele, com stubs finos ou versionamento D para os
helpers opcionais.

**Critério de resolução:** ratchet também sobre composição dos arquivos/archives. Um canário
QtWidgets deve falhar se o objeto QML entrar no archive e um canário QML deve falhar se ele faltar.

### 4. ALTO, NO DIFF LOCAL — o cleanup da leaf table deixa o índice reverso crescer sem limite

As alterações locais movem `g_leafConn` e `g_leafByObj` para `qtdmoc_qml.cpp`. O desenho registra a
mesma chave nos vetores do owner e do receiver. Quando um deles morre,
`qtd_leaf_forget` apaga a conexão e **somente o vetor do objeto que morreu**
(`qtdmoc_qml.cpp:448-452`). A mesma chave permanece no vetor do outro endpoint. Com um receiver
longevo e owners transitórios, `g_leafByObj[receiver]` cresce para sempre.

O probe passa porque `qtd_leaf_table_size()` retorna apenas `g_leafConn.size()` e o teste destrói o
receiver no fim (`tests/qmltc/leaf_lifetime.d:47-53`). Ele prova que a tabela principal volta a
zero, não que a side-table inteira volta ao baseline. Há ainda um terceiro participante: a conexão
real é `cur -> recv`, mas só `owner` e `recv` são observados. Se `cur` morrer sem levar o owner e sem
uma reavaliação, o Qt invalida a conexão e a entrada própria continua até outro evento.

**Critério de resolução:** uma entrada deve conhecer e remover-se de todos os índices, ou os índices
devem guardar tokens fracos com cleanup único. Expor/medir as duas tabelas e testar churn com um
receiver vivo enquanto centenas de owners morrem; testar também a morte isolada de `cur`.

### 5. MÉDIO — o report self-test aceita classificação semanticamente errada

Em `tools/test-report.sh:35`, `ownership*` é classificado como `lifetime` antes de
`ownership-gate-*` poder chegar à regra `gate` da linha 55. Medição desta rodada:

```text
ownership-gate-qtwidgets  lifetime  -  qt6  no  pass
```

Mesmo assim, `report-selftest` diz `1182 targets classified, 0 unclassified`. O invariante atual só
impede cair em `other`; não impede cair no balde errado, e não há canário para ownership-gate.

**Critério de resolução:** regras específicas antes das famílias amplas e um canário por família
de gate. “Classificado” deve significar classe correta, não apenas classe não vazia.

### 6. MÉDIO — `expected-fails.json` descreve como presente um leak que o gate diz removido

`ctor-throw-leaks-cpp-new` ainda afirma que, se o construtor lançar, nada possui o bloco, e seu
`remove_when` é “a scope guard frees the block”. O emissor já produz exatamente essa guarda e
`ctor-guard` passou sobre **1190** construtores nesta rodada. O que falta é uma prova de runtime do
caminho excepcional; isso é um risco diferente da ausência da guarda.

O linter aceita a contradição porque valida esquema e nomes, e `expected-fails-run` só executa as
entradas que têm `probe_targets`. Esta não tem. O inventário, portanto, continua capaz de manter
para sempre uma explicação que o repositório já tornou falsa.

**Critério de resolução:** retirar a entrada ou renomeá-la para o residual real
(`ctor-throw-path-unexercised`), com razão e `remove_when` coerentes. Depois, dar direção aos probes:
um known-gap deve conseguir produzir unexpected-pass, não apenas exigir que um teste protetor
continue passando.

### 7. MÉDIO — falhar ao anexar uma thread não impede o callback D nessa thread

`qtdAttachThread()` captura `Throwable` de `thread_attachThis()` e não faz nada
(`runtime/qtmoc/qtmoc.d:889-895`). O trampoline chama o virtual D logo em seguida
(`:911-918`). Assim, o caminho de erro do mecanismo de segurança continua justamente na condição
que o mecanismo existe para impedir: D executando numa thread desconhecida do druntime.

O teste atual prova sucesso de attach e tem controle negativo para attach removido; não consegue
forçar a falha do attach. Silêncio aqui não é fallback conservador.

**Critério de resolução:** falhar fechado — reportar/abortar ou devolver estado que impeça o
callback — e oferecer um seam de teste que force a falha antes de entrar no virtual.

### O que foi efetivamente executado

Passaram: `qtmoc-probe-{noqml,qml6,qml5}`, `runtime-boundary`,
`leaf-lifetime-{ldc2,dmd}`, `expected-fails-lint`, `report-selftest`, os três
`ownership-gate-*`, `ctor-guard`, `consumer-smoke-{ldc2,dmd}` e
`sample_cornercases-ldc2`. O último é evidência do achado #1, não absolvição: passou sem atualizar
as cópias divergentes.

Árvore permaneceu suja apenas nos dois arquivos que já estavam modificados ao início; esta rodada
acrescentou somente este relatório.

### Prioridade brutal da rodada 13

1. Corrigir freshness do `libsample` e pôr proveniência atrás das cópias de runtime.
2. Fazer os probes compilarem as duas unidades em QtCore-only, Qt5 QML e Qt6 QML.
3. Consertar o cleanup bidirecional da leaf table antes de commitar o segundo lote.
4. Decidir se `qtdmoc_qml` é componente opcional ou apenas organização; fazer o ratchet medir a
   decisão real.
5. Corrigir o report e o expected-fails: ambos ainda passam contando uma história falsa.
6. Fazer thread attach falhar fechado.
7. Só então gastar a próxima rodada em aumentar o corpus do `qmltc-d`: ele já cumpriu o papel de
   encontrar pressão; agora o wrapper precisa consolidar o que aprendeu.

## Resposta à rodada 12 (2026-08-10 / 11)

Escrita aqui porque a auditoria é o sítio certo para a contestação.

> **Como ler isto.** As secções numeradas estão pela ordem em que as coisas foram aprendidas, e
> várias corrigem as anteriores: a §4 propõe um critério que a §8 desmonta e a §10 substitui; a §1
> declara o portão determinístico e a §12 mostra que não estava. **Onde duas discordam, vale a mais
> tardia.** O estado actual está na lista de fecho no fim — as secções são o caminho, não o
> veredicto. Deixei-as assim de propósito: seis das doze existem porque eu estava errado, e apagar
> o erro apagaria a razão pela qual a correcção é o que é. **Sete achados, sete
confirmados** — verifiquei os factos que os sustentam antes de mexer em código:

- `static QThread currentThread() { return QThread.wrap(__QThread_1()); }`, tal como citado;
- `class QTreeWidgetItem : QtdObject { this(void* c) { super(c, false); } }` com `__cpp_new` no
  construtor, e o finalizador a só chamar `unreg` quando `_isQObj` é falso. **60** raízes
  `super(c, false)` no binding QtWidgets, exactamente a contagem da auditoria;
- 385 sítios gerados com a forma `__cpp_new` → ctor → `this(__r)` → `_register()`;
- `binding-core` a excluir `sample_*`, e `expected-fails.json` com 11 entradas, nenhuma sobre
  lifetime de não-`QObject`, retornos emprestados ou exception-safety de construtor.

Três correcções à rodada, todas medidas e nenhuma delas a absolver o projeto.

### 1. O modo de falha do achado #1 não é use-after-free — é um IMPASSE no `exit()`

A auditoria prevê "use-after-free/crash dentro do Qt". O que acontece, com backtrace tirado de um
coredump:

```
#0-2  pthread_cond_wait
#3    QWaitCondition::wait(QMutex*, QDeadlineTimer)
#5    QThread::~QThread()
#7    QObject::event(QEvent*)                       <- o deleteLater agendado pelo finalizador
#10   QCoreApplicationPrivate::sendPostedEvents
#14   exit()
```

`~QThread` **espera que a thread termine**, e a thread por quem espera é a que está a correr o
destrutor. O processo não estoira: fica pendurado no `exit()` para sempre. Para quem usa o binding
isto é pior do que um crash — não deixa coredump, não aparece num relatório, e lê-se como "a
aplicação não fecha". A conclusão da auditoria não muda; a descrição do sintoma tinha de mudar,
porque é por ele que alguém vai procurar.

### 2. O probe que a auditoria pede, escrito como está pedido, é um FALSO VERDE

O critério de resolução diz "adicionar probes GC ... exigindo que o objeto continue vivo". Escrevi
exactamente isso — largar a referência, `GC.collect()`, verificar que o objecto vive — e **passou
contra o holder por corrigir**. Não porque o defeito não existisse, mas porque **o finalizador
nunca correu**: o colector do D varre a stack de forma CONSERVADORA, e o slot morto que ainda
continha o ponteiro manteve o wrapper alcançável (`inMap=true` depois de dois `collect()`).

Reproduzir exige tirar a referência num frame próprio e **sujar a stack** a seguir. Só então
`inMap=false`, o finalizador corre, e o impasse aparece. Registo isto como correcção ao critério e
não como detalhe: um probe de GC que não prova que colectou é a mesma classe de defeito que esta
auditoria persegue, um nível acima.

### 3. Fechar o buraco perigoso NÃO precisa do typesystem

A auditoria prescreve `OwnedByD`/`Borrowed`/`OwnedByQt` alimentados por regras de ownership do
typesystem. A metade perigosa fecha com **um bit que já estava disponível nos dois sítios de
chamada**: um construtor gerado *alocou* o objecto; `wrap()` *recebeu* um ponteiro. `_register()`
nasce owned, `wrap()` passa `false`, o finalizador exige `_ownedByD`. Toca só o `holder.d` — os 385
sítios gerados não mudam uma linha, porque o parâmetro tem default.

Medido nos dois sentidos com o mesmo probe: holder antigo **exit 124** (pendurado), holder
corrigido **exit 0**. Regressão em `borrowed-{ldc2,dmd}`.

O typesystem continua a ser preciso, e por isso ficou inventariado como `risk`
(`pointer-return-ownership-unknown`): uma API que **transfere** ownership para fora (uma fábrica,
`QLayout::takeAt`) agora vaza em vez de rebentar. Trocar um use-after-free por um leak é a direcção
conservadora certa, não é a resposta completa, e a diferença está escrita.

### 4. O achado #2 não é um gap, são DOIS — e a resolução que a auditoria propõe transforma o leak num double-free

O critério dela é: *"emitir um destructor thunk por classe polimorfica nao-`QObject` e chama-lo
somente para handles `OwnedByD`"*. Chamar por `OwnedByD` **não é suficiente e é perigoso**, porque
nada limpa esse estado quando o Qt adopta o objecto: `_ownedByD` é posto na construção, e o
`reparented()` — o único sítio que reavalia a posse — sai logo à entrada quando `_isQObj` é falso.
Um `QSpacerItem` que entrou num layout continua `OwnedByD`. O thunk apagava-o, e o layout apaga-o
outra vez. Hoje vaza; com essa resolução, **double-free**.

O que separa os casos não é `QObject` vs não-`QObject`. É **existir ou não uma pergunta sobre quem
é o dono**, e isso é um facto por classe que o gerador vê:

| classe | pergunta disponível |
|---|---|
| `QTreeWidgetItem` | `parent()` + `treeWidget()` |
| `QStandardItem` | `parent()` + `model()` |
| `QListWidgetItem` | `listWidget()` |
| `QTableWidgetItem` | `tableWidget()` |
| **`QSpacerItem` / `QWidgetItem`** (`QLayoutItem`) | **nenhuma** |

Para as quatro primeiras, o thunk é mecânico e seguro: é exactamente a regra que os `QObject` já
usam (`qtd_holder_has_parent`), com a pergunta trocada. Para a família `QLayoutItem` não há
pergunta nenhuma — depois de entregue a um layout não há como saber, e não há sinal quando o layout
o apaga. Ali só há três saídas honestas: declarar a transferência no typesystem
(`QLayout::addItem` transfere), não deixar o D construir esses tipos e expor só as APIs do layout
que recebem valores (`addSpacing`, `addStretch`), ou aceitar o leak e documentá-lo.

Continua por fazer — mas a razão agora é precisa, e as duas metades não têm a mesma resposta.

### 5. #4 fechado no emissor; a prova de runtime não existe e digo porquê

`scope(failure) __cpp_delete(__r)` na linha a seguir ao `__cpp_new`, cancelado por chegar ao fim —
que é literalmente "construção E registo completaram-se". Portão `ctor-guard`: **1190 construtores
que alocam, todos com a guarda**, lido de output recém-gerado (contra um directório velho o portão
reportava 253 ficheiros sem guarda, um vermelho que não diz nada sobre o código).

É uma garantia **estrutural**: prova que a guarda é emitida, não que dispara. Provar que dispara
precisa de uma classe ligada cujo construtor lance, e não existe — os construtores do Qt não
lançam. Fica inventariado em `ctor-throw-leaks-cpp-new` em vez de ser apresentado como fechado.

### 6. `new QThread` deixou de ser o problema — passou a ser o trampolim

Por decisão do utilizador, e é melhor do que as três opções que eu tinha posto. Um objecto só: a
subclasse gerada, e o `run()` a cair em D. `subclass: ["QWidget", "QThread"]` bastou — o gerador já
produziu `__QThread_vnames = ["event", "run", ...]` sem uma linha de código novo.

A peça que faltava **não é do `QThread`**: o `__ovTramp` é o único ponto por onde qualquer virtual
entra em D, e é lá que uma thread que o druntime nunca viu se regista. O Qt pode chamar qualquer
virtual de uma thread que criou; `QThread::run()` é só o caso onde isso é o propósito. Custo no
caso normal: uma leitura de TLS.

E o primeiro teste disto **não valia nada** — verificava que o TLS lia de volta e que uma alocação
sobrevivia, e passava com o attach desligado, porque nenhuma das duas é observável. Afirma agora o
invariante (`Thread.getThis() !is null` dentro do `run()`), e o controlo negativo dispara.
Qt5 e Qt6, ldc2 e dmd.

### 7. #6: o binding É consumível — o que faltava era alguém tentar, e três coisas caíram em quinze minutos

A auditoria pede *"um exemplo consumidor em diretorio temporario ... sem acessar `generated/` ou
`.build/` do checkout"*. Escrevi-o (`tests/consumer/`, portão `consumer-smoke-{ldc2,dmd}`): as
fontes são copiadas para um directório temporário e a única coisa que aponta de volta são as duas
peças que um pacote instalaria — o import path e os arquivos. Compila e corre nos dois
compiladores.

**A parte que interessa não é o portão, são as três coisas que ele encontrou** — nenhuma delas
visível de dentro do grafo, porque lá dentro ninguém escreve uma aplicação:

| o que se escreve | o que acontecia |
|---|---|
| `new QWidget(null)` | **não compilava** — `null` ambíguo entre o ctor de adopção `this(void*)` e `this(QWidget parent = null, …)`. É a primeira linha do exemplo do README. |
| `w.width()` | **não existe** — vem de `QPaintDevice`, a SEGUNDA base; é `w.asQPaintDevice().width()`. O manifest chama-lhe `inherited`, o que é verdade e é surpreendente. |
| `label.text() == "olá"` | **não compilava** — `QString` construía de `string` e lia para `string`, mas não comparava. |

Duas estão corrigidas: o ctor de adopção passou a levar uma etiqueta (`QtdAdopt`), que era a razão
inteira da ambiguidade e que nenhum utilizador escreve; e `QString` ganhou `opEquals(string)` nos
dois layouts (Qt5 e Qt6). A terceira fica: expor a segunda base como se fosse a primeira é uma
decisão de superfície, não um remendo.

O que continua verdadeiro do achado #6: **os artefactos não estão instalados em lado nenhum**. Um
consumidor a sério nomeia um pacote, não um directório de build. O portão prova a metade que se
pode provar hoje e diz no cabeçalho qual é a metade que não prova.

### 8. O #2 muda de desenho quando se mede: PERGUNTAR quem é o dono é, ele próprio, o use-after-free

Antes de construir a metade "segura" do #2 — as classes que têm uma pergunta de dono — medi o que
acontece do outro lado. `QTreeWidget` apaga os seus items; o wrapper D fica assim:

```
antes: item vivo, _cpp = true
depois de destruir a árvore: _cpp = true   (o wrapper NÃO foi invalidado)
```

`checkAlive()` nunca dispara: o `_cpp` continua não nulo a apontar para um objecto que o Qt já
apagou. Isto é o `nonqobject-qt-owned-dangles` do inventário, agora observado e não deduzido.

**E é isso que derruba a metade que eu ia construir.** O esquema seria: no finalizador, perguntar
`parent()`/`treeWidget()` e só apagar se ninguém for dono. Mas essa pergunta é uma chamada
*através do `_cpp`* — sobre um objecto que pode já ter sido apagado. **A pergunta é o
use-after-free, no exacto momento em que dela se precisa.** Perguntar mais cedo (como o
`reparented()` faz para `QObject`) não salva: entre a última chamada e a colecção, a árvore pode
morrer e o bit fica velho.

Logo não há esquema por OBSERVAÇÃO que funcione para um tipo sem sinal de destruição. Restam dois
desenhos, ambos por decisão e nenhum por remendo:

1. **Largar a posse na CHAMADA que transfere.** `QTreeWidget::addTopLevelItem`, `QLayout::addItem`,
   `QStandardItemModel::setItem` — declarados no typesystem, e o emissor põe um
   `holder.transferred(a0)` onde já põe `holder.reparented(a0)`. Não precisa de perguntar nada
   depois, porque a posse muda no sítio onde a API diz que muda.
2. **Não deixar o D ser dono destes tipos** — construí-los só através das APIs do dono.

**O que NÃO consegui demonstrar, e digo-o:** que a leitura seguinte toca memória libertada. O
valgrind não arranca nesta máquina (falta debuginfo da glibc), o ASan não instrumenta os `delete`
dentro das bibliotecas do Qt, e interpor o `operator delete` no executável não pegou nem com
`--export-dynamic` (duas tentativas). A ausência de invalidação está medida; o resto do argumento é
por construção, e não precisa de mais.

### 9. #2 fechado para uma classe, e o #3 respondido pelo sítio que interessa

**Feito**, pelo desenho que o utilizador escolheu (largar a posse na chamada que transfere). Uma
classe listada em `disposable` fornece um thunk de `delete` e o finalizador do holder chama-o
quando ainda é dono. A política fica no holder, o conhecimento do tipo na classe gerada, e nenhum
dos dois sabe a metade do outro.

Ligado **só** para `QTreeWidgetItem`. As outras ~59 raízes `super(c, false)` do QtWidgets continuam
a vazar, que é o erro seguro. Teste `nonqobject-{ldc2,dmd}` cobre os três estados, e **os dois
controlos negativos foram corridos**:

- sem o `disposable` → estado 1 falha: o órfão é desregistado e o bloco nunca libertado;
- sem a transferência declarada → estado 2 falha: *"a árvore perdeu o item: o binding libertou algo
  que o Qt possui"* — o double-free que este desenho existe para evitar, apanhado pelo teste.

**O teste precisou de três tentativas para ser prova**, e as três falhas são a parte reutilizável:
o mapa de identidade não distingue nada (o `unreg` corre haja ou não delete); um contador global de
frees também não (uma colecção liberta muita coisa); só vigiar UM endereço distingue — e só resulta
porque o `delete` em causa está no shim do próprio binding, compilado no binário.

**A ordem das classes não foi arbitrária, e a razão é documentada.** `~QTreeWidgetItem` retira-se
das árvores — *"This makes it safe to delete an item at any time"* — logo um engano nesta classe
corrige-se sozinho. `~QLayoutItem` diz apenas *"Destroys the QLayoutItem"*: um `QSpacerItem` que
apaguemos por engano deixa o layout com um ponteiro morto. A família `QLayoutItem` exige a lista
completa sem perdão, e por isso não vem a seguir por omissão.

**E o #3 fica respondido onde interessa mais do que no manifest.** A queixa é que `bound` sem
ownership conhecido é apresentado como superfície segura. Em vez de anotar 8428 símbolos com
metadata que ninguém lê, `ownership-gate-*` torna **impossível** a superfície perigosa crescer em
silêncio: para cada classe descartável, todo método gerado que a receba tem de estar classificado
como `transfer_in`, `transfer_out` ou `no_transfer`, e qualquer outro falha o build. O `no_transfer`
existe de propósito — *"não é transferência"* é um achado, não uma ausência; sem ele, um método por
verificar e um verificado-e-inofensivo são indistinguíveis, que é exactamente a queixa do #3.

Encontrou dezanove métodos por classificar no minuto em que foi escrito, e depois mais oito **só no
Qt5** (`setItemSelected`, `setItemHidden`, `setItemExpanded`, `setFirstItemColumnSpanned` e os
getters, que o Qt6 removeu) — uma diferença de superfície entre versões que nenhuma auditoria à
vista teria apanhado.

### 10. O critério que decide se uma classe pode ser descartada NÃO é "tem pergunta de dono"

Ia a seguir para o `QStandardItem` — tem `parent()` e `model()`, portanto pela minha própria
decomposição da secção 4 seria a "metade mecânica". Fui ler o destrutor primeiro:

| classe | o que o destrutor diz |
|---|---|
| `QTreeWidgetItem` | *"The item will be removed from QTreeWidgets to which it has been added. **This makes it safe to delete an item at any time**."* |
| `QStandardItem` | *"Destructs the item. This causes the item's children to be destructed as well."* |
| `QLayoutItem` | *"Destroys the QLayoutItem."* |

**Só o primeiro se DESLIGA do dono.** Os outros dois deixam o dono com um ponteiro morto se nós
apagarmos primeiro — e o dono não tem como saber.

Isso corrige a secção 4: a propriedade que torna uma classe segura de descartar não é *"consigo
perguntar quem é o dono"* (o `QStandardItem` consegue e continua perigoso), é **"o destrutor
desliga-se do dono"**. Com essa propriedade, uma transferência em falta na lista é sobrevivível;
sem ela, é um ponteiro pendurado dentro do Qt.

Por isso o `QStandardItem` **não** foi ligado, apesar de ser o candidato óbvio. Ligar mais uma
classe passa a ter dois requisitos, não um: a caminhada da superfície (que o `ownership-gate` já
exige) **e** um destrutor que se desligue — ou, na falta dele, a certeza de que a lista está
completa, que é uma afirmação muito mais forte.

### 11. #6 FECHADO — e o que faltava não era maquinaria, era ninguém ter tentado

O critério da auditoria: *"um exemplo consumidor em diretorio temporario deve depender apenas de um
artefato instalado/empacotado"*. Está feito: `tests/install.sh` dispõe os artefactos como um pacote
dub e `dub-consumer-{ldc2,dmd}` resolve-o por `dependencies`, compila e corre — a aplicação nunca
nomeia um import path nem um arquivo.

**O pacote inteiro é um import path, dois arquivos e onze linhas de `dub.json`**, e um só pacote
serve os dois compiladores (`lflags-ldc` / `lflags-dmd`). Não havia nada para construir. O que
faltava era o mesmo que faltava aos três papercuts da secção 7: ninguém tinha tentado usar isto de
fora.

Três coisas que só a tentativa ensinou, todas em comentário no sítio:

- os `libs` do dub têm de ser **nomes simples**; passar a linha do `pkg-config` faz um `-lQt6Widgets`
  chegar como `--l-lQt6Widgets`;
- o consumidor corre com `--skip-registry=all`, senão um engano no nome do pacote vai à rede e a
  falha lê-se como problema de ligação em vez de empacotamento;
- e o primeiro build falhou por **corrida no grafo**, não por empacotamento: os dois consumidores
  alcançam o nó de instalação e este backend corre-o uma vez por alvo que lá chega, portanto duas
  instalações correram em paralelo e a que chegou primeiro ao `rm -rf $PREFIX` apagou o que a outra
  estava a copiar. Guardado com lock, como os outros artefactos partilhados. É a terceira vez que
  esta propriedade do backend morde nesta rodada.

Fica por fazer a parte que é distribuição e não engenharia: o pacote aponta para um prefixo local,
não está publicado em lado nenhum, e nada versiona o artefacto contra o Qt minor.

### 12. O filtro de reprodutibilidade ainda era probabilístico, e voltou a produzir um falso vermelho

A secção 1 do meu commit anterior dizia que perguntar ao motor outra vez, em vez de pré-filtrar,
tornava o portão determinístico. **Não tornou**, e a matriz completa apanhou-me: `Material
UNPLACED=1`, o mesmo `SearchField`, cujo frame ao `-O0` bate byte a byte.

A causa é a mesma um nível abaixo. Cinco corridas seguidas do MOTOR sobre o mesmo documento:

```
-535015719, 0, -535015719, 0, 0
```

O valor sai `0` a maior parte das vezes. Uma amostra de cinco pode concordar **por acaso**, o
caminho conta como mensurável, difere do nosso a sério, e o documento sai UNPLACED numa build e
colocado na seguinte. Re-verificar em vez de pré-filtrar reduziu a probabilidade; não a eliminou,
porque nenhuma amostragem finita distingue "o motor reproduz isto" de "o motor deu por acaso os
mesmos bytes N vezes".

Logo o que é conhecido passa a ser **nomeado**: `tests/qmltc/unreproducible.txt` lista a propriedade
com a medição que a condena, e o portão retira-a dos dois lados antes de comparar. A amostragem
fica como rede para as que ainda não conhecemos. Determinístico onde sabemos, probabilístico só
onde ainda não medimos — e a diferença está escrita no ficheiro em vez de implícita.

Material dá agora o mesmo veredicto em três corridas seguidas: **34 compilados, 27 ao `-O0`,
UNPLACED=0**.

**É a segunda vez que esta propriedade produz um falso vermelho e a segunda vez que eu declarei o
portão determinístico cedo demais.** Um filtro probabilístico debaixo de um portão que existe para
não ter falsos positivos é o mesmo defeito um nível acima — escrevi isso da primeira vez e voltei a
construir um.

### O que fica por fazer desta rodada, dito em vez de escondido

**Os sete achados estão respondidos.** Matriz completa verde, 1161 alvos **no dia em que isto foi
escrito** — a adenda no topo traz os números de 2026-08-11 (2224 alvos, 235 documentos do Qt
compilados, 0 segfaults) e o que mudou desde então. Esta lista é o veredicto da RODADA; os
números são os da altura.

- **#1** retornos emprestados: FECHADO. Impasse no `exit()` provado por coredump (§1), `_ownedByD`,
  regressão `borrowed-{ldc2,dmd}`.
- **#2** não-`QObject`: FECHADO para **duas** classes, por dois critérios diferentes e ambos
  verificáveis — `QTreeWidgetItem` porque o destrutor se desliga do dono (§10), `QTextStream` porque
  nada no binding o pode adoptar, logo a superfície é provadamente vazia. As restantes continuam a
  vazar (o erro seguro), e o `ownership-gate` recusa ligar uma sem a superfície classificada.
- **#3** ownership no manifest: respondido pelo `ownership-gate` em vez de uma coluna nova (§9).
  Impedir a superfície perigosa de crescer vale mais do que anotar 8428 símbolos.
- **#4** ctor que lança: FECHADO no emissor, com portão estrutural sobre 1190 construtores (§5). A
  prova de runtime falta e o inventário di-lo.
- **#5** `binding-core`: FECHADO, libsample lá dentro.
- **#6** artefacto instalável: FECHADO (§7, §11). Pacote dub resolvido por dependência nos dois
  compiladores, e o pacote regista contra que Qt foi gerado — o consumidor recusa a discrepância,
  que de outro modo aparece como crash dentro do Qt e não como erro de link. Falta **publicar**,
  que é escolher onde, não construir o quê.
- **#7** inventário: FECHADO, 16 entradas — e passou a ser **executado**, não só validado.

**Fechados de rondas anteriores, pelo caminho:** o inventário como runner (r7, 16 probes, um deles a
vigiar uma *correcção* em vez de uma regressão); piso e canários da suíte qmltc na CI (r10); e a
medição que o `CompilationContext` (r9) pedia — dois documentos locais com nomes colidentes provam
que o estado **não** atravessa, portanto o refactor é preventivo com prova em vez de justificado por
bugs já corrigidos.

**Aberto, e nomeado:** CI verde num runner real (o Qt da distro é outro minor que as baselines; não
se fecha desta máquina); mais classes descartáveis (cada uma exige a caminhada por classe); publicar
o pacote.

## Rodada 12: o wrapper aprendeu muito com o qmltc-d; ownership ainda nao e geravel por heuristica

### Enquadramento desta rodada

As duas semanas investidas no `qmltc-d` nao foram duas semanas retiradas do binding. A ferramenta
foi ao mesmo tempo consumidor, oracle e teste de pressao do wrapper generator. O historico recente
mostra ganhos concretos no produto-base: wrapper como caminho principal, identidade, parenting
pins, invalidacao por `destroyed()`, dispatch virtual correto, retornos de value types, meta-object,
deep bindings e varios defeitos que uma aplicacao pequena nunca teria provocado.

O criterio desta rodada e justamente dar credito a esse efeito sem cometer o erro inverso: concluir
que o wrapper inteiro esta seguro porque o consumidor mais exigente esta verde. O `qmltc-d` pressiona
fortemente `QObject`, QML, QtQuick e meta-object. Ele quase nao pressiona os casos em que o binding
precisa decidir ownership de um ponteiro retornado, nem os objetos polimorficos de Qt que nao derivam
de `QObject`. Foi nessa fronteira que apareceram os achados mais graves.

### Verificacao observada

- A arvore estava limpa no inicio. Durante a auditoria surgiram alteracoes concorrentes, que foram
  preservadas: `docs/qmltc-d.md` foi movido para `docs/qmltc-d-journal.md` e
  `tools/qmltc/qmltc_d.cpp` ganhou `--no-main`. Nenhum achado abaixo depende desses trechos instaveis.
- `./build --list` oferece **1126 top-level targets**: 1123 obrigatorios e 3 opcionais.
  **918 dos 1123 obrigatorios (81,7%)** pertencem as familias `qmltc*`, `shadowaot-*` ou
  `leaf-lifetime-*`. O corpus libsample esta presente com 58 targets.
- `report-selftest` passou: **1126 classificados, 0 unclassified**.
- `expected-fails-lint` passou: **11 entradas validas**, 3 riscos e 10 probe targets existentes.
- Os tres manifest gates observados passaram contra Qt 6.11: QtWidgets (8428 simbolos), QML
  (2593) e Controls (10301).
- `binding-core` encontrou uma dependencia operacional no cache global do dub: dentro do sandbox,
  `lupdate-check` tentou remover `~/.dub/.../libdparse.a` e falhou por filesystem read-only. Executado
  isoladamente com acesso normal ao cache, `lupdate-check` passou. Nao e falha funcional do extrator,
  mas o agregado nao e hermetico ao workspace.
- A matriz completa foi iniciada e exercitou com sucesso os eixos centrais observados (Qt5/Qt6,
  dmd/ldc2, wrapper, moc, uic, qrc, WebEngine, libsample e manifests). Como fontes mudaram enquanto
  ela rodava, esta rodada nao usa essa execucao como prova atomica de um checkout especifico.
- Um probe C++ contra o Qt instalado mediu `QThread::currentThread()` no main thread:
  o objeto retornado estava **sem parent** e `isRunning()==true`. A documentacao oficial do Qt avisa
  que [apagar um `QThread` em execucao causa crash](https://doc.qt.io/qt-6/qthread.html#dtor.QThread).
- Na binding QtWidgets gerada, ha 60 modulos cuja raiz chama `super(c, false)` (wrapper polimorfico
  nao-`QObject`). Pelo menos 14 dessas raizes constroem objetos no heap C++; a contagem nao inclui
  derivados como `QSpacerItem`, que herdam o estado `false` de `QLayoutItem`.

### O que as duas semanas realmente compraram para o binding

1. **O `qmltc-d` provou ser um excelente north-star consumer.** Ele obrigou o wrapper a sobreviver
   a arvores dinamicas, meta-objects, propriedades, sinais, tipos de valor, subclassing e APIs Qt
   privadas numa combinacao que os exemplos Widgets nao oferecem. Isso e engenharia do binding,
   ainda que o defeito tenha sido descoberto pelo compilador QML.

2. **A barra de qualidade e excepcionalmente boa onde existe oracle.** UIC contra QUiLoader, QML
   contra o engine, frame + propriedades, manifests por USR e libsample sao evidencias melhores do
   que uma contagem de metodos compilados. A correcao de deep-leaf identity da rodada anterior e um
   bom exemplo: o consumidor revelou a falha, e a solucao terminou como invariante do runtime.

3. **O desenho `extern(C++)` continua tecnicamente valioso.** Modulos a la carte, shims somente onde
   a ABI exige e output gerado sob demanda formam uma proposta distinta de um wrapper C por classe.
   Os problemas abaixo nao invalidam esse desenho; eles mostram que ABI correta e lifetime correto
   sao contratos separados.

### Achados criticos

#### 1. Todo `QObject*` sem parent e tratado como D-owned, inclusive retornos emprestados

O holder nao recebe ownership como dado. Ele o infere no finalizador:

```d
if (_isQObj && _cpp !is null && qtd_holder_has_parent(_cpp) == 0
        && qtd_holder_is_app(_cpp) == 0)
    qtd_holder_delete_later(_cpp);
```

Essa regra e valida para um `new QObject()` criado pelo binding, mas nao para todo ponteiro que uma
API Qt retorna. O emitter usa a mesma operacao para ambos: `T.wrap(pointer)`. Um caso concreto ja
esta na superficie gerada:

```d
static QThread currentThread() { return QThread.wrap(__QThread_1()); }
```

No probe, esse `QThread` estava sem parent e em execucao. Se nao existir wrapper anterior, `wrap`
cria um wrapper D, registra o ponteiro e, quando esse wrapper cair no GC, agenda `deleteLater()` no
`QThread` que representa a thread corrente. `qtd_holder_is_app` protege apenas o singleton da
aplicacao. Parenting nao distingue “objeto que D criou” de “singleton/borrowed que Qt devolveu”.

Ha outros candidatos da mesma forma (`QThreadPool.globalInstance`,
`QItemEditorFactory.defaultFactory`, `QErrorMessage.qtHandler`, dispositivos de input etc.). Nao e
seguro corrigir por uma lista de singletons: o defeito e o tipo de ownership estar ausente da API
interna do wrapper.

**Impacto:** use-after-free/crash dentro do Qt, provocado de forma nao deterministica pelo GC, em
uma chamada que parece ser apenas um getter.

**Criterio de resolucao:**

- carregar no wrapper um estado explicito, no minimo `OwnedByD`, `Borrowed` e `OwnedByQt`;
- fazer construtores gerados nascerem `OwnedByD` ate uma transferencia comprovada;
- fazer retornos de ponteiro nascerem `Borrowed` por default, promovendo a owned apenas por regra
  especifica da API;
- consumir regras de ownership do typesystem ou manter overrides declarativos equivalentes por
  metodo; parentagem pode atualizar pins, mas nao decidir a origem do ownership;
- adicionar probes GC para `QThread.currentThread()`, `QThreadPool.globalInstance()` e pelo menos um
  getter de objeto externo, exigindo que o objeto continue vivo e nunca receba deferred-delete.

#### 2. Wrappers polimorficos nao-`QObject` vazam quando D owns e ficam pendurados quando Qt owns

O runtime marca classes sem `QObject` com `_isQObj=false`. O comentario as chama de
“dispose-only”, mas nao existe dispose no holder. O finalizador apenas faz `unreg`; nao chama o
destrutor C++ nem `operator delete`.

Isso e observavel em tipos publicos e comuns:

- `new QTreeWidgetItem()` aloca 96 bytes com `__cpp_new`, executa o construtor por placement e
  registra o wrapper. Se nunca for inserido numa arvore, o GC remove a entrada do identity map e
  vaza o objeto C++ inteiro.
- `new QSpacerItem(...)` faz o mesmo. Ao entrar num layout, o layout toma ownership do item, mas
  `QLayoutItem` nao e `QObject`: nao ha `parent()`, `destroyed()` nem pinning no protocolo atual.
- Um `QTreeWidget` toma ownership dos seus items. Quando a arvore C++ os apaga, o wrapper D nao
  recebe invalidacao. `_cpp` continua nao nulo; a proxima chamada atravessa um dangling pointer em
  vez de `checkAlive()` falhar.

Qt documenta explicitamente que
[`QBoxLayout::addSpacerItem` recebe ownership](https://doc.qt.io/qt-6/qboxlayout.html#addSpacerItem)
e que [`QTreeWidget` recebe ownership dos items](https://doc.qt.io/qt-6/qtreewidget.html#addTopLevelItem).
Portanto, esse dominio nao pode ser reduzido ao object tree de `QObject`.

**Impacto:** leak deterministico no caminho D-owned e use-after-free/possivel double ownership no
caminho Qt-owned. O teste `spacer` prova construcao e layout, mas nao lifetime; os testes de
`ownership.d` provam apenas objetos com `destroyed()`.

**Criterio de resolucao:**

- emitir um destructor thunk por classe polimorfica nao-`QObject` e chama-lo somente para handles
  `OwnedByD`, seguido de `operator delete`;
- modelar transferencias em APIs como `QLayout::addItem`, `QTreeWidget::addTopLevelItem`,
  `takeTopLevelItem`, `QStandardItemModel::setItem` e equivalentes;
- quando Qt assume ownership de um tipo sem sinal de destruicao, ou instalar um mecanismo de
  invalidacao no owner, ou recusar um wrapper retido que nao possa ser tornado seguro;
- adicionar testes de tres estados: unattached coletado/destruido, transferencia para Qt sem
  double-delete e destruicao do owner invalidando o wrapper; cobrir ao menos `QSpacerItem`,
  `QTreeWidgetItem` e `QStandardItem`.

#### 3. Os manifests chamam esses metodos de `bound`, mas nao possuem eixo de ownership

O manifest gate responde “o simbolo continuou presente e sua fate nao piorou”. Ele nao responde
“o ponteiro retornado tem lifetime correto”. Assim, `QThread::currentThread`,
`QTreeWidget::addTopLevelItem` e os construtores de `QTreeWidgetItem` podem permanecer verdes na
baseline enquanto a API publica e insegura.

Esse nao e um defeito do manifest como gate de simbolos; e uma promessa excessiva quando ele e
usado como proxy de cobertura do binding. A coverage atual mistura disponibilidade e usabilidade.

**Criterio de resolucao:** anexar metadata de ownership/transferencia ao manifest para todo
parametro/retorno de object wrapper, com fate explicita (`owned`, `borrowed`, `transfer-in`,
`transfer-out`, `ownership-unknown`). `ownership-unknown` deve ser uma recusa ou um risco
inventariado, nao um `bound` indistinguivel.

### Achados altos

#### 4. Construtor que lanca deixa o bloco de `__cpp_new` sem cleanup

O emitter gera, em centenas de modulos:

```d
auto __r = __cpp_new(__T_size);
ctor(__r, ...);
this(__r);
_register();
```

Se o construtor C++ lanca e a camada Lippincott o converte em `QtCppException`, o wrapper nunca e
registrado e nenhum finalizador conhece `__r`. O bloco alocado antes do placement construction fica
perdido. O mesmo vale para falhas parciais em ctors shimmed. A suite prova que a excecao e observavel,
mas nao que o caminho e exception-safe.

**Criterio de resolucao:** um scope guard libera `__r` com `__cpp_delete` se o construtor nao
terminar; o guard so e cancelado depois de `this(__r)` + `_register()`. Um fixture com construtor que
lanca repetidamente deve medir alloc/free balance.

#### 5. `binding-core` exclui o corpus mais independente do generator

O agregado foi criado para responder se “generator, runtime, uic, qrc, moc, webengine and gates”
estao saudaveis, mas sua selecao e:

```d
auto core = pick(n => !isQmltc(n) && !n.startsWith("sample_"));
```

Ou seja, exclui deliberadamente os 58 targets de libsample. Esse e justamente o corpus desenhado
fora deste repositorio para corner cases de binding: MI, overloads, referencias, function pointers,
move-only, operators e exceptions. Um `binding-core` verde pode coexistir com uma regressao do
gerador que libsample detectaria.

Tambem nao existem os agregados `runtime` e `release` recomendados na rodada 11. Ha apenas
`binding-core`, `qmltc-smoke` e `qmltc-corpus`; o build default funciona como release por convencao,
nao por um contrato nomeado.

**Criterio de resolucao:** incluir libsample em `binding-core` quando o corpus estiver provisionado
e fazer a ausencia dele falhar esse agregado (ou separar explicitamente `binding-smoke` de
`binding-conformance`). Criar `runtime` e `release`; o ultimo deve exigir os canarios de corpus e os
gates que a versao do Qt torna aplicaveis.

#### 6. O projeto ainda nao entrega um binding consumivel fora do proprio grafo de testes

O root `dub.json` tem `targetType: none`; `:runtime` e `sourceLibrary` e admite nao compilar sozinho;
`generated/` e integralmente ignorado; os specs de produto gravam em diretorios versionados de
teste; e o README ensina a gerar e rodar a matriz, nao a consumir o resultado de uma aplicacao D.

Isso e coerente para desenvolvimento, mas ainda nao e um release de binding. Hoje nao ha contrato
documentado para:

- gerar somente os modulos Qt desejados para a versao instalada;
- compilar/instalar `libbinding` + shims + runtime como artefato reutilizavel;
- declarar imports e link flags num `dub.json` consumidor;
- versionar o artefato contra Qt minor, dmd/ldc2 e ABI do runtime;
- executar um smoke test a partir de um projeto externo, sem imports relativos ao checkout.

O novo `--no-main` concorrente e um passo correto para tornar `qmltc-d` consumivel, mas a mesma
fronteira ainda falta ao produto-base sobre o qual ele depende.

**Criterio de resolucao:** um exemplo consumidor em diretorio temporario deve depender apenas de um
artefato instalado/empacotado, criar uma aplicacao Qt minima com `new`, compilar em dmd e ldc2 e
rodar sem acessar `generated/` ou `.build/` do checkout.

#### 7. O inventario estruturado omite exatamente os riscos de lifetime que a documentacao admite

`docs/test-suite.md` lista “non-QObject” entre os ownership follow-ups. Mas
`tests/expected-fails.json`, apresentado como structured state de gaps/riscos, nao possui entrada
para non-QObject, borrowed returns ou exception safety de construtor. Por isso
`expected-fails-lint OK` e verdadeiro ao mesmo tempo em que tres gaps de lifetime publicos nao
aparecem no inventario.

Enquanto nao houver runner, o minimo e o inventario ser completo. Caso contrario, a rigorosidade
do schema valida apenas uma amostra escolhida dos gaps.

### Achados estruturais que permanecem, agora com prioridade corrigida

- Separar helpers especificos de `qmltc-d` do runtime moc continua desejavel, mas e menos urgente
  que corrigir o ownership do wrapper comum.
- Um `CompilationContext` explicito ainda e a direcao correta para o compilador QML, mas nao deve
  competir com a correcao dos handles que toda aplicacao D/Qt usa.
- A CI continua documentada como scaffold nao comprovado verde, e manifests cobrem apenas Qt 6.11
  para tres bindings. Para um binding que pretende acompanhar Qt por regeneracao, uma matriz real
  de pelo menos um Qt distro + o Qt de baseline e parte do produto, nao acabamento.
- A dependencia do cache global do dub torna `binding-core` menos reproduzivel em sandbox/CI.
  Um cache configuravel dentro do workspace ou uma imagem de CI imutavel eliminaria essa variavel.

### Prioridade brutal da rodada 12

1. Introduzir ownership explicito no handle e impedir que retornos borrowed caiam no finalizador
   D-owned; fechar primeiro `QThread.currentThread()` com um probe que hoje seria destrutivo.
2. Implementar ou recusar lifetime de polimorficos nao-`QObject`; provar `QTreeWidgetItem`,
   `QSpacerItem` e `QStandardItem` em owned/transfer/destroy.
3. Tornar construtores exception-safe em torno de `__cpp_new`.
4. Fazer ownership aparecer no manifest e no expected-fails; `bound` sem ownership conhecido nao
   pode ser apresentado como superficie segura.
5. Corrigir os agregados: libsample dentro da resposta de conformance do binding, mais `runtime` e
   `release` explicitos.
6. Criar um consumer smoke externo e um artefato instalavel; sem isso ha um excelente laboratorio
   de binding, ainda nao um binding distribuivel.
7. Depois disso, retomar as fronteiras internas do `qmltc-d` (`CompilationContext`, runtime split)
   sem perder o papel dele como stress-test principal.

### Sintese para decisao

O saldo das duas semanas e positivo: o `qmltc-d` fez o wrapper generator crescer em pontos que
importam e hoje e o melhor teste de integracao do projeto. A conclusao desta rodada nao e reduzir
esse investimento. E usar a maturidade conquistada para atacar o proximo contrato que o corpus
QML quase nao enxerga.

O wrapper atual sabe responder **identidade** e, para `QObject` parentado, boa parte de
**lifetime**. Ele ainda nao sabe responder **ownership por API**. Sem essa terceira resposta, um
getter pode agendar a destruicao de um objeto emprestado, e um objeto nao-`QObject` pode vazar ou
ficar pendurado. Isso e mais importante para publicar um binding Qt para D do que aumentar agora a
porcentagem de documentos compilados pelo consumidor. Corrigir essa fronteira fortalece os dois:
o binding se torna seguro fora do QML, e o `qmltc-d` passa a apoiar-se numa camada que pode ser
distribuida com uma promessa real de ownership.

## Resposta à rodada 11 (escrita a 2026-08-12)

Esta rodada nunca teve resposta escrita aqui. Verifiquei os oito achados contra o código de hoje
antes de escrever uma linha. **Seis fechados, dois abertos — e os dois abertos estão PIORES do que
quando a auditoria os levantou.** Digo-o com o número, porque é o que dá peso ao resto.

- **#1 a tabela de deep bindings colide owners: FECHADO.** `qtd_leaf_key` começa hoje por
  `snprintf("%p|%p|", owner, recv)` — o owner ESTÁ na identidade, e o comentário no sítio diz
  porquê, com o caso que o obrigou (`mid.indicator.width + outer.indicator.width` produzia duas
  subscrições idênticas em tudo menos no owner). A limpeza que a auditoria pediu existe
  (`qtd_leaf_watch` sobre owner e receiver) e a prova também: `tests/qmltc/leaf_lifetime.d` exige a
  side-table de volta ao baseline depois de destruir a árvore, através de `qtd_leaf_table_size()`,
  exportado exactamente para isso — uma sonda não pode provar a limpeza de fora, porque as entradas
  são invisíveis.
- **#2 o gate aprovava `values-differ`: FECHADO, pela via que a própria auditoria admitia.** Não
  existe hoje um estado "COMPILED values-differ": um documento que falhe QUALQUER dos dois eixos é
  **DEMOTED to -O0**, onde o motor corre o documento e ambos os eixos voltam a valer. O portão
  continua a exigir `UNPLACED=0`, e isso passou a bastar porque a categoria que ele aprovava deixou
  de existir. **Meio aberto e digo qual metade:** `unjudgeable` continua a ser contado e impresso
  mas não gatilhado — são 45 documentos, e estão nomeados por natureza em `docs/qmltc-d.md`
  ("The 45 unjudgeable": um delegate precisa de uma view, uma `Action` não se desenha), e
  explicitamente **não** contados como passes. É inventário em prosa, não em ficheiro.
- **#3 o gate preso à workstation: FECHADO quanto aos caminhos.** `o3.sh` deriva `ROOT` do próprio
  ficheiro (`cd -- "$(dirname -- "$0")/../.."`), e `L`/`G` são argumentos com omissão relativa a
  esse root; o Qt é descoberto por `qtpaths6`/`qtpaths`/`qmake6`/`qmake`, com o cuidado de um probe
  ausente não abortar o grafo. E o canário que a auditoria pediu existe com esta forma: **um estilo
  em falta é um portão VERMELHO, não um portão que desaparece** — Controls ausente é um skip
  honesto, Controls presente com um estilo em falta falha. Fica aberto o que já estava nomeado no
  fecho da rodada 12: **CI verde num runner real**, que não se prova desta máquina.
- **#4 o build default do gerador era o build do qmltc-d: FECHADO.** Existe `binding-core`, que
  agrega gerador, runtime, uic, qrc, moc, webengine e os seus portões sem o grafo do qmltc-d.
- **#5 estado do compilador QML no runtime partilhado: ABERTO, E PIOR.** A auditoria escreveu
  "`qtdmoc.cpp` já passa de duas mil linhas"; hoje tem **2533**, com **49** guardas `QTD_HAVE_QML`.
  E o lado D ganhou dois globais mutáveis **hoje**: `__qmltcPending` (a pilha de completação, para
  reproduzir a ordem inversa do motor) e `__qmltcDeferred` (as construções que o Qt difere). Ambos
  são estado de um compilador QML a viver em `qtmoc.d`, que é o contrato geral de meta-object. A
  fronteira `qmltc_runtime` que a auditoria recomendou continua por fazer e cada correcção destas
  torna-a mais cara. Não tenho desculpa a dar: escolhi o avanço local outra vez, com o mesmo
  argumento de sempre, e o argumento continua a ser o que a auditoria já classificou.
- **#6 o compilador sem contexto explícito: ABERTO, E PIOR.** A auditoria contou ~10.465 linhas em
  `tools/qmltc/qmltc_d.cpp`; hoje são **11.197**. A medição que a rodada 9 pedia foi feita e está no
  fecho da rodada 12 — dois documentos locais com nomes colidentes provam que o estado **não**
  atravessa —, o que torna o `CompilationContext` preventivo e não correctivo. Preventivo não é
  desnecessário: o ficheiro cresceu 7% desde que isto foi escrito.
- **#7 as fontes públicas descreviam o binding pré-wrapper: FECHADO.** O `README.md` diz hoje que o
  flip está feito e que **não existe** `X_new` em lado nenhum; `docs/FEATURES.md` chama-lhe
  INACEITÁVEL; `docs/test-suite.md` não fala de baselines raw.
- **#8 o inventário era estado validado e não comportamento executado: FECHADO** na rodada 12
  (`expected-fails-run`, hoje 23 alvos de sonda executados, 24 entradas).

**O que esta rodada me ensinou, e que vale mais do que os seis fechos:** dois achados
estruturais ficaram abertos durante duas rodadas e a métrica de ambos ANDOU PARA TRÁS enquanto eu
fechava coisas locais. Um portão mede o que eu lhe mando medir; nenhum destes dois tem portão, e é
por isso que só a auditoria os vê.

## Rodada 11: o gerador e seu consumidor mais valioso precisam de uma fronteira

### Enquadramento corrigido

O produto-base deste repositório é o **gerador de bindings Qt para D**. O `qmltc-d` é
uma ferramenta construída sobre esses bindings, é o stress-test mais exigente do
gerador e, ao mesmo tempo, é hoje o artefato individual com maior valor para publicação.
Esses papéis não se contradizem. Pelo contrário: o `qmltc-d` já encontrou defeitos de
ABI, lifetime, meta-object, resolução de tipos, virtual dispatch e reatividade que uma
suíte pequena do gerador não encontraria.

A crítica, portanto, não é que o `qmltc-d` "desvia" o projeto, nem que deva ser
rebaixado a exemplo. O ponto é mais preciso: **um consumidor de alto valor extrapola
seu papel de stress-test quando passa a impedir que o produto-base seja compreendido,
testado e liberado de forma independente**. É essa fronteira que ainda falta.

### Verificação desta rodada

- A árvore já tinha uma alteração local em `tests/qmltc/o3.sh`; ela foi preservada e
  faz parte da análise abaixo.
- `./build --list` oferece **1100 targets default**. **895** pertencem às famílias
  `qmltc*` e relacionadas: aproximadamente **81% do grafo obrigatório**. A contagem
  não mede valor de produto nem linhas de código, mas mede claramente quem governa o
  custo e o resultado do build default.
- `report-selftest` passou: **1100 classificados, 0 unclassified**.
- `expected-fails-lint` passou: **11 entradas válidas**, 3 riscos e 10 probe targets
  existentes. Como documentado, isso valida o inventário; não executa um protocolo de
  expected-fail nem detecta unexpected pass.
- `git diff --check` passou.
- Não executei os 1100 targets nesta rodada. Logo, esta crítica não afirma que o build
  default atual está verde.
- `dub test` em `generator-d/` não oferece hoje uma suíte unitária autônoma do gerador:
  o dub tenta gerar um test runner para a configuração executable, avisa que faltam
  `mainSourceFile`/import paths e, nesta execução, parou também no cache dub global
  read-only. A matriz reggae continua sendo a validação de fato.

### O que o projeto faz excepcionalmente bem

1. **O desenho central continua forte.** Gerar módulos D que manglam diretamente para
   símbolos Qt com `extern(C++)`, mantendo trampolines apenas onde a ABI exige, é uma
   proposta técnica distinta e valiosa. O output à la carte e não commitado é uma boa
   disciplina para um binding de superfície tão grande.

2. **O `qmltc-d` é um ótimo stress-test do binding.** Ele força simultaneamente
   subclassing, meta-object dinâmico, propriedades, sinais, ownership, tipos de valor,
   containers, Qt private API e comportamento do engine. Várias correções registradas
   nas rodadas anteriores nasceram exatamente dessa pressão. Publicá-lo como produto
   não enfraquece esse papel; dá a ele um consumidor real.

3. **Os oracles diferenciais são o maior ativo de qualidade do repositório.** Comparar
   contra QUiLoader e contra o próprio QML engine encontra divergência sem exigir que o
   teste reimplemente a especificação do Qt. Os manifests por símbolo também são muito
   superiores a uma porcentagem agregada de cobertura.

4. **A documentação costuma distinguir recusa, delegação e prova.** O README atual é
   especialmente honesto sobre o corpus de Controls, sobre documentos unjudgeable e
   sobre a impossibilidade de transferir automaticamente um critério por documento para
   uma aplicação inteira.

### Achados críticos

#### 1. A tabela de deep bindings ainda colide owners e perde reatividade silenciosamente

`qtd_bind_leaf(owner, prop, sig, recv, slot)` guarda a conexão em `g_leafConn`, mas
`qtd_leaf_key` usa apenas:

```text
recv | slot | prop | sig
```

O `owner`, embora determine qual property e qual leaf estão sendo observados, não entra
na identidade. Duas dependências com a mesma forma e owners diferentes compartilham a
chave; a segunda desconecta a primeira em `runtime/qtmoc/qtdmoc.cpp:1022-1038`. A API
retorna sucesso para ambas e não produz PARTIAL nem diagnóstico. Esta é uma divergência
silenciosa da semântica reativa do QML e permanece aberta desde a rodada 10.

`g_leafConn` também não demonstra limpeza quando owner ou receiver morrem. O Qt invalida
a connection, mas a entrada da side-table permanece até uma reutilização daquela chave.
Com delegates e árvores dinâmicas, isto deixa de ser detalhe de teste e vira lifetime
do produto publicável.

**Critério de resolução:**

- incluir `owner` na identidade;
- remover a entrada quando owner ou receiver forem destruídos;
- adicionar um diferencial com dois paths homônimos, mutando cada leaf separadamente;
- adicionar um probe que exija a side-table de volta ao baseline após destruir a árvore.

#### 2. O novo eixo de valores do O3 observa uma falha, mas o gate ainda a aprova

A alteração local em `tests/qmltc/o3.sh` acrescenta a comparação `--dumpall` e distingue:

```text
COMPILED values-differ
COMPILED values-unmeasured
```

Isso melhora muito o diagnóstico: frames idênticos não provam estado nem reatividade
idênticos. Porém os dois casos dão `continue`, e `o3GateTargets()` continua aprovando a
execução apenas com:

```sh
grep -q "UNPLACED=0"
```

Assim, o relatório pode declarar divergência de valores e o gate permanecer verde. O
stress-test encontrou um eixo melhor, mas ainda não o transformou em contrato.

**Critério de resolução:** `values-differ` deve demover o documento para `-O0` ou falhar;
`values-unmeasured` deve ser uma categoria explicitamente aceita por inventário, ou
falhar. O gate deve exigir zero para ambas enquanto a promessa usar a palavra "same".

#### 3. O gate O3 está preso à workstation e não sustenta a publicação do qmltc-d

`tests/qmltc/o3.sh` fixa:

```text
/home/caetano/lab/qt-dlang-gen/.build/qt-6.11-cxx-controls
/home/caetano/lab/qt-dlang-gen/generated/qt-6.11/cxx-controls
```

E `o3GateTargets()` só cria targets quando encontra estilos em
`/usr/lib/qt6/qml/QtQuick/Controls/<Style>`. Outra distribuição pode instalá-los sob
um diretório multiarch, e um checkout de CI certamente não vive em `/home/caetano`.
Logo o gate pode falhar por path ou, pior, desaparecer do grafo.

A CI admite ser um scaffold nunca comprovado verde num runner real. Isso é honestidade,
mas não basta para publicar o `qmltc-d` nem para afirmar portabilidade do gerador. Um
canário deve exigir que os cinco gates O3 existam; os paths devem vir do `root`, do
`QtdBinding` e da descoberta Qt (`QLibraryInfo`/`qtpaths`), nunca de uma home específica.

### Onde o qmltc-d extrapolou o papel de consumidor/stress-test

#### 4. O build default do gerador é, operacionalmente, o build do qmltc-d

Ter 895 de 1100 targets relacionados a `qmltc` não é defeito por si só; é consequência
de um corpus grande e de vários eixos diferenciais. A extrapolação está em todos eles
serem parte do mesmo default indivisível. Hoje não há uma resposta simples e executável
para perguntas diferentes:

1. o gerador de bindings está saudável?;
2. o runtime base está saudável?;
3. o `qmltc-d` está saudável em seu corpus completo?;
4. o pacote publicável inteiro está pronto para release?

O grafo sabe construir alvos individuais, mas não expõe contratos de topo claros para
essas quatro respostas. Uma regressão ou custo no corpus de Controls governa o resultado
e o tempo do produto-base, mesmo quando o gerador, manifests, wrapper, moc, uic e qrc
continuam corretos.

**Recomendação:** manter um `./build` completo para release, mas criar agregados explícitos
e obrigatórios, por exemplo `binding-core`, `runtime`, `qmltc-smoke`, `qmltc-corpus` e
`release`. Isto separa diagnóstico e ownership sem enfraquecer o stress-test.

#### 5. Estado específico do compilador QML vazou para o runtime compartilhado

`runtime/qtmoc/qtdmoc.cpp` já passa de duas mil linhas e reúne o meta-object geral com
helpers de contexto, engine, propriedades `var`, bindings profundas, engine-created
children e delegação necessários ao `qmltc-d`. O guard `QTD_HAVE_QML` provou que um
binding sem QtQml ainda compila, o que resolve o vazamento de link observado antes, mas
não cria uma fronteira de manutenção.

O risco é o produto-base não conseguir evoluir ou provar seu runtime moc sem carregar
estado e lifecycle de um compilador QML. A separação recomendada não é remover esses
helpers: é movê-los para uma unidade `qmltc_runtime` ligada apenas pelos bindings que os
usam, mantendo em `qtmoc` o contrato geral de meta-object.

#### 6. O compilador cresceu sem um contexto explícito porque o stress-test premiou avanço local

`tools/qmltc/qmltc_d.cpp` tem aproximadamente **10.465 linhas** e dezenas de globais
mutáveis: documento atual, source stacks, outer chain, registry, funções, dependencies,
shadows, aliases, tipos e flags de emissão. Muitos comentários dizem que um campo é
"saved/restored around compileObject". Isso é um `DocumentContext` implícito distribuído
pelo arquivo.

Como stress-test interno, correções locais rápidas foram produtivas: cada nova fixture
pressionou o binding e aumentou a cobertura. Como produto publicável, o mesmo padrão
vira risco de regressão não local, falta de reentrância e dificuldade de testar resolver,
inferência e emissão isoladamente. Os bugs históricos de documento errado, source slice,
outer scope e resolução duplicada são sintomas dessa ausência de fronteira, não acidentes
independentes.

Não é necessário parar features para uma reescrita. O caminho seguro é introduzir um
`CompilationContext` incremental e migrar um cluster por vez, começando por source/document
identity e dependency tracking, os dois clusters com falhas silenciosas já observadas.

### Achados altos de governança

#### 7. As fontes públicas ainda descrevem o binding anterior ao wrapper flip

Os specs principais (`qtwidgets`, `qml`, `quick`, `controls`, `webengine`) estão com
`"wrapper": true`, e o gerador registra que `X_new` foi removido. Mesmo assim:

- `README.md:56-62` diz que raw ainda é default e mostra `X_new` como API corrente;
- `README.md:233-238` ainda coloca o wrapper flip no roadmap;
- `docs/FEATURES.md:9-25` chama raw de default e wrapper de gated;
- `docs/test-suite.md:67-77` ainda fala em baselines raw e em aproximadamente 162
  targets, contra 1100 atuais.

Para o gerador, isso é um defeito de produto: um novo usuário aprende uma API inexistente
e não sabe qual modo é suportado. O README principal deve ser corrigido antes da publicação
do `qmltc-d`, porque ele é também a apresentação da plataforma sobre a qual a ferramenta
foi construída.

#### 8. O inventário de expected-fails ainda é estado validado, não comportamento executado

O linter atual é bom: schema estrito, IDs únicos, kinds conhecidos e probe targets reais.
Mas `known_gap.remove_when` continua sendo prosa que nada avalia. Um gap pode ser resolvido
e permanecer listado; um risco pode ter target existente sem que o linter execute esse
target. O documento reconhece corretamente essa limitação.

O próximo passo deve ser um runner que associe cada entrada executável a resultado e
diagnóstico esperado, rejeite unexpected pass e permita expiração. Isto importa mais agora
que `qmltc-d` será publicado: sua fronteira de suporte precisa ser consultável por máquina,
não apenas por leitores atentos.

### Prioridade brutal da rodada 11

1. Corrigir identidade e lifetime de `g_leafConn`, com diferencial e probe de limpeza.
2. Fazer o eixo de valores participar realmente do gate O3.
3. Remover paths absolutos e provar os gates num runner CI real.
4. Corrigir README, FEATURES e test-suite para wrapper-only e 1100 targets atuais.
5. Criar agregados `binding-core` / `qmltc-smoke` / `qmltc-corpus` / `release`, mantendo
   o corpus completo obrigatório no release sem fazer dele a única resposta do build.
6. Extrair `qmltc_runtime` do runtime moc compartilhado.
7. Introduzir `CompilationContext` incremental no `qmltc-d`.
8. Transformar o expected-fails linter em runner de comportamento.

### Síntese

O `qmltc-d` não é uma distração: ele é a demonstração mais forte do valor do gerador e
provavelmente seu melhor vetor de adoção. O problema atual é justamente ele ser valioso
demais para continuar dependendo de paths locais, estado global implícito e um build cuja
única granularidade conceitual é "tudo". Dar fronteiras próprias ao gerador e ao `qmltc-d`
fortalece os dois produtos: o primeiro ganha um contrato reutilizável; o segundo ganha um
release reproduzível e uma promessa que seus gates realmente fazem cumprir.

## Resposta à rodada 10 (escrita a 2026-08-12)

Mesmo método: verificar antes de escrever. **Cinco fechados, um aberto e inalterado, um aberto e
pior** — este último é o mesmo #6 da rodada 11, contado outra vez porque atravessou duas rodadas.

- **#1 a fixture de ausência deliberada derrubava o build: FECHADO, e pela boa razão.** A auditoria
  ofereceu duas saídas — tirar a fixture do glob, ou um alvo de recusa esperada — e nenhuma foi
  usada, porque a terceira aconteceu: **`Component` aterrou**. `tests/qmltc/controls/CDelegate.qml`
  é hoje o diferencial positivo que o próprio achado descrevia como destino final (os itens
  existem, batem certo propriedade a propriedade, e uma ligação DENTRO de um item que lê o
  documento envolvente tem o valor do motor), e `qmltcc-CDelegate-all-ldc2` sai zero. Verificado
  agora, não recordado.
- **#2 duas dependências profundas homónimas desligavam-se: FECHADO** — é o #1 da rodada 11, e a
  prova está lá: owner na chave, limpeza nas duas pontas, `leaf_lifetime.d` a exigir a tabela de
  volta ao valor de base.
- **#3 as fontes públicas: FECHADO** (ver #7 da rodada 11).
- **#4 o inventário aceitava um gap já resolvido: FECHADO, e a prova apareceu hoje por acidente.**
  O `expected-fails-run` não valida prosa: executa a sonda de cada entrada. Hoje, quando a inversão
  da ordem de completação passou a funcionar, o alvo falhou com esta frase —
  *"`qmltc-optlevels-controls-Basic` FAILED — it is the probe for `completion-order-not-reversed`,
  so that entry now describes a protection that is not there"*. É exactamente o mecanismo que a
  auditoria pediu: uma entrada cujo risco deixou de existir passa a ser um vermelho, não um
  comentário desactualizado.
- **#5 a maior suíte podia desaparecer por capability: FECHADO** na rodada 12 (piso e canários da
  suíte qmltc na CI), e o portão o3 herdou a mesma forma — um estilo em falta é vermelho.
- **#6 o compilador cresceu e o contexto explícito não começou: ABERTO E PIOR.** Duas rodadas
  depois: **11.197** linhas. Ver a resposta à rodada 11.
- **#7 worker QObject fora do contrato: ABERTO E INALTERADO, e a auditoria já o tinha classificado
  bem** — "dívida estrutural, não regressão". A política continua a ser a mesma: `g_ownerThread`
  fixa-se na primeira utilização e qualquer mutação de outra thread **aborta alto** com a operação
  em causa. Oito sítios com mutex em `qtdmoc.cpp`, o resto sob a política de uma thread. Não mexi,
  e a razão é a que a auditoria própria dá: é uma contenção CORRECTA, e o que falta é o desenho de
  concorrência, não um remendo. Fica dito que continua a proibir networking, timers e workers com
  `@QObject` em D.

**O que se repete entre as rodadas 10, 11 e 12:** os achados que fecho são os que têm um portão a
segui-los. Os dois que não fecham — a fronteira do runtime e o contexto do compilador — são
precisamente os dois que nenhum portão mede. Não é coincidência e não é falta de tempo: é o que a
métrica escolhe por mim quando eu não escolho.

## Rodada 10: o binding virou wrapper; agora o estado declarado ficou para trás

Esta rodada mantém a régua corrigida da rodada 9. O objeto é o projeto inteiro, e o
`qmltc-d` continua em desenvolvimento. Não considero a ausência de `Component`,
keyboard parity ou qualquer outro item deliberadamente futuro como defeito por si só.
Procurei novamente as duas classes que importam nesta fase:

1. uma unidade chamada CLEAN que diverge silenciosamente do engine;
2. governança que afirma um estado diferente daquele que o build realmente executa.

Encontrei as duas.

### Verificação desta rodada

- A árvore começou limpa. Não havia mudanças locais a preservar.
- `git diff --check` passou antes da edição desta crítica.
- `./build --list` oferece **678 targets default** (679 linhas incluindo o cabeçalho),
  dos quais **476** pertencem às famílias `qmltc*`.
- `report-selftest` passou: **678 classificados, 0 unclassified**.
- Os probes `qtmoc-probe-{noqml,qml5,qml6}` passaram; os executáveis
  `noqml_helpers` também passaram em Qt5/Qt6 e ldc2/dmd.
- Wrapper lifetime, moc/metaobject, Qt5/Qt6, QRC, WebEngine, UIC e seus diferenciais
  passaram na execução observada. UIC: **60 OK, 2 waived, 0 mismatch**.
- Os diferenciais Quick exercitados produziram frames pixel-idênticos; o gate de
  construção de Controls terminou em **61 objetos, 0 falhas**.
- O `./build` default, contudo, terminou **exit 1** ao gerar `CDelegate.qml`: a recusa
  de `Component` é esperada, mas a fixture entrou no grafo obrigatório.
- Construí ainda um probe C++ fora da suíte para `qtd_bind_leaf`: duas inscrições
  retornaram sucesso, porém só a segunda continuou conectada
  (`connected=1,1 leafA=0 leafB=1`).

### O que a rodada 9 realmente fechou

1. **O vazamento de `QQmlEngine` foi corrigido e ganhou os probes pedidos.** O helper
   está guardado por `QTD_HAVE_QML`, compila em QtQml-free, Qt5 QML e Qt6 QML, e os
   helpers no-op linkam dentro de bindings sem QtQml. A falha crítica anterior está
   fechada.

2. **O report passou a descrever a matriz atual.** As famílias `qmltc*`, o eixo Qt5
   de `qmltc5`, os probes e os novos targets têm classificação; canários e a regra
   “nenhum target vira other” estão em self-test. O achado anterior está fechado.

3. **O wrapper deixou de ser caminho secundário.** QtWidgets, QtQml, QtQuick,
   Controls, WebEngine e por fim libsample migraram; `X_new` foi removido do projeto.
   Isto resolve uma das dívidas estruturais mais antigas e merece peso maior que uma
   longa lista de features pequenas.

4. **A migração pressionou o generator de maneira produtiva.** Foram corrigidos
   dispatch virtual que bypassava vtable, overrides pure-virtual antes inalcançáveis,
   container params/returns, referências tratadas como pointers, identidade de
   wrapper e fates fantasmas no manifest. O manifest wrapper saltar de 731 para 8429
   linhas tornou a cobertura mais honesta, não apenas maior.

5. **O `qmltc-d` elevou de novo a qualidade do oracle.** Agora compara todas as
   propriedades, identidade de objetos, estado após mudança, paths profundos,
   attached properties, singleton real, baseUrl de documento e reatividade que passa
   por value/object groups. Isso é avanço na régua 1:1, não simples feature counting.

Permanecem abertos da rodada 9: `CompilationContext`/IR, worker QObjects, expected-fail
runner, CI real e isolamento físico do runtime. O guard + probes tornou a separação de
fontes menos urgente; não vou fingir que ausência de split é defeito enquanto a fronteira
condicional estiver comprovadamente fechada nos três modos.

### Achados críticos

#### 1. Uma fixture que deveria medir uma ausência deliberada derruba o default build

`docs/qmltc-d.md` diz corretamente que `tests/qmltc/controls/CDelegate.qml` é a
fixture de aceitação escrita **antes** da implementação de `Component`, e conclui:

> the fixture is deliberately NOT wired into the build

Mas `qmltcTargets()` usa `dirEntries(corpusDir, "*.qml")` e transforma todo arquivo
do diretório em target. O build lista:

```text
qmltcc-CDelegate-ldc2
qmltcc-CDelegate-dmd
```

Ao chegar nele, `qmltc-d` faz exatamente o que deveria nesta fase: retorna PARTIAL e
explica que `delegate` recebe um `Component` (template), não um objeto. O target, porém,
espera exit zero e derruba a matriz:

```text
qmltc-d: CDelegate.qml: 'delegate' ... takes a Component ... skipped (later phase)
```

O defeito não é “Component ainda não existe”. O defeito é o grafo contradizer a
política documentada e transformar uma recusa conhecida em falha tardia do build
obrigatório, depois de executar quase toda a matriz.

**Critério de resolução:**

- mover acceptance fixtures incompletas para um diretório fora do glob, OU registrar
  um target de expected-refusal que exija exit 3 e o diagnóstico canário;
- o target deve falhar se a tool abortar, retornar outra classe de erro ou perder o
  diagnóstico;
- quando `Component` aterrissar, o mesmo fixture muda para o diferencial positivo de
  itens, outer binding e mutação já especificado no documento;
- `./build` volta a terminar zero.

#### 2. Duas dependências profundas homônimas desconectam uma à outra silenciosamente

`qtd_bind_leaf(owner, prop, sig, recv, slot)` mantém a conexão dinâmica numa tabela.
A chave atual é:

```cpp
recv | slot | prop | sig
```

O argumento `owner` não participa. Assim, uma binding que precise acompanhar dois
owners diferentes através da mesma property/signature — por exemplo, a forma
`a.parent.width + b.parent.width`, ou dois object paths equivalentes — registra duas
dependências sob a mesma chave. A segunda chama `QObject::disconnect` na primeira.

O probe usou dois `QQuickItem` owners, cada um com seu próprio parent, ambos conectando
`parent.widthChanged()` ao mesmo `QTimer::start()`:

```text
connected=1,1 leafA=0 leafB=1
```

As duas APIs informaram sucesso. Alterar o primeiro leaf não chamou o slot; alterar o
segundo chamou. Não há PARTIAL, warning ou connect failure. Esta é uma divergência
silenciosa da semântica de dependencies do QML.

A tabela também não remove suas entradas quando o receiver morre. Qt invalida a
`QMetaObject::Connection`, mas o `unordered_map` retém chave/conexão até uma eventual
reutilização daquela combinação. Isso é leak de side-table e torna o problema pior
quando delegates dinâmicos começarem a existir.

**Critério de resolução:**

- a identidade inclui `owner` além de receiver/slot/property/signal;
- destruir owner ou receiver limpa a entrada, não apenas invalida a conexão Qt;
- uma fixture diferencial lê dois paths homônimos, muta cada leaf separadamente e
  exige recompute nas duas direções;
- um lifecycle probe prova que a tabela volta ao baseline após destruir a árvore.

### Achados altos

#### 3. As fontes de verdade públicas ainda descrevem o projeto anterior ao wrapper flip

Os commits removeram `X_new` e fizeram todos os bindings usarem wrapper. Mesmo assim:

- `README.md` diz que raw mode ainda é default para QtWidgets, QML e UIC;
- a seção Construction ainda mostra `QQmlApplicationEngine_new`/`QWidget_new` como API
  corrente;
- o Roadmap ainda manda tornar wrapper mode default;
- `docs/FEATURES.md` chama wrapper de gated, raw de default e repete o mesmo TODO;
- `docs/test-suite.md` diz que os manifest baselines são “raw-QtWidgets + raw-QML”,
  embora os specs e baselines tenham sido migrados para wrapper;
- `docs/test-suite.md` ainda fala em relatório sobre aproximadamente 162 targets,
  contra 678 atuais.

Isto não é atraso cosmético. Construction/ownership é o contrato público central de um
binding. Hoje o código entregou uma melhora estrutural que a documentação oficial nega.

**Critério de resolução:** README, FEATURES e test-suite passam por uma atualização
atômica com o wrapper flip: um único modelo de construção, targets/manifest atuais e
nenhum roadmap já concluído.

#### 4. O expected-fails aceitou um gap que já foi resolvido

`tests/expected-fails.json` ainda contém `virtual-container-return`:

```text
An overridden virtual that returns a container/QList still dispatches non-virtually
remove_when: a container/QList-return-capable virtual shim lands
```

Esse shim aterrissou em `5b7d61d`: virtual QList returns passam por trampoline e vtable.
`docs/FEATURES.md` repete o gap antigo. O linter segue verde porque `known_gap` não tem
probe, não avalia `remove_when` e não detecta unexpected pass.

Esta era uma limitação assumida do linter; agora existe uma demonstração concreta do
seu custo: o structured state ficou falso e nenhum gate reclamou.

**Critério de resolução:** remover/reescrever a entrada conforme o long tail real e
transformar gaps testáveis em probes executáveis. O futuro runner precisa detectar
quando `remove_when` se tornou verdade ou quando um probe passou inesperadamente.

#### 5. A maior suíte pode desaparecer por capability sem um floor institucional

O projeto corretamente colocou floor e canários em libsample. Não fez o equivalente
para `qmltc`/Controls:

- `qmltcControlsRuntimeTargets` retorna array vazio se um path absoluto
  `/usr/lib/qt6/qml/QtQuick/Controls/Basic` não existir;
- esse path é layout de instalação, não API do Qt, e o workflow declara outra distro;
- a CI verifica 58 `sample_*`, mas não exige contagem mínima nem canários dos 476
  targets `qmltc*`;
- o report self-test valida como um nome seria classificado; não exige que o canário
  exista no grafo.

Logo o report pode estar perfeitamente classificado e ainda não executar o corpus de
Controls que mais encontra bugs no wrapper. Como a CI continua declaradamente nunca
comprovada verde, isto não é uma falha observada no runner, mas é uma rota concreta de
conformance disappearance.

**Critério de resolução:** descobrir `QT_INSTALL_QML` via Qt/qtpaths em vez de path
absoluto; CI exige um floor e canários para corpus, render, click/time e Controls runtime;
capability ausente aparece como skip explícito, não como target inexistente.

### Achados estruturais

#### 6. O compilador cresceu; o contexto explícito não começou

`qmltc_d.cpp` passou de aproximadamente 5.200 para **6.528 linhas** e mantém **63
globais estáticos**. Desde a rodada anterior, 44 commits tocaram o arquivo. A maioria
das mudanças é semanticamente justificada e coberta; o problema é o custo cumulativo
de preservar scopes/documentos por save/restore manual.

O histórico recente já inclui bugs de source text errado, alias-only imports, outer
objects com vários hops e use-site AST splice. Todos são exatamente estados que um
`DocumentContext` tornaria locais por construção.

Não proponho parar o trabalho de feature nem reescrever o lowering. Proponho começar
pela parte menos controversa: source text, imports, document URL, resolution stack e
diagnostics dentro de um contexto explícito, deixando registries imutáveis separados.

#### 7. Worker QObject continua fora do contrato

O owner-thread abort continua sendo uma contenção correta para mapas globais não
sincronizados, mas networking/timers/workers com D `@QObject` continuam proibidos. O
novo `g_leafConn` até usa mutex, porém outros side-tables e caches de context/singleton
permanecem sob a política global de uma thread.

Isto permanece dívida estrutural, não regressão desta rodada.

### Correções documentais específicas do qmltc-d

O documento técnico é valioso, mas já contém afirmações incompatíveis com o grafo:

- diz que `CDelegate` não está wired, mas dois targets obrigatórios existem;
- registra “472 green em ~4 min” enquanto o grafo agora oferece 476 targets e a matriz
  comportamental atual tem outra duração operacional;
- seções antigas ainda anunciam scores intermediários como “estado atual” antes das
  medições mais novas.

Preservar o diário de descobertas é útil. O que falta é separar claramente
**current scoreboard** de **historical measurements**, para que uma busca não encontre
três respostas válidas em datas diferentes sem saber qual governa o release atual.

### Prioridade brutal da rodada 10

1. **Tirar `CDelegate` do caminho positivo obrigatório** e restaurar `./build` verde;
   manter a recusa como expected-refusal executável.
2. **Corrigir a identidade e o lifetime de `g_leafConn`**, com diferencial de duas
   dependências homônimas.
3. **Atualizar README/FEATURES/test-suite/expected-fails** para o wrapper-only real.
4. **Dar floor/canários à suíte qmltc na CI** e eliminar o path QML absoluto.
5. **Formalizar expected-fail runner**, agora que há um unexpected pass histórico
   concreto.
6. **Começar `DocumentContext` incremental**, sem bloquear o avanço semântico.
7. **Comprovar a CI real** sobre a matriz que a documentação declara.
8. **Evoluir qtmoc para worker QObjects** quando as fronteiras de lifetime estiverem
   cobertas.

### Veredito da rodada 10

Esta foi uma rodada tecnicamente forte. O projeto fechou a regressão crítica anterior,
fez wrapper mode virar realidade em toda a superfície, corrigiu cobertura falsa no
manifest e tornou o diferencial QML muito mais difícil de enganar. O núcleo está melhor
que a documentação deixa parecer.

Mas há duas falhas reais no estado atual. A primeira é visível: o default build termina
vermelho porque uma fixture declarada “não wired” foi capturada por um glob. A segunda
é pior: duas dependências profundas podem receber connect-success e uma delas ficar
morta porque a side-table colide owners diferentes.

Resumo brutal: **a pressão do `qmltc-d` continua funcionando**. Desta vez ela provou que
o wrapper generator amadureceu mais rápido que suas fontes de verdade e que o runtime
reativo ainda possui uma chave de identidade incompleta. Restaurem a honestidade em
três níveis — build, state files e dependency identity — antes de usar a próxima leva
de features para aumentar novamente a superfície.

## Resposta à rodada 9 (escrita a 2026-08-12)

Verificado antes de escrito. **Quatro fechados, três abertos** — e os três abertos são os MESMOS de
sempre, o que a esta altura já é o achado principal desta releitura toda.

- **#1 um helper de QML quebrou os consumidores não-QML: FECHADO, e com os quatro critérios que a
  auditoria escreveu, não com três.** O `qtd_qml_engine()` está sob `#ifdef QTD_HAVE_QML`, e o
  comentário no sítio nomeia o defeito pelo que ele é — *"a feature-isolation defect, not a QML
  one"*. Os probes existem e são alvos do build: `qtmoc-probe-noqml` compila `qtdmoc.cpp`
  deliberadamente **sem** QtQml ("No QtQml in sight: the configuration that broke"), e
  `qtmoc-probe-qml6` e `qtmoc-probe-qml5` cobrem as duas versões. `./build` sai zero.
- **#2 `qtmoc` é uma fronteira larga demais: ABERTO E PIOR.** É o #5 da rodada 11 — 2533 linhas, 49
  guardas, e dois globais de compilador QML acrescentados hoje ao runtime partilhado.
- **#3 o report não descrevia a maior parte da matriz: FECHADO, incluindo a parte que a auditoria
  pôs como preferência e não como requisito.** `category()` conhece `qmltc-*`, `qmltc5-*`,
  `qmltcq-*`, `qmltcc-*`, `qmltcd-*` e `leaf-lifetime-*`; `qtaxis()` reconhece `qmltc5-*` e
  `qtmoc-probe-qml5` como Qt5; e o parser tem **self-test** (`--self-test`, alvo `report-selftest`)
  com um nome canário por família, exactamente como pedido. O que fica por fazer é a preferência
  declarada — a metadata nascer no alvo reggae em vez de ser reconstruída por padrões — e isso
  continua por fazer, dito aqui em vez de contado como fechado.
- **#4 o `qmltc-d` precisa de contexto explícito: ABERTO E PIOR.** 11.197 linhas. Ver rodada 11.
- **#5 o melhor modelo de ownership não era o default: FECHADO.** Os nove bindings de produto são
  wrapper (`controls`, `qml`, `qml_qt5`, `quick`, `qtwidgets`, `qtwidgets_wrap`,
  `qtwidgets_wrap_qt5`, `webengine_wrap`, `wraptest`); os que continuam raw são fixtures e probes do
  próprio gerador (`enum`, `flags`, `ctr`, `str`, `signals`, `probe`, `corpustypes`, `test`), que
  existem para testar o emissor e não para ser consumidos. E `X_new` deixou de ser API: o README diz
  que não existe em lado nenhum e o `docs/FEATURES.md` chama-lhe INACEITÁVEL.
- **#6 o runtime moc limitado à owner thread: ABERTO E INALTERADO** — ver rodada 10 #7, com a
  classificação que a auditoria lhe deu.
- **#7 generator IR, typesystem e manifests incompletos: ABERTO.** O `ownership-gate` da rodada 12
  atacou a metade que interessava (impedir a superfície perigosa de crescer) em vez de anotar 8428
  símbolos, e isso está respondido lá; o IR e o typesystem continuam por fazer.

**O padrão, agora com três rodadas de prova:** de dezasseis achados relidos hoje (rodadas 9, 10 e
11), fecharam-se treze — e os três que não fecham são o mesmo par de fronteiras (o runtime
partilhado, o contexto do compilador) mais a política de thread. Os treze tinham portão ou viraram
portão. Os três não têm nenhum, e a métrica deles ANDOU PARA TRÁS enquanto eu fechava os outros.

## Rodada 9: o qmltc-d virou teste de integração; as fronteiras do projeto não acompanharam

Esta rodada corrige a régua da crítica anterior. O objeto principal continua sendo o
**qt-dlang-gen como um todo**: generator, runtimes, tools, grafo, testes e CI. O
`qmltc-d` é uma das tools — hoje a maior e a que mais pressiona o restante — mas está
deliberadamente em aproximadamente **60% de feature completeness**.

Portanto, uma construção QML ainda recusada, um tipo ainda não mapeado ou uma expressão
ainda sem lowering **não são defeitos por si mesmos**. O contrato desta fase é:

1. o que foi transpilado deve bater **1:1** com o documento interpretado;
2. o que ainda não foi transpilado deve terminar em PARTIAL/refusal explícita;
3. ampliar o corpus deve expor bugs no wrapper generator e no runtime, para então
   corrigi-los com regressões focadas.

Esse terceiro ponto explica corretamente por que o avanço do `qmltc-d` continua
encontrando defeitos fora dele. Isso é uma função produtiva da tool, não evidência de
que ela deveria parar até o restante do projeto estar perfeito.

### Verificação desta rodada

- Preservei as alterações preexistentes em `generator-d/emit.d`,
  `tools/qmltc/qmltc_d.cpp` e `tests/qmltc/qtd_qmlvalues.cpp`.
- `git diff --check` passou.
- `./build --list` apresenta **665 targets default**.
- **472 / 665** pertencem às famílias `qmltc`, `qmltc5`, `qmltcq`, `qmltcc` e
  `qmltcd`.
- A duração de aproximadamente **uma hora** para a matriz atual é esperada: os testes
  novos exercitam construção, comportamento, passagem de tempo, eventos e render,
  e não apenas geração/compilação. Não classifico essa duração, isoladamente, como
  defeito do report ou da CI.
- `./build` falhou ao compilar o `qtdmoc.cpp` do binding QtWidgets: o helper
  `qtd_qml_engine()` usa `QQmlEngine` fora do guard de QML.
- Uma execução focada que incluía `sample_cornercases-ldc2` reproduziu a mesma falha
  no `qtdmoc.cpp` gerado para libsample. Portanto o alcance não é só o `qmltc-d`.

### Correção explícita da crítica anterior

Eu havia deixado o `qmltc-d` dominar o julgamento do repositório e tratei parte do
backlog dos 40% restantes como distância de maturidade do projeto inteiro. Essa leitura
estava errada.

Também associei a execução longa principalmente ao modelo por-target do report. Esse
diagnóstico não estava demonstrado: a matriz atual faz trabalho de runtime deliberadamente
caro, especialmente nos diferenciais de comportamento. O modelo do report ainda tem
problemas de classificação descritos abaixo, mas “leva uma hora” não prova que ele seja
a causa.

O julgamento corrigido é: o método do `qmltc-d` é uma das melhores ferramentas de
validação do projeto. O risco está nas fronteiras e na governança que precisam absorver
as descobertas dessa tool sem deixar um requisito QML contaminar bindings não-QML.

### O que está forte de verdade

1. **A régua 1:1 é a régua correta.** Dumps de propriedades, cobertura das propriedades
   que o engine realmente criou, verificação de attachment, mutações, clique, passagem
   de tempo e frame atacam classes diferentes de falso verde.

2. **PARTIAL é um resultado válido nesta fase.** Recusar uma unidade que ainda não pode
   ser traduzida é melhor do que emitir uma aproximação. A futura cadeia de fallback
   pode consumir essa fronteira; escondê-la agora impediria medir o transpilador estático.

3. **O `qmltc-d` está servindo como fuzzing semântico do binding.** Tipos reais de
   Controls fizeram o generator atravessar herança, private APIs, value groups,
   propriedades objeto/lista, completion e contexto. Encontrar bugs do wrapper generator
   nesse processo é progresso mensurável.

4. **As correções anteriores do runtime permaneceram conceitualmente certas.**
   `qt_metacast`, identidade de registro, validação de slot/NOTIFY, falha observável de
   factory e guard de owner thread transformaram violações silenciosas em contratos
   testados.

5. **As outras tools também avançaram.** O UIC passou a comparar a estrutura de layouts;
   QRC verifica payload; casos libsample que eram no-op viraram asserts. O repositório não
   ficou parado enquanto o `qmltc-d` cresceu.

### Achado crítico

#### 1. Um helper exclusivo de QML quebrou os consumidores não-QML do runtime compartilhado

`runtime/qtmoc/qtdmoc.cpp` inclui `QQmlEngine` somente sob `QTD_ENABLE_QML`, mas define:

```cpp
static QQmlEngine* qtd_qml_engine() {
    static QQmlEngine* eng = nullptr;
    if (!eng) eng = new QQmlEngine;
    return eng;
}
```

fora de `#ifdef QTD_HAVE_QML`. O corpo de `qtd_attach_context` é guardado; a declaração
do tipo e o helper que o retorna não são.

O default build então tenta compilar esse arquivo também para QtWidgets e libsample,
sem QtQml, e falha com:

```text
qtdmoc.cpp:497:8: error: unknown type name 'QQmlEngine'
```

Isto não invalida a estratégia de usar um contexto para objetos QML compilados. A
descoberta em Controls é válida: vários tipos precisam de `QQmlContext` mesmo sem
interpretar o documento. O defeito é de **feature isolation** no runtime compartilhado.

**Critério de resolução:**

- o helper inteiro fica sob o guard correto ou vai para uma unidade QML separada;
- existe um probe que compila `qtdmoc.cpp` deliberadamente **sem** QtQml;
- existem probes com QtQml em Qt5 e Qt6;
- `./build` e `sample_cornercases-{ldc2,dmd}` voltam a passar.

### Achados altos

#### 2. `qtmoc` tornou-se uma fronteira larga demais

O mesmo arquivo hoje concentra metaobjeto genérico, side-tables, registro/factory QML,
helpers de property, context/engine, parser status, rebinding profundo e semântica
necessária pelo `qmltc-d`.

Macros condicionais são aceitáveis, mas o blast radius observado mostra que a fronteira
não é forte: uma função específica do transpilador entrou no artefato de QtWidgets e no
de libsample.

Não é necessário fazer uma grande reescrita agora. É necessário impedir dependências
impossíveis por construção.

**Critério de resolução:**

- separar ao menos `qtmoc-core` de `qtmoc-qml`, ou fazer o build selecionar fontes
  distintas em vez de copiar sempre a mesma unidade;
- um consumidor QtCore/QtWidgets não vê headers, símbolos nem link flags de QtQml;
- o suporte específico de contexto do `qmltc-d` tem um teste de linkage independente.

#### 3. O report não descreve a maior parte da matriz

`tools/test-report.sh::category()` conhece `qml-*`, mas não as famílias `qmltc*`.
Assim, os **472 targets** do transpilador caem em `other`. `qtaxis()` reconhece apenas
o marcador `-qt5`; os targets `qmltc5-*` são registrados como Qt6.

O teste pode executar corretamente e o artifact ainda contar uma história errada sobre
qual categoria e qual Qt foram exercitados. Com 472 de 665 targets afetados, isso deixou
de ser um detalhe de naming.

**Critério de resolução:**

- `qmltc`, `qmltc5`, `qmltcq`, `qmltcc`, `qmltcd` e os gates Controls ganham categoria
  e eixo Qt corretos;
- o parser do report tem um self-test sobre nomes canários de cada família;
- preferencialmente, metadata de categoria/compiler/Qt nasce no target reggae, em vez
  de ser reconstruída por padrões de string num segundo sistema.

#### 4. O `qmltc-d` precisa de contexto explícito antes dos 40% finais

`tools/qmltc/qmltc_d.cpp` tem mais de cinco mil linhas e mantém dezenas de estados
globais: documento atual, imports, type registry, escopos, outer chain, aliases,
dependencies, diagnostics e temporários de lowering. A recursão salva e restaura
manualmente grandes conjuntos desses globais.

Isto não é uma crítica a features ausentes nem uma exigência de reescrita antes de
continuar. É um risco de completar o compilador: local types, imports qualificados,
singletons e objetos aninhados já mostraram bugs de estado pertencente ao documento
errado.

**Critério de resolução:**

- introduzir incrementalmente um `CompilationContext`/`DocumentContext`;
- imports, source text, diagnostics e resolution stack deixam de depender de save/restore
  manual;
- um teste compila dois documentos locais com imports/aliases diferentes e prova que
  nenhum estado atravessa a fronteira;
- o lowering pode continuar textual por enquanto; uma IR completa não é precondição.

### Achados estruturais que continuam válidos para o projeto inteiro

#### 5. O melhor modelo de ownership ainda não é o default

GC-wrapper tem identity map, invalidation, parenting pins e testes relevantes, mas
bindings centrais ainda usam raw mode e `X_new`. Manter dois contratos de construção
continua sendo dívida de produto, independentemente do estado do `qmltc-d`.

**Critério de resolução:** wrapper mode vira default nos bindings suportados; os testes
raw restantes são migrados; `X_new` deixa de ser API de uso normal.

#### 6. O runtime moc continua limitado à owner thread

Abortar em vez de permitir data race silenciosa foi a decisão segura. Ainda assim,
worker QObjects, timers, networking e outros padrões Qt fora da GUI thread permanecem
fora do contrato.

**Critério de resolução:** tabelas sincronizadas ou ownership por thread, com construção,
queued dispatch e destruição em worker cobertos. Até lá, a limitação deve continuar
explícita e não ser confundida com a restrição de GUI thread dos widgets.

#### 7. Generator IR, typesystem e manifests continuam incompletos

O generator principal ainda mistura AST walk, política, emissão e recovery; `loadRules`
continua sendo um subset regex; manifests ainda não cobrem Qt5, wrapper e webengine;
expected-fails continua sendo linter, não runner.

Esses pontos não foram criados pelo `qmltc-d`, mas ele aumenta a pressão sobre todos
eles. A prioridade deve ser guiada pelos bugs que o diferencial 1:1 realmente encontra,
não por uma tentativa abstrata de reproduzir todo o typesystem do PySide de uma vez.

### Prioridade brutal da rodada 9

1. **Restaurar o default build:** guardar/separar `qtd_qml_engine` e adicionar o probe
   não-QML.
2. **Isolar o runtime QML:** impedir que features do transpilador entrem em bindings
   QtCore/QtWidgets/libsample.
3. **Consertar a verdade do report:** 472 targets não podem ser `other`, e `qmltc5`
   não pode aparecer como Qt6.
4. **Continuar o diferencial 1:1:** tratar cada bug encontrado no wrapper/runtime como
   resultado esperado da pressão, com regressão focada.
5. **Introduzir `CompilationContext` incremental no `qmltc-d` antes do último 40%.**
6. **Tornar GC-wrapper default.**
7. **Evoluir o runtime de owner-thread-only para worker QObjects reais.**
8. **Completar a governança restante:** expected-fail runner, manifests dos outros
   modos e CI comprovadamente verde.
9. **Introduzir IR no generator principal conforme as descobertas exigirem**, sem
   bloquear artificialmente o trabalho semântico atual.

### Veredito da rodada 9

O `qmltc-d` estar em 60% não reduz o mérito do projeto nem constitui o problema
principal. A tool está fazendo exatamente o trabalho mais útil nesta fase: comparar
transpilado e interpretado, recusar o que ainda não sabe fazer e forçar o wrapper
generator a atravessar casos reais que a suíte anterior não alcançava.

O sinal preocupante não é “novos bugs apareceram”. Bugs novos devem aparecer quando o
corpus ganha profundidade. O sinal preocupante é um requisito QML conseguir quebrar
QtWidgets e libsample pela mesma unidade compartilhada, enquanto o report já não sabe
classificar a maior parte da matriz que executa.

Resumo brutal corrigido: **continuem usando o `qmltc-d` para quebrar o projeto** — essa
é uma excelente estratégia de desenvolvimento. Mas cada quebra precisa terminar em uma
fronteira mais forte, um probe cruzado e metadata de teste correta. A maturidade agora
será medida não pela ausência de descobertas durante os 40% restantes, e sim pela
capacidade do repositório de absorvê-las sem regressão lateral.

## Resposta à rodada 8 (escrita a 2026-08-12)

Dez achados, verificados um a um. **Oito fechados, um meio-fechado com número novo, um contido por
decisão.** O código cita a rodada pelo número em cinco sítios diferentes, o que é a maneira mais
barata de a correcção não se perder.

- **#1 a CI chamava advisory o que `./build` tornava obrigatório: FECHADO.** `ci.yml` faz a
  separação explícita — os portões obrigatórios correm no passo normal e há um passo advisory
  `continue-on-error` à parte, condicionado, com o comentário a citar "r8 #1".
- **#2 o metaobjeto anunciava a classe e o `qt_metacast` negava-a: FECHADO, e é o achado mais bem
  fechado desta rodada.** O corpo compara agora o nome antes de delegar
  (`if (n && mo && strcmp(n, mo->className()) == 0) return this;`), o comentário no sítio conta o
  caso exacto que a auditoria correu (`qt_metacast("Dup")` a devolver null com
  `className()=="Dup"`), e existe alvo permanente: `metacast-{ldc2,dmd}`.
- **#3 a idempotência de `qmlRegisterType` colapsava tipos D diferentes: FECHADO**, com
  `homocollide-{ldc2,dmd}` no grafo.
- **#4 `@Slot` aceitava retorno que o metaobjeto descarta: FECHADO** — `qtmoc.d` tem hoje uma
  secção "meta-method contract (critics r8 #4)" e a regra escrita: um método que devolve valor é um
  INVOKABLE, não um slot, e é recusado como tal.
- **#5 falha da factory QML produzia carrier sem backend: FECHADO** — o `qt_metacall` guarda o caso
  ("a failed QML instance has no backing obj, r8 #5").
- **#6 os side-tables eram data races fora da thread principal: CONTIDO POR DECISÃO, e a auditoria
  concordou depois.** `g_ownerThread` fixa-se na primeira utilização e qualquer mutação de outra
  thread **aborta alto** com a operação em causa — a secção chama-se literalmente "thread affinity
  (critics r8 #6)". Continua a proibir workers, e isso está dito nas rodadas 9 e 10 com a
  classificação que a própria auditoria lhe deu: dívida estrutural, não regressão.
- **#7 o corpus pinado tinha fallback não pinado e asserção fraca: FECHADO, nas duas metades.** A CI
  clona `6.8.0` **sem fallback** ("if the tag/clone fails, the JOB fails") e a conformidade exige a
  contagem conhecida completa em vez de `n>0` — as duas com o número da rodada no comentário.
- **#8 o report era uma segunda execução falível: FECHADO.** O report É hoje a execução de registo
  (sai não-zero se algo falhou, para a CI poder gatilhar), marca a árvore como DIRTY quando há
  ficheiros gerados/editados à solta, e regista *skip* em vez de um verde que não executou.
- **#9 o grafo libsample escondia DAG mau com locks: METADE FECHADA, e a outra metade tem agora
  número.** O que a auditoria listou como duplicado resolveu-se para os bindings: numa matriz
  completa de hoje, `gen.stamp`, `libshims.a` e `libbinding_ldc2.a` são anunciados **zero** vezes
  repetidas. `libsample.a` é anunciado **116 vezes** para 58 consumidores. Continuam dois `flock` no
  grafo. A contenção segue correcta e o custo segue real — e a diferença face à rodada 8 é que
  agora é um número em vez de "muitas vezes".
- **#10 universais contraditórios na documentação: FECHADO, incluindo a parte do QRC.**
  `docs/test-suite.md` diz hoje que alguns alvos são **deliberadamente** single-config e nomeia
  quais; a tabela do moc lista `cannon_t1..t11` com o que t10 e t11 provam. E o QRC deixou de ser um
  fixture ASCII: o teste serve um **PNG** e afirma os **bytes exactos** através do próprio
  `QFile`/`QResource` do Qt — o que é mais forte do que o oráculo contra `rcc` que a auditoria
  pediu, porque é o Qt a analisar o nosso blob, não uma comparação de ficheiros.

**O que esta rodada mostra e as outras não mostravam:** quando um achado vira **alvo com nome**
(`metacast-*`, `homocollide-*`), fecha e fica fechado. Os dois que não têm alvo — o DAG do libsample
e a política de thread — são os dois que continuam a discutir-se cinco rodadas depois.

## Rodada 8: os gates aprenderam a falhar; o metaobjeto ainda mente

Nesta rodada eu não reli apenas a resolução. Revisei os commits desde a rodada 7,
o grafo completo, CI, manifests, linter, report, runtime holder/moc/QML, geração do
metaobjeto e os testes novos. Depois construí probes fora da suíte para perguntar ao
Qt o que os testes atuais não perguntam.

A régua continua sendo PySide. Isso inclui coerência com o modelo de objetos do Qt,
introspecção, erro observável, thread affinity e uma CI que execute o contrato que
descreve.

### Verificação desta rodada

- Preservei a alteração preexistente em `runtime/uic/uiform.d` e o diretório não
  rastreado `tests/qmltc/`.
- `./build --list` agora lista **162 targets**, sendo **58** `sample_*`.
- `./build` passou completo: Qt 5.15 + Qt 6.11, dmd + ldc2, libsample,
  UIC 60/60, QML, homônimos, AOT, `.qmltypes`, QRC, WebEngine, lupdate e gates.
- `homonym-*` e `qmltwo-*` passaram nas quatro combinações Qt/compilador.
- Os três falsos verdes da rodada 7 agora falham corretamente:
  - chave duplicada no baseline do manifest: **exit 1**;
  - fate inventado: **exit 1**;
  - schema errado + ID duplicado no expected-fails: **exit 1**.
- O report agora classifica corretamente `expected-fails-lint` como `gate / -`
  e `homonym-ldc2` como `qml / qt6`.
- Reproduzi três defeitos novos:
  - `qt_metacast("Dup")` sobre um `newQObject!Dup` retornou **null**;
  - `@Slot int answer()` compilou, mas `QMetaObject::invokeMethod` com retorno
    respondeu **false** e não escreveu o resultado;
  - duas classes D homônimas distintas, registradas no mesmo URI/nome/versão,
    fizeram a segunda chamada retornar silenciosamente como “idempotente”.
- `git diff --check` passou.

### O que foi realmente fechado

1. **Os manifest gates agora são fail-closed no conteúdo.** Fate desconhecido,
   linha malformada e duplicata em qualquer lado falham. O unittest atravessa o
   parser real. A crítica da rodada 7 foi resolvida.

2. **O expected-fails agora tem um linter honesto e estrito.** Schema, kinds,
   campos básicos e IDs são validados por regras compiladas no programa. O projeto
   parou de chamá-lo de runner. Ainda falta o runner, mas já não há propaganda falsa.

3. **O erro de registro backend ficou observável.** `nullptr` agora vira exceção D,
   a alocação C++ é liberada e o slot Qt5 é revertido. Isso fecha o bug específico
   de sucesso após recusa do backend.

4. **A chave do cache inclui NOTIFY, e homônimos reais foram testados.** `AlphaDup`
   e `BetaDup` usam duas classes D chamadas `Dup`, com formas diferentes, e ambas
   funcionam em Qt5/Qt6 e dmd/ldc2. É uma correção válida, com teste válido.

5. **O report corrigiu as mentiras concretas apontadas.** A arquitetura por padrões
   de nome continua frágil, mas não vou fingir que as duas classificações reproduzidas
   na rodada passada permanecem erradas.

6. **O Lippincott por assinatura continua sendo a peça mais sofisticada do projeto.**
   Nada nesta rodada diminuiu esse julgamento. A tradução de exceções C++ para D,
   compartilhada por forma ABI e compatível com dead stripping, é trabalho de
   binding-runtime sério. O contraste atual é incômodo: a fronteira de exceção está
   mais madura que partes básicas do metaobject protocol.

### Achados críticos

#### 1. A CI chama os manifest gates de advisory, mas `./build` já os torna obrigatórios

O workflow tem um passo posterior:

```yaml
continue-on-error: true
run:
  ./build manifest-gate-qtwidgets
  ./build manifest-gate-qml
```

Isso parece tornar os gates advisory. Não torna.

`reggaefile.d` adiciona `manifestGateTargets(...)` ao array `all`, e `Build(all)`
faz `./build` executar todos eles. O passo anterior da CI, “Build + run the full
matrix”, chama `./build` sem filtro. Portanto os manifests 6.11 rodam ali de forma
obrigatória, antes do `continue-on-error`, no runner cujo próprio arquivo diz ter
outro Qt minor.

Resultado: a correção da CI ainda não alcança o comportamento declarado. Se o
baseline divergir no Ubuntu, o job morre no full build; o passo advisory nunca
resgata nada.

Isto precisa ser resolvido no grafo, não no texto do workflow: criar agregadores
separados (`matrix`, `version-independent-gates`, `manifest-gates`) ou permitir
exclusão explícita por ambiente. Enquanto `./build` significar tudo, o gate é
obrigatório.

#### 2. O metaobjeto dinâmico anuncia a classe, mas `qt_metacast` nega que ela exista

`QtdMocObject::metaObject()` devolve o `QMetaObject` construído para a classe D. Seu
`qt_metacast`, porém, faz apenas:

```cpp
return QObject::qt_metacast(n);
```

O trampoline de `QtdWidget` repete o erro, delegando diretamente para
`Base::qt_metacast(n)`.

Um moc gerado pelo Qt primeiro compara `n` com o nome da própria classe e devolve
`this`; só depois delega à base. O runtime atual pula essa etapa. Meu probe criou
`newQObject!homonym_a.Dup()` e chamou `qt_metacast("Dup")`: recebeu **null**, apesar
de `metaObject()->className()` ser `Dup`.

Isso quebra a coerência do QObject protocol e afeta `qobject_cast`, interfaces,
descoberta por nome e código Qt que usa metacast. Sinais e properties verdes não
compensam um metaobjeto que não reconhece seu próprio tipo.

### Achados altos

#### 3. A idempotência de `qmlRegisterType` colapsa tipos D diferentes

A chave é:

```d
T.stringof ~ "|" ~ uri ~ "|" ~ qmlName ~ "|" ~ version
```

`T.stringof` não é identidade de tipo. As duas classes dos módulos `homonym_a` e
`homonym_b` têm o mesmo `T.stringof == "Dup"`. O teste novo não encontra esse bug
porque usa nomes QML diferentes, `AlphaDup` e `BetaDup`.

Meu probe registrou:

```d
qmlRegisterType!(homonym_a.Dup)("Collision", 1, 0, "Dup");
qmlRegisterType!(homonym_b.Dup)("Collision", 1, 0, "Dup");
```

A segunda chamada foi silenciosamente aceita como repetição idempotente; não chegou
ao backend e não informou conflito. Uma classe diferente foi confundida com a
primeira.

Idempotência deve guardar identidade real de `T` e o handle/type id retornado. Para
uma mesma chave pública com outro tipo, a API deve rejeitar conflito explicitamente.
Concatenar strings sem estrutura também não é uma base adequada para identidade.

#### 4. `@Slot` aceita retorno que o metaobjeto descarta

`slotSigs` gera apenas `nome(parâmetros)`. `QMetaObjectBuilder::addSlot` recebe essa
assinatura sem return type. `callSlot` invoca o método D e descarta qualquer retorno.
Não há `static assert` exigindo `void`.

O probe:

```d
@QObject class Returner {
    @Slot int answer() { return 42; }
}
```

compilou normalmente. Uma chamada Qt com `Q_RETURN_ARG(int, result)` falhou:
`invoke=0`, `result=-1`.

Há duas soluções honestas: implementar return marshaling via `args[0]` e registrar
o tipo de retorno, ou rejeitar todo `@Slot` não-void em compile time. Aceitar e
degradar silenciosamente é a pior opção.

O mesmo rigor falta em properties: um nome NOTIFY inexistente vira índice `-1` e
remove silenciosamente a notificação. A assinatura do sinal NOTIFY também não é
validada contra a property.

#### 5. Falha da factory QML ainda produz carrier sem backend

O contrato novo cobre falha de **registro**. Não cobre falha de **instanciação**.
Se `new T()` ou `wireQObject` lança, a factory registra o callback error e retorna
`null`. `qtd_qml_construct` já executou placement-new do `QtdMocObject`, inseriu
`g_moAttach` e termina com `dobj == null`.

O engine recebe um QObject cuja metadata existe, mas cujo dispatch D não existe.
Não há mecanismo que converta isso em erro de criação QML, destrua imediatamente o
carrier ou impeça uso posterior. A prioridade da rodada 7 mencionava explicitamente
falha de factory; a resolução fechou apenas o backend de registro.

#### 6. Os side-tables do runtime são data races fora da thread principal

O runtime mantém estado global mutável sem sincronização:

- C++: `g_moCache` e `g_moAttach`, ambos `std::unordered_map`;
- D: `_reg`, `_qmlFactories` e `_qmlRegistered`, todos associative arrays
  `__gshared`;
- holder: `_pinned` e o mapa C++ de wrappers.

`holder.d` pelo menos declara “Single-threaded by design”. `qtmoc` não impõe nem
documenta essa restrição. QObject não significa exclusivamente GUI: objetos podem
ser criados, destruídos e receber queued calls em worker threads. Duas construções
ou destruições concorrentes mutam esses maps sem proteção, comportamento indefinido
em C++ e race no runtime D.

Para maturidade PySide, “Qt main thread” não pode ser uma suposição global do binding.
Widgets exigem GUI thread; QObject, QThread, networking, timers e workers não. Ou o
runtime ganha locking/ownership por thread, ou a limitação precisa ser explícita e
enforced.

### Achados médios

#### 7. O corpus “pinado” da CI tem fallback não pinado e uma asserção fraca

O workflow tenta clonar `6.8.0`, mas em qualquer falha executa:

```sh
git clone --depth 1 https://code.qt.io/pyside/pyside-setup.git ...
```

Isso baixa o HEAD do servidor. A descrição “PINNED revision” fica falsa justamente
no fallback. Falha de rede/tag deveria falhar o job; não selecionar outra API.

Depois a CI exige apenas `n > 0` para `sample_*`. Um corpus parcial com um único
target passa a conformance. O contrato local conhecido é 58 targets; a CI deveria
exigir a contagem esperada e alguns IDs canários, ou derivar um manifest pinado dos
casos.

Ainda não existe evidência de uma execução real do workflow. O scaffold melhorou,
mas “CI presente” e “CI comprovadamente verde” continuam estados diferentes.

#### 8. O report continua sendo uma segunda execução falível, não um relatório da primeira

Depois de `./build`, a CI chama `test-report.sh`, que executa os 162 targets de novo.
O exit code é ignorado com `|| true`. Assim:

- o artifact pode divergir do resultado que decidiu o job;
- um teste stateful/flaky pode passar numa execução e falhar na outra;
- a duração da pipeline quase dobra;
- arquivos não rastreados continuam ausentes do dirty state;
- targets omitidos por capability não aparecem como skip.

As classificações concretas foram corrigidas. A arquitetura ainda precisa coletar
eventos/resultados da execução de record.

#### 9. O grafo libsample continua escondendo DAG ruim com locks

A matriz completa voltou a anunciar `libsample.a`, `gen.stamp`,
`libbinding_{dmd,ldc2}.a` e `libshims.a` muitas vezes. O cache de `qtdBindLib`
resolveu bindings normais, mas o subgrafo libsample ainda cria instâncias repetidas
dos mesmos produtores para os 58 consumidores.

`flock` mantém o build funcional e merece crédito como contenção. Ainda custa
scheduling, processos e diagnóstico. A CI duplicada pelo report amplia o custo.

#### 10. A documentação ainda contém universais contraditórios

`docs/test-suite.md` começa corretamente dizendo que muitos targets são
single-config, mas a seção Matrix afirma “every target, both” para os compiladores.
Gates e lupdate continuam singletons. A tabela moc ainda lista `cannon_t1..t9`,
omitindo `t10` e `t11`.

O QRC também permanece no mesmo estado: um fixture ASCII e nenhum oracle contra
`rcc`. Isso está assumido como follow-up e não merece ser reembalado como descoberta,
mas continua incompatível com uma alegação de substituto geral de `rcc`.

### Prioridade brutal da rodada 8

1. **Corrigir `qt_metacast` nos dois carriers.** Comparar o className/interface
   local antes de delegar à base; testar metacast positivo, base e tipo inexistente.
2. **Separar os agregadores da CI.** O full matrix do runner não pode executar
   manifests 6.11 antes do passo advisory.
3. **Dar identidade real ao registro QML.** Tipo D inequívoco + chave pública
   estruturada; repetição idêntica é no-op, colisão diferente é erro.
4. **Definir o contrato de métodos meta.** Implementar retorno de slot ou rejeitá-lo;
   validar NOTIFY existente e assinatura compatível em compile time.
5. **Tratar falha de factory QML como falha de criação, com cleanup completo.**
6. **Definir a política de threading do runtime.** Locks/propriedade por thread e
   testes com worker QObjects; não estender a restrição de QWidget a todo QObject.
7. **Fazer a CI realmente reprodutível.** Sem fallback para HEAD, contagem/canários
   do corpus e primeiro run comprovado.
8. **Transformar o report em output da execução de record.**
9. **Deduplicar os produtores do subgrafo libsample.**
10. **Continuar o trabalho estrutural assumido:** runner de expected-fails, baselines
    por Qt minor, QRC diferencial, IR, typesystem completo, wrapper-default e
    Windows/SEH para o Lippincott.

### Veredito da rodada 8

Esta rodada confirma uma melhora importante: quando pressionados com fixtures
corrompidas, os gates agora falham. O projeto também respondeu corretamente à crítica
de homônimos no cache e não esconde mais que expected-fails é apenas lint. Isso é
maturidade crescente, não teatro.

O problema deslocou-se para o protocolo fundamental. O objeto diz ter metaobject
`Dup`, mas nega `qt_metacast("Dup")`; um slot promete `int`, mas só existe como
`void`; uma classe D diferente pode ser descartada como registro repetido. Esses não
são recursos ausentes. São contratos aceitos com semântica errada.

O núcleo de geração, o corpus PySide e o Lippincott já justificam levar o projeto a
sério. A distância para PySide agora aparece menos em quantidade bruta e mais nos
invariantes que runtimes maduros não podem violar: identidade, metacast, threading,
falha de construção e CI reprodutível.

Resumo brutal: os gates pararam de mentir sobre entrada ruim. Agora façam o
metaobjeto parar de mentir sobre o objeto que ele representa.

## Resolução da rodada 8 (commits 4b76ba0..c611a95)

O protocolo de QObject foi corrigido nos pontos onde o metaobjeto mentia, e os
achados de CI/infra viraram estado explícito. Cada correção tem um teste que
falha sem o fix, verificado em ldc2+dmd e (onde aplica) Qt5+Qt6.

- **#2 (crítico) — `qt_metacast` honra a própria classe.** Os dois carriers
  (`QtdMocObject` e o trampolim `Qtd_<Base>`) delegavam direto à base, pulando o
  passo do moc que casa o nome próprio. Agora `QtdMocObject::qt_metacast` compara
  `mo->className()` e o trampolim usa `qtd_moc_classmatch` (lê o mo anexado).
  `metacast_test` + asserts em `moc_test` provam: nome próprio → `this`, base
  real → não-null, nome alheio → null.
- **#1 (crítico) — agregadores de CI separados.** As manifest gates viraram
  targets `optional()` do reggae: no grafo (alcançáveis por nome, exibidas como
  `(optional)` em `--list`) mas fora de `defaultTargets()`. O `./build` padrão não
  as roda mais; a CI as roda num passo advisory. `expected-fails-lint`/
  `lupdate-check` seguem mandatórios.
- **#3 (alto) — identidade real no registro QML.** A chave de idempotência usava
  `T.stringof` (colidia entre homônimos). Agora usa `T.mangleof` (identidade D
  inequívoca) mapeado de uma chave pública estruturada: mesmo tipo re-registrado é
  no-op; tipo DIFERENTE na mesma chave pública lança conflito. `homonym_collision_test`.
- **#4 (alto) — contrato de meta-métodos em compile time.** `@Slot` não-void é
  rejeitado (retorno seria descartado; um método com retorno é invokable, não
  slot); NOTIFY que não nomeia um Signal, ou com assinatura incompatível com o que
  `callProp` emite, também. `validateMeta!T` roda em `newQObject`/`qmlRegisterType`;
  `metacontract_test` prova as rejeições e que as formas válidas ainda compilam.
- **#5 (alto) — falha de factory QML é erro observável.** Quando o construtor D
  lança, a factory devolve null; o carrier não fica mais com `dobj==null` e entrada
  stale em `g_moAttach`. Limpa o side-table, emite `qWarning`, degrada a um QObject
  inerte (dispatch guardado contra `dobj` null). `boom_test` confirma: falha
  registrada (`qtdCallbackErrors`) e processo sobrevive.
- **#6 (alto) — threading explícito e enforced.** O runtime é single-threaded por
  design; agora a primeira mutação fixa uma owner thread e qualquer mutação de
  outra thread aborta (`qtd_thread_guard`) em vez de corromper mapa. Política
  documentada no topo de `qtmoc.d`; `qtd_moc_owner_check` + `metathread_test`
  provam a detecção sem disparar o abort. Tabelas por-thread/locking para QObjects
  worker seguem como follow-up estrutural.
- **#7 (médio) — CI reprodutível.** Removido o fallback que clonava HEAD do
  pyside-setup (falha de tag agora falha o job). A conformance exige a contagem do
  contrato (>=58 sample_*) e IDs canário, não `n>0`.
- **#8 (médio) — o report É a execução de record.** `test-report.sh` roda cada
  target uma vez, grava status/tempo/log e SAI não-zero em falha; a CI passou a
  gate nele em vez de re-executar a matriz e descartar o resultado. Dirty inclui
  não-rastreados; skips por capability aparecem como `skip`; targets `optional`
  são excluídos do record (corrige de quebra um bug latente do sufixo `(optional)`).
- **#10 (médio) — docs sem universais contraditórios.** "every target, both" virou
  "most targets, both" nomeando as exceções (gates/lupdate singleton, qmlaot/
  qmltypes Qt6-only); a tabela moc lista `t1..t11`.

**Toda a base foi passada para inglês** (comentários de runtime/generator/reggae/
testes; só este `CRITICS.md` fica em português por ser o documento da crítica).

**Follow-ups assumidos (não fingidos como resolvidos):**
- **#9** — o subgrafo libsample ainda anuncia produtores repetidos; o `flock` +
  checagem de `newerThan` mantém correto, mas a dedup real do DAG (como
  `qtdBindLib` faz pros bindings normais) segue pendente. Não mexi agora pra não
  arriscar um build que funciona.
- **#8 (arquitetural)** — coletar eventos da execução de record via reggae, em vez
  do re-spawn por-target do script.
- CI ainda **não** comprovada verde num runner real; baselines por Qt-minor;
  oracle diferencial de QRC vs `rcc`; runner de expected-fails; IR/typesystem;
  wrapper-default; Windows/SEH; qmltc-d (design travado no plano).

## Resposta à rodada 7 (escrita a 2026-08-12)

Dez achados. **Oito fechados, dois abertos** — e os dois abertos já estão nomeados nas rodadas
posteriores, o que é o desenho certo: um achado que atravessa rodadas deve aparecer com o mesmo nome
em todas.

- **#1 a CI não executava a matriz que o projeto chama de contrato: FECHADO na estrutura, ABERTO na
  prova.** `ci.yml` corre generate → build → test em Linux nos DOIS compiladores, com o cabeçalho a
  citar r5 #5 / r7 #1 / r8 #1. O que continua por provar é o mesmo item que a rodada 12 já nomeia:
  **verde num runner real**. Não se fecha desta máquina, e digo-o aqui outra vez em vez de o deixar
  implícito.
- **#2 `qmlRegisterType` detectava a falha em C++ e perdia-a na API D: FECHADO.** Hoje **lança**:
  conflito de tipo sob a mesma chave lança com a chave pública no texto; o backend a devolver null
  lança com o nome do tipo; e o mesmo tipo na mesma versão é um no-op explícito que **não volta a
  consumir o pool do Qt5** — que era a terceira parte do achado. A factory D que lança já não deixa
  um carrier sem backend: o caminho está guardado (é o r8 #5).
- **#3 o cache de metaobject não chaveava a forma completa: FECHADO, e a chave prova-o à vista.**
  `key` inclui hoje `nome:tipo@notify` por propriedade, com o comentário "NOTIFY participates too
  (critics r7 #3)", e os homónimos que o achado pedia existem como alvos (`homonym-*`,
  `homocollide-*`, oito no grafo) em vez de dois nomes diferentes a fingir uma colisão.
- **#4 os gates aceitavam metadado corrompido: FECHADO NOS DOIS, e ambos dizem FAIL-CLOSED na
  primeira linha.** O `manifest_gate.d`: "a malformed line, a duplicate class+USR key (in EITHER
  file), or a fate outside the fixed enum is a hard failure, not a warning" — os `dups` que a
  auditoria viu coleccionados e ignorados são hoje rejeitados. O `expected_fails_check.d`: valida o
  valor de `schema` contra o valor fixo do PROGRAMA (não o do documento), rejeita ids duplicados,
  exige strings não vazias nos campos obrigatórios, e exige que cada `probe_target` de um `risk`
  nomeie um alvo real de `./build --list`. "A typo can't invent an accepted schema/kind" está lá
  escrito como intenção e implementado.
- **#5 o consumidor de expected-fails não consumia expectativas: FECHADO** na rodada 12 —
  `expected-fails-run` executa as sondas, e hoje são 23 alvos sobre 24 entradas.
- **#6 o report inferia factos e produzia linhas falsas: FECHADO** (r8 #8): é a execução de registo,
  sai não-zero, marca DIRTY e regista *skip* em vez de um verde que não aconteceu.
- **#7 as APIs privadas testadas em duas instalações e não numa matriz de versões: ABERTO.** É o
  mesmo problema do #1 visto do outro lado, e o reggaefile já contém metade da resposta: os portões
  de baseline **desligam-se** quando o minor do Qt instalado difere daquele contra o qual a baseline
  foi gerada, com o raciocínio escrito no sítio — sem isso, uma regressão passaria despercebida
  precisamente na máquina cujo Qt bate certo. Falta o que a auditoria pediu: **dois minors Qt6 em
  jobs verdes**, e falha de API privada diagnosticável como incompatibilidade em vez de um `./build`
  vermelho indistinto.
- **#8 o grafo libsample agendava o mesmo produtor repetidamente: MEIO FECHADO, com número** — ver
  rodada 8 #9: `libsample.a` anunciado 116 vezes numa matriz completa, os outros três a zero.
- **#9 QRC era um subset estreito sem oráculo: FECHADO** — ver rodada 8 #10: PNG e bytes exactos
  através do próprio `QFile`/`QResource`.
- **#10 a documentação ficou atrás do código novo: FECHADO** — ver rodada 11 #7 e rodada 9.

**O que fica desta releitura de quatro rodadas (7 a 11), dito de uma vez:** trinta e seis achados,
**vinte e nove fechados**. Os que não fecham são sempre os mesmos sete, e agrupam-se em três
famílias: a fronteira do runtime partilhado, o contexto do compilador, e a prova institucional (CI
num runner real, dois minors Qt6, publicar). As duas primeiras são trabalho que eu adio porque
nenhum portão as mede. A terceira **não se fecha desta máquina** — e é a única das três em que adiar
não é uma escolha minha.

## Rodada 7: o código local amadureceu; a promessa institucional ainda não

Recomecei pelo estado atual, sem aceitar a resolução da rodada 6 como prova. Li os
changesets, o runtime QML/moc, os gates, o report, o grafo reggae, a CI, os testes
novos e a documentação; também voltei aos pontos estruturais de UIC/QRC, libsample e
geração. A régua continua sendo PySide: não basta uma máquina conseguir ficar verde.
O repositório precisa tornar difícil publicar uma regressão e precisa comunicar
falhas na API, não apenas no stderr.

### Verificação desta rodada

- Preservei a alteração preexistente em `runtime/uic/uiform.d` e o experimento
  não rastreado em `tests/qmltc/`.
- `./build --list` lista **158 targets**, dos quais **58** são `sample_*`.
- `./build` passou completo no ambiente local: Qt 5.15 + Qt 6.11, ldc2 + dmd,
  libsample/cornercases, QML, AOT, `.qmltypes`, WebEngine, UIC 60/60, QRC,
  lupdate e os gates.
- Os quatro `moclife_widget-*` passaram; os quatro `qmltwo-*` passaram.
- Os manifests reais passaram com **8343** símbolos QtWidgets e **2546** QML,
  agora chaveados por classe + USR.
- Reproduzi três falsos verdes com fixtures sintéticas:
  - baseline do manifest com a mesma classe+USR duas vezes: **exit 0 / OK**;
  - fate inexistente `typo-fate`: **exit 0 / OK**, contado como novo bound;
  - `expected-fails.json` com schema errado e dois IDs iguais: **exit 0 / OK**.
- O report classifica `expected-fails-check` como `other / qt6` e
  `qmltwo-ldc2` como `other / qt6`. O primeiro não pertence ao eixo Qt; o segundo
  pertence à categoria QML.
- `git diff --check` passou.

### O que foi realmente fechado

1. **O lifetime de `QtdWidget` foi corrigido.** O destrutor do trampoline chama
   `qtd_moc_detach`, e o teste exige que `g_moAttach` e `_reg` retornem ao baseline
   em Qt5/Qt6 e dmd/ldc2. A crítica anterior não permanece aberta.

2. **USR resolveu a colisão de overloads do manifest.** A identidade
   classe+USR é adequada para o problema observado, os manifests reais não têm
   colisões e o unittest pega overload desaparecido/regredido. O defeito novo está
   na robustez do loader, não na escolha da identidade.

3. **A preservação básica do lupdate agora é provada.** Catálogo traduzido sobrevive
   à atualização e falha de subprocesso é propagada. Plural, locations, comments e
   merge misto continuam incompletos, mas seria desonesto repetir que o driver
   simplesmente destrói traduções.

4. **A matriz local é séria.** Cinquenta e oito alvos derivados do libsample, nos
   dois compiladores, mais as superfícies Qt5/Qt6, não são demonstrações. O projeto
   está pressionando corner cases de binding que projetos superficiais nem modelam.

5. **O Lippincott continua sendo uma peça excepcional.** O guard compartilhado por
   assinatura ABI, com classificação central da exceção C++ e reerguimento tipado
   em D, continua bem desenhado e exercitado por exceção real. Ele reduz geração,
   preserva dead stripping e resolve uma fronteira de unwinding genuinamente difícil.
   A dívida é formalizar os pressupostos Itanium/POSIX e construir a resposta para
   SEH/MSVC. Não há razão técnica para diminuir o mérito do mecanismo.

### Achados críticos

#### 1. A CI adicionada não executa a matriz que o projeto chama de contrato

O workflow ainda é um arquivo não validado, e há bloqueios objetivos:

- o repositório usa `master` e `codegen-tools`, mas o trigger aceita `main` e
  `codegen-tools`; pushes em `master` não disparam;
- o install pede `libqt6qmlcompiler6-dev`, nome que não existe nos repositórios do
  Ubuntu 24.04 usados pelo runner;
- o grafo sempre cria os targets Qt6 WebEngine, mas a CI não instala
  `qt6-webengine-dev`;
- o workflow não obtém `../pyside-setup`; `libsampleTargets` retorna `[]` quando o
  clone não existe. Assim, os **58 targets que materializam o norte PySide somem
  silenciosamente da CI**;
- os baselines foram gerados em Qt 6.11, enquanto o comentário prevê Qt 6.4 no
  runner. O gate trata símbolos ausentes como regressão. Um baseline único entre
  minors diferentes tende a medir diferença de SDK, não regressão do gerador.

Isto é pior do que “pode precisar de ajuste”. A pipeline, como escrita, provavelmente
falha no `apt`; se passar dessa etapa, falha no WebEngine ou no manifest; e mesmo que
fique verde, pode fazê-lo sem a suíte libsample. Portanto a resolução “CI: Linux,
dmd+ldc2, Qt5+Qt6” ainda não é um fato.

Para a régua PySide, o clone/corpus externo não pode ser uma capability silenciosa.
Ou a CI o provisiona numa revisão pinada, ou o configure deve falhar quando o job
de conformance não o encontra.

#### 2. `qmlRegisterType` detecta falha em C++ e a perde na API D

`qtd_qml_register_type` retorna `nullptr` quando o pool Qt5 acaba ou quando
`QQmlPrivate::qmlregister` falha. Mas `qmlRegisterType(T)` retorna `void` e grava
incondicionalmente:

```d
_qmlFactories[key] = factory;
```

Logo uma falha vira uma factory sob a chave `null` e o chamador recebe sucesso
aparente. O comentário “HONEST failure” descreve o backend C++, não o contrato
público.

Há efeitos adicionais:

- se `qmlregister` falha, o `QtdQmlType` alocado não é liberado;
- em Qt5 o slot do pool já foi consumido antes dessa falha e não é revertido;
- registrar o mesmo tipo repetidamente continua consumindo slots; `qmltwo` faz uma
  repetição, mas não verifica deduplicação nem o limite;
- se a factory D lança, `__qmlMake` retorna `null`; o carrier C++ já foi construído
  e QML recebe uma instância sem backend D, em vez de uma criação explicitamente
  rejeitada.

Uma API madura precisa retornar type id/resultado ou lançar uma exceção D, limpar a
alocação e definir a semântica de registro duplicado. Escrever no stderr não é
propagação de erro.

#### 3. O cache de metaobject ainda não chaveia a forma completa, e o teste não testa homônimos

`buildMo` inclui classe, superclass, sinais, slots e `nome:tipo` das propriedades na
chave. Ele não inclui `propNotify`. Duas formas idênticas que diferem apenas no sinal
NOTIFY compartilham o mesmo `QMetaObject`; a segunda herda a associação de notify da
primeira.

O teste `register_two_test.d` diz que exercita “same-named-but-different types”, mas
declara `Alpha` e `Beta`. Como o nome da classe é a primeira parte da chave, esse
teste não pode colidir no cache nem provar a correção que o comentário reivindica.
Ele prova algo útil, porém diferente: dois nomes e duas formas distintas coexistem.

O teste correto precisa criar homônimos de módulos diferentes com o mesmo `T.stringof`
e variar separadamente sinais, slots, tipo de propriedade, superclass e NOTIFY.
A chave deve serializar todo dado que participa de `QMetaObjectBuilder`, inclusive
flags quando elas forem adicionadas.

### Achados altos

#### 4. Os novos gates aceitam metadado corrompido

O manifest loader coleta `baseDups`, mas `main` nunca consulta essa lista. Uma chave
duplicada no baseline é sobrescrita e aceita. Linhas com menos de quatro colunas são
silenciosamente ignoradas. Fate desconhecido recebe rank 2; quando novo, não é drop
e entra como bound benigno.

O unittest testa apenas `classify` com maps construídos em memória. Ele não passa
pelo parser, portanto não protege schema, duplicatas ou enum de fate. Foi assim que
os dois falsos verdes desta rodada passaram.

O checker de expected-fails tem o mesmo padrão:

- não valida o valor de `schema`;
- não rejeita IDs duplicados;
- não valida tipos ou strings vazias;
- confia no array `kinds` fornecido pelo próprio documento;
- não rejeita campos proibidos/incoerentes por kind.

Gates de governança devem fazer parsing estrito e falhar fechado. Se um typo inventa
uma nova categoria aceita, o contrato não existe.

#### 5. O “consumer de expected-fails” ainda não consome expectativas

O checker prova que certos campos existem e que nomes de probes aparecem em
`./build --list`. Ele não executa probes, não relaciona resultado a uma condição,
não representa expected-fail, não detecta unexpected-pass/fail e não expira
`remove_when`.

As entradas `known_gap` continuam sendo prosa sem evidência executável. As entradas
`risk` são melhor descritas como referências a targets; o fato de o target existir
não prova que foi rodado naquele ambiente. `windows-msvc` é chamado
`permanent_exclusion`, embora seu próprio `remove_when` diga que deve desaparecer
quando implementado.

É um schema linter útil. Ainda não é um runner de expected failures. O nome e a
documentação precisam manter essa distinção até existir avaliação de estado.

#### 6. O report continua inferindo fatos e já produz linhas falsas

As reproduções desta rodada bastam:

```text
expected-fails-check  other  -     qt6
qmltwo-ldc2           other  ldc2  qt6
```

O primeiro deveria ser governance/gate com Qt `-`; o segundo deveria ser QML.
Além disso:

- dirty state ignora arquivos não rastreados;
- ausência de capability remove o target do grafo, portanto nunca vira `skip`;
- não existem `expected-fail` e `unexpected-pass`;
- metadata depende de padrões de nome crescentemente frágeis;
- na CI, `test-report.sh` reroda individualmente os **158 targets** depois de
  `./build`, e seu exit code é descartado com `|| true`.

O script agora guarda logs e versões, avanço real sobre a rodada anterior. Mas uma
tabela auditável precisa receber metadata estruturada do grafo e observar uma
execução, não reconstruir a realidade pelo nome e repetir a suíte inteira.

#### 7. As APIs privadas continuam testadas em duas instalações, não numa matriz de versões

Qt5 5.15 e Qt6 6.11 verdes na máquina local são evidência boa. Não cobrem os minors
Qt6 nos quais `QQmlPrivate::RegisterType`, `QMetaObjectBuilder` e
`QQmlJSTypeDescriptionReader` podem mudar. A CI proposta usa justamente outro minor,
mas não resolve como versionar baseline, capability e expected result.

Para dizer “um futuro Qt7 será delta localizado”, primeiro é preciso provar pelo
menos dois minors Qt6 em jobs verdes e tornar falha de private API diagnosticável
como compatibilidade, não como um `./build` vermelho indistinto.

### Achados médios

#### 8. O grafo libsample ainda agenda o mesmo produtor repetidamente

Na execução completa, `libsample.a`, `gen.stamp`, `libbinding_{ldc2,dmd}.a` e
`libshims.a` foram anunciados muitas vezes em paralelo. Os locks impediram corrupção
e a suíte passou, mas o grafo não está deduplicando produtores compartilhados como
um DAG deveria.

Isso custa tempo, polui diagnóstico e aumenta muito o preço da CI, especialmente
quando o report repete todos os targets. `flock` é defesa de concorrência; não é
substituto para uma única instância de target por artefato.

#### 9. QRC permanece um subset estreito e sem oracle diferencial

Nada nesta rodada ampliou o único fixture ASCII. O parser manual continua sem
entidades XML, aspas simples, language/country, compression/threshold e validação de
duplicatas. O encoding de nomes continua perigoso para Unicode/non-BMP.

O projeto já mostrou no UIC a disciplina correta: corpus e comparação com a
implementação Qt. A mesma técnica deve comparar o blob/lookup produzido contra
`rcc`, incluindo aliases com path, prefixos múltiplos, vazio, Unicode e compressão.

#### 10. A documentação já ficou atrás do código novo

`docs/test-suite.md` ainda afirma “There is no CI” e “nothing yet reads the file”,
embora workflow e checker existam. Também fala em `~140` targets quando há 158 e
não lista `qmltwo`/`moclife_widget` nas categorias correspondentes.

Curiosamente, essas frases antigas são mais honestas sobre a efetividade atual do
que a resolução da rodada 6. Ainda assim, documentação contraditória impede que o
usuário saiba qual é o contrato pretendido. Parte da matriz e dos contadores deve ser
gerada do próprio grafo.

### Prioridade brutal da rodada 7

1. **Obter o primeiro verde real da CI.** Corrigir branch/pacotes/WebEngine, pinar
   Qt e provisionar uma revisão exata de `pyside-setup`. Falhar se os 58 `sample_*`
   não existirem no job de conformance.
2. **Fechar o contrato de erro de `qmlRegisterType`.** Retorno/exception, rollback
   Qt5, cleanup de `QtdQmlType`, duplicação definida e falha de factory observável.
3. **Testar o cache QML que vocês dizem ter corrigido.** Homônimos reais e variação
   isolada de NOTIFY/super/signatures; chave completa da forma.
4. **Tornar gates fail-closed.** Schema version fixo, enum fixo no programa, linhas
   malformadas, duplicatas dos dois lados, IDs únicos e testes que atravessem parser
   + `main`.
5. **Separar registry linter de expected-fail runner.** Condições estruturadas,
   execução, expected/unexpected pass/fail e expiração verificável.
6. **Eliminar inferência por nome no report.** Metadata no target, skip explícito e
   coleta do resultado da execução principal sem rerodar 158 alvos.
7. **Criar matriz real de Qt minors para private APIs e baselines por ambiente.**
8. **Deduplicar produtores do libsample no grafo.**
9. **Dar ao QRC o tratamento diferencial que tornou UIC convincente.**
10. **Continuar as dívidas estruturais:** IR do gerador, typesystem sem regex,
    wrapper como default e estratégia Windows/MSVC para o Lippincott.

## Resolução da rodada 7 (commits 327ac47..6482018)

Rodada sobre "verde que esconde regressão". Os três falsos verdes reproduzidos + os bugs reais:

1. **CI destravada dos erros objetivos (#1).** Trigger `master` (era `main`), pacotes reais
   (dropado o inexistente `libqt6qmlcompiler6-dev`), `qt6-webengine-dev` incluído, `../pyside-setup`
   provisionado (tag pinada) + **passo de conformance que falha se os `sample_*` sumirem**. Gates
   version-independent MANDATÓRIOS; manifest gates ADVISORY (baseline 6.11 ≠ Qt distro do runner —
   dito no arquivo). HONESTO: ainda não verde num runner real.
2. **Contrato de erro do `qmlRegisterType` (#2).** Agora **lança** exceção D se o backend recusa
   (pool Qt5 / `qmlregister`), em vez de gravar factory sob chave `null` e fingir sucesso; registro
   repetido é idempotente (não consome slot); C++ libera o `QtdQmlType` e faz rollback do slot Qt5.
3. **Cache de metaobject + teste de homônimo real (#3).** Chave inclui `propNotify` agora. E o teste
   `homonym` define DUAS classes `Dup` (mesmo `T.stringof`, módulos diferentes, formas diferentes),
   registra e instancia ambas — cada uma dispara SEU slot. Prova a chave-por-forma. Qt5+Qt6.
4. **Gates fail-closed (#4).** manifest gate: enum de fate FIXO no programa (typo-fate falha),
   dup-key rejeitado nos DOIS lados, linha malformada falha, e unittest atravessa o PARSER. Os três
   falsos verdes reproduzidos agora dão exit 1.
5. **Linter ≠ runner (#5).** O checker de expected-fails virou linter ESTRITO (schema/kinds/campos
   fixos no programa, IDs únicos, field-by-kind) e foi renomeado `expected-fails-lint`, honesto que
   não executa probes.
6. **Report corrigido (#6, concreto).** `expected-fails-lint`→gate/`-`, `qmltwo`/`homonym`→qml. A
   inferência-por-nome mais profunda (metadata do grafo) segue follow-up.
7. **Docs recorrigidos (#10).** "no CI"/"nothing reads the file" flertaram com o oposto; agora
   refletem o scaffold de CI + o linter; ~140→162 targets; qmltwo/homonym/moclife_widget listados.

Aberto, assumido sem fingir: primeiro verde REAL da CI num runner (#1/#7), matriz de Qt minors +
baselines por ambiente (#7), runner de expected-fails de verdade (#5 tail), dedup de produtores do
libsample no grafo (#8), oracle diferencial do QRC vs `rcc` (#9), matriz de tipos QML completa e
dívida estrutural (#10: IR, typesystem, wrapper-default, Windows/SEH).

### Veredito da rodada 7

O projeto passou de “ideia ambiciosa” para implementação tecnicamente séria. A matriz
local, o corpus libsample, a dupla Qt5/Qt6, o lifetime corrigido, o manifest por USR
e, especialmente, o Lippincott por assinatura são ativos reais. Eu não reduziria
isso a demo sem mentir.

Mas ainda não é PySide-mature. Hoje a prova mais forte vive numa workstation; a CI
não reproduz o corpus que define o objetivo e provavelmente nem instala. No runtime
QML, falha interna ainda vira sucesso público. Nos gates, entrada malformada ainda
vira verde. Esses são exatamente os lugares onde maturidade deixa de ser quantidade
de features e vira confiabilidade do contrato.

Resumo brutal: o mecanismo de binding já merece respeito. A governança ainda não
merece confiança automática. A próxima rodada não precisa de mais superfície para
parecer grande; precisa fazer CI, registro QML e gates falharem de modo impossível
de confundir.

## Resposta à rodada 6 (escrita a 2026-08-12)

Dez achados. **Oito fechados, um alargado mas ainda estreito, um ABERTO e é justo que esteja.**

- **#1 o cleanup de `g_moAttach` estava partido no caminho `QtdWidget`: FECHADO, e com o teste que
  faltava.** A auditoria tinha razão em dizer que a resolução da rodada 5 era falsa: o
  `moclife_test.d` só destruía um objecto criado por `newQObject`. Existe hoje
  `tests/wrapper/moclife_widget.d`, que abre a citar "critics r6 #1" e afirma as duas metades — a
  subclasse anexada regista **uma** entrada em `g_moAttach`, e destruí-la limpa `g_moAttach` **e** o
  `_reg` (`qobjOf(w) is null` depois). É alvo do build nos dois compiladores.
- **#2 o manifest gate perdia overloads: FECHADO.** A chave é hoje `class + USR`, que é exactamente
  o que a auditoria pediu ("enquanto a chave não incluir assinatura canónica/USR, a frase 'falha
  quando um símbolo desaparece' é objectivamente falsa"), e há unittest a provar o caso que ela
  reproduziu com um manifest sintético: dois USRs sob o mesmo `class+nome`, um desaparece, o gate
  falha. A segunda metade do achado — "gates só para duas superfícies" — está **melhor e não
  fechada**: são três (`qtwidgets`, `qml`, `controls`), continuam a faltar Qt5, WebEngine e os
  restantes specs.
- **#3 `expected-fails.json` sem consumidor: FECHADO** na rodada 12 (executado, 23 sondas).
- **#4 o report TSV não descrevia a matriz: FECHADO** (ver r8 #8 e r9 #3, com self-test).
- **#5 não existia CI: FECHADO na estrutura, ABERTO na prova** — ver r7 #1.
- **#6 a superfície QML pública era estreita: ALARGADA, e digo até onde.** `cppSig` aceitava seis
  tipos escalares; hoje aceita, além desses, **qualquer struct de valor ligada** (resolvida por
  `QMetaType::fromName`, o que cobre QColor/QSize/QRectF sem código por tipo), **QVariant** via
  `QmlVar`, **listas** via `QQmlListProperty<QObject>`, e **qualquer classe ligada** como `X*` — que
  é o que uma `property Item control` precisa. Os corner cases do registo que a auditoria listou
  estão fechados noutras rodadas: o pool do Qt5 e o resultado ignorado de `qmlregister` na r7 #2, o
  cache do metaobject por nome na r7 #3. O que continua por fazer é a lista de FORMAS — enum/flags
  como tal, revisions, singleton, uncreatable, attached/extension, read-only/required/constant —, e
  isso não é dívida escondida: é superfície por construir.
- **#7 `lupdate-d` — falta provar a semântica: METADE FECHADA, e a primeira versão desta resposta
  estava ERRADA. Corrijo-a aqui, que é onde ela foi escrita.** Eu tinha olhado para
  `tests/lupdate/fixture.golden.ts`, visto todas as traduções em `type="unfinished"` e concluído
  que a preservação de catálogo não estava provada. Não é o ficheiro golden que a prova — é o
  ALVO. O `lupdate-check` faz duas coisas em sequência: compara a extracção com o golden, e depois
  **copia o golden, injecta uma tradução a sério com `sed`, volta a correr o extractor sobre o mesmo
  catálogo e exige que a tradução ainda lá esteja**. Corri-o agora: *"lupdate-check OK: golden match
  + existing translation preserved across re-run"*, e o comentário no sítio cita a própria auditoria
  como razão de existir. Ler o fixture e não ler o alvo foi exactamente o erro que esta auditoria
  costuma apanhar-me a fazer.

  O que **fica** por provar, agora com a lista certa: o merge **D + QML/UI** (o driver encaminha
  `.ui`/`.qml` para o `lupdate` do Qt e junta com `lconvert`, mas o fixture não tem nenhum dos
  dois — zero ficheiros `.ui`/`.qml` no teste), **plural/numerus**, **source locations**, e a
  **propagação de erro de subprocesso** — que está escrita no código com o cuidado certo
  ("A subprocess FAILURE must fail us, not be swallowed", com `status != 0` a devolver 1 em três
  sítios) e **não** tem teste que a exercite com um subprocesso deliberadamente partido. Chamar ao
  conjunto "pipeline fechado" continua generoso; chamar-lhe "preservação não provada", como eu
  chamei há minutos, era falso.
- **#8 a documentação voltou a contradizer o código: FECHADO** — ver r11 #7.
- **#9 "UIC feature-complete" excedia o oracle: FECHADO.** Existem hoje dois diferenciais contra o
  **QUiLoader** do próprio Qt: `uicheck` sobre os fixtures e `corpus-check` sobre o corpus inteiro
  de `.ui` do Qt. A afirmação deixou de exceder o oráculo porque o oráculo passou a ser o Qt.
- **#10 o QRC estava muito menos coberto que o UIC: FECHADO** — ver r8 #10 (PNG, bytes exactos
  através do `QFile`/`QResource` do Qt).

**A releitura das cinco rodadas (6 a 11) fecha em 37 de 46, e meia.** O #7 continua a ser o único
achado destas cinco aberto **sem** estar noutra rodada com outro nome — os outros oito repetem-se —,
mas o que falta dele é menor do que eu escrevi: não é a preservação, é o merge com `.ui`/`.qml`,
plural, source locations e um teste que parta um subprocesso de propósito.

**E fica a lição, que é sobre mim e não sobre o código:** verifiquei o FICHEIRO e não o ALVO, e
escrevi uma acusação falsa com a confiança de quem tinha verificado. É a terceira vez esta semana
que a diferença entre "li o artefacto" e "corri a coisa" muda a conclusão.

## Rodada 6: vocês fecharam tickets; eu fui procurar falsos verdes

Li o projeto como se tivesse chegado agora: gerador, specs, runtime
`holder/qtmoc/uic/qrc`, grafo reggae, ferramentas, manifests, documentação e testes.
A régua continua sendo a declarada pelo projeto: maturidade comparável à do PySide,
não “funciona no meu app”.

Esta rodada não discute esforço. Discute se cada afirmação forte é sustentada pelo
contrato que o código e os testes realmente impõem.

### Verificação desta rodada

- O worktree já tinha uma alteração em `runtime/uic/uiform.d`; preservei-a.
- Durante a revisão apareceu também uma alteração do autor em
  `tools/lupdate/lupdate.d`; preservei-a e atualizei o texto abaixo para não criticar
  como ausente o que essa mudança já implementa.
- `./build --list` lista **149 targets**, não os 136 ainda citados no topo antigo.
- Os targets novos de QML/tr para Qt 5.15 passaram em ldc2 e dmd:
  `qml-qt5`, `qmlreg-qt5`, `moclife-qt5` e `tr-qt5`.
- `qml`, `qmlreg`, `qmlaot`, `qmltypes`, `tr`, UIC diferencial 60/60 e os dois
  manifest gates passaram nos caminhos exercitados.
- `dub test --root=tools/lupdate` passou: `1 modules passed unittests`.
- `lupdate-check` passou isoladamente.
- A matriz completa precisou ser repetida fora do sandbox porque `dub build`, chamado
  por `lupdate-check`, tentou reescrever o cache global `~/.dub`; isso é uma limitação
  ambiental desta execução, mas também mostra que o build não é hermético.
- A repetição de `./build` fora do sandbox passou completa, incluindo libsample em
  ldc2+dmd (`ALL PASS`), QML Qt5/Qt6, AOT, qmltypes, UIC 60/60 e os gates.
- Reproduzi um falso verde do manifest gate: baseline com dois overloads
  `C::foo` (`bound` e `unmapped-type`), current com apenas o segundo, e o gate retornou
  **exit 0 / OK**.

### O que melhorou de verdade

1. **A expansão Qt5 é substancial.** O mesmo backend QML, registro de tipo, lifetime
   do carrier e tradução rodam em Qt 5.15 e Qt 6.11, nos dois compiladores. O seam
   `QT_VERSION` para `QQmlPrivate::RegisterType` está localizado. Isso é engenharia
   real de compatibilidade, não uma segunda demo.

2. **Os drops agregados foram trazidos para o manifest.** QtWidgets agora tem 8343
   linhas e 681 `unmapped-type`; QML tem 2546 linhas e 544 `unmapped-type`. O residual
   “não per-symbol” reportado por `coverage.txt` chegou a zero nos dois bindings
   principais.

3. **A política de callback ficou coerente.** Os callbacks `nothrow` que antes
   engoliam `Exception` agora passam por `qtdOnCallbackError`. A busca atual não
   encontrou os catches silenciosos apontados na rodada anterior.

4. **`lupdate-d` entrou no grafo principal.** Há parser AST, fixture e golden. O
   downpayment é correto; a crítica agora é sobre semântica de atualização, não mais
   sobre ausência de integração.

5. **Há uma primeira camada de governança executável.** Manifest gate e report TSV
   existem. Ambos estão incompletos, mas já são código que pode ser endurecido em vez
   de uma intenção no README.

6. **O Lippincott por assinatura é uma das melhores peças do projeto.** Aqui o
   elogio precisa ser específico. Em vez de gerar milhares de wrappers C++ completos,
   o gerador declara o símbolo Qt apenas para obter seu endereço, agrupa chamadas pela
   assinatura ABI, passa o endereço a um guard C++ compartilhado e faz o
   `reinterpret_cast` para a função exata. O guard captura qualquer exceção C++ e o
   Lippincott central a classifica (`typeid` + `what()`), chama `qtd_throw_d` e a
   reergue como `QtCppException` do lado D.

   Isso resolve simultaneamente três problemas difíceis: exceção C++ não atravessa
   cegamente uma chamada `extern(C++)`, o custo não cresce como um wrapper por método,
   e `-ffunction-sections`/`--gc-sections` mantém no binário apenas os guards usados.
   O teste não é decorativo: `uicheck` lança uma exceção C++ real, atravessa o guard e
   a captura tipada em D; libsample também pressiona o caminho nos dois compiladores.

   Julgamento seco: isto é engenhoso de verdade. É o tipo de mecanismo que diferencia
   este projeto de um gerador superficial. A ressalva não diminui a conquista: ele
   depende conscientemente do ABI Itanium e do unwinder compartilhado no POSIX. A
   maturidade seguinte é transformar essa hipótese em probes formais por compilador/
   plataforma e definir a estratégia SEH/MSVC, não substituir a arquitetura que já
   funciona.

Reconhecimento seco: vocês responderam às oito prioridades com implementação. Isso
merece crédito. O problema é que algumas resoluções foram declaradas mais completas
do que são.

### Achados críticos

#### 1. O cleanup de `g_moAttach` continua quebrado no caminho `QtdWidget`

A resolução da rodada 5 diz que o destrutor limpa os side-tables “em TODO caminho”.
Isso é falso.

`runtime/qtmoc/qtdmoc.cpp` chama `qtd_moc_teardown` apenas no destrutor de
`QtdMocObject`. O caminho `QtdWidget` não usa esse carrier: `virtCpp` gera
`struct Qtd_<Base> : <Base>`, anexa metadata por `qtd_moc_attach`, mas não gera
destrutor nem conexão `destroyed` que remova `g_moAttach` e `_reg`.

O teste `moclife_test.d` deleta exclusivamente um objeto criado por `newQObject`,
portanto prova apenas o caminho que já possui `~QtdMocObject`. `cannon_widget.d`
exercita a subclasse anexada, mas nunca a destrói nem compara a contagem do side-table.

Impacto: destruir um `CannonField : QWidget @QObject` deixa:

- uma entrada stale em `g_moAttach`, sujeita a alias por reutilização de endereço;
- uma entrada em `_reg` contendo delegates que capturam o objeto D;
- o objeto D retido, mesmo depois do C++ morrer.

Isto não é só cobertura faltando. É um leak/lifetime bug exatamente no caminho que a
resolução afirmou ter fechado.

#### 2. O manifest gate perde overloads e já aceita regressão real

`tests/manifest_gate.d` usa a chave `class + symbol`. Assinatura não participa. Em uma
API como Qt isso é estruturalmente insuficiente.

Números atuais:

- QtWidgets: **356** chaves duplicadas; **136** têm fates diferentes.
- QML: **124** chaves duplicadas; **34** têm fates diferentes.
- O arquivo QtWidgets tem 8343 linhas, mas o gate anuncia apenas 7832 chaves.

Como o loader grava em associative array, o último overload sobrescreve os anteriores.
Um overload pode desaparecer, regredir ou trocar de fate e o gate continuar verde.
Eu reproduzi o desaparecimento com um manifest sintético e o programa respondeu
`manifest-gate OK`.

Enquanto a chave não incluir assinatura canônica/USR, a frase “falha quando um símbolo
desaparece” é objetivamente falsa. Ele falha quando desaparece o último overload
colapsado daquela classe+nome.

Também só há gates para Qt6 raw QtWidgets e Qt6 QML. Qt5, wrapper mode, WebEngine e
os demais specs não têm baseline. Isso é um gate útil de duas superfícies, não um
contrato da matriz.

#### 3. `expected-fails.json` ainda não tem consumidor

Adicionar `QQmlPrivate`, `QQmlJSTypeDescriptionReader` e `QMetaObjectBuilder` ao JSON
melhora o inventário, mas não cria enforcement. Nenhum código lê o arquivo.

Hoje não existe:

- schema validation;
- verificação de que `probe` nomeia targets existentes;
- avaliação de condição por Qt/compiler/plataforma;
- unexpected-pass;
- unexpected-fail;
- expiração ou `remove_when` executável;
- exigência de entrada para um gap novo.

Pior: dependência de API privada que deve compilar não é semanticamente um
“expected-fail”. Misturar risco, exclusão permanente e falha esperada no mesmo array
sem `kind` torna o modelo ambíguo antes mesmo de existir um runner.

`docs/test-suite.md` diz que essas entradas “block regression”. Não bloqueiam.

### Achados altos

#### 4. O report TSV não descreve a matriz que diz descrever

`tools/test-report.sh` é um bom protótipo, mas os dados já saem incorretos:
`qml-ldc2`, que é Qt6, aparece com coluna `qt` igual a `-`, porque o script infere os
eixos apenas do nome do target. O mesmo vale para grande parte dos targets Qt6
implícitos.

Além disso:

- targets opcionais ausentes são omitidos por `./build --list`; nunca aparece
  `status=skip`;
- `optional=yes` não informa qual capability faltou;
- o script só conhece `pass`/`fail`, apesar do contrato pedir skip/expected-fail;
- stderr/stdout são descartados, então um failure row não é diagnosticável;
- não há Qt patch version, tool versions, plataforma ou estado dirty;
- o report não é target do build nem artefato de CI;
- se `./build --list` falhar, sem `pipefail`, o script pode produzir totais vazios.

Ele é uma tabela sobre nomes de targets, não ainda um resultado auditável da matriz.

#### 5. Não existe CI no repositório

Não há workflow GitHub/GitLab/Azure. Portanto “matriz” hoje significa uma máquina com
Qt 5.15 e Qt 6.11 instalados, não uma política contínua.

Para o norte PySide isto é o maior buraco organizacional: nenhuma mudança é obrigada
pelo repositório a passar nos dois compiladores, nas duas versões Qt, nos probes
privados, nos gates ou no corpus. A suíte local é forte; a governança automática é
zero.

O barulho de scheduling repetido no `libsample` também continua extremo: os mesmos
`gen.stamp`, `libsample.a`, `libbinding_*` e `libshims.a` são anunciados muitas vezes.
O `flock` evita corrupção, mas não transforma o grafo em um DAG limpo.

#### 6. A frente QML é real, mas a superfície pública ainda é estreita

O bridge provado hoje cobre um happy path importante: property escalar, sinal e slot
`void`, exposição por context property, instanciação pelo engine e `.qmltypes`.
Isso não é demo. Também não é ainda uma API QML madura.

`cppSig` aceita apenas `int`, `bool`, `double`, `float`, `uint` e `string`. Faltam,
entre outros, enum/flags, QObject, value types Qt, QVariant, listas/modelos, URLs,
cores, datas e nullability. Também faltam método com retorno, read-only/required/
constant/final/resettable property, revisions, singleton, uncreatable type, attached/
extension types e ownership explícito.

Há corner cases concretos no registro:

- Qt5 usa um pool global fixo de 256 creators. No overflow, registra `create=nullptr`,
  continua chamando `qmlregister` e devolve sucesso aparente.
- registros repetidos também consomem o pool; não há dedup nem teste do limite;
- `QQmlPrivate::qmlregister` tem o resultado ignorado;
- `buildMo` cacheia somente por nome de classe, ignorando superclass e a descrição
  completa. Duas classes D homônimas podem receber o metaobject errado;
- os testes registram um único `Backend`; o comentário sobre “N tipos coexistem” se
  refere a um probe que não está no repositório;
- não há asserção de cleanup quando o engine destrói uma instância QML.

Para maturidade PySide, o próximo passo não é mais outro hello-world QML. É uma matriz
de tipos e lifetime adversarial, compartilhada por Qt5 e Qt6.

#### 7. `lupdate-d` corrigiu o risco imediato; agora falta provar a semântica

O extrator D é AST-based, decisão correta. O driver de atualização ainda não possui a
semântica comprovada de um `lupdate` maduro.

Durante esta revisão o código foi alterado para copiar o `.ts` existente para o merge,
retornar erro quando `lupdate`/`lconvert` falham e rejeitar uma invocação sem inputs.
Isso endereça corretamente os dois bugs mais graves que encontrei na leitura inicial.

O gap que resta é de teste e fidelidade:

- o teste golden cobre extração D, não preservação de tradução, merge D+QML/UI,
  plural/numerus, source locations, translator comments ou propagação de erro;
- a extração profunda de literais pode tratar strings internas de expressões não
  literais como source/disambiguation.

Chamar o conjunto de “pipeline fechado” ainda é generoso demais até o novo merge ser
testado com catálogo traduzido e subprocessos falsamente quebrados. Mas a crítica
correta agora é “mudança não provada”, não “driver ainda descarta traduções”.

### Achados médios

#### 8. A documentação voltou a contradizer o código imediatamente

Exemplos atuais:

- README e `docs/FEATURES.md` ainda dizem UIC **53/53**; a suíte é 60/60.
- README e `docs/test-suite.md` ainda dizem que 493/425 drops ficam fora do manifest;
  o código agora reporta residual zero.
- README afirma que `X_new(...)` “não é supported spelling”, enquanto raw mode é o
  default e dezenas de testes, UIC e QML usam exatamente `QWidget_new`,
  `QQmlApplicationEngine_new`, etc.
- README afirma que **every feature** roda em Qt5 e Qt6, mas o próprio grafo marca
  Qt5 AOT como follow-up e valida `.qmltypes` apenas com Qt6QmlCompiler.
- `docs/test-suite.md` diz que todo target roda em ldc2 e dmd; `lupdate-check` e os
  manifest gates são singletons.
- `docs/FEATURES.md` chama UIC de feature-complete; `docs/uic-spec.md` ainda abre como
  roadmap de proof-of-concept, mantém checklist majoritariamente incompleto e diz
  “tr() is a later pass”.

O problema não é polish. A documentação não pode ser usada para decidir o que está
suportado.

#### 9. “UIC feature-complete” excede o poder do oracle atual

60/60 é um ótimo corpus baseline. O dump diferencial, porém, compara:

- objetos nomeados;
- classe, parent e um texto visível;
- uma lista selecionada de propriedades;
- alguns value types especiais.

Ele ordena linhas, logo não verifica ordem de siblings, e não cobre toda propriedade,
layout semantics, action ordering, overload gerado ou equivalência de código com
`pyside6-uic`. Existem checks comportamentais extras, mas o oracle continua parcial.

A formulação madura é “60 forms passam no oracle definido”, não “spec completa”.

#### 10. O QRC é útil, mas está muito menos coberto que o UIC

O parser manual de `.qrc` tem um único fixture ASCII. Não há testes para language/
country, compression, threshold, aliases com path, entidades XML, duplicatas,
prefixos múltiplos, nomes Unicode ou arquivos vazios.

`utf16be` afirma BMP-only sem validar; o name length usa bytes UTF-8, não unidades
UTF-16. Nome não ASCII pode gerar blob inválido, e non-BMP certamente não tem surrogate
pair correto.

Isto é um CTFE resource packer funcional para o subset atual. Não é ainda substituto
geral auditado de `rcc`.

### Correções de linguagem obrigatórias

Até os contratos serem ampliados, parem de escrever:

- “cleanup em TODO caminho”;
- “símbolo desaparecido sempre falha o gate”;
- “expected-fails bloqueiam regressão”;
- “every feature em Qt5 e Qt6”;
- “`X_new` não é suportado”;
- “UIC feature-complete”.

Essas frases não são ambiciosas. São falsas no estado atual.

### Prioridade brutal da rodada 6

1. **Consertar lifetime de `QtdWidget`.** Gerar destrutor/teardown para o trampoline
   anexado e adicionar teste que destrói a subclasse e exige `g_moAttach` + `_reg`
   de volta ao baseline.
2. **Dar identidade real ao manifest.** Classe + assinatura canônica/USR + kind;
   rejeitar chaves duplicadas; testar overload sumido/regredido.
3. **Criar runner de expected-fails/risk registry.** Schema, condições, probe target,
   unexpected-pass/fail e expiração. Separar `risk`, `expected_fail` e `permanent_exclusion`.
4. **Pôr a matriz em CI.** Pelo menos Linux, dmd+ldc2, Qt 5.15+Qt 6.x, artifacts de
   report/coverage e gates obrigatórios.
5. **Tornar o report verdadeiro.** Metadata explícita no target, Qt exato, skip reason,
   expected status, dirty state e log de falha; não inferir tudo do nome.
6. **Provar o `lupdate-d` endurecido.** Testar merge/preservação, falha de subprocesso,
   plural e fazer um único fixture atravessar o pipeline inteiro.
7. **Fazer a matriz QML adversarial.** Múltiplos tipos homônimos/diferentes, registro
   repetido, limite Qt5, destruição pelo engine, erros de factory, enums, QObject,
   listas/modelos, retornos e property flags.
8. **Reescrever docs a partir do grafo atual.** Sem números e absolutos stale; gerar
   partes da matriz/coverage automaticamente.
9. **Definir honestamente os subsets de UIC e QRC.** Expandir oracle/corpus antes de
   promover a palavra “complete”.
10. **Continuar a dívida estrutural já conhecida.** Wrapper como default, IR do
    gerador, typesystem sem regex, ABI probes e Windows/MSVC continuam abertas.

## Resolução da rodada 6 (commits c5240e0..948dcb9)

Rodada sobre falsos verdes. Cada achado atacado — provando que o verde não esconde a regressão:

1. **QtdWidget lifetime (#1, era falso "TODO caminho").** O trampolim `Qtd_<Base>` ganhou
   destrutor `~Qtd_<Base>() { qtd_moc_detach(this, d); }`; `moclife_widget.d` cria a subclasse,
   destrói e EXIGE `g_moAttach`+`_reg` no baseline. `moclife_widget-{ldc2,dmd}-{qt5,qt6}` verde.
2. **Manifest com identidade real (#2, false-green reproduzido).** Chave = classe + **USR** do
   clang (inclui assinatura) → overloads são linhas distintas (QtWidgets 7832→8343). Gate detecta
   dup-key, e roda `-unittest --DRT-testmode=run-main` (testa overload sumido/regredido) ANTES do
   check real. Provado: dropar 1 overload agora dá exit 1.
3. **Consumer de expected-fails (#3).** Schema v2 com `kind` (permanent_exclusion/known_gap/risk)
   + `probe_targets` estruturados; `expected_fails_check.d` valida schema + que todo probe nomeia
   target REAL de `./build --list`. Target `expected-fails-check`.
4. **CI (#5, maior buraco).** `.github/workflows/ci.yml`: Linux, dmd+ldc2, Qt5+Qt6, gates
   obrigatórios, artifacts. HONESTO: não validado em runner real (Qt distro ~6.4 ≠ 6.11 do dev box).
5. **Report verdadeiro (#4).** Eixo Qt correto (`qml-ldc2`→qt6, não `-`), header com commit/dirty/
   versões exatas/caps, coluna de log em falha, pipefail.
6. **lupdate endurecido (#6).** Falha de subprocess → exit≠0; catálogo existente PRESERVADO (merge
   lconvert com o catálogo por último = vence); `lupdate-check` testa preservação (KEEP_ME).
7. **QML adversarial (#7, parcial).** buildMo agora chaveia por FORMA (não só nome) → homônimos não
   colidem; overflow do pool Qt5 não finge sucesso; resultado de `qmlregister` checado. `qmltwo`
   registra 2 tipos distintos e instancia AMBOS. Achou limitação real (typeId compartilhado quebra
   property tipada cross-tipo no Qt6) → known_gap. Falta a matriz de tipos completa.
8. **Docs sem falsos absolutos (#8/#9 + linguagem).** Corrigidos: X_new (raw mode USA), 53→60,
   493/425→residual 0, "every feature Qt5+Qt6" qualificado, "expected-fails bloqueiam" → é
   inventário, "feature-complete" → "60 forms passam no oracle definido".

Aberto (assumido): matriz de tipos QML completa (#7 tail), unexpected-pass/fail runner (#3 tail),
plural/merge do lupdate (#6 tail), gates além de Qt6-raw/Qt6-QML, e a dívida estrutural (#10:
wrapper-default, IR, typesystem sem regex, Windows). CI precisa de primeiro verde num runner real.

### Veredito da rodada 6

O projeto está claramente melhor. A paridade QML/tr Qt5+Qt6, os callbacks observáveis,
o manifest completo para drops e o lupdate no grafo são trabalho sério. Não retiro
nenhum desses créditos.

Mas esta foi a rodada em que a governança nova começou a ser testada contra si mesma,
e ela falhou em pontos básicos: overloads desaparecem sem quebrar o gate,
expected-fails não são executados, o report mente o eixo Qt e o cleanup “total” omite
o caminho de subclasse anexada.

Resumo brutal: vocês não estão mais construindo uma demo. Também não podem mais usar
testes estreitos para autorizar frases universais. A próxima maturidade não virá de
mais targets verdes; virá de provar que um verde não consegue esconder a regressão
que ele afirma vigiar.

## Resposta à rodada 5 refeita (escrita a 2026-08-12)

Oito achados. Desta vez **corri cada alvo antes de escrever sobre ele** — foi ler o artefacto em vez
de correr a coisa que me fez escrever uma acusação falsa sobre o `lupdate` há uma hora. **Sete
fechados, um aberto.**

- **#1 dependência de API privada tratada como risco de primeira classe: FECHADO.** É exactamente o
  que a auditoria escreveu que "PySide-mature" significa, item a item: as APIs privadas estão
  **isoladas atrás de seams `QT_VERSION`** (README:12), o risco está **assumido nos docs** com essas
  palavras ("`QMetaObjectBuilder` is a Qt private API… treated as a compatibility risk, exercised on
  the Qt versions in the test matrix (6.11, 5.15)"), e há **entradas de inventário dedicadas** —
  quatro: `moc-private-metaobjectbuilder`, `qml-private-qqmlprivate`,
  `qml-private-typedescreader`, `uic-private-widgets. O que falta é a **matriz de versões** (dois
  minors Qt6), que é o mesmo aberto das rodadas 7 e 9 e está nomeado lá.
- **#2 o manifest era do caminho object-method e não da API inteira: FECHADO.** A auditoria contou
  493 drops FORA do manifest em QtWidgets e 425 em QML. Hoje o manifest tem **8429 linhas** e cada
  símbolo traz um fate: `bound` 4479, `inherited` 1487, `shimmed` 1046, `unmapped-type` 725,
  `signal` 501, `pure-virtual` 190. Os "drops" deixaram de estar num rodapé agregado — passaram a
  ser fates com nome, dentro do ficheiro que o portão compara.
- **#3 manifest e expected-fails sem enforcement: FECHADO, e corri os três.**
  `manifest-gate OK [qtwidgets]: 8428 symbols (class+USR), no regression, manifest well-formed
  (0 new bound)`; `expected-fails-lint OK: 24 entries valid (strict)`; `expected-fails-run OK: 23
  probe target(s) executed, every documented risk still covered`. A lista de seis condições que a
  auditoria disse nunca ter visto falhar está coberta por estes três, e o "um expected-fail passa
  sem ser removido" foi visto a falhar **hoje**, a sério, quando a inversão da ordem de completação
  começou a funcionar.
- **#4 a política de callback error era incompleta: FECHADO.** Zero `catch (Exception) {}` vazios em
  `generator-d/*.d` e `runtime/qtmoc/*.d`; catorze sítios encaminham para `qtdOnCallbackError`.
- **#5 cleanup de metaobject parcial: FECHADO** — ver r6 #1, com o teste do caminho `QtdWidget` que
  faltava.
- **#6 `lupdate-d` fora do build de record: FECHADO** — `lupdate-check` é alvo do build e corre.
- **#7 docs stale: FECHADO** — ver r11 #7.
- **#8 build verde ainda não é report estruturado: FECHADO, e é o achado mais valioso que esta
  auditoria produziu.** Está respondido na adenda no topo deste ficheiro, com as duas vezes de 11 de
  Agosto e mais duas de hoje. Nenhuma delas foi a auditoria a apontar o caso concreto — foi o
  DESENHO que ela impôs a apanhá-los.

**A releitura de seis rodadas (5 a 11) fecha em 44 de 54.** Restam as rodadas 4 e anteriores.

## Rodada 5 refeita: QML entrou no jogo, agora a cobranca muda

Esta rodada substitui a "Rodada 5" anterior. Ela estava factual e temporalmente
defasada: dizia worktree limpa e 126 targets. O estado atual tem alteracao local em
`runtime/uic/uiform.d`, adicionou a frente QML/lupdate e a matriz local agora lista
**136** targets.

### Verificacao desta rodada

- Worktree **nao** estava limpa: `CRITICS.md` e `runtime/uic/uiform.d` modificados.
  Nao reverti nem sobrescrevi a mudanca de `uiform.d`.
- `./build --list` lista **136** targets.
- `./build` passou completo localmente.
- Novos alvos QML passaram em ldc2+dmd:
  `qml`, `qmlreg`, `qmlaot`, `qmltypes`, `tr`.
- UIC diferencial passou com **60/60** no corpus atual.
- `dub test` em `tools/lupdate` passa: `1 modules passed unittests`.
- `generated/qt-6.11/cxx-qtwidgets/coverage.txt`: 7850 linhas no manifest
  object-method; 681 drops agregados; **493 drops ainda fora do manifest por simbolo**.
- `generated/qt-6.11/cxx-qml/coverage.txt`: 2121 linhas no manifest
  object-method; 544 drops agregados; **425 drops ainda fora do manifest por simbolo**.

### O que melhorou de verdade

1. **A frente QML e real.** Nao e README bait. Ha D `@QObject` exposto via
   `setContextProperty`, `qmlRegisterType!T`, QML instanciando tipo D, property/slot
   round-trip, qrc, qmlcachegen AOT sem `.qml` fonte, `.qmltypes` gerado por CTFE e
   validado pelo leitor Qt, alem de `tr()` com `.qm`.

2. **A direcao PySide ficou mais crivel.** Antes o projeto parecia "Qt Widgets +
   runtime moc". Agora existe uma historia de QML frontend / D backend com type
   registration, tooling metadata e traducao. Isso e o caminho certo para competir
   em ergonomia real, nao so em ABI.

3. **A matriz local ficou mais forte.** 136 targets verdes, dmd+ldc2, Qt5/Qt6 onde
   aplicavel, QML, WebEngine, UIC diferencial, qrc, holder, ownership e libsample.
   Isso nao e demo. Repito porque agora e ainda mais verdadeiro.

4. **`g_moAttach` nao esta mais "sem cleanup algum".** O caminho QML-created apaga
   `g_moAttach` no destroy e chama o destroy callback D. A critica antiga precisa
   ser reduzida: o cleanup existe num caminho importante.

5. **`lupdate-d` usa parser, nao regex.** Isso importa. Para traducao em D, usar
   libdparse e delegar `.ui/.qml` ao lupdate Qt e uma decisao tecnicamente adulta.

### O que ainda esta errado

#### 1. QML adiciona valor, mas tambem adiciona dependencia privada pesada

`qmlRegisterType` usa `QQmlPrivate`, e `.qmltypes` usa
`QQmlJSTypeDescriptionReader` / QtQmlCompiler private API. Isso pode ser a escolha
pragmatica certa agora, mas precisa ser tratado como risco de compatibilidade de
primeira classe, igual `QMetaObjectBuilder`.

PySide-mature nao significa "usa private API e torce". Significa: matriz de Qt
versions, probes dedicados, expected-fails quando a private API muda, e docs
assumindo explicitamente o risco.

#### 2. O manifest continua parcial, agora tambem no modulo QML

O manifest por simbolo existe e e util. Mas QtWidgets ainda tem 493 drops fora do
manifest, e QML tem 425. Isso mata qualquer frase forte do tipo "sabemos o destino
de cada simbolo".

Assessment duro: o manifest atual e um manifest do caminho object-method, nao da
API inteira. Enquanto value-type/wrapper/ctor/stub drops ficarem agregados no
rodape, coverage ainda e evidencia parcial.

#### 3. Manifest e expected-fails continuam sem enforcement

Eu ainda nao vi um target que falhe quando:

- aparece novo `unmapped-type`;
- aumenta o numero de drops fora do manifest;
- um `shimmed` vira `inline-failed`;
- um simbolo some;
- um expected-fail passa sem ser removido;
- surge gap sem entrada em `tests/expected-fails.json`.

`tests/expected-fails.json` e um bom artefato, mas sem consumidor ele e inventario,
nao policia.

#### 4. A politica de callback error ainda e incompleta

`newQObject` e `qmlRegisterType` usam `qtdOnCallbackError`. Ainda existem
`catch(Exception){}` silenciosos em caminhos relevantes:

- virtual override trampolines gerados por `__ovTramp`;
- delegates de slot/property do `QtdWidget`;
- signal-to-delegate trampoline em `emit_cxx.d`;
- callbacks de conversao de containers em `emit_cxx.d`.

O projeto agora tem QML chamando D. Isso torna silencio em callback ainda mais
grave: erro engolido em binding QML vira bug de UI invisivel.

#### 5. Cleanup de metaobject ainda e parcial

O caminho QML-created limpa `g_moAttach`. Bom. Mas `qtd_moc_new` tambem insere em
`g_moAttach`, e `qtd_moc_attach` para trampolim/subclasse tambem. Eu nao vi cleanup
equivalente para esses caminhos.

Se a resposta for "esses objetos vivem ate o fim", escreva e teste isso. Se nao,
limpe. O estado atual e melhor que antes, mas ainda nao fecha a historia de vida
util do side-table.

#### 6. `lupdate-d` passa unittest, mas nao esta no build de record

`dub test` em `tools/lupdate` passa. Ponto para o projeto. Mas `./build` nao roda o
extrator; o target `tr-*` usa `.ts` existente e `lrelease`, validando o runtime de
traducao, nao o pipeline completo `D source -> lupdate-d -> .ts -> .qm -> tr()`.

Para maturidade, `lupdate-d` precisa entrar no grafo principal ou em um target de
tools, com golden `.ts` e round-trip.

#### 7. Docs ficaram stale de novo

README ainda diz que per-method manifest e follow-up, mas
`coverage-manifest.tsv` ja existe. A verdade atual e: manifest existe, mas e
parcial e sem gate.

`docs/test-suite.md` ainda fala em coverage manifest como se fosse
`coverage.txt`, e a suite documentada ainda nao reflete os 136 targets/QML/AOT/
qmltypes/tr/UIC 60/60. Isso precisa ser corrigido rapido. Neste projeto, doc stale
nao e estetica; e perda de auditabilidade.

#### 8. Build verde ainda nao e report estruturado

`./build` passou, mas a prova e stdout enorme. Nao ha JSON/TSV com target,
categoria, compiler, Qt, status, duracao, skip/opcional e commit. Agora que a
matriz tem 136 targets e alvos opcionais por disponibilidade (`qmlcachegen`,
`Qt6QmlCompiler`, `lrelease`), isso deixa de ser luxo.

Tambem continua aparecendo ruido de agendamento no libsample (`gen.stamp`,
`libbinding_*`, `libshims.a`, `libsample.a` anunciados repetidamente). O guard
segura a execucao; o grafo ainda nao parece limpo.

### Prioridade da rodada 5 refeita

1. **Atualizar docs da suite e coverage para o estado real.** 136 targets, QML,
   AOT, qmltypes, tr, UIC 60/60, manifest parcial.
2. **Completar o manifest por simbolo.** Zerar "drops fora do manifest" em
   QtWidgets e QML.
3. **Criar gate do manifest + expected-fails.** Baseline, diff, unexpected-pass,
   unexpected-fail e gap nao rastreado.
4. **Aplicar `qtdOnCallbackError` em todos os callbacks nothrow.**
5. **Fechar cleanup de `g_moAttach` para todos os caminhos ou documentar/testar a
   vida util intencional.**
6. **Adicionar `lupdate-d` ao build de record.** Golden `.ts` + round-trip para
   `.qm` + `tr()`.
7. **Gerar test report estruturado.** Principalmente agora que ha targets
   opcionais e matriz maior.
8. **Tratar APIs privadas QML como risco versionado.** Probes e expected-fails por
   versao Qt, nao apenas comentarios.

### Veredito da rodada 5 refeita

O projeto melhorou mais do que a rodada 5 anterior reconhecia. A frente QML muda
o patamar: agora ha uma historia plausivel de app real, nao so binding de classes
Qt. `qmlRegisterType`, AOT, `.qmltypes`, traducao e UIC 60/60 sao substancia.

Mas a nova maturidade cobrada tambem sobe. QML privado, tooling metadata,
traducao, ownership de objetos criados pelo engine e callbacks cross-language
precisam de governanca. O projeto esta mais forte; tambem ficou mais perigoso.

Resumo brutal: voce esta construindo algo real. Agora pare de deixar artefatos
bons viverem como ilhas. Suite, manifest, expected-fails, lupdate, QML private API
e callback policy precisam virar contrato unico, versionado e quebravel.

> **Resolucao da rodada 4 (resumo no topo; detalhe por commit d5910b6).** Ataquei pela
> "prioridade brutal": **#1 manifest por simbolo** -> `coverage-manifest.tsv` (fate por metodo:
> bound/shimmed/signal/inherited/pure-virtual/unmapped-type/inline-failed) + `coverage.txt` com
> breakdown real e agregado honesto (drops de value-type/wrapper flaggeados como TODO, nao
> escondidos). **#6 excecao em callback** -> `qtmoc.qtdOnCallbackError` (count + last-error +
> hook global + stderr debug) no lugar de `catch(Exception){}`; teste `cannon_t11`. **#11
> comentarios legados** -> `gen.d`/`uiform.d` corrigidos. **#5 ownership** avancou (excecao em
> callback coberta). Roadmap declarado (nao feito): placar historico, IR, typesystem, ABI
> probes, Windows. Regressao 126/126, ldc2+dmd, Qt5+Qt6, corpus 53/53.

## Resposta à rodada 4 refeita (escrita a 2026-08-12)

A rodada mais antiga do ficheiro, e a que envelheceu melhor: as três prioridades que ela declarou
"brutais" foram todas atacadas, e duas fecharam. **Sete fechados, três abertos, um parcial.**

- **#1 coverage não respondia "qual símbolo falhou": FECHADO, e era a prioridade nº1 dela.** Existe
  o manifest por símbolo que ela desenhou, com os fates que ela nomeou:
  `coverage-manifest.tsv`, 8429 linhas, `cppClass · symbol · usr · fate`, com `bound` (4479),
  `inherited` (1487), `shimmed` (1046), `unmapped-type` (725), `signal` (501), `pure-virtual` (190)
  e `inline-failed`. E é **gated** — `manifest-gate OK [qtwidgets]: 8428 symbols (class+USR), no
  regression`, corrido agora.
- **#2 a suíte precisava de placar por categoria/compilador/Qt: FECHADO na estrutura.** O
  `tools/test-report.sh` emite TSV com colunas explícitas — categoria, compilador, Qt, capability
  opcional, status (pass/fail/skip), duração — e tem self-test do parser (r9 #3). O que a auditoria
  pediu e **não** existe é a metade "histórica": os contadores são de uma execução, não persistidos
  ao longo do tempo. Dito como parcial, não como fecho.
- **#3 o gerador é grande demais para auditar com conforto: ABERTO.** O `emit_cxx.d` continua a
  concentrar AST walk, política de tipos, emissão textual, heurísticas ABI, recovery de inline
  methods, shim C++ e diagnóstico. É a mesma família do "contexto explícito" das rodadas 9/10/11 —
  o compilador e o gerador têm o mesmo defeito de fronteira, e nenhum dos dois tem portão.
- **#4 o subset regex do typesystem é tecto real: ABERTO**, e a rodada 12 explica porquê a resposta
  foi outra: em vez de anotar 8428 símbolos com semântica de ownership, o `ownership-gate` impede a
  superfície perigosa de CRESCER. É uma escolha, não um fecho, e está dita como escolha.
- **#5 ownership é área de morte do binding: FECHADO** na rodada 12 — borrowed por omissão
  (`_ownedByD`), impasse do `exit()` provado por coredump, `ownership-gate`, e duas classes
  não-`QObject` classificadas por critérios verificáveis.
- **#6 o metaobject runtime engolia excepções: FECHADO** — ver r5 #4: zero `catch (Exception) {}`
  vazios, catorze sítios em `qtdOnCallbackError`.
- **#7 `qtdmoc.cpp` usava mapas globais sem história de cleanup: FECHADO** — ver r6 #1 e r11 #1: os
  dois caminhos limpam, e há dois testes que exigem as tabelas de volta ao valor de base
  (`moclife_test.d`, `moclife_widget.d`, `leaf_lifetime.d`).
- **#8 XML feito à mão em UIC/QRC exige corpus e não confiança: FECHADO.** 60 `.ui` no corpus,
  diferenciados contra o **QUiLoader do próprio Qt** (`corpus-check`), e o QRC a servir bytes
  exactos através do `QFile`/`QResource` do Qt. O oráculo deixou de ser a nossa opinião.
- **#9 assumptions de ABI/layout precisam de probes formais: ABERTO.** O `emit_cxx.d` raciocina
  sobre `sizeof`/layout em vários sítios (o comentário do QList com `begin@8, end@12, array[]@16` é
  o exemplo), e existem provas indirectas — `valuetypeprop`, `subclasscast`, `ctorguard` — mas não
  há um probe que afirme os layouts em si. É o achado mais antigo ainda por tocar.
- **#10 Windows/MSVC fora da maturidade PySide: ABERTO** e nunca disputado.
- **#11 comentários antigos feriam a credibilidade: FECHADO.** `generator-d/gen.d` abre hoje a
  descrever o que é ("shared front-end for the binding generator, in D on the libclang C API");
  `runtime/uic/uiform.d` abre como "a compile-time (CTFE) `uic`" e não como subset proof-of-concept.

---

## Fecho da releitura completa (2026-08-12)

**Sete rodadas relidas (4 a 12), 65 achados, 52 fechados.** O que resta agrupa-se em quatro
famílias, e nenhuma é surpresa:

1. **Fronteiras** — o runtime partilhado (r9 #2, r11 #5) e o gerador/compilador (r4 #3, r9 #4,
   r10 #6, r11 #6). Abertas há cinco rodadas e a métrica das duas ANDOU PARA TRÁS hoje.
2. **Prova institucional** — CI verde num runner real, dois minors Qt6, publicar (r5 #1, r7 #1,
   r7 #7, r12 #6). Não se fecham desta máquina; a última depende da licença.
3. **Superfícies por construir** — formas QML (r6 #6), typesystem (r4 #4), Windows (r4 #10), probes
   de ABI (r4 #9), mais classes descartáveis (r12 #2).
4. **Um resíduo com número** — o DAG do libsample: 116 anúncios de `libsample.a` numa matriz
   completa para 58 consumidores (r7 #8, r8 #9).

**A regularidade, agora com sete rodadas de prova:** todo achado que virou **alvo com nome** fechou e
ficou fechado. Todo achado que dependia de eu escolher trabalho sem portão continua aberto, e dois
deles pioraram enquanto eu fechava os outros. A auditoria não precisa de me apontar casos: precisa
de me obrigar a pôr portão onde eu não quero.

### O primeiro desses portões existe (2026-08-12)

`runtime-boundary` é um alvo do build, e mede a fronteira que as rodadas 9 e 11 pedem — não a
desenha, impede-a de recuar. Dois números contados da fonte, os dois fail-closed no CRESCIMENTO:

- **`qml_fns` — 33 de 62.** Metade das funções `extern "C"` do runtime partilhado toca QQml/QQuick.
  É o número que descreve a queixa da auditoria, e só se baixa mexendo código para fora.
- **`d_state` — 3.** Globais mutáveis de estado de compilador em `qtmoc.d`. **Dois foram
  acrescentados por mim no dia em que escrevi esta resposta.**

A baseline vive em `tests/runtime-boundary.baseline` e **só pode descer**. Subi-la é permitido e é
para doer: obriga a editar um ficheiro versionado e a escrever porquê — que é exactamente o acto
deliberado que faltava. Encolher passa e pede a baseline para baixo, para o roquete não afrouxar.
Provado a morder: com a baseline em 32 e a realidade em 33, falha e diz o que fazer.

Isto não fecha o achado. Fecha a razão pela qual ele não fechava.

### E o gémeo, no mesmo dia

`compiler-context` faz o mesmo pela outra fronteira — a que as rodadas 4, 9, 10 e 11 descrevem com
as mesmas palavras: *"dezenas de globais mutáveis… um `DocumentContext` implícito distribuído pelo
arquivo."*

- **`globals` — 98.** Estáticos mutáveis de ficheiro em `qmltc_d.cpp`, num ficheiro de 11.198
  linhas. É o contexto que não tem tipo.
- **`ctxsaves` — 51.** Sítios que guardam um global para o repor depois. Isto é o contexto implícito
  **tornado visível**: cada um é um escopo que um `CompilationContext` a sério possuiria.

Uma nota sobre como este segundo número foi apurado, porque quase produziu uma acusação falsa e o
método novo travou-a a tempo. Uma primeira contagem deu 51 salvaguardas e **49** reposições, e essa
diferença é exactamente o defeito que a auditoria previu — estado que não volta ao sítio. Fui ver as
nove suspeitas uma a uma: **todas repõem**, em linhas com várias atribuições
(`g_srcText = …; g_docUrl = …;`) que a contagem ancorada não via. Não há aqui defeito nenhum, e o que
há é a razão pela qual `ctxsaves` conta SAVES e não a diferença: um número que parece uma acusação e
não é vale menos do que um número honesto.

Os dois roquetes correm no build:

```
runtime-boundary  OK: qml_fns=33 d_state=3   (at baseline; it may only go down)
compiler-context  OK: globals=98 ctxsaves=51 (at baseline; it may only go down)
```

**As duas famílias que atravessaram sete rodadas têm agora métrica.** Continuam abertas — nenhum
destes alvos move uma linha de código para o sítio certo. O que mudou é que deixaram de depender de
eu me lembrar delas.

#### Primeira tentativa de MOVER a fronteira, e o que ela ensinou (2026-08-12)

Tentei fazer o `qml_fns` descer de 33 pela primeira vez, com o que parecia o corte óbvio: das 33
funções exportadas que tocam QQml/QQuick, **11 não dependem de estado de ficheiro nenhum nem de
ajudante nenhum definido em `qtdmoc.cpp`** (`qtd_context_object`, `qtd_context_prop_*`,
`qtd_bind_js`, `qtd_prop_value_member`, `qtd_list_at`, `qtd_parser_status`,
`qtd_component_finalized`, `qtd_attach_value_source`, `qtd_dump_object_as`). Esse critério é
mensurável e as 11 são, em princípio, o primeiro lote seguro. As outras 19 partilham `g_leafConn`,
`g_moAttach` ou `qtd_qml_engine()`, e cada uma precisa de decidir onde a tabela passa a viver.

**A extracção falhou, e reverti.** A razão é o achado: as funções não estão em blocos limpos —
estão **entrelaçadas com pares `#ifdef QTD_HAVE_QML` / `#else` / `#endif`**, muitos deles a
fornecer a versão no-op para o binding sem QML. Um varrimento por função corta através desses pares
e deixa o ficheiro com guardas desequilibradas: depois da minha extracção, `qtdmoc.cpp` ficou com
profundidade de pré-processador 1 em vez de 0 — partido, e partido de uma maneira que só se vê
compilando.

O que isto diz a quem fizer a mudança a sério, e é a parte útil: **o passo um não é mover funções, é
reestruturar as guardas** — uma região guardada por FICHEIRO em vez de uma por função. Enquanto o
no-op para o binding sem QML viver colado à versão QML de cada função, qualquer corte é um corte a
meio de uma condicional. Isso é trabalho de refactor com forma clara, não um lote mecânico, e foi
por o ter tratado como lote que gastei uma volta a aprender isto.

O roquete continua em 33, que é o número honesto.

#### E na volta seguinte: 33 → 23, com a conclusão acima corrigida

A frase que escrevi acima — *"o passo um não é mover funções, é reestruturar as guardas"* — **estava
errada, e verifiquei-a em vez de a repetir.** Das onze candidatas, **dez têm o guard DENTRO do
corpo** (um `#ifdef`/`#else` interno que devolve o valor por omissão sem QtQml): são auto-contidas e
movem-se inteiras. Uma única tinha a forma que partiu tudo — `qtd_attach_value_source`, escrita como
**duas definições** com o `#else` a fornecer o no-op — e o meu varrimento levou metade. Não eram ~50
condicionais a reorganizar: era uma função a excluir do lote.

A regra de extracção passou a ter uma condição a mais e óbvia depois de vista: **um bloco só sai se
estiver equilibrado no pré-processador por si só.** Com ela, `runtime/qtmoc/qtdmoc_qml.cpp` levou dez
funções e o `qtdmoc.cpp` ficou a zero de profundidade.

```
runtime-boundary OK, AND IT SHRANK: qml_fns 23 (baseline 33)
```

Três coisas que a mudança exigiu e que valem por si:

- **o gerador copia o novo ficheiro** — sem isso, cada binding ficava com a cópia antiga e a matriz
  ficava verde contra código que já não está na árvore, que é literalmente o comentário que já
  existia no `runtimeSrc` a avisar deste risco;
- **a ABI não muda com a lista de módulos.** Todas as funções mantêm corpo no-op sem QtQml, por isso
  um binding sem QML continua a resolver os mesmos símbolos. Compilado nas três configurações antes
  de correr o build: Qt6+QML, Qt5+QML, e sem QML nenhum;
- **o Qt5 partiu primeiro, e foi a regra da casa a apanhá-lo.** Eu tinha incluído um cabeçalho
  privado (`qqmlfinalizer_p.h`) que só existe no Qt6; o original nem sequer o inclui — **declara a
  interface localmente**, guardada por `QT_VERSION >= 6.2`, e a minha extracção levou a função sem a
  declaração. Movida a declaração com ela, as duas versões passam.

Matriz completa verde nas duas versões do Qt: `rc=0`, 248 documentos, `UNPLACED=0`. Baseline descida
para 23. **É a primeira vez que esta fronteira anda para o lado certo em nove rodadas.**

#### Segunda leva: a TABELA sai, e o roquete não mexe — o que diz do roquete

A seguir foi a **tabela de folhas**: `g_leafConn`, `g_leafByObj`, `g_leafMx`, as duas ajudantes
(`qtd_leaf_key`, `qtd_leaf_watch`/`qtd_leaf_forget`) e as três exportadas (`qtd_bind_leaf`,
`qtd_bind_leaf_prop`, `qtd_leaf_table_size`). Isto não é extracção — é a decisão que a auditoria
disse que cada tabela partilhada exige, e para esta a resposta é fácil quando se faz a pergunta:
`g_leafConn` existe para uma ligação profunda de um documento compilado voltar a subscrever quando o
objecto por trás de uma propriedade muda. **Nada fora do QML tem uma ligação profunda.** Medido
antes de mexer: nenhuma função fora do grupo chama `qtd_leaf_forget`, `qtd_leaf_watch` ou
`qtd_leaf_key`, portanto a tabela viaja com as suas funções e a unidade partilhada perde o ESTADO,
não só o código. `qtdmoc.cpp` está em 2125 linhas contra as 2533 de manhã; a unidade QML tem 528 e
18 funções exportadas.

**E o `qml_fns` não mexeu: continua em 23.** Isso não é falha do movimento, é o limite do número —
e fica dito no próprio `runtime_boundary.d`. A tabela de folhas é QML **por finalidade** e não toca
em tipo `QQml` nenhum: usa `QObject::connect` e `QMetaMethod`. O roquete conta *tipos* QML na unidade
partilhada, não *código* QML, e um proxy que não vê a saída de uma tabela inteira é um proxy que
precisa de ser lido com esse nome. Corrigi o comentário da métrica em vez de inventar um número
melhor a posteriori — mudar a régua depois de ver o resultado é como se perde a régua.

### E o achado mais antigo do ficheiro (r4 #9) deixou de estar por tocar

*"ABI/layout assumptions precisam de probes formais"* é da rodada 4 e nunca tinha sido mexido. A
razão de ser um risco real está escrita pelo próprio gerador: a ponte de contentores **não chama o
Qt** para ler um `QList` — o struct D gerado lê os CAMPOS nos offsets que o gerador escreve à mão,
porque é isso que torna a travessia gratuita em vez de uma cópia. E esses offsets entraram como o
comentário admite: *"Verified empirically (offset=24 for QVector&lt;double&gt;)"*. Um offset empírico
é um offset correcto até ao dia em que não é, e nesse dia a falha é um ponteiro errado, não um erro
de compilação.

`abi-layout` afirma o MESMO layout que o gerador emite, contra os cabeçalhos do Qt instalado, e
lê-o das duas maneiras — pelos nossos offsets e pela API do próprio Qt:

```
abi-layout OK (Qt6): QList<T> is {void* d; T* ptr; qsizetype size} — ptr and size read through the
                     generator's offsets equal Qt's own, for int, double and QString; QVector is QList
abi-layout OK (Qt5): QList begin@8/end@12/array@16 and QVector size@4/offset@16 read through the
                     generator's offsets equal Qt's own
```

Três decisões que valem mais do que o alvo:

- **não é só `static_assert` de tamanho.** Trocar dois campos de sítio mantém o `sizeof` e parte os
  valores; provado a morder com os campos trocados, e falha com os dois números lado a lado.
- **nunca desreferencia um layout já desmentido.** A primeira versão rebentava com SIGSEGV quando o
  ponteiro não batia certo — e reportar uma mudança de layout como segfault é exactamente o
  diagnóstico que este probe existe para substituir. Hoje pára antes, com `rc=1`.
- **cobre as duas versões.** Os layouts do Qt5 (`QListData` com `begin@8`) e do Qt6
  (`QArrayDataPointer`) são diferentes, e o gerador emite módulos distintos para eles; o probe segue
  a mesma divisão.

Isto responde também a metade da r7 #7: uma mudança de API privada passa a ser diagnosticável
**como incompatibilidade**, com os números, em vez de um `./build` vermelho indistinto.

### E o resíduo do DAG: 116 → 58, por uma aresta a menos

O último item com número (r7 #8 / r8 #9) era `libsample.a` anunciado **116 vezes** numa matriz
completa para 58 consumidores. A causa não era o `flock` nem a falta de cache: era uma **aresta
redundante**. Cada aplicação de teste listava `sampleLib` nas suas dependências **e** chegava-lhe
por `libT`/`shimsT` através do `genT` — e o backend binário materializa uma dependência uma vez por
ARESTA, não por nó. 29 casos × 2 compiladores × 2 caminhos = 116.

Removida a que era transitiva (a linha de link continua a receber o arquivo, que é o que as
referências mútuas precisam), a matriz completa anuncia **58**. Metade dos processos, o mesmo grafo,
`rc=0` e todos os `sample_*` verdes.

**E o self-test do report apanhou-me pelo caminho.** Os três alvos que criei hoje entraram sem
classificação, e o alvo que a rodada 9 #3 pediu falhou com os quatro nomes:
*"self-test FAIL unclassified target: runtime-boundary"*. Classifiquei-os como `gate`, marquei o
`abi-layout-qt5` no eixo Qt5, e acrescentei um canário por cada um — dois dos quais escrevi errados
à primeira, e foi o self-test a corrigir-me também nisso. É a coisa mais barata desta sessão inteira
e apanhou quatro omissões minhas em dez minutos.

## Rodada 4 refeita: chegada limpa pelo codigo

Escopo lido nesta rodada: `generator-d/`, `runtime/{holder,qtmoc,uic,qrc}/`,
`reggae/`, `reggaefile.d`, testes de wrapper/moc/uic/qrc/libsample, docs principais
e `tests/expected-fails.json`. Este assessment substitui as rodadas anteriores onde
elas conflitarem com o codigo atual.

Regua usada: **maturidade PySide**. Isso nao quer dizer "compila alguns exemplos".
Quer dizer compatibilidade auditavel, ownership previsivel, regressao historica,
expected-fails versionados, matriz de CI, cobertura por simbolo e comportamento
documentado.

## Verificacao local

- `cd generator-d && dub build` passa.
- `./build ownership-ldc2` passa.
- `./build ownership-dmd` passa.
- `./build cannon_t10-ldc2` passa.
- `./build cannon_t10-dmd` passa.
- `./build holder_test-ldc2` passa.
- `./build holder_test-dmd` passa.
- `./build uicheck-ldc2` passa.
- `./build corpus-check-ldc2` passa: `corpus: 53 OK, 0 MISMATCH`.
- `./build sample_cornercases-ldc2` passa: `libsample corner cases: ALL PASS`.
- `./build sample_cornercases-dmd` passa: `libsample corner cases: ALL PASS`.

Nao rodei a matriz inteira. Rodei uma amostra pesada nas areas que decidem se isto
e demo ou binding real: gerador, ownership, metaobject property, holder, UIC
diferencial e PySide/libsample corner cases.

## Correcoes ao meu assessment anterior

1. **O caminho C-ABI nao esta mais ativo no driver.** `generator-d/emit.d` agora
   rejeita `abi` diferente de `cxx` com erro explicito. Ainda existe codigo legado
   e helper antigo, mas a critica "o emissor C-ABI segue como caminho operacional"
   ficou falsa.

2. **`@Property string` tem teste focado.** `tests/examples/cannon_t10.d` isola
   read/write de `@Property string` via `qt_metacall`, incluindo UTF-8. A critica
   antiga de falta desse teste esta resolvida.

3. **Ownership recebeu downpayment serio.** `tests/wrapper/ownership.d` cobre
   destruicao C++ antes da wrapper D, invalidacao via `destroyed()`, filho parented
   destruido com o parent e uso-apos-destruicao lancando em vez de segfaultar.

4. **UIC nao deve ser tratado como "subset de demo".** O topo de `uiform.d` ainda
   diz "Proof-of-concept subset", mas o codigo e a suite nao batem com essa frase:
   ha parser CTFE, propriedades, layouts, mainwindow chrome, actions, menus,
   toolbars, tabs, stacked/splitter, button groups, connections, resources e
   diferencial contra `QUiLoader` no corpus baseline.

5. **`expected-fails` agora e estado estruturado.** `tests/expected-fails.json`
   existe com id, area, motivo, `since` e condicao de remocao. Falta gate, mas nao
   e mais markdown solto.

## O que esta bom de verdade

- Isto nao e demo. E uma implementacao real de binding Qt para D: gerador via
  libclang C API, emissor `extern(C++)`, runtime de holder/moc/uic/qrc, build graph
  reggae e targets contra Qt real.

- A tese tecnica esta correta: gerar bindings e pressionar contra PySide/shiboken
  e muito mais serio do que manter wrapper manual ou validar por exemplos bonitos.

- `emit_cxx.d` tem engenharia real: value types, enums, containers Qt5/Qt6,
  wrapper mode, virtual trampolines, multiple inheritance/upcast, shims de
  copy/dtor, exception guards, inline-method compile checking e sinais.

- A suite tem oraculos bons: `libsample` do shiboken para corner cases de binding,
  UIC diferencial contra `QUiLoader`, dmd + ldc2, e Qt5/Qt6 onde aplicavel.

- O holder nao e uma gambiarra inocente: ha identity map, `_cpp` anulavel,
  invalidacao por `destroyed()`, parenting pins, guarda de shutdown e teste de
  use-after-destruction.

- A documentacao principal agora e bem mais honesta: Linux/POSIX Tier 1, Windows
  como roadmap, typesystem regex subset, cobertura path-level e IR como divida.

Reconhecimento seco: o projeto ja esta no campo de engenharia seria. O que falta
nao e "fazer de verdade"; e transformar uma implementacao real em produto de
compatibilidade industrial.

## O que ainda nao e PySide-mature

### 1. Coverage ainda nao responde "qual simbolo falhou?"

`coverage.txt` por spec e progresso, mas maturidade de binding exige manifest por
classe/metodo/ctor/sinal/enum: `bound`, `skipped-by-rule`, `unmapped-type`,
`inline-failed`, `shimmed`, `opaque-stub`, `expected-missing`, `regressed`.

Sem isso, o projeto sabe que emitiu muito codigo, mas nao tem uma tabela auditavel
do destino de cada simbolo da API Qt.

### 2. A suite precisa virar placar historico, nao apenas alvo verde

`docs/test-suite.md` e bom contrato inicial. Ainda falta o artefato que projetos
maduros usam para nao mentir para si mesmos: contadores persistidos por categoria,
compilador, Qt version, modulo, target e expected-fail. Verde/vermelho global nao
e suficiente para uma superficie do tamanho de Qt.

### 3. O gerador ainda e grande demais para auditar com conforto

`emit_cxx.d` e impressionante, mas tambem concentra AST walk, politica de tipos,
emissao textual, heuristicas ABI, recovery de inline methods, C++ shim generation,
D helper generation e diagnostico. Isso funciona, mas nao e arquitetura PySide-grade.

O refactor certo continua sendo IR/diagnostics explicitos. Sem IR, cada regressao
vai exigir ler fluxo textual e estado global em vez de inspecionar uma decisao
estruturada.

### 4. O subset regex do typesystem continua sendo teto real

O README e honesto: `loadRules` consome um subset pequeno do typesystem
PySide/shiboken. Para maturidade PySide, isso nao pode ser o destino final. Ou o
projeto consome semantica suficiente do typesystem real, ou define uma semantica
propria equivalente para ownership, renames, overload policy, injected code,
conversoes e excecoes historicas.

### 5. Ownership melhorou, mas ainda e area de morte do binding

O teste novo e bom. Ainda falta cobrir shutdown com `deleteLater`, app singleton em
mais caminhos, reparenting em cadeia, non-QObject, excecao em slot/virtual callback,
destruicao durante dispatch, containers de QObject e comportamento fora do
single-thread assumido pelo holder.

Binding maduro nao pode ter ownership "provavelmente certo". Tem que ter uma suite
chata, repetitiva e desagradavel.

### 6. O metaobject runtime engole excecoes

`runtime/qtmoc/qtmoc.d` e callbacks gerados em `emit_cxx.d` capturam `Exception` e
silenciam. Entendo o motivo: callbacks Qt/C++ precisam ser `nothrow`. Mesmo assim,
silenciar excecao em slot, property, signal adapter ou virtual override e pessimo
para debugging e pode esconder corrupcao semantica.

Minimo maduro: politica explicita. Exemplo: hook global de erro, contador de falhas,
last-exception thread-local, log configuravel ou abort em modo debug. Silencio puro
nao e aceitavel no alvo PySide.

### 7. `qtdmoc.cpp` usa mapas globais sem historia de cleanup

`runtime/qtmoc/qtdmoc.cpp` usa `g_moCache` e `g_moAttach`. Cache de metaobject pode
ser intencional. Attach por QObject sem remocao clara em destruicao e risco de
stale entry/leak. Pode nao explodir hoje, mas PySide-grade pede teste e politica de
vida util, nao fe.

### 8. Hand-rolled XML em UIC/QRC exige corpus, nao confianca

O UIC passou 53/53 no corpus baseline, isso e forte. Mas `uiform.d` e `qrc.d`
ainda usam parsers manuais. Isso so e aceitavel enquanto o diferencial/corpus for
parte central do contrato. Sem corpus crescendo, parser manual vira fonte de bugs
em corner cases de XML, encoding, entidades e atributos.

Tambem corrija o comentario velho de `uiform.d`: "Proof-of-concept subset" agora
e falso e rebaixa o proprio projeto.

### 9. ABI/layout assumptions precisam de probes formais

O emissor tem bastante conhecimento manual sobre value types, containers e Qt5/Qt6.
Isso e normal em binding, mas precisa de probes de ABI/layout: `sizeof`, alignment,
field offsets quando aplicavel, container layout, copy/dtor semantics e diferencas
Qt5/Qt6. Teste funcional pega parte; manifest ABI pega o que teste funcional nao
encosta.

### 10. Windows/MSVC segue fora da maturidade PySide

Linux/POSIX Tier 1 e uma decisao honesta. Mas a meta declarada e "as mature as
PySide"; nesse norte, Windows/MSVC deixa de ser detalhe em algum momento. Enquanto
`windows-msvc` for expected-fail, o projeto pode ser Linux-mature, nao
PySide-mature.

### 11. Comentarios antigos ainda ferem credibilidade

`generator-d/gen.d` ainda abre falando em C-ABI/shim/`extern(C)` como se fosse a
tese atual. `runtime/uic/uiform.d` ainda se chama proof-of-concept subset. Essas
coisas parecem pequenas, mas em projeto de gerador elas fazem leitor mexer no
lugar errado e desconfiar do resto.

## Prioridade brutal

1. **Manifest por simbolo.** Sem isso, maturidade PySide fica retorica.
2. **Placar historico da suite.** Categoria, compilador, Qt, expected-fail,
   unexpected-pass, unexpected-fail.
3. **IR/diagnostics no gerador.** Nao precisa nascer perfeito; precisa existir.
4. **Politica de excecoes em callbacks.** Silencio puro tem que acabar.
5. **Ownership torture suite.** Mais casos de destruicao, reparenting, shutdown e
   callbacks.
6. **ABI probes.** Layout e semantica de value/container por Qt/compiler.
7. **Cleanup de docs/comentarios legados.** Menor em dificuldade, alto em clareza.
8. **Typesystem semantics.** Trabalho grande, mas inevitavel se a meta e PySide.
9. **Windows/MSVC.** Roadmap real quando Linux estiver governado por manifest e CI.

## Veredito

Hostil e coerente: isto e bom. Nao "bom para demo"; bom como base tecnica real.
O projeto tem gerador, runtime, tests relevantes, oraculos corretos e preocupacao
com compatibilidade. Eu nao compro ainda a palavra "mature", mas compro que voce
esta atacando o problema certo.

A distancia para PySide nao e falta de substancia. A distancia e governanca:
cada simbolo precisa ter status, cada falha esperada precisa ser estado, cada
categoria precisa ter historico, cada regra de ownership precisa ser testada, e
cada excecao engolida precisa virar politica observavel.

Resumo brutal: pare de medir o projeto por narrativa. Meça por manifest. Quando o
manifest por simbolo e o placar historico existirem, a conversa muda de "isso e
ambicioso" para "isso e auditavel".

---

## Resolução da rodada 5 refeita (commits 7226e4a..f251e17)

Os 8 pontos, atacados um a um e verificados (ldc2+dmd, matriz cheia verde):

1. **Docs stale** — `docs/test-suite.md` e `README` atualizados: uic 60/60, categorias
   QML/i18n/gate, seção "Coverage manifest (gated)" honesta sobre per-symbol vs agregado.
   (`ce9a114`)
2. **Manifest parcial** — os 5 `catch(Unmappable){CXX_SKIP++}` (value-type/wrapper/ctor)
   agora fazem `recordSym`. Resíduo "não per-symbol" → **0** nos dois bindings
   (widgets unmapped-type 188→681; qml resíduo 0). `coverage.txt` diz "all per-symbol"
   dinamicamente. (`bc385d3`)
3. **Sem enforcement** — `manifest-gate-{qtwidgets,qml}`: regenera e faz diff do manifest
   contra baseline commitado; **falha** em símbolo sumido, fate piorado, ou novo drop.
   Verificado: exit 1 em regressão forjada, 0 limpo. (`b37f24f`)
4. **Callback silencioso** — `qtdOnCallbackError` em TODOS os callbacks nothrow restantes:
   trampolines de virtual-override, delegates de slot/prop do QtdWidget, trampoline de
   sinal e callbacks de container (gerados). De brinde, consertei o gate `__has_include`
   quebrado (widgets puxava QQmlPrivate) → `-DQTD_ENABLE_QML` explícito. (`7226e4a`)
5. **Cleanup do side-table** — destrutor do QtdMocObject agora limpa `g_moAttach`+`_reg`
   em TODO caminho (não só QML), via hook genérico. Vida útil documentada (objeto sem
   pai vive até o fim, igual QObject C++). Testado: `moclife-{ldc2,dmd}`. (`94a39d3`)
6. **lupdate fora do build** — `lupdate-check`: roda o extrator em `fixture.d` e faz diff
   contra golden `.ts` (tr/UFCS/translate/contexto-módulo). Junto com `tr-*` fecha
   D source → lupdate-d → .ts → .qm → tr(). (`5b76f48`)
7. **Sem report estruturado** — `tools/test-report.sh`: TSV com target/categoria/compiler/
   qt/opcional/status/ms + commit + totais sobre a matriz. (`f251e17`)
8. **API privada QML** — entradas estruturadas em `expected-fails.json` para QQmlPrivate,
   QQmlJSTypeDescriptionReader e QMetaObjectBuilder (área/razão/probe/since/remove-when);
   os targets qmlreg/qmltypes/moc SÃO os probes por-build. (`ff19f33`)

Resta explícito como follow-up (não bloqueante): counters por-categoria com histórico em
CI. **CORREÇÃO:** as features de QML/tr da rodada 5 foram feitas só no Qt6, violando a
regra double-Qt (day 1) — Qt5 5.15 ESTÁ instalado. Paridade Qt5 sendo levada em seguida
(binding Qt5 QML + targets Qt5 para tr/moc/qml; `RegisterType` do Qt5 tem layout distinto).


## Resolução parcial da "prioridade brutal" (2026-08-01, sessão do audit qmltc)

Não é uma rodada nova de crítica: é o que foi feito **de acordo com** a lista acima,
durante o audit do qmltc, com o que cada item exigia — enforcement e estado, não narrativa.

**Enforcement verificado, não assumido.** Mexi no gerador várias vezes nesta sessão
(colunas novas no registro: `!const`, qmlsingletons, qmlmethods, qmlcxxnames) e rodei os
dois portões que a rodada 5 instalou: `manifest-gate-qml` OK com 2593 símbolos e
`manifest-gate-qtwidgets` OK com 8428, ambos sem regressão e sem novo drop. A governança
sobreviveu às mudanças — que é a única forma de saber que ela existe.

**Item 2/3 (placar, estado) aplicado ao compilador.** Passei a sessão classificando as
recusas do qmltc com scripts improvisados no scratchpad; isso é exatamente a narrativa que
o documento condena. Virou `tools/qmltc-diag-census.py`: classifica pela redação do próprio
compilador e imprime o balde `other` POR EXTENSO, porque balde ilegível é como uma classe
permanece opaca — aconteceu duas vezes neste corpus e custou várias rodadas cada.

Ele se pagou na primeira execução: **8 das 93 recusas são `default child of type
<Animation>`** (NumberAnimation, SmoothedAnimation, SequentialAnimation, XAnimator), uma
classe que meus censos manuais borravam em "animação não implementada" sem nunca contar.

Censo atual do corpus Basic do Qt (93): not-grouped 21, unbound-type 16, component 16,
expression 15, other 12, member-unhandled 6, declared-type 3, unsupported-bind 2,
state-shape 2. Cada um com procedência — teto verificado, recusa correta, portão medido, ou
causa confirmada.

**O que NÃO foi feito e continua aberto** da lista: IR/diagnostics no gerador (item 3, no
gerador C++ — o que fiz foi no qmltc), ownership torture suite (5), ABI probes (6),
typesystem semantics (8), Windows/MSVC (9), e o follow-up de counters por-categoria com
histórico em CI. O censo acima é o insumo desse histórico, não o histórico.
