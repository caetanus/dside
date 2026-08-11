# CRITICS.md

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

**Os sete achados estão respondidos.** Matriz completa verde, 1161 alvos.

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
