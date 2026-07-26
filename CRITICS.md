# CRITICS.md

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
