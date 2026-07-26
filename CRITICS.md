# CRITICS.md

Uma leitura adversarial e pedante do projeto. A ideia aqui nao e negar que ha
engenharia real: ha. O problema e que o projeto vende varias teses fortes antes
de separar com nitidez o que e produto, experimento, legado e contrato publico.

## Status das resolucoes

Critica endereamos ponto a ponto. A tese central — desonestidade de narrativa e
fronteira borrada — foi atacada reescrevendo o README para bater com o codigo real.

| # | Tema | Status | Acao |
|---|------|--------|------|
| 1 | Narrativa arquitetural inconsistente | **Resolvido (doc)** | README reescrito p/ uma unica arquitetura canonica (`extern(C++)`), matriz de status, gaps honestos. Codigo: `emit.d` ainda dual-ABI — listado como gap; C-ABI marcado deprecated (roadmap: mover p/ `legacy/`). |
| 2 | "QML not Widgets" nao bate | **Resolvido (doc)** | Narrativa corrigida: "binding amplo de Qt, Widgets e o campo de prova"; parei de vender QML-first. |
| 3 | Build hostil / POSIX-only | **Parcial** | "Linux/POSIX e Tier 1" agora no topo do README, sem rodeio. Encapsular comandos em argv estruturado: adiado (roadmap). |
| 4 | Gerador monolitico / sem IR | **Adiado (reconhecido)** | Listado explicitamente como known gap + roadmap (IR). Refactor grande, nao feito nesta passada. |
| 5 | Regex XML = economia falsa | **Resolvido (doc)** | Promessa reduzida honestamente: "subconjunto regex (rejections + object/value-type), NAO semantica de ownership/rename". |
| 6 | Skips silenciosos sem contrato | **Parcial** | Gerador agora persiste `coverage.txt` por spec (lista completa de unmapped, nao so top-30 no stdout). Manifest por-metodo com status (bound/skipped/shimmed/…): follow-up. |
| 7 | Buraco de runtime (prop `string`) | **Resolvido (codigo)** | `qtmoc` le QString property via novo `qtd_qs_set` (ReadProperty). moc tests verdes ldc+dmd. Risco de `QMetaObjectBuilder` (API privada) documentado. |
| 8 | Entulho historico no caminho principal | **Resolvido (doc)** | Matriz de status (supported/experimental/legacy/tests-only). Milestones-fosseis removidos do README (dirs ja deletados: runtime/app,metaobject,vibe_qt,convert). C-ABI/bootstrap marcados legacy. |
| 9 | Sucesso medido por demos que compilam | **Parcial** | `wraptest` ja cobre identidade/parenting-pin/reclamacao-de-orfao; invariantes mais paranoicos (destruicao C++ antes do wrapper, deleteLater em shutdown, reparent, app singleton, nao-QObject): follow-up rastreado. |
| 10 | Veredito pedante | **Endereado** | README enxuto, menos retorica, gaps honestos, legado fora da narrativa principal. Contrato publico -> `docs/FEATURES.md`. |

Follow-ups rastreados (roadmap no README): wrapper como default; mover C-ABI p/ `legacy/`
+ IR do gerador; manifest de cobertura por-metodo; testes de invariante de ownership do
`holder`; encapsular comandos de build perigosos.

---

*A critica original, preservada:*

## 1. A narrativa arquitetural esta inconsistente

O README abre dizendo que a direcao atual e `extern(C++)`, geracao sob demanda e
saida nao commitada (`README.md:20-30`). Poucas linhas depois, a secao
"Architecture decisions" ainda afirma explicitamente "C-ABI shim boundary, not
extern(C++)" e que os gerados devem ser commitados por versao de Qt
(`README.md:54-63`). A secao de layout tambem descreve `generated/qt-6.11/`
como saida commitada e `bootstrap/` como C-ABI (`README.md:71-80`).

Isso nao e apenas "documentacao velha": o codigo tambem carrega os dois modelos.
`generator-d/gen.d` ainda se apresenta como pipeline C-ABI (`generator-d/gen.d:1-4`),
`generator-d/emit.d` escolhe entre `abi == "cxx"` e o emissor antigo
(`generator-d/emit.d:337-380`), e `emitContainers` ainda emite `extern(C)`/C++
shim no fim do mesmo arquivo (`generator-d/emit.d:526+`). O leitor precisa
inferir qual arquitetura e canonica a partir de comentarios, specs e build graph.
Isso e uma pessima interface para contribuidores e para voce mesmo daqui a seis
meses.

Acao recomendada: declarar uma unica arquitetura canonica. Mover o emissor C-ABI
para `legacy/` ou para um modulo explicitamente deprecated, e deixar o README
principal conter apenas a direcao suportada.

## 2. "QML + QJS, not Widgets" nao bate com o centro de gravidade do repo

O README diz que o alvo deliberado e QML + QJSEngine, nao Widgets
(`README.md:32-45`). Mas o build principal gira fortemente em torno de Widgets:
`widget_test`, `moc_test`, exemplos `cannon_*`, CTFE uic, corpus de `.ui`,
QRC, WebEngine e libsample (`reggaefile.d` e `./build --list`). Isso pode ser
uma estrategia valida para provar cobertura de ABI, mas entao a tese do produto
nao e "QML first"; e "binding amplo de Qt, com QML como caso de uso".

O risco e gastar energia expandindo superficie antes de ter uma API publica
minima e polida. Hoje o projeto parece uma prova de dominio tecnico, nao uma
biblioteca que alguem externo consegue adotar com confianca.

Acao recomendada: escolher o pacote de entrega. Se for QML, crie um exemplo
canonico pequeno e repetivel no fluxo atual. Se for bindings Qt amplos, pare de
diminuir Widgets na narrativa.

## 3. O build e poderoso, mas hostil e fragil

O build real e reggae, nao DUB. `dub build :generator` passa, mas
`dub build :runtime` falha porque o subpacote e `sourceLibrary` e nao e
construivel isoladamente via comando normal. Isso combina com
`runtime/dub.json:3-6`, mas ainda significa que o workspace DUB nao e um fluxo de
validacao completo.

O build graph em `reggae/qtd_build.d` monta comandos shell por concatenacao,
com `rm -rf`, `flock`, `find`, `for`, `$(...)`, `sed -i`, globs e redirecionamento
(`reggae/qtd_build.d:58-67`, `91-123`, `193-223`). O proprio roadmap de Windows
admite que todos os alvos dependem de dialeto POSIX shell (`docs/windows-roadmap.md:144-153`).

Isso ate pode ser aceitavel para um laboratorio Linux, mas e uma base ruim para
uma ferramenta que promete atravessar Qt5/Qt6, dmd/ldc2 e eventualmente Windows.
Tambem ha pouca protecao contra paths com espacos ou caracteres especiais, porque
os comandos sao strings, nao argv estruturado.

Acao recomendada: manter reggae se quiser, mas encapsular comandos perigosos em
programas D pequenos ou helpers com argv estruturado. No minimo, documentar
"Linux/POSIX shell e requisito de Tier 1" no topo, sem rodeio.

## 4. O gerador e um arquivo-orquestrador grande demais

`generator-d/emit.d` e `generator-d/emit_cxx.d` concentram descoberta, emissao,
runtime embutido, verificacao de inline, geracao de C++ auxiliar, stubs opacos,
copias de runtime e relatorio. `emit.d` escreve dezenas de arquivos diretamente
(`generator-d/emit.d:345-513`) e ainda dispara a verificacao de inlines no meio
do pipeline (`generator-d/emit.d:429-432`). `emit_cxx.d` inclui logica de parse,
verificacao com `dmd`, regex sobre erros do compilador e reescrita de arquivos
(`generator-d/emit_cxx.d:1069-1138`).

Isso e funcional, mas pouco auditavel. Em gerador de binding, o maior inimigo e
erro silencioso de ABI. Quanto mais o pipeline mistura AST, politica de tipos,
emissao textual, validacao e mutacao posterior dos arquivos, mais dificil fica
responder "por que este simbolo foi gerado assim?".

Acao recomendada: introduzir uma IR intermediaria explicita para classes,
metodos, tipos, ownership e shims requeridos. O emissor deve consumir IR; a
validacao deve produzir diagnostics sobre IR ou artefatos, nao reescrever texto
como etapa normal.

## 5. O tratamento de XML de shiboken por regex e uma economia falsa

`loadRules` parseia typesystem XML com regex simples
(`generator-d/gen.d:118-132`). O comentario vende isso como "no XML dep", mas a
dependencia real e mais cara: voce esta dependendo de um formato XML externo,
versionado por PySide, com semantica de rejeicao, ownership e tipos. Regex pega
os casos felizes, nao a semantica.

Pior: o README diz que consome ownership/ignore/rename (`README.md:51-53`), mas
o codigo mostrado captura rejeicoes, object-type e value-type. Isso e uma
distancia entre promessa e implementacao.

Acao recomendada: ou usar parser XML de verdade, ou reduzir a promessa: "usamos
um subconjunto muito pequeno do typesystem". Do jeito atual, parece mais robusto
do que e.

## 6. Skips silenciosos sao aceitaveis para exploracao, nao para contrato

O gerador acumula `UNMAPPED` e imprime top 30 (`generator-d/emit.d:518-523`), e
varios caminhos simplesmente fazem `continue`, `return []` ou geram stub opaco.
Para um prototipo isso e pragmatico. Para bindings, "compila" nao e sinonimo de
"cobertura honesta": um metodo omitido pode ser a diferenca entre exemplo bonito
e uso real.

O problema aparece tambem na traducao de inline: a politica e "tenta, compila,
se nao der remove ou troca por shim" (`README.md:197-204`,
`generator-d/emit_cxx.d:1076-1138`). Isso e esperto, mas precisa virar relatorio
persistente por spec, nao apenas stdout.

Acao recomendada: gerar um manifest de cobertura por classe/metodo com status:
bound, skipped-by-rule, unmapped-type, no-symbol, inline-failed, shimmed. Testar
regressao desse manifest.

## 7. O runtime ainda tem buracos de produto

`qtmoc` ainda tem TODO direto em leitura de propriedade `string`
(`runtime/qtmoc/qtmoc.d:209-211`). Isso atinge uma das promessas centrais:
meta-objeto/QML com propriedades dinamicas. O projeto tambem depende de
`QMetaObjectBuilder`, uma API privada do Qt, reconhecida no build
(`reggae/qtd_build.d:33-42`). Pode ser a unica rota pragmatica, mas deve ser
tratada como risco central de compatibilidade, nao como detalhe de implementacao.

Acao recomendada: fechar o caminho basico de propriedades `string` antes de
expandir mais UIC/Widgets. E documentar explicitamente quais versoes de Qt foram
testadas com a API privada.

## 8. O repo carrega muito entulho historico no caminho principal

Ha `legacy/`, `bootstrap/`, `generator/` Python historico, `generator-d/`,
runtime atual, docs antigas, specs antigas e specs atuais. O README ate tenta
explicar que partes sao historicas (`README.md:27-30`), mas depois continua
descrevendo bootstrap e gerador Python como milestones vivos (`README.md:130-183`).

Isso aumenta custo cognitivo e reduz confianca. Um revisor nao deveria precisar
descobrir por arqueologia quais diretorios sao fonte de verdade.

Acao recomendada: criar uma matriz simples no README: "supported", "experimental",
"legacy/reference", "tests only". Depois mover todo texto antigo para docs
historicos e deixar o README curto.

## 9. O projeto mede sucesso demais por demos que compilam

Ha muitos alvos e isso e bom. Mas o criterio dominante parece ser "compila nos
dois compiladores e roda um smoke/headless". Faltam garantias mais proximas do
risco real: ABI/layout, ownership, destruicao, excecoes, propagacao de parent,
thread/main-loop, diferencas Qt patch/minor e diagnosticos de cobertura.

Exemplo concreto: `holder.d` tem um design ambicioso de identidade, invalidacao
e parenting pins, mas isso e uma area onde testes deveriam ser paranoicos:
destruicao C++ antes da wrapper D, deleteLater em shutdown, child parented sem
referencia D, reparenting, app singleton, objetos nao-QObject. Ha algum teste de
holder, mas a criticidade pede mais do que "um alvo existe".

Acao recomendada: escrever testes de comportamento por invariantes de ownership,
nao apenas apps exemplo.

## 10. Veredito pedante

O projeto tem ambicao tecnica legitima e varias solucoes boas: libclang C API,
`pragma(mangle)` a partir do clang, arquivos por modulo, arquivos gerados fora do
repo, build por arquivos objeto em archive, comparacao diferencial de UIC contra
QUiLoader. O problema e disciplina de produto e fronteira.

Hoje ele parece uma colecao de provas tecnicas que cresceram rapido demais em
torno de uma tese boa. Para virar ferramenta confiavel, precisa de menos retorica
no README, menos legado no caminho principal, mais manifest de cobertura, e um
contrato publico pequeno que seja mantido sem desculpas.
