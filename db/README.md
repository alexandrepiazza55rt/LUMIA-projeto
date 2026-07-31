# Modelo de dados — Fundação

Schema das decisões que travam todo o resto do sistema: a **hierarquia de
estabelecimentos**, o **Meu Catálogo**, a **Minha Agenda** e o **Meu Balcão**
(caixa e comanda). Escrito para PostgreSQL 16+ e validado contra um banco real —
**142 asserções**, incluindo um teste de concorrência com 30 sessões simultâneas.

```bash
./db/run.sh                # migrations + seed + testes
./db/run.sh --so-testes    # apenas a suíte
```

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| `migrations/0001_convencoes.sql` | Extensões, UUIDv7, domínios (`valor_monetario`, `moeda`, `fuso_iana`, `cnpj`), enums de convenção |
| `migrations/0002_hierarquia.sql` | Célula, tenant, árvore organizacional, pessoa jurídica, estabelecimento, unidade operacional, RLS |
| `migrations/0003_catalogo.sql` | Taxonomia canônica, serviços, variantes, produtos, ficha técnica, preços, atributos fiscais |
| `migrations/0004_papeis.sql` | Papéis `lumia_app` e `lumia_leitura` com concessões |
| `migrations/0005_preco_deterministico.sql` | `EXCLUDE` que impede empate ambíguo de prioridade de tabela |
| `migrations/0006_corrige_profundidade_subarvore.sql` | Correção de erro de 1 na profundidade ao mover subárvore |
| `migrations/0007_agenda.sql` | Profissional, cliente, recurso agendável, agendamento, **reserva com EXCLUDE**, bloqueio, lista de espera |
| `migrations/0008_caixa.sql` | Terminal, sessão de caixa, **livro append-only**, conferência cega, divergência, papéis operador/gestor |
| `migrations/0009_comanda.sql` | Comanda, **cadeia de custódia**, itens multi-executor, pagamento idempotente, junção/divisão |
| `seed_demo.sql` | Rede com 2 estabelecimentos em **fusos diferentes** (SP e Manaus), coloração com pausa química, custo com 2 vigências |
| `tests/test_fundacao.sql` | 40 asserções de hierarquia e catálogo |
| `tests/test_agenda.sql` | 37 asserções de agenda |
| `tests/test_balcao.sql` | 59 asserções de caixa e comanda; termina em `ROLLBACK`, é idempotente |
| `tests/test_concorrencia.sh` | 30 sessões paralelas disputando o mesmo horário |

As migrations 0005 e 0006 existem porque a suíte de testes encontrou os dois
problemas. Ficaram como migrations separadas em vez de edição das anteriores
para preservar o histórico — em produção, migration aplicada não se reescreve.

## Convenções (verificadas por teste, não por disciplina)

- **PK composta `(tenant_id, id)`** em toda tabela de tenant. Toda FK também
  carrega `tenant_id`, então **o banco impede referência cruzada entre tenants**
  — deixa de depender de o desenvolvedor lembrar do `WHERE`.
- **`tenant_id` é a primeira coluna de todo índice.**
- **UUIDv7 gerado pela aplicação.** Ordenável por tempo (preserva localidade de
  índice) e compatível com geração offline. `lumia.uuid_v7()` existe para seed e
  teste, não como `DEFAULT`.
- **Numeração humana sequencial por tenant** ao lado da PK técnica: o dono fala
  "unidade 2", não um UUID.
- **RLS habilitada *e* forçada** em toda tabela com `tenant_id`. Política única
  por `tenant_id`; visibilidade por estabelecimento é RBAC na aplicação, nunca
  uma segunda política. **Sem contexto de tenant, zero linhas** — falha fechada.
- **Soft delete com tombstone** (`removido_em`) e `atualizado_em` indexado, para
  que o app móvel receba remoções no pull incremental.
- **Vigência (SCD-2)** em preço, custo e parâmetro fiscal, com `EXCLUDE USING
  gist` impedindo sobreposição. Nenhuma condição de corrida consegue furar.
- **`sistema_origem` + `id_externo`** único por tenant: reimportar a base de um
  concorrente não duplica.
- **Fuso IANA por estabelecimento**, validado contra `pg_timezone_names`.

## A hierarquia

```
GRUPO  →  PESSOA_JURIDICA (CNPJ)  →  ESTABELECIMENTO  →  UNIDADE
```

Regra de fronteira gravada no modelo:

- **Franqueado = tenant próprio.** Controlador LGPD distinto, CNPJ próprio,
  numeração fiscal própria. O vínculo com o franqueador é referência
  `tenant.franqueador_id` entre tenants — nunca acesso direto à linha.
- **Filial = estabelecimento do mesmo tenant.**

A árvore usa `parent_id` + **caminho materializado** em `ltree`, mantido por
trigger. Consultar a subárvore de um estabelecimento é um operador, sem recursão:

```sql
SELECT * FROM lumia.no_org
 WHERE caminho <@ (SELECT caminho FROM lumia.no_org WHERE id = :estabelecimento);
```

Mover um nó reposiciona todos os descendentes automaticamente. O trigger de
hierarquia rejeita aninhamento inválido — um `ESTABELECIMENTO` não pode ser
filho de uma `UNIDADE`.

## O catálogo

**Serviço** é o nó do qual agenda, comanda, comissão, estoque, DRE e as Bússolas
dependem. Três pontos que o schema resolve e que costumam ser subestimados:

**1. Tempo por etapa.** Coloração ocupa o profissional 40 min, depois 30 min de
pausa química, depois 20 min de finalização. Durante a pausa o profissional
atende outra pessoa, mas a cadeira segue ocupada:

```sql
duracao_ativa_min, duracao_processamento_min, duracao_finalizacao_min,
libera_profissional_no_processamento, libera_recurso_no_processamento
```

Sem modelar isso, a agenda perde cerca de 30% da capacidade real.

**2. Preço não é atributo do serviço.** É linha com vigência em
`tabela_preco_item`, variando por unidade, nível do profissional, canal, faixa
horária e convênio. A resolução é determinística — prioridade da tabela, depois
especificidade — via `lumia.preco_vigente()`.

**3. Ficha técnica é a única fonte do custo direto.** Produto comprado em frasco
de 1 L e consumido em ml (`fator_conversao = 1000`); a variante multiplica a dose
(`fator_consumo`). `lumia.custo_direto_servico()` avalia tudo pelo custo
**vigente na data do fato**.

## O teste que importa

```
custo direto em março  = 8,40   (tinta a R$ 80/L)
custo direto em agosto = 9,60   (tinta a R$ 100/L, reajuste em 01/jul)
consultar março DEPOIS do reajuste = 8,40   ← a margem histórica não mudou
```

É isso que a vigência protege. Com `UPDATE` de valor, o reajuste de julho
reescreveria o relatório de março, a comissão seria recalculada
retroativamente — gerando passivo trabalhista — e não haveria backfill
possível, porque a informação da vigência teria sido destruída.

## A agenda: a garantia está no banco

Em vez de "um agendamento tem um horário", o modelo tem **reservas** — uma linha
por `(recurso, intervalo)`. Uma única constraint faz o double-booking ser
impossível:

```sql
CONSTRAINT rs_sem_sobreposicao EXCLUDE USING gist (
  tenant_id WITH =, recurso_id WITH =, slot WITH =, periodo WITH &&
) WHERE (ativa)
```

`recurso_agendavel` unifica profissional e unidade operacional sob uma
identidade só, de modo que **uma** constraint cobre profissional, sala, cadeira,
maca e equipamento. Capacidade > 1 (uma sala para duas pessoas) é modelada por
`slot`: a sala aceita slot 1 e 2 no mesmo horário e recusa o terceiro.

### A pausa química cai fora de graça

Coloração ocupa a profissional 40 min, depois 30 min de pausa química, depois
20 min de finalização. Durante a pausa ela atende outra cliente, mas a cadeira
segue ocupada. No modelo isso não é código especial — é a contagem de linhas:

```
profissional →  2 reservas (antes e depois da pausa)   =  70 min
cadeira      →  1 reserva contígua                     = 100 min
```

É essa distinção que devolve ao salão cerca de 30% da capacidade que uma agenda
ingênua desperdiça.

### A prova de concorrência

```
30 sessões PostgreSQL simultâneas disputando o mesmo horário
   sessões que gravaram ......... 1
   recusadas pela constraint .... 29
   reservas no banco ............ 1
```

Nenhum lock distribuído participou. `lumia.slot_livre()` existe para a tela de
disponibilidade, mas **não é a garantia** — entre consultar e gravar há uma
janela de corrida, e é o `EXCLUDE` que a fecha. A aplicação trata a violação de
exclusão como "o horário acabou de ser ocupado" e reapresenta a agenda.

### Fuso é por estabelecimento, não por servidor

O mesmo instante UTC cai em **dias comerciais diferentes**:

```
2026-03-11 03:30 UTC  →  11/mar em São Paulo (UTC-3)
2026-03-11 03:30 UTC  →  10/mar em Manaus    (UTC-4)
```

Sem isso, o fechamento de caixa da virada vaza para o dia seguinte.

## O balcão: o ponto mais delicado

É onde dinheiro real encontra responsabilidade pessoal. Três decisões, cada uma
vinda de uma restrição concreta.

### 1. O livro do caixa é imutável de verdade

`movimento_caixa` é append-only, e não por convenção: um trigger recusa `UPDATE`
e `DELETE`. Corrigir é lançar `ESTORNO` ou `AJUSTE` apontando para o original. O
saldo **nunca** é uma coluna — é sempre derivado da soma do livro, então não
existe número que alguém possa "acertar".

Sangria exige motivo escrito e autorizador (constraints, não validação de tela) e
não deixa a gaveta negativa. Retirada não registrada é a origem mais comum de
quebra de caixa.

### 2. A conferência cega é imposta pelo banco

O operador declara o que contou sem ver o que o sistema esperava. Isso não é
campo escondido na interface — é **GRANT em nível de coluna**:

```sql
GRANT SELECT (tenant_id, id, sessao_caixa_id, meio_pagamento, valor_declarado,
              recontagens, declarado_em, declarado_por, criado_em)
  ON lumia.conferencia_caixa TO lumia_caixa_operador;
```

Sem `valor_esperado` nem `divergencia` na lista, o papel do operador
literalmente não consegue lê-los. O teste prova:

```
operador NAO consegue ler valor_esperado  → permission denied
operador NAO consegue ler a divergencia   → permission denied
operador LE o que ele mesmo declarou      → ok
```

Uma constraint separa quem conta de quem apura: `apurada_por <> conferida_por`.
Sem essa segregação, a conferência cega perderia o sentido.

### 3. Divergência não vira desconto automático

O art. 462 da CLT protege a integridade salarial, e a jurisprudência sobre
desconto de quebra de caixa é dividida — há decisões nos dois sentidos, com o
TST tratando de forma diferente quando existe gratificação de quebra de caixa
paga ao empregado.

Por isso o sistema **registra e para**: valor, justificativa e decisão nomeada
de quem decidiu. Nenhum débito é gerado contra o operador. O teste verifica
literalmente que nenhum lançamento de ajuste apareceu depois da apuração. A
consequência financeira é ato humano documentado, nunca efeito colateral de
software.

## A comanda: responsabilidade sem ambiguidade

`comanda_custodia` guarda quem respondia pela comanda **em cada instante**, com
o mesmo mecanismo da agenda — períodos com `EXCLUDE` contra sobreposição, mais
um trigger que impede buraco entre um elo e o seguinte. Resultado: a comanda
nunca fica sem dono, nem por um microssegundo, e "de quem era a comanda às 15h40
de terça?" é uma consulta, não uma investigação.

Passar a comanda adiante exige **motivo tipado** (troca de turno, cliente mudou
de profissional, encaminhamento para o caixa…), e motivo `OUTRO` exige
justificativa escrita. Só quem detém a comanda pode passá-la. Ambos os lados
ficam nomeados: quem entregou, quem recebeu, quem autorizou.

Uma comanda tem **vários executores**: a recepção abre, a cabeleireira executa um
item, a manicure parceira executa outro, o caixa recebe. Cada papel fica
registrado no lugar certo — e o item de parceira carrega
`titular_receita = PROFISSIONAL_PARCEIRO`, porque a Lei 13.352/2016 manda o salão
centralizar o recebimento mas discriminar a parte do parceiro na nota.

O preço praticado é congelado no item junto com o preço de tabela do mesmo
instante, de modo que a auditoria de margem explica cada centavo de desconto sem
depender da tabela de hoje. Desconto sem motivo e sem autorizador é recusado.

Pagamento tem **chave de idempotência** única por tenant: o botão clicado duas
vezes, ou o retry após timeout, resulta em um pagamento — não em cobrança
dobrada.

### Custódia e comissão são eixos independentes

Custódia e execução respondem a perguntas diferentes: a custódia diz **em qual
caixa o dinheiro entra**; o executor do item diz **a quem a produção pertence**.
Elas divergem exatamente no caso que motiva a transferência — o profissional vai
almoçar e passa a comanda adiante.

Por isso `vw_producao_executor` agrega por `comanda_item.executor_id` e não pode
sequer mencionar a custódia. O teste do balcão prova as duas coisas: a produção
da cabeleireira e a da manicure continuam intactas depois de três transferências,
o caixa que ficou com a comanda no fim não produziu nada, e a definição da view
é verificada contra qualquer referência a `custodia` ou `responsavel_atual`. O
controle negativo foi executado: reescrita a view atribuindo produção pelo
responsável atual, a asserção estrutural reprova.

Uma única consulta de apuração que confundisse os dois eixos pagaria o
profissional errado — e o erro só apareceria na reclamação de quem recebeu a
menos, depois do pagamento feito. É a decisão irreversível 18, e veio da lente do
sistema legado: lá, a máquina de transferência e a regra "o dinheiro cai no caixa
de quem recebeu" foram construídas separadamente, e a interação das duas com a
comissão nunca foi declarada nem testada.

## Próximas migrations

`0010` diante: estoque (livro append-only com custo médio ponderado e baixa
disparada pelo check-out), fiscal (regime versionado, memória de cálculo
imutável, numeração sem lacuna).

O núcleo financeiro (`lancamento`) ainda não existe, e é onde entram quatro
achados da lente do legado antes da primeira linha de DDL: **natureza em eixos
independentes** (`afeta_receita`, `afeta_gaveta`, `gera_comissao` são ortogonais
— gorjeta em dinheiro entra na gaveta sem ser receita), **estorno que herda a
natureza da origem por trigger**, **origem polimórfica** (`tipo_origem` +
`id_origem`, nunca `comanda_id` no ledger, porque locação, compra e conta a pagar
também produzem lançamento) e **efeito tipado com inverso declarado**, para que o
estorno enumere os efeitos gravados em vez de repetir uma lista escrita à mão.
