# Invariantes da Fase de Fundação

> ### Leia isto antes: a maior parte já existe
>
> Este documento foi escrito a partir do CHANGELOG do sistema legado, **antes** de eu conhecer o
> blueprint e o schema já implementados. Confrontado com eles, o resultado honesto é:
>
> | | |
> |---|---|
> | Já implementado no banco | 43 tabelas, 9 migrations, **142 asserções** passando — inclusive contagem cega, custódia com `EXCLUDE`, RLS forçada, idempotência de pagamento |
> | Já coberto por `gaps.json` | a maioria destes 34 — fuso e dia operacional, `FORCE RLS`, snapshot, multi-executor, auditoria com de/para, mascaramento de ambientes |
> | Genuinamente novo | **12 achados** e **4 decisões irreversíveis**, agora em `gaps.json` como lente 7 |
>
> **A fonte de verdade é [`gaps.json`](../../gaps.json) e [`architecture.json`](../../architecture.json)**,
> renderizados no [fluxograma](../../index.html) e no [dossiê](../../dossie.html). Este arquivo fica
> como derivação: o mecanismo concreto (DDL, GRANT, política, lint, teste) de cada invariante, útil
> na hora de escrever a migration — não como uma segunda especificação concorrente.
>
> Os quatro que viraram decisão irreversível: **F-C3** (natureza em eixos independentes → decisão 17),
> **F-D1** (cliente sem GRANT de escrita → decisão 19), **F-E3** (documento renderizado imutável →
> decisão 20) e o invariante de custódia × comissão (decisão 18), este último já provado em
> `db/tests/test_balcao.sql` com controle negativo.

Os 34 itens que precisam existir **no commit 1**, porque cada um marca toda linha que o sistema
gravar depois. O critério de entrada está em [`ANALISE-DO-LEGADO.md §2`](./ANALISE-DO-LEGADO.md).

Cada item traz a **cicatriz** que o originou (quando existe), **como implementar** e **o teste que
prova**. Regra do legado que vale aqui: teste só conta como prova depois de demonstrado que ele
**falharia** se o defeito existisse (controle negativo).

O DDL abaixo é ilustrativo do mecanismo, não o schema final.

---

## A · Identidade, empresa e autoria

### F-A1 · Isolamento por empresa, com RLS que a própria aplicação não contorna
**Regra.** Toda tabela nasce com `empresa_id NOT NULL` e RLS ligada negando por padrão — inclusive as
de usuários, perfis e permissões. O sistema opera com um salão só e nada na tela mostra troca de
empresa.

**Por quê.** O legado adotou "multi-tenant oculto" (22/07) e acertou. Mas deixou a tabela de
perfis/permissões sem a coluna, "seguro e inofensivo com um salão só" — é exatamente assim que se
chega em uma tabela que precisa ser reformada com dados dentro.

**Como implementar.** `empresa_id uuid NOT NULL REFERENCES empresa` em todas; `ALTER TABLE … ENABLE
ROW LEVEL SECURITY` **e `FORCE ROW LEVEL SECURITY`**; papel de aplicação (`app_rw`) que **não é dono**
de nenhuma tabela; policies filtrando por `empresa_id = fn_empresa_do_ator()`.

> ⚠️ Sem `FORCE`, o dono da tabela ignora as policies. Se as funções `SECURITY DEFINER` rodarem como
> proprietário, todo o isolamento e todo o append-only são decorativos — e o teste de isolamento passa.

**Teste.** Dois atores de empresas diferentes: o segundo não lê nenhuma linha do primeiro e é barrado
ao tentar gravar na empresa dele. Controle negativo: com `FORCE` removido, o teste tem que falhar.

---

### F-A2 · Login e ficha de equipe são entidades distintas
**Regra.** `usuario` (identidade de acesso) ≠ `equipe` (a pessoa do salão: meta, jornada, comissão,
especialidade). Vínculo **opcional** nos dois sentidos: existe profissional sem login (a assistente) e
login sem ficha (a recepção).

**Cicatriz.** 23/07: quem era criado com a função "Profissional" ia parar na tabela de **login**, que
a agenda, o PDV, as comissões e a transferência **não leem** — "a pessoa ganhava acesso mas não
existia como profissional". O legado precisou de uma tabela nova (`profissionais_negocio`) e de uma
migração no meio do caminho.

**Como implementar.** Regra de FK, fixada agora: **tudo que é negócio** (agendamento, item de comanda,
comissão) aponta para `equipe`; **tudo que é ato do sistema** (autoria, trilha, sessão de caixa,
responsabilidade por comanda) aponta para `usuario`. `equipe.usuario_id uuid NULL UNIQUE`.

**Teste.** Criar pessoa sem login e agendá-la; criar login sem ficha e provar que ele não aparece como
executante de serviço.

---

### F-A3 · O autor é imposto pelo servidor, nunca recebido por parâmetro
**Regra.** O autor de qualquer escrita é a identidade da sessão autenticada no instante da ação,
capturada **por valor**.

**Cicatriz.** Ciclo 09 (21/07): a referência do "usuário atual" apontava para a constante global do
sistema — cada troca de perfil corrompia a identidade do administrador e o autor registrado nas
trilhas. Os 428 testes não pegaram; o revisor independente pegou.

**Como implementar.** Nenhuma RPC aceita `autor_id` como argumento; toda função deriva de
`auth.uid()`. Coluna `criado_por uuid NOT NULL DEFAULT fn_ator_atual()` sem GRANT de escrita para
`app_rw`.

**Teste.** Chamar a RPC passando `autor_id` de outro usuário e provar que a linha gravada tem o ator
autenticado. Controle negativo: uma versão que confia no parâmetro grava errado.

---

### F-A4 · Ator-sistema explícito para escritas não humanas
**Regra.** Migração, seed, rotina automática e trigger escrevem com uma identidade de sistema
declarada, nunca `NULL` nem "usuário padrão".

**Como implementar.** Linhas fixas em `usuario` (`sistema:migracao`, `sistema:seed`, `sistema:rotina`)
com `tipo='sistema'`, sem credencial de login, referenciáveis por `criado_por`. `CHECK` impedindo que
ator do tipo sistema apareça em operação originada de sessão humana.

**Teste.** Rodar uma migração que grava e provar que a trilha nomeia o ator de sistema.

---

### F-A5 · Identificadores gerados pelo servidor, estáveis, independentes de estado
**Regra.** `uuid` gerado no banco. Nenhuma entidade é identificada por data, por posição em lista ou
por dado de negócio. Situação é **atributo** do registro, nunca lista separada.

**Cicatriz.** O legado guardava comandas em duas listas (abertas e fechadas) e precisou de "um
tratamento próprio que separa por situação ao carregar e junta ao gravar"; a abertura de caixa era
"identificada pela data (e não por um código)" e precisou de "um atalho para casar certo" (22/07).

**Como implementar.** `id uuid PRIMARY KEY DEFAULT gen_random_uuid()`; `status` como coluna com FK
para tabela de domínio.

---

### F-A6 · Nada se apaga: entidade referenciada por histórico se desativa
**Regra.** Desativar preserva o histórico; reativar restaura a **mesma** ficha, nunca cria outra.

**Cicatriz.** 17/06: apagar um login no painel do Supabase não apagava a ficha do usuário. 23/07:
despromover profissional passou a desativar (nunca apagar) e repromover reativa preservando histórico.

**Como implementar.** `ativo boolean NOT NULL DEFAULT true` + `desativado_em/por`; sem GRANT de
`DELETE` em nenhuma tabela referenciada por fato; FKs `ON DELETE RESTRICT`.

---

### F-A7 · Permissão em dois eixos: função × escopo
**Regra.** Permissão é conjunto de funções vindas de catálogo **no banco** (nunca perfis fixos no
código), **e** um eixo de escopo, em que a restrição mais estreita **prevalece** sobre a concessão
ampla.

**Cicatriz.** O legado saiu de 4 perfis fixos para funções marcáveis (15/06) e acertou — mas manteve
"quem é Profissional só mexe na própria agenda, mesmo que também tenha Agenda Geral", que a união pura
de concessões não expressa. Ficou como `if` na aplicação.

**Como implementar.** `funcao(codigo, modulo)`, `perfil_funcao`, e **`escopo`** por concessão
(`proprio | equipe | empresa`) com precedência do mais restritivo resolvida numa função só,
`fn_escopo_efetivo(ator, funcao)`, consumida **pelas policies** — não pela aplicação.

**Teste.** Ator com `agenda:ler(empresa)` **e** `agenda:ler(proprio)` só enxerga a própria agenda,
consultando direto o banco, sem passar pela aplicação. O catálogo nunca é embarcado no cliente
(ver §4 da análise: o legado criou uma segunda fonte de verdade de autorização em 23/07).

---

## B · Tempo

### F-B1 · Fuso da empresa e dia operacional como coluna própria
**Regra.** `empresa.fuso` cadastrado; todo fato que alimenta "o dia" carrega `data_operacional date`
derivada **no servidor**, nunca `date(created_at)` no fuso de quem abriu o navegador.

**Por quê.** O changelog fala em "caixa do dia", "faturamento de hoje", "reset diário da numeração" e
"meta ÷ 26 dias úteis" — e nunca define o que é um dia. Salão que fecha às 21h com comanda aberta
resolve isso uma vez, no dia 1, ou convive para sempre com números que não batem por um fuso.

**Como implementar.** `data_operacional date NOT NULL DEFAULT fn_dia_operacional(now(), empresa_id)`,
sem GRANT de escrita. A virada do dia é parâmetro da empresa, não `00:00` implícito.

---

### F-B2 · O relógio é do banco
**Regra.** `created_at timestamptz NOT NULL DEFAULT now()`, sem GRANT de escrita. Toda RPC **ignora**
qualquer hora recebida por parâmetro.

**Por quê.** No protótipo a hora vinha da máquina que gravava. Com três computadores no salão, um
relógio adiantado joga o recebimento para o caixa de amanhã; um atrasado, para um dia já fechado. A
linha não guarda de onde veio a hora — é indetectável depois.

**Nota.** Não conflita com "motor puro recebe a hora injetada": quem injeta é o **aplicador**, que roda
no servidor, com `now()` do banco. O motor continua testável fora dele.

---

## C · Dinheiro

### F-C1 · Dinheiro é inteiro de centavos
**Regra.** `CREATE DOMAIN centavos AS bigint`. Nenhum `real`, `double precision` ou `money` no schema.
Percentuais em `numeric(7,4)`.

**Por quê.** Escolha de **tipo**: depois de milhares de linhas gravadas não dá nem para saber quais
centavos já estavam errados. O legado nasceu com `number` de JavaScript num blob e só descobriu na
hora de criar as tabelas reais (22/07: "dinheiro em campo numérico, nunca ponto flutuante").
Inteiro em vez de `numeric` porque PostgREST serializa `numeric` como número JSON e o cliente
reintroduz float na volta.

**Como implementar.** No TS, `type Centavos = number & { readonly __c: unique symbol }` com construtor
que exige `Number.isSafeInteger`; `parseFloat` proibido por lint em `src/dinheiro/**`.

**Teste.** Consulta a `information_schema.columns` falha o CI se aparecer tipo aproximado no schema.

---

### F-C2 · Append-only por GRANT, com política por classe de tabela
**Regra.** **Fato financeiro e auditoria:** sem GRANT de `UPDATE` nem `DELETE` — correção só por linha
nova. **Cadastro:** `UPDATE` permitido, com trilha de/para obrigatória na mesma transação.

**Por quê.** O legado só conseguiu garantir isso quando chegou ao banco; no protótipo era convenção de
código, que é o mesmo que nada. Resolve também a contradição do próprio changelog, que diz "só
acrescenta" em alguns lugares e "acrescenta e atualiza" em outros.

**Como implementar.** `REVOKE UPDATE, DELETE, TRUNCATE ON <tabelas de fato> FROM app_rw`; RLS sem
nenhuma policy `FOR DELETE` (nega por omissão); trigger `BEFORE UPDATE` que só libera colunas de uma
allowlist explícita por tabela (ex.: `conciliado_em`) e levanta exceção em qualquer outra.

**Teste.** Contagem das tabelas de fato é monotonicamente não-decrescente ao longo da suíte inteira.

---

### F-C3 · Natureza do lançamento com eixos independentes
**Regra.** A natureza declara, **separadamente**, se afeta receita, se afeta a gaveta e se gera
comissão. Estorno **herda** a natureza do original.

**Cicatriz.** 07/07: "ao estornar uma comanda que tinha criado crédito (ou gorjeta em dinheiro), o
lançamento de estorno entrava como *receita* e derrubava indevidamente o relatório de receita do dia
(a gaveta já ficava certa)". O bug só foi possível porque a natureza era inferida na hora do relatório.

**Como implementar.**
```sql
natureza_lancamento(codigo text PK, afeta_receita bool NOT NULL,
                    afeta_gaveta bool NOT NULL, gera_comissao bool NOT NULL)
lancamento(..., natureza_codigo text NOT NULL REFERENCES natureza_lancamento,
           valor centavos NOT NULL, estorna_id uuid UNIQUE REFERENCES lancamento(id))
```
Trigger: se `estorna_id` preenchido, então mesma natureza, mesma empresa, `valor = -original`, e o
original ainda não estornado. **Todo relatório agrega pelas flags**, nunca pelo sinal do valor.

> Um único enum "receita/despesa" não serve: gorjeta em dinheiro afeta a gaveta e **não** é receita;
> gorjeta em cartão não afeta nenhuma das duas. São eixos ortogonais.

---

### F-C4 · Origem polimórfica: o ledger nunca nasce preso à comanda
**Regra.** `tipo_origem` (tabela de domínio) + `id_origem`, ambos `NOT NULL`. **Sem coluna
`comanda_id` no lançamento.**

**Por quê.** O legado tinha pelo menos quatro produtores de lançamento que não são comanda: locação de
sala, compra de fornecedor, conta a pagar e movimentação de sessão de caixa. Uma tabela de lançamentos
que nasce com `comanda_id NOT NULL` obriga, na fase da locação, ou a criar comanda fantasma ou a
afrouxar a coluna com histórico dentro.

**Como implementar.** Domínio começa com os poucos tipos da fase 0 e cresce por `INSERT`. Fiado,
crédito e gorjeta referenciam a origem por aí (é o que permite "fiado de venda estornada não pode ser
recebido" sem uma FK direta para comanda).

---

### F-C5 · Saldo é sempre soma de um livro, nunca coluna
**Regra.** Nenhuma coluna de saldo em `cliente`. Crédito, fiado, pontos de fidelidade e cashback são
movimentos append-only com origem; saldo é `VIEW`.

**Cicatriz.** Fidelidade foi modelada como *um número por cliente* — "os pontos de 16 clientes subiram
ao banco (ex.: um cliente com 2.100 pontos)" (22/07). Nada diz de onde vieram esses pontos, e estornar
a venda que os gerou não tem como devolvê-los. Cashback é pior: é obrigação em reais.

**Como implementar.** `movimento_saldo(cliente_id, natureza, quantidade, tipo_origem, id_origem,
data_operacional)` append-only; `saldo_cliente` como view agregando. Cashback entra no ledger de
dinheiro com natureza própria (`afeta_receita=false`, `afeta_gaveta=false` na concessão).

---

### F-C6 · Contrato único de retrato congelado
**Regra.** Um só formato de snapshot para todos os consumidores: `jsonb` + `schema_versao`
obrigatório, coluna **sem GRANT de `UPDATE`**, leitor **recusa** versão desconhecida.

**Por quê.** O legado tem quatro snapshots diferentes (item do fechamento, preço do agendamento,
comprovante de caixa, comprovante de sessão), cada um com formato próprio. Quatro serializações
incompatíveis é o caminho garantido para quatro migrações incompatíveis.

**Teste.** Ida e volta byte a byte: grava, relê, `expect(lido).toStrictEqual(gravado)`. Dentro do
payload, dinheiro é inteiro e data/percentual são **texto** — texto congelado só existe aqui dentro,
nunca como tipo de coluna.

---

### F-C7 · O snapshot grava a procedência do valor
**Regra.** Ao lado de cada valor congelado, **qual nível da cascata o resolveu**: específico do
serviço, da pessoa, padrão do salão, ou digitado com motivo.

**Cicatriz.** 23/07: havia uma matriz de comissão fixa no código, "invisível ao dono", e um fallback de
40%. Olhando um fechamento antigo era impossível saber se aquele 40% veio do cadastro do serviço, do
cadastro da pessoa, ou do número escondido — que foi o que causou a "comissão fantasma" de 11/06.

**Como implementar.** `origem_preco`, `origem_percentual`, `origem_duracao` (enum de domínio)
`NOT NULL` no snapshot do item, preenchidas pelo motor puro, que já precisa decidir a cascata para
calcular. Valor digitado à mão carrega motivo obrigatório.

---

### F-C8 · Leitura viva × leitura congelada, declarada
**Regra.** Tela operacional lê o cadastro atual; dinheiro, comprovante e documento leem o snapshot.
**Consulta que produz dinheiro não faz JOIN com tabela de catálogo.**

**Por quê.** O legado garante que o snapshot seja *gravado*; ninguém declarou a regra do lado da
*leitura*, que é onde a garantia vaza. É barato escrever um relatório de comissão que dá JOIN em
`servico` para pegar o nome e leva o percentual de carona — e aí o passado volta a ser recalculado,
com o snapshot intacto do lado. Nada quebra, o número só fica errado.

**Teste de fundação.** Fechar uma comanda; depois alterar preço do serviço, nome do cliente, % do
profissional e nome do produto; provar byte a byte que fechamento, comprovante e apuração não mudaram.

---

### F-C9 · Todo efeito declara seu inverso; o estorno enumera, não lista à mão
**Regra.** Cada saída do motor é um **efeito tipado** persistido com referência ao fechamento; a
tabela de domínio de tipos declara o inverso de cada um. O estorno recebe os efeitos gravados e
devolve os inversos. Efeito de tipo desconhecido **falha** a operação.

**Por quê.** É a lacuna entre todos os domínios. Fechar uma comanda produz lançamento, comissão, baixa
de estoque, cashback, crédito e gorjeta — e o estorno do legado é uma função que lista à mão os casos
conhecidos. Atomicidade garante que o executado foi tudo; **não** garante que a lista esteja completa.
Cada módulo novo é uma chance de esquecer um inverso, e cada esquecimento é dinheiro ou estoque que
sobra.

**Teste de propriedade.** Para qualquer fechamento: fechar + estornar devolve o mundo ao estado
anterior em todas as tabelas afetadas.

---

### F-C10 · Período fechado é trava do banco
**Regra.** Depois de fechado o dia (caixa) ou o mês (comissão), nenhum fato novo entra com data dentro
dele — a única entrada é linha carimbada com referência ao evento de reabertura.

**Por quê.** Snapshot impede que o passado seja **recalculado**; não impede que um fato **novo** seja
inserido com data retroativa num dia já conciliado. O número que o dono assinou muda depois de ele ter
assinado.

**Como implementar.** `periodo_fechado(empresa_id, tipo, inicio, fim, fechado_por/em, reaberto_por/em)`
append-only + trigger genérica que recusa `INSERT` cuja `data_operacional` caia em período fechado,
salvo com referência à reabertura. **O que** fecha o dia (as pendências, a conferência) é fase 3.

---

## D · Escrita

### F-D1 · O cliente não tem GRANT de escrita
**Regra.** `app_rw` tem `SELECT` nas tabelas permitidas por RLS e **`EXECUTE` nas RPCs**. Nenhum
`INSERT`/`UPDATE` direto em tabela de fato, de nenhum lugar.

**Por quê.** É o que torna a duplicação de motor de dinheiro **inexprimível**, em vez de proibida por
disciplina. O legado tinha a regra escrita ("um motor único") e mesmo assim o Fechamento de Caixa
usava uma cópia local do cálculo, sem as travas — descoberto só na auditoria de 07/07. E foi assim que
em 23/07, depois de a migração estar "concluída", nasceu um cadastro que gravava só no navegador.

**Teste de arquitetura.** CI reprova qualquer `insert into <tabela de fato>` fora dos arquivos de
função do banco.

---

### F-D2 · Idempotência com escopo definido
**Regra.** Toda RPC de escrita exige chave de idempotência. Índice único em
`(empresa_id, operacao, chave)`, sem expiração. Repetir devolve o mesmo resultado, não um segundo
registro.

**Cicatriz.** 11/06: "pagamento de locação não duplica com clique repetido". O legado corrigiu caso a
caso; três das quatro menções a idempotência no changelog nem definem o escopo da chave — e escopo
errado de índice único é justamente o que só aparece com dados dentro.

**Teste.** Segunda chamada com a mesma chave devolve o mesmo id e a contagem não muda. Controle
negativo obrigatório.

---

### F-D3 · Operação multi-tabela é transacional
**Regra.** Dá tudo certo ou nada é gravado.

**Cicatriz.** É o único ponto que o legado acertou cedo: marcar "Profissional" cria usuário e ficha
"numa única operação que dá tudo certo ou nada" (15/06). Vale generalizar: fechamento toca lançamento,
comissão, estoque, crédito e gorjeta.

---

### F-D4 · Número humano de documento alocado no servidor
**Regra.** `UNIQUE (empresa_id, numero_exibicao)` desde o DDL, `NOT NULL`. Alocação dentro da mesma
transação que cria o registro. **Nunca `max(numero)+1` lido pelo cliente.** Modo manual grava a mesma
coluna e é rejeitado pelo mesmo índice — uma via de escrita, não duas.

**Cicatriz.** A numeração de comandas (17/06, parametrizável com reset diário/mensal/anual) era uma
sequência no navegador — e foi **uma das 10 listas que o autosave não observava** (21/07). Cadastrar e
fechar o navegador antes de outra mudança perdia o contador.

**Por quê separado do id.** `uuid` resolve o identificador técnico. O dono entrega ao cliente um papel
com "CMD-42"; dois documentos com o mesmo número é dano que não se desfaz — não se renumera histórico
já impresso e conciliado.

---

### F-D5 · Toda leitura de lista tem contrato paginado
**Regra.** O acesso de leitura devolve `(linhas, total, truncado)`. Limite sempre explícito. Consulta
que soma dinheiro **agrega no banco**, nunca no cliente.

**Por quê.** Armadilha desta stack que o legado nunca enfrentou porque lia tudo da memória: PostgREST
trunca a resposta num limite padrão e devolve **200 OK**. Um relatório de conciliação que para
silenciosamente na milésima linha bate um total errado — o modo de falha exato que o próprio legado
proibiu do lado da escrita ("nada some em silêncio").

**Teste.** Inserir `limite+1` linhas e provar que o total bate e o truncamento é sinalizado.

---

## E · Pessoas e dados pessoais

### F-E1 · Dado pessoal separado do fato financeiro
**Regra.** Ledger, snapshots e trilhas guardam `cliente_id` (+ no máximo o primeiro nome, para leitura
operacional). CPF, telefone, endereço, nascimento, foto e assinatura ficam **só** no cadastro.
Anonimizar é `UPDATE` na tabela de pessoa — permitido e auditado — enquanto o ledger segue proibido de
`UPDATE`.

**Por quê.** Colisão frontal entre a espinha da fundação (nada de dinheiro se apaga) e o direito de
exclusão do titular. Se a fundação seguir o instinto de denormalizar — gravar nome e CPF dentro do
snapshot, como o legado fazia nos documentos — ou se descumpre a LGPD ou se viola o livro-razão. Não
existe conserto depois: o dado já está congelado dentro de payloads imutáveis.

**Regra negativa, custo zero:** nenhum payload `jsonb` congela dado pessoal.

---

### F-E2 · CPF/CNPJ e telefone não são chave única
**Regra.** Validados por dígito verificador **no banco**, armazenados normalizados (só dígitos),
`NULL` permitido, índice **não** único. Duplicidade apenas **avisa**.

**Por quê.** Decisão explícita do dono (23/06). É contraintuitiva e uma fundação bem-intencionada a
quebra sozinha: `UNIQUE(cpf)` parece higiene de modelagem e é o erro aqui — mãe e filha com o mesmo
telefone, cliente sem documento, CPF do responsável. Se nascer `UNIQUE`, a recepção trava no balcão com
o cliente na frente. E-mail idem (marido e mulher usam o mesmo).

**Como implementar.** Coluna gerada com só dígitos + `CHECK` de dígito verificador quando preenchido.
A detecção de duplicidade é consulta que alimenta o aviso — comportamento de tela, fase posterior.

---

### F-E3 · Documento emitido é texto renderizado imutável
**Regra.** Termo assinado, comprovante de caixa e recibo são gravados como conteúdo renderizado, com
versão do modelo e autor — **nunca re-renderizados a partir do cadastro atual**.

**Cicatriz dupla.** (1) No legado, o termo que o profissional assinou com o dedo é regenerado dos dados
atuais: mude a % principal em agosto e o documento "assinado" em junho passa a exibir a nova
porcentagem — a assinatura deixa de provar o acordo, que é a única prova que o dono tem. (2) O mesmo
documento foi vulnerável a **injeção de código** pelo seu próprio texto, publicado por ~3 semanas até
a auditoria C2 (07/07).

**Como implementar.** `documento_emitido(tipo, versao_modelo, conteudo_renderizado, hash,
assinado_por, assinado_em, imagem_assinatura)` append-only. Toda impressão/PDF lê dali. Lint proíbe
`innerHTML`, `dangerouslySetInnerHTML` e marcação montada por concatenação em todo o repositório:
texto do dono e do cliente é **dado**, nunca template.

---

## F · Provas, ambiente e lei

### F-F1 · Migração numerada, versionada, re-executável, aplicada por script
**Regra.** Toda mudança de schema é migração SQL numerada no repositório, idempotente, aplicada por
script. **Nenhuma migração pode afrouxar permissão já fechada.** Migração escrita ≠ migração aplicada:
a pendência é rastreada.

**Cicatriz.** 22/07: a migration 0003 foi **abortada** porque "reabria em silêncio um furo de segurança
já fechado — deixava qualquer usuário logado criar usuários". E o legado terminou com 0014, 0015 e
0016 pendentes de aplicação manual pelo dono.

**Teste.** Suíte que roda todas as migrações do zero contra banco limpo e depois roda de novo; e um
teste de permissão que falha se um GRANT fechado reaparecer.

---

### F-F2 · Separação de ambientes: produção nunca é alvo de teste nem de seed
**Regra.** Projeto de banco separado por ambiente. CI roda contra banco **efêmero**, destruído ao fim.
Seed é explícito, idempotente, **bloqueado em produção**, e **nunca contém dinheiro** — no máximo
catálogo. Toda linha semeada carrega `origem='seed'`.

**Cicatriz.** Nos ciclos 21–24 o sistema subiu **sozinho** para o banco 16 clientes, 19 serviços, 31
agendamentos, 17 produtos, os pontos de 16 clientes e — o pior — **48 comandas e 70 lançamentos
financeiros** de exemplo. Com append-only, esse dinheiro fictício não sai mais.

> Isto também resolve a impossibilidade lógica do legado: "o teste desfaz seus próprios rastros" não
> convive com "sem GRANT de DELETE". Limpeza é por destruição do ambiente.

---

### F-F3 · Ponto de retorno provado antes do primeiro dado real
**Regra.** PITR habilitado e uma **restauração efetivamente executada** antes de o primeiro dado de
cliente entrar.

**Por quê.** Append-only e soft delete não cobrem os dois caminhos destrutivos que sobram: migração
ruim (a 0003 quase rodou) e erro de operação no painel do provedor. O legado usou exportação manual de
JSON como "o seguro" e o próprio changelog a chama de paliativo — além de o arquivo conter a base
inteira de clientes, baixável por qualquer um com acesso a Configurações e sem registro de quem baixou.

---

### F-F4 · Configuração validada no boot
**Regra.** Aplicação e cada função de servidor conferem no arranque a lista declarada de variáveis e
**abortam nomeando exatamente o que falta**. Paridade de runtime entre dev e produção. Smoke test
pós-deploy como portão de entrega.

**Cicatriz.** 15/06: criação de usuários entregue "testada de ponta a ponta". 17/06: erro **500** em
produção — variáveis faltando na Vercel **e** um import sem a extensão `.js`, que só quebra no runtime
do servidor. A funcionalidade nem rodava em `npm run dev`.

---

### F-F5 · Os invariantes acima têm teste com controle negativo, no CI
**Regra.** Portões: verificação de tipos limpa, build OK, suítes verdes **com números** (N/N), e cada
invariante desta página com um teste que **prova que falharia** se o defeito existisse.

**Por quê.** É a melhor prática que o legado desenvolveu sozinho (o revisor independente que
**reprovou** ciclos e interceptou 2 bugs críticos antes do commit) e vale herdar. Mas a forma barata
dela é máquina: invariante que mora no banco é validado contra o banco. Esconder o botão na tela nunca
contou como garantia — o legado escreveu isso e ainda assim deixou o Fechamento de Caixa com uma cópia
do cálculo sem travas.

---

### F-F6 · A lei escrita nasce no primeiro commit
**Regra.** `CLAUDE.md` na raiz + o padrão de desenvolvimento, com: as regras de ouro, as decisões do
dono que não se reabrem, as restrições vinculantes das fases futuras e os antipadrões proibidos.
Toda entrega vira linha no `CHANGELOG.md` em linguagem de dono, **incluindo reprovações e bugs
interceptados**, e entrada publicada nunca é reescrita.

**Por quê.** O legado só criou a lei no **ciclo 17**, depois de 33 mil linhas — e o changelog em
linguagem simples desde 11/06 é o motivo de esta análise ser possível. As duas coisas custam nada no
dia 1 e são impagáveis depois.

---

## Resumo

| Bloco | Itens | O que garante |
|---|---|---|
| A · Identidade | 7 | de quem é cada linha e quem pode vê-la |
| B · Tempo | 2 | de quando é cada linha |
| C · Dinheiro | 10 | que o dinheiro é exato, imutável, rastreável e reversível |
| D · Escrita | 5 | que só existe um caminho de gravação, e ele não duplica |
| E · Pessoas | 3 | LGPD sem violar o livro-razão |
| F · Provas | 6 | que tudo acima está ligado de verdade |
| **Total** | **34** | |
