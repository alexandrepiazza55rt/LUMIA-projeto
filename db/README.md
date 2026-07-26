# Modelo de dados — Fundação

Schema das duas decisões que travam todo o resto do sistema: a **hierarquia de
estabelecimentos** e o **Meu Catálogo**. Escrito para PostgreSQL 16+ e validado
contra um banco real — 40 asserções, todas passando.

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
| `seed_demo.sql` | Rede com 2 estabelecimentos em **fusos diferentes** (SP e Manaus), coloração com pausa química, custo com 2 vigências |
| `tests/test_fundacao.sql` | 40 asserções; termina em `ROLLBACK`, é idempotente |

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

## Próximas migrations

`0007` diante: agenda (com garantia de não-sobreposição multi-recurso **no
banco**, não em lock de Redis), balcão (comanda com itens polimórficos e
multi-executor), estoque (livro append-only), fiscal (regime versionado e
memória de cálculo imutável).
