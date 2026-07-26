# CRITICS.md

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
CI, e rodar o probe de API privada numa matriz de versões Qt (só 6.11 instalada aqui).
