-- =============================================================================
-- LUMIA · Testes de fundação
-- =============================================================================
-- Estes testes não verificam "o SQL roda". Verificam que o schema torna
-- IMPOSSÍVEL violar cada decisão irreversível — o que a análise de lacunas
-- exigiu no CI. Rodar com:
--   psql -v ON_ERROR_STOP=1 -f db/tests/test_fundacao.sql
-- Qualquer falha aborta com exceção.
--
-- Pré-requisito: migrations 0001–0004 + seed_demo.sql aplicados.
-- =============================================================================

\set ON_ERROR_STOP on
\timing off

-- A suíte roda inteira dentro de UMA transação encerrada por ROLLBACK. Assim é
-- idempotente (pode rodar N vezes no CI) e não deixa resíduo no banco. Os
-- blocos que capturam exceção usam savepoint interno do PL/pgSQL, então a
-- transação sobrevive a cada teste de rejeição.
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.ok(p_condicao boolean, p_nome text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_condicao THEN
    RAISE NOTICE '  OK   %', p_nome;
  ELSE
    RAISE EXCEPTION 'FALHOU: %', p_nome;
  END IF;
END;
$$;

-- Executa SQL esperando que ele FALHE. Se passar, o teste falha.
CREATE OR REPLACE FUNCTION pg_temp.deve_falhar(p_sql text, p_nome text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN others THEN
    RAISE NOTICE '  OK   % (bloqueado: %)', p_nome, left(SQLERRM, 60);
    RETURN;
  END;
  RAISE EXCEPTION 'FALHOU: % — a operação deveria ter sido bloqueada e passou', p_nome;
END;
$$;

-- Executa SQL esperando que ele PASSE.
CREATE OR REPLACE FUNCTION pg_temp.deve_passar(p_sql text, p_nome text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE '  OK   %', p_nome;
EXCEPTION WHEN others THEN
  RAISE EXCEPTION 'FALHOU: % — deveria ter sido aceito, mas: %', p_nome, SQLERRM;
END;
$$;

\echo ''
\echo '=== 1. Convenções de chave e vigência ==============================='

DO $$
DECLARE v_tenant uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);

  -- Toda tabela de tenant tem PK composta começando por tenant_id.
  PERFORM pg_temp.ok(NOT EXISTS (
    SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_constraint k ON k.conrelid = c.oid AND k.contype = 'p'
     WHERE n.nspname = 'lumia' AND c.relkind = 'r'
       AND EXISTS (SELECT 1 FROM information_schema.columns col
                    WHERE col.table_schema='lumia' AND col.table_name=c.relname
                      AND col.column_name='tenant_id')
       -- primeira coluna da PK precisa ser tenant_id
       AND (SELECT attname FROM pg_attribute
             WHERE attrelid = c.oid AND attnum = k.conkey[1]) <> 'tenant_id'
  ), 'toda tabela com tenant_id tem tenant_id como 1a coluna da PK');

  -- Toda tabela com tenant_id tem RLS habilitada e forçada.
  PERFORM pg_temp.ok(NOT EXISTS (
    SELECT 1 FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='lumia' AND c.relkind='r'
       AND EXISTS (SELECT 1 FROM information_schema.columns col
                    WHERE col.table_schema='lumia' AND col.table_name=c.relname
                      AND col.column_name='tenant_id')
       AND NOT (c.relrowsecurity AND c.relforcerowsecurity)
  ), 'toda tabela com tenant_id tem RLS habilitada E forcada');

  -- Toda tabela com vigência precisa de EXCLUDE. Não há exceção: mesmo onde a
  -- sobreposição é intencional (tabela_preco, em que convênio convive com a
  -- tabela geral), o EXCLUDE existe para impedir o EMPATE AMBÍGUO — mesma
  -- prioridade, mesmo escopo e vigências sobrepostas tornariam a resolução de
  -- preço arbitrária.
  PERFORM pg_temp.ok(NOT EXISTS (
    SELECT 1 FROM information_schema.columns col
      JOIN pg_class c ON c.relname = col.table_name AND c.relnamespace='lumia'::regnamespace
     WHERE col.table_schema='lumia' AND col.column_name='vigencia'
       AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                        WHERE k.conrelid=c.oid AND k.contype='x')
  ), 'toda tabela com coluna vigencia tem EXCLUDE anti-sobreposicao');
END $$;

-- Empate ambíguo de prioridade é bloqueado; sobreposição entre prioridades
-- diferentes continua permitida.
DO $$
DECLARE v_tenant uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.tabela_preco (tenant_id, id, nome, canal, prioridade, vigencia)
    VALUES (%L, lumia.uuid_v7(), 'Outra tabela geral', 'TODOS', 0,
            daterange('2026-06-01','2026-12-01','[)'))
  $q$, v_tenant),
  'duas tabelas com a MESMA prioridade e vigencia sobreposta sao rejeitadas');

  PERFORM pg_temp.deve_passar(format($q$
    INSERT INTO lumia.tabela_preco (tenant_id, id, nome, canal, prioridade, vigencia)
    VALUES (%L, lumia.uuid_v7(), 'Campanha Dia das Maes', 'TODOS', 20,
            daterange('2026-05-01','2026-05-15','[)'))
  $q$, v_tenant),
  'tabela com prioridade DIFERENTE pode se sobrepor (convenio, campanha)');
END $$;

\echo ''
\echo '=== 2. Hierarquia organizacional ==================================='

DO $$
DECLARE
  v_tenant uuid := '00000000-0000-7000-8000-00000000a001';
  v_pinheiros uuid := '00000000-0000-7000-8000-00000000b003';
  v_sala uuid := '00000000-0000-7000-8000-00000000b005';
  v_cadeira uuid := '00000000-0000-7000-8000-00000000b006';
  v_caminho_sala ltree;
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);

  SELECT caminho INTO v_caminho_sala FROM lumia.no_org WHERE id = v_sala;

  -- Cadeira é descendente da sala pelo caminho materializado.
  PERFORM pg_temp.ok(
    (SELECT caminho <@ v_caminho_sala FROM lumia.no_org WHERE id = v_cadeira),
    'caminho materializado: cadeira e descendente da sala');

  -- Descendentes do estabelecimento: sala + cadeira + cabine = 3
  PERFORM pg_temp.ok(
    (SELECT count(*) FROM lumia.no_org
      WHERE caminho <@ (SELECT caminho FROM lumia.no_org WHERE id=v_pinheiros)
        AND id <> v_pinheiros) = 3,
    'consulta de subarvore retorna as 3 unidades do estabelecimento');

  -- Profundidade coerente
  PERFORM pg_temp.ok(
    (SELECT profundidade FROM lumia.no_org WHERE id=v_cadeira) = 4,
    'profundidade da cadeira = 4 (grupo>pj>estab>sala>cadeira)');
END $$;

-- Hierarquia inválida é rejeitada pelo trigger.
DO $$
DECLARE v_tenant uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.no_org (tenant_id, id, tipo, pai_id, nome, caminho, profundidade)
    VALUES (%L, lumia.uuid_v7(), 'ESTABELECIMENTO', %L, 'Estab dentro de unidade', 'x', 0)
  $q$, v_tenant, '00000000-0000-7000-8000-00000000b006'),
  'ESTABELECIMENTO nao pode ser filho de UNIDADE');

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.no_org (tenant_id, id, tipo, pai_id, nome, caminho, profundidade)
    VALUES (%L, lumia.uuid_v7(), 'GRUPO', %L, 'Grupo com pai', 'x', 0)
  $q$, v_tenant, '00000000-0000-7000-8000-00000000b001'),
  'GRUPO nao pode ter pai');

  PERFORM pg_temp.deve_falhar(format($q$
    UPDATE lumia.estabelecimento SET fuso = 'America/Nao_Existe'
     WHERE no_org_id = %L
  $q$, '00000000-0000-7000-8000-00000000b003'),
  'fuso IANA inexistente e rejeitado');
END $$;

\echo ''
\echo '=== 3. Isolamento entre tenants ===================================='

-- Cria um segundo tenant e prova que nenhum dos dois enxerga o outro.
DO $$
DECLARE
  v_t1 uuid := '00000000-0000-7000-8000-00000000a001';
  v_t2 uuid := '00000000-0000-7000-8000-00000000a002';
  v_visiveis int;
BEGIN
  -- criação como superusuário (administração de plataforma)
  INSERT INTO lumia.tenant (id, celula_id, slug, nome_exibicao, status)
  VALUES (v_t2, '00000000-0000-7000-8000-0000000000c1', 'salao-rival', 'Salão Rival', 'ATIVO')
  ON CONFLICT (id) DO NOTHING;

  PERFORM set_config('lumia.tenant_id', v_t2::text, true);
  INSERT INTO lumia.no_org (tenant_id, id, tipo, pai_id, nome, caminho, profundidade)
  VALUES (v_t2, '00000000-0000-7000-8000-00000000b201', 'GRUPO', NULL, 'Grupo Rival', 'x', 0)
  ON CONFLICT DO NOTHING;

  -- Como o teste roda como superusuário, RLS é ignorada; a verificação real de
  -- isolamento é feita abaixo com o papel lumia_app.
  PERFORM pg_temp.ok(true, 'tenant 2 criado para o teste de isolamento');
END $$;

-- Agora como lumia_app, que É contido pela política.
SET ROLE lumia_app;

DO $$
DECLARE
  v_t1 uuid := '00000000-0000-7000-8000-00000000a001';
  v_t2 uuid := '00000000-0000-7000-8000-00000000a002';
  v_n1 int; v_n2 int; v_sem_ctx int;
BEGIN
  PERFORM set_config('lumia.tenant_id', v_t1::text, true);
  SELECT count(*) INTO v_n1 FROM lumia.no_org;

  PERFORM set_config('lumia.tenant_id', v_t2::text, true);
  SELECT count(*) INTO v_n2 FROM lumia.no_org;

  PERFORM pg_temp.ok(v_n1 = 7, 'tenant 1 ve exatamente seus 7 nos');
  PERFORM pg_temp.ok(v_n2 = 1, 'tenant 2 ve exatamente seu 1 no');

  -- Sem contexto de tenant, nada é visível: falha fechada.
  PERFORM set_config('lumia.tenant_id', '', true);
  SELECT count(*) INTO v_sem_ctx FROM lumia.no_org;
  PERFORM pg_temp.ok(v_sem_ctx = 0, 'sem contexto de tenant, zero linhas visiveis');

  -- Serviços do tenant 1 não aparecem para o tenant 2.
  PERFORM set_config('lumia.tenant_id', v_t2::text, true);
  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.servico) = 0,
    'tenant 2 nao ve nenhum servico do tenant 1');
END $$;

-- Escrever para outro tenant é bloqueado pelo WITH CHECK da política.
DO $$
BEGIN
  PERFORM set_config('lumia.tenant_id', '00000000-0000-7000-8000-00000000a002', true);
  PERFORM pg_temp.deve_falhar($q$
    INSERT INTO lumia.no_org (tenant_id, id, tipo, pai_id, nome, caminho, profundidade)
    VALUES ('00000000-0000-7000-8000-00000000a001', lumia.uuid_v7(), 'GRUPO', NULL, 'Invasor', 'x', 0)
  $q$, 'gravar linha com tenant_id de outro tenant e bloqueado (WITH CHECK)');
END $$;

RESET ROLE;

-- FK composta impede referência cruzada entre tenants, mesmo como superusuário.
DO $$
BEGIN
  PERFORM set_config('lumia.tenant_id', '00000000-0000-7000-8000-00000000a002', true);
  PERFORM pg_temp.deve_falhar($q$
    INSERT INTO lumia.no_org (tenant_id, id, tipo, pai_id, nome, caminho, profundidade)
    VALUES ('00000000-0000-7000-8000-00000000a002', lumia.uuid_v7(), 'PESSOA_JURIDICA',
            '00000000-0000-7000-8000-00000000b001',  -- grupo do TENANT 1
            'PJ apontando para grupo de outro tenant', 'x', 0)
  $q$, 'FK composta impede apontar para pai de outro tenant');
END $$;

\echo ''
\echo '=== 4. Vigência: sobreposição é impossível ========================='

DO $$
DECLARE v_tenant uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);

  -- Custo do produto já tem [2026-01-01, 2026-07-01) e [2026-07-01, ∞).
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.produto_custo_versao
      (tenant_id, id, produto_id, custo_unitario_compra, vigencia)
    VALUES (%L, lumia.uuid_v7(), %L, 95.0, daterange('2026-06-01','2026-08-01','[)'))
  $q$, v_tenant, '00000000-0000-7000-8000-00000000f001'),
  'custo com vigencia sobreposta e rejeitado pelo EXCLUDE');

  -- Vigência adjacente (sem sobrepor) é aceita.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.produto_custo_versao
      (tenant_id, id, produto_id, custo_unitario_compra, vigencia)
    VALUES (%L, lumia.uuid_v7(), %L, 45.0, daterange('2027-01-01', NULL, '[)'))
  $q$, v_tenant, '00000000-0000-7000-8000-00000000f002'),
  'vigencia aberta a direita que engole vigencia existente e rejeitada');

  -- Preço com mesma chave e vigência sobreposta é rejeitado.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.tabela_preco_item
      (tenant_id, id, tabela_preco_id, servico_id, variante_id, preco, vigencia)
    VALUES (%L, lumia.uuid_v7(), %L, %L, %L, 999.0, daterange('2026-03-01','2026-09-01','[)'))
  $q$, v_tenant, '00000000-0000-7000-8000-000000009001',
       '00000000-0000-7000-8000-00000000e001','00000000-0000-7000-8000-00000000e101'),
  'preco com vigencia sobreposta para a mesma chave e rejeitado');
END $$;

\echo ''
\echo '=== 5. Catálogo: integridade referencial obrigatória ==============='

DO $$
DECLARE v_tenant uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.tabela_preco_item (tenant_id, id, tabela_preco_id, preco, vigencia)
    VALUES (%L, lumia.uuid_v7(), %L, 100.0, daterange('2028-01-01',NULL,'[)'))
  $q$, v_tenant, '00000000-0000-7000-8000-000000009001'),
  'item de preco sem servico nem produto e rejeitado (XOR)');

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.tabela_preco_item
      (tenant_id, id, tabela_preco_id, servico_id, produto_id, preco, vigencia)
    VALUES (%L, lumia.uuid_v7(), %L, %L, %L, 100.0, daterange('2028-01-01',NULL,'[)'))
  $q$, v_tenant, '00000000-0000-7000-8000-000000009001',
       '00000000-0000-7000-8000-00000000e001','00000000-0000-7000-8000-00000000f003'),
  'item de preco com servico E produto e rejeitado (XOR)');

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.servico
      (tenant_id, id, numero, nome, duracao_ativa_min, duracao_finalizacao_min)
    VALUES (%L, lumia.uuid_v7(), 900, 'Servico com finalizacao sem pausa', 30, 15)
  $q$, v_tenant),
  'finalizacao sem tempo de processamento e rejeitada');

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.produto
      (tenant_id, id, numero, natureza, sku, nome,
       unidade_compra_codigo, unidade_consumo_codigo, sistema_origem)
    VALUES (%L, lumia.uuid_v7(), 901, 'REVENDA', 'X-1', 'Import incompleto', 'un','un','trinks')
  $q$, v_tenant),
  'sistema_origem sem id_externo e rejeitado');

  -- Reimportação idempotente: mesmo id_externo não duplica.
  PERFORM pg_temp.deve_passar(format($q$
    INSERT INTO lumia.produto
      (tenant_id, id, numero, natureza, sku, nome,
       unidade_compra_codigo, unidade_consumo_codigo, sistema_origem, id_externo, origem)
    VALUES (%L, lumia.uuid_v7(), 902, 'REVENDA', 'IMP-1', 'Produto importado',
            'un','un','trinks','ext-123','IMPORTACAO')
  $q$, v_tenant),
  'primeira importacao com id_externo e aceita');

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.produto
      (tenant_id, id, numero, natureza, sku, nome,
       unidade_compra_codigo, unidade_consumo_codigo, sistema_origem, id_externo, origem)
    VALUES (%L, lumia.uuid_v7(), 903, 'REVENDA', 'IMP-2', 'Mesma origem externa',
            'un','un','trinks','ext-123','IMPORTACAO')
  $q$, v_tenant),
  'reimportar o mesmo id_externo nao duplica a base');
END $$;

\echo ''
\echo '=== 6. Custo direto e preço: o teste que importa =================='

-- Este é o teste que prova a decisão nº 5: o reajuste de julho NÃO pode
-- reescrever a margem de março.
DO $$
DECLARE
  v_tenant   uuid := '00000000-0000-7000-8000-00000000a001';
  v_servico  uuid := '00000000-0000-7000-8000-00000000e001';
  v_curto    uuid := '00000000-0000-7000-8000-00000000e101';
  v_longo    uuid := '00000000-0000-7000-8000-00000000e103';
  v_custo_marco  numeric;
  v_custo_agosto numeric;
  v_custo_longo  numeric;
  v_preco_geral  numeric;
  v_preco_conv   numeric;
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);

  -- Custo em MARÇO: tinta a R$80/L → 60ml = 60/1000*80 = 4,80
  --                 OX   a R$40/L → 90ml = 90/1000*40 = 3,60   Total = 8,40
  v_custo_marco := lumia.custo_direto_servico(v_tenant, v_servico, v_curto, '2026-03-15');
  PERFORM pg_temp.ok(v_custo_marco = 8.4000,
    format('custo direto em marco = 8,40 (obtido: %s)', v_custo_marco));

  -- Custo em AGOSTO, após o reajuste: tinta a R$100/L → 6,00 + 3,60 = 9,60
  v_custo_agosto := lumia.custo_direto_servico(v_tenant, v_servico, v_curto, '2026-08-15');
  PERFORM pg_temp.ok(v_custo_agosto = 9.6000,
    format('custo direto em agosto = 9,60 apos reajuste (obtido: %s)', v_custo_agosto));

  -- E O PONTO CENTRAL: consultar março DEPOIS do reajuste devolve o valor de março.
  PERFORM pg_temp.ok(
    lumia.custo_direto_servico(v_tenant, v_servico, v_curto, '2026-03-15') = 8.4000,
    'o reajuste de julho NAO reescreveu a margem de marco');

  -- Variante longo consome 1,8x: 8,40 * 1,8 = 15,12 (em março)
  v_custo_longo := lumia.custo_direto_servico(v_tenant, v_servico, v_longo, '2026-03-15');
  PERFORM pg_temp.ok(v_custo_longo = 15.1200,
    format('variante longo aplica fator 1,8 = 15,12 (obtido: %s)', v_custo_longo));

  -- Preço: tabela geral vs convênio (prioridade maior ganha)
  SELECT preco INTO v_preco_geral FROM lumia.preco_vigente(
    v_tenant, '2026-03-15', '00000000-0000-7000-8000-00000000b003', 'BALCAO'::lumia.canal_venda,
    v_servico, v_curto, NULL, NULL, NULL);
  PERFORM pg_temp.ok(v_preco_geral = 150.0000,
    format('convenio (prioridade 10) vence a tabela geral: 150,00 (obtido: %s)', v_preco_geral));

  -- Variante longo só existe na tabela geral → 260
  SELECT preco INTO v_preco_conv FROM lumia.preco_vigente(
    v_tenant, '2026-03-15', '00000000-0000-7000-8000-00000000b003', 'BALCAO'::lumia.canal_venda,
    v_servico, v_longo, NULL, NULL, NULL);
  PERFORM pg_temp.ok(v_preco_conv = 260.0000,
    format('variante longo resolve para 260,00 na tabela geral (obtido: %s)', v_preco_conv));

  -- Margem de contribuição em março, variante curto: 150 - 8,40
  PERFORM pg_temp.ok((v_preco_geral - v_custo_marco) = 141.6000,
    'margem de contribuicao calculavel a partir do catalogo');
END $$;

\echo ''
\echo '=== 7. Alíquota por município (mesmo serviço, dois estabelecimentos) ==='

DO $$
DECLARE
  v_tenant uuid := '00000000-0000-7000-8000-00000000a001';
  v_sp numeric; v_am numeric;
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);
  SELECT aliquota_iss INTO v_sp FROM lumia.servico_atributo_fiscal
   WHERE servico_id='00000000-0000-7000-8000-00000000e001'
     AND estabelecimento_id='00000000-0000-7000-8000-00000000b003';
  SELECT aliquota_iss INTO v_am FROM lumia.servico_atributo_fiscal
   WHERE servico_id='00000000-0000-7000-8000-00000000e001'
     AND estabelecimento_id='00000000-0000-7000-8000-00000000b004';
  PERFORM pg_temp.ok(v_sp = 2.0 AND v_am = 5.0,
    format('mesmo servico, ISS 2%% em SP e 5%% em Manaus (%s / %s)', v_sp, v_am));
END $$;

\echo ''
\echo '=== 8. Tombstone e sincronização incremental ======================'

-- ATENÇÃO a uma armadilha de fundação registrada aqui de propósito: now()
-- devolve o instante de INÍCIO DA TRANSAÇÃO, não o instante da linha. Isso é
-- desejável — todas as linhas de uma operação compartilham o mesmo carimbo, o
-- que dá consistência atômica ao pull incremental — mas implica que a aplicação
-- NÃO deve usar clock_timestamp() em atualizado_em, ou duas linhas da mesma
-- operação cairiam em páginas diferentes da sincronização e uma se perderia.
DO $$
DECLARE
  v_tenant  uuid := '00000000-0000-7000-8000-00000000a001';
  v_alvo    uuid := '00000000-0000-7000-8000-00000000e002';
  v_controle uuid := '00000000-0000-7000-8000-00000000e001';
  v_marca   timestamptz := '2026-01-01 00:00:00+00';
  v_alterados int;
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);

  -- Linha de controle: sincronizada há muito tempo, não deve reaparecer.
  UPDATE lumia.servico SET atualizado_em = '2025-06-01 00:00:00+00' WHERE id = v_controle;

  -- Remoção lógica do serviço alvo.
  UPDATE lumia.servico
     SET removido_em = now(), atualizado_em = now()
   WHERE id = v_alvo;

  -- O app móvel pede "o que mudou desde a última sincronização".
  SELECT count(*) INTO v_alterados
    FROM lumia.servico WHERE atualizado_em > v_marca;

  PERFORM pg_temp.ok(v_alterados = 1,
    'pull incremental traz exatamente a linha alterada (a de controle nao volta)');

  PERFORM pg_temp.ok(
    (SELECT removido_em IS NOT NULL FROM lumia.servico WHERE id = v_alvo),
    'soft delete marcado: o app recebe a remocao e apaga o registro local');

  PERFORM pg_temp.ok(
    (SELECT count(*) FROM lumia.servico WHERE id = v_alvo) = 1,
    'a linha permanece como tombstone, nao e apagada fisicamente');
END $$;

\echo ''
\echo '=== 9. Movimentação de subárvore ================================='

DO $$
DECLARE
  v_tenant uuid := '00000000-0000-7000-8000-00000000a001';
  v_manaus uuid := '00000000-0000-7000-8000-00000000b004';
  v_sala   uuid := '00000000-0000-7000-8000-00000000b005';
  v_cadeira uuid := '00000000-0000-7000-8000-00000000b006';
BEGIN
  PERFORM set_config('lumia.tenant_id', v_tenant::text, true);

  -- Move a sala (com a cadeira dentro) para o estabelecimento de Manaus.
  UPDATE lumia.no_org SET pai_id = v_manaus WHERE id = v_sala;

  PERFORM pg_temp.ok(
    (SELECT caminho <@ (SELECT caminho FROM lumia.no_org WHERE id=v_manaus)
       FROM lumia.no_org WHERE id = v_cadeira),
    'mover a sala reposicionou a cadeira (descendente) automaticamente');

  PERFORM pg_temp.ok(
    (SELECT profundidade FROM lumia.no_org WHERE id=v_cadeira) = 4,
    'profundidade do descendente recalculada apos a mudanca');

  -- volta ao lugar
  UPDATE lumia.no_org SET pai_id = '00000000-0000-7000-8000-00000000b003' WHERE id = v_sala;
END $$;

ROLLBACK;

\echo ''
\echo '===================================================================='
\echo ' TODOS OS TESTES DE FUNDAÇÃO PASSARAM — banco devolvido ao estado inicial'
\echo '===================================================================='
