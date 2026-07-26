# CRITICS.md

Reassessment depois da rodada de correcoes. A primeira critica mirava dois
problemas principais: narrativa desonesta/desatualizada e falta de fronteira entre
produto, experimento e legado. Essa parte melhorou bastante. O projeto agora se
apresenta de forma mais honesta: binding amplo de Qt, `extern(C++)` canonico,
Linux/POSIX como Tier 1, reggae como build de verdade, e gaps declarados.

## Verificacao feita nesta rodada

- `cd generator-d && dub build` passa.
- `./build moc_test-ldc2-qt6` passa.
- `./build moc_test-dmd-qt6` passa.
- `./build wraptest-ldc2` passa.
- `./build wraptest-dmd` passa.
- `coverage.txt` existe em geracoes recentes, por exemplo:
  `generated/qt-6.11/cxx-qtwidgets-wrap/coverage.txt`.

Isso nao e a matriz inteira, mas cobre as areas que eu tinha criticado mais
diretamente: gerador, moc e holder/wrapper.

## Assessment atualizado

| # | Tema antigo | Novo status | Avaliacao atual |
|---|-------------|-------------|-----------------|
| 1 | Narrativa arquitetural inconsistente | **Majoritariamente resolvido** | O README agora declara `extern(C++)` como caminho canonico e coloca o C-ABI antigo como legado/gap. Bom. Ainda sobra comentario antigo em `generator-d/gen.d` e documentacao velha em `generator-d/README.md` falando C-ABI como se fosse a tese atual. |
| 2 | "QML not Widgets" contradizia o repo | **Resolvido** | O README parou de vender QML-first e assume binding amplo/Widgets como campo de prova. Isso bate melhor com os testes e specs. |
| 3 | Build POSIX hostil | **Honestamente aceito, nao resolvido** | A critica tecnica continua: comandos shell concatenados, POSIX-hardcoded, paths fragilizados. Mas agora isso esta declarado como Tier 1 Linux/POSIX. Para um projeto de laboratorio isso e aceitavel; para produto multiplataforma ainda e divida. |
| 4 | Gerador monolitico / sem IR | **Nao resolvido, mas declarado** | Continua sendo a maior divida tecnica real. `emit.d`/`emit_cxx.d` ainda misturam AST, politica, emissao textual, compilacao/verificacao e reescrita. A honestidade no README reduz confusao, nao reduz risco. |
| 5 | XML de shiboken via regex vendido demais | **Resolvido na narrativa** | O README agora diz claramente que e subconjunto regex: rejections + object/value-type, nao ownership/rename completo. A implementacao continua simples, mas a promessa agora cabe no codigo. |
| 6 | Skips silenciosos | **Parcialmente melhorado** | `coverage.txt` persistido e progresso real. Mas o arquivo ainda e agregado por tipo unmapped, nao um manifest por metodo com status (`bound`, `skipped-by-rule`, `inline-failed`, `shimmed`, etc.). O contrato de cobertura ainda nao e auditavel o suficiente para bindings. |
| 7 | `qtmoc` nao lia property `string` | **Implementado, teste direto ainda desejavel** | `qtd_qs_set` e o caminho `ReadProperty` para `string` existem em `runtime/qtmoc/qtmoc.d`. Os alvos `moc_test` passam em ldc2/dmd, mas o teste atual exercita sinal/slot e override; eu nao vi um teste focado em `@Property string` read/write. |
| 8 | Entulho historico confundindo o caminho principal | **Resolvido no README principal** | A matriz de status ajuda bastante. Ainda existe documentacao secundaria velha (`generator-d/README.md`) que reabre confusao C-ABI. |
| 9 | Sucesso medido por demos/smoke | **Melhorou um pouco, ainda pendente** | `wraptest` cobre identidade, parenting-pins e reclamacao de orfaos. Ainda faltam invariantes mais agressivos: C++ destroi antes da wrapper D, `deleteLater` em shutdown, app singleton, reparenting variado, objeto nao-QObject, e teste direto de property string. |
| 10 | "Colecao de provas tecnicas" | **Bem menos verdadeiro** | O README agora tem mapa, status e riscos. O projeto ainda e uma ferramenta em maturacao, mas a fronteira mental esta muito melhor. |

## Criticas novas / remanescentes

### 1. `CRITICS.md` nao deve preservar critica velha como se ainda valesse

A versao anterior do arquivo tinha uma tabela dizendo que pontos foram resolvidos,
mas preservava a critica original inteira logo abaixo. Isso era historico util,
mas ruim como assessment atual: um leitor encontra acusacoes que o proprio topo
diz que ja foram corrigidas. Este arquivo agora substitui a critica antiga por
estado atual.

### 2. O README ainda tem uma pequena inconsistencia sobre cobertura

O README diz que cobertura e reportada a stderr e que "persisted per-spec
manifest" e follow-up. O codigo ja grava `coverage.txt` em `outDir`, e eu vi
arquivos gerados. O que ainda e follow-up nao e "persistir alguma coisa"; e
persistir um manifest por metodo/status. Ajuste recomendado: trocar o texto para
"`coverage.txt` agregado existe; manifest por-metodo ainda falta".

### 3. `generator-d/README.md` ficou para tras

O README principal foi corrigido, mas `generator-d/README.md` ainda abre dizendo
que o gerador mapeia pela fronteira C-ABI e emite C shim + `extern(C)`. Isso agora
contradiz a tese principal. Como esse arquivo fica dentro do gerador, ele e mais
perigoso que doc historica em `legacy/`: e facil um contribuidor ler isso como
verdade atual.

Acao recomendada: reescrever `generator-d/README.md` com o mesmo contrato do README
principal ou marcar explicitamente quais paragrafos sao historicos.

### 4. `coverage.txt` com zero unmapped pode ser enganoso

Os `coverage.txt` que inspecionei mostram `0 functions bound` e `0 unmapped` para
bindings enormes. Isso pode estar correto se `total` conta apenas o caminho C-ABI
antigo e o caminho `extern(C++)` nao alimenta esse contador. Mas entao o arquivo
nao e uma cobertura honesta ainda; e um resumo parcial com numeros potencialmente
sem sentido para o caminho canonico.

Acao recomendada: fazer a cobertura nascer da IR/diagnostics do emissor C++ real,
ou no minimo separar contadores: `cxx_methods_bound`, `cxx_methods_skipped`,
`legacy_c_functions_bound`.

### 5. Testar contra PySide e o caminho certo; agora isso precisa virar contrato

Se a suite PySide/shiboken e o oracle de compatibilidade real do projeto, isso
muda bastante a avaliacao: deixa de ser "demos que compilam" e passa a ser uma
estrategia madura de diferencial contra uma implementacao dominante. Esse e o
caminho correto para mirar maturidade PySide.

Mas para contar como maturidade, precisa estar claro e auditavel:

- qual subconjunto da suite PySide roda hoje;
- quais testes sao expected-fail e por qual gap;
- quais testes sao gate de CI;
- se a suite cobre libsample apenas, Qt modules reais, uic, metaobject,
  ownership, overloads, exceptions e containers;
- qual matriz de Qt/compilador/plataforma roda regularmente.

Acao recomendada: documentar o "PySide compatibility suite" como artefato de
primeira classe, com contadores por categoria e historico de regressao. Isso vale
mais do que qualquer lista manual de features.

### 6. A documentacao agora e honesta, mas o codigo ainda carrega o custo do legado

Declarar o C-ABI como deprecated e correto. Mas enquanto o emissor antigo mora no
mesmo `emit.d`, ele continua aumentando custo de leitura e risco de alteracao
errada. Isso nao precisa ser resolvido antes de qualquer feature, mas deveria ser
tratado como refactor de saude, nao como limpeza cosmetica.

## Veredito novo

Voce resolveu a parte mais grave: o projeto agora diz o que e, o que nao e, em
qual plataforma vive, e quais riscos esta aceitando. Isso muda a avaliacao de
"prova tecnica com narrativa inflada" para "projeto tecnicamente ambicioso com
dividas conhecidas".

As pendencias reais agora sao mais estreitas e mais tecnicas:

- separar ou aposentar o emissor C-ABI antigo;
- introduzir IR/diagnostics para o gerador;
- transformar cobertura em manifest por metodo/status;
- tornar a suite PySide/shiboken um gate documentado, com expected-fails
  rastreados;
- corrigir docs secundarias que ainda contam a historia antiga;
- ampliar testes de ownership e `qtmoc` properties.

Em termos pedantes: antes a critica era de coerencia. Agora a critica e de
industrializacao.

## Resolucao da rodada 2

| # | Critica nova | Status | Acao |
|---|--------------|--------|------|
| 1 | CRITICS.md preservava critica velha | **Resolvido (por voce)** | Voce substituiu a critica antiga por reassessment atual. |
| 2 | README inconsistente sobre cobertura | **Resolvido** | Bullet trocado: `coverage.txt` agregado EXISTE; falta o manifest POR-METODO (bound/skipped-by-rule/inline-failed/shimmed). |
| 3 | `generator-d/README.md` ficou p/ tras | **Resolvido** | Reescrito p/ a tese `extern(C++)` canonica; C-ABI marcado legacy no proprio arquivo; tabela apontando `emit_cxx.d`. |
| 4 | `coverage.txt` com 0 unmapped enganoso | **Resolvido** | Contadores POR-CAMINHO. cxx-qtwidgets: `7630 D bindings emitted, 681 methods/ctors dropped (unmapped-type)`. `done:`/stdout idem. `total`/`MISSING` (C-ABI) so no caminho legacy. |
| 5 | Suite PySide precisa virar contrato | **Parcial** | Suite documentada como artefato em `docs/test-suite.md` (categorias, matriz Qt/compilador, o que roda). Contadores por-categoria + historico de regressao no CI: follow-up. |
| 6 | Codigo ainda carrega custo do legado | **Aceito, adiado** | C-ABI ainda em `emit.d`; documentado deprecated no README e `generator-d/README.md`. Mover p/ `legacy/` fica no roadmap (refactor de saude). |

Follow-ups tecnicos remanescentes: aposentar o emissor C-ABI de `emit.d`;
IR/diagnostics no gerador; cobertura por-metodo/status; contadores por-categoria +
historico de regressao da suite; testes de invariante de ownership do `holder`;
teste focado de `@Property string`.

## Rodada 3: norte explicito — maturidade PySide

Agora o criterio nao e mais "isso parece um projeto promissor?". O criterio e:
**isso consegue virar algo tao maduro quanto PySide?** Essa regua e muito mais
dura. PySide-mature significa contrato de compatibilidade, regressao visivel,
ownership preciso, comportamento documentado, CI por matriz, expected-fails
rastreados, e cobertura auditavel. Nao significa "muitos targets verdes" nem
"o README ficou honesto".

Com esse norte, a avaliacao atual e:

### O que esta realmente bom

- A tese tecnica e correta: gerar binding em vez de manter wrapper manual.
- O caminho canonico `extern(C++)` e ambicioso, mas tecnicamente defensavel.
- O projeto ja esta sendo pressionado pelo tipo certo de suite: PySide/shiboken
  `libsample` e corner cases. Isso muda a avaliacao. Nao e so demo; e uma
  tentativa real de compatibilidade contra um oracle maduro.
- `docs/test-suite.md` agora transforma a suite em artefato documentado:
  categorias, matriz, expected-fails/exclusions e follow-ups. Isso e exatamente
  o tipo de documento que um projeto serio precisa.
- `coverage.txt` melhorou: agora mostra contadores do caminho `extern(C++)`
  (`public D bindings emitted`, `dropped as unmapped-type`) em vez de numeros
  enganadores do caminho legado.
- `generator-d/README.md` foi corrigido para a tese atual e marca o C-ABI como
  legacy/deprecated.
- Os testes focados que rodei (`moc_test` ldc2/dmd, `wraptest` ldc2/dmd,
  `generator-d dub build`) passam.

Isso merece reconhecimento seco: o projeto nao e teatro. Ha substancia tecnica e
voce esta atacando os problemas certos.

### O que ainda nao e PySide-mature

1. **A suite PySide precisa virar placar, nao apenas descricao.**
   `docs/test-suite.md` e um bom contrato inicial, mas maturidade exige contadores
   persistidos por categoria, por compilador, por Qt version, por target e por
   expected-fail. "cornercases asserts ALL PASS" e forte; agora tem que virar
   numero historico, comparavel entre commits.

2. **Expected-fails precisam ser arquivos de estado, nao texto.**
   Um expected-fail maduro tem id, motivo, area, link para gap, data/commit de
   introducao e condicao de remocao. Texto em markdown e melhor que nada, mas
   nao impede regressao nem mede progresso.

3. **Coverage ainda nao e cobertura PySide-grade.**
   `coverage.txt` por path e progresso, mas ainda nao responde a pergunta
   madura: para cada classe/metodo/ctor/sinal/enum, qual foi o destino?
   `bound`, `skipped-by-rule`, `unmapped-type`, `inline-failed`, `shimmed`,
   `opaque-stub`, `expected-missing`, `regressed`. Sem isso, cobertura ainda e
   uma estatistica, nao um contrato.

4. **Regex de typesystem continua sendo teto de maturidade.**
   E aceitavel como subset honesto. Nao e aceitavel como destino final PySide-like.
   PySide e maduro justamente porque sua semantica de typesystem cobre ownership,
   renames, injected code, overload policy, conversoes e excecoes historicas. Se
   este projeto quer ser tao maduro quanto PySide, precisa ou consumir essa
   semantica de verdade ou declarar uma semantica propria equivalente.

5. **Ownership ainda precisa ser tratado como area de risco maximo.**
   `wraptest` e bom, mas ownership e onde binding morre em producao. A regua
   PySide pede testes para: C++ destruir antes da wrapper D, wrapper D morrer
   antes do QObject parented, `deleteLater` durante shutdown, app singleton,
   reparenting em cadeia, objetos nao-QObject, sinal `destroyed()` durante GC,
   excecao em slot/virtual callback, e interacao com containers de QObject.

6. **O C-ABI legado ainda custa clareza operacional.**
   A documentacao agora esta honesta, mas o codigo canonico ainda divide casa com
   o emissor antigo em `emit.d`. Para PySide-mature, isso e ruido estrutural:
   aumenta o risco de mexer no lugar errado e dificulta auditabilidade.

7. **Linux/POSIX Tier 1 e honesto, mas nao e maturidade PySide.**
   Nao estou cobrando Windows hoje como se fosse trivial. Mas o norte PySide
   implica que Windows/MSVC deixa de ser "nice to have" em algum momento. Enquanto
   for roadmap, o projeto e Linux-mature, nao PySide-mature.

8. **`@Property string` ainda pede teste focado.**
   O codigo existe (`qtd_qs_set`, ReadProperty). A suite documenta a lacuna de
   teste direto. Para maturidade, nao basta "passa via moc_test" se o alvo nao
   isola o comportamento.

### Veredito hostil, mas coerente

Antes, a falha principal era coerencia: README e codigo contavam historias
diferentes. Isso foi majoritariamente corrigido.

Agora a falha principal e evidencia industrial. O projeto tem engenharia real,
testes relevantes e uma direcao tecnicamente seria. Mas "as mature as PySide" so
comeca quando a suite PySide/cornercases vira painel de controle: pass/fail por
categoria, expected-fails versionados, manifest por simbolo, regressao historica
e CI de matriz.

Resumo brutal: voce ja saiu da fase "prova tecnica inflada". Ainda nao chegou na
fase "binding maduro". Esta no meio: arquitetura promissora, testes certos,
governanca de compatibilidade ainda incompleta.

## Resolucao da rodada 3

O norte (PySide-maturity = governanca) e aceito. Entreguei os downpayments concretos e
verificaveis; os itens de infraestrutura industrial grande estao no roadmap, sem fingir.

| # | Gap (rodada 3) | Status | Acao |
|---|----------------|--------|------|
| 8 | `@Property string` pede teste focado | **Resolvido** | `tests/examples/cannon_t10.d`: escreve E le uma @Property string custom via `setProperty`/`property` (qt_metacall Write/ReadProperty), isolando o caminho `qtd_qs_set`. Verde ldc2+dmd. |
| 5 | Ownership como area de risco maximo | **Downpayment real** | `tests/wrapper/ownership.d` (alvo `ownership-{ldc2,dmd}`): C++ destroi via `deleteLater`+`sendPostedEvents` -> destroyed() invalida a wrapper (self E filho parented); uso-apos-destruicao LANCA (checkAlive), nao segfaulta. Faltam ainda: shutdown, app singleton, non-QObject, excecao em callback — rastreados. |
| 2 | Expected-fails como estado, nao texto | **Resolvido (v1)** | `tests/expected-fails.json`: id/area/reason/since/remove-when por entrada. Referenciado em `docs/test-suite.md`. |
| 1 | Suite vira placar com historico | **Roadmap (nao feito)** | `docs/test-suite.md` e o contrato; contadores persistidos por categoria/compilador/Qt + historico de regressao no CI ainda nao existem. Nao fingido. |
| 3 | Cobertura por-simbolo (destino de cada) | **Parcial -> roadmap** | Contadores por-CAMINHO honestos ja existem (`cxxBound`/`CXX_SKIP`). Manifest POR-SIMBOLO (bound/skipped-by-rule/inline-failed/shimmed/opaque-stub/regressed por classe/metodo) ainda nao. |
| 4 | Regex de typesystem e teto | **Aceito, roadmap** | Honesto como subset hoje; semantica completa (ownership/rename/inject/overload) ou uma semantica propria equivalente e trabalho de porte grande. |
| 6 | C-ABI legado ainda em `emit.d` | **Aceito, roadmap** | Refactor de saude: mover o emissor C-ABI p/ `legacy/`. Documentado deprecated. |
| 7 | Windows/MSVC | **Roadmap explicito** | `windows-msvc` em `expected-fails.json`; `docs/windows-roadmap.md`. Linux-mature, nao PySide-mature — assumido. |

Honestidade: dos 8, dois viraram teste verde (5 parcial, 8 completo), um virou artefato de
estado (2). Os quatro grandes de industrializacao (placar historico #1, manifest por-simbolo
#3, semantica de typesystem #4, aposentar C-ABI #6) sao trabalho de infra que nao cabe num
commit honesto de uma rodada — ficam no roadmap, declarados, nao varridos.
