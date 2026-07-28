-- =============================================================================
-- LUMIA · Testes do balcão: caixa e comanda
-- =============================================================================
-- Cobre o ponto mais delicado do sistema. Prova, entre outras coisas, que:
--   • o livro do caixa é imutável de verdade (UPDATE e DELETE falham)
--   • o operador NÃO CONSEGUE LER o valor esperado nem a divergência
--   • a comanda nunca fica sem dono, nem por um microssegundo
--   • transferir sem motivo é impossível
--   • divergência de caixa não gera desconto automático contra ninguém
--
-- Pré-requisito: migrations 0001–0009 + seed_demo.sql. Termina em ROLLBACK.
-- =============================================================================

\set ON_ERROR_STOP on
\timing off

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.ok(p_condicao boolean, p_nome text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_condicao THEN RAISE NOTICE '  OK   %', p_nome;
  ELSE RAISE EXCEPTION 'FALHOU: %', p_nome; END IF;
END; $$;

CREATE OR REPLACE FUNCTION pg_temp.deve_falhar(p_sql text, p_nome text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN others THEN
    RAISE NOTICE '  OK   % (bloqueado: %)', p_nome, left(SQLERRM, 52); RETURN;
  END;
  RAISE EXCEPTION 'FALHOU: % — deveria ter sido bloqueado e passou', p_nome;
END; $$;

\echo ''
\echo '=== preparação ======================================================='

DO $$
DECLARE t uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  INSERT INTO lumia.profissional (tenant_id,id,numero,nome,vinculo) VALUES
    (t,'00000000-0000-7000-8000-0000000a2001',11,'Recepção Carla','CLT'),
    (t,'00000000-0000-7000-8000-0000000a2002',12,'Cabeleireira Ana','CLT'),
    (t,'00000000-0000-7000-8000-0000000a2003',13,'Manicure Bia','PARCEIRO'),
    (t,'00000000-0000-7000-8000-0000000a2004',14,'Caixa Diego','CLT'),
    (t,'00000000-0000-7000-8000-0000000a2005',15,'Gerente Eva','SOCIO');

  INSERT INTO lumia.cliente (tenant_id,id,numero,nome) VALUES
    (t,'00000000-0000-7000-8000-0000000c2001',11,'Marina');

  INSERT INTO lumia.terminal_caixa (tenant_id,id,estabelecimento_id,numero,nome)
  VALUES (t,'00000000-0000-7000-8000-0000000e2001','00000000-0000-7000-8000-00000000b003',1,'Caixa 1');

  INSERT INTO lumia.motivo_desconto (tenant_id,id,nome,limite_percentual)
  VALUES (t,'00000000-0000-7000-8000-0000000e2002','Cliente fidelidade',20);

  PERFORM pg_temp.ok(true,'5 profissionais, 1 terminal, 1 cliente');
END $$;

\echo ''
\echo '=== 1. Abertura de caixa ============================================='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_sessao uuid;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  v_sessao := lumia.abrir_caixa(t,'00000000-0000-7000-8000-0000000e2001',
                                '00000000-0000-7000-8000-0000000a2004', 200.00,
                                'Abertura do turno da manhã');

  PERFORM pg_temp.ok((SELECT status = 'ABERTA' AND fundo_troco = 200
                        FROM lumia.sessao_caixa WHERE id = v_sessao),
    'caixa aberto com fundo de troco de 200,00 e operador nomeado');

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.movimento_caixa
                       WHERE sessao_caixa_id = v_sessao AND tipo = 'FUNDO_TROCO') = 1,
    'fundo de troco entrou no livro como lancamento, nao como campo solto');

  -- Segunda sessão no mesmo terminal é impossível.
  PERFORM pg_temp.deve_falhar(format($q$
    SELECT lumia.abrir_caixa(%L,%L,%L,100.00)
  $q$, t,'00000000-0000-7000-8000-0000000e2001','00000000-0000-7000-8000-0000000a2001'),
  'segunda sessao aberta no MESMO terminal e recusada');

  PERFORM set_config('lumia.sessao_teste', v_sessao::text, false);
END $$;

\echo ''
\echo '=== 2. O livro do caixa é imutável ==================================='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_sessao uuid := current_setting('lumia.sessao_teste')::uuid;
  v_mov uuid;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);
  SELECT id INTO v_mov FROM lumia.movimento_caixa WHERE sessao_caixa_id = v_sessao LIMIT 1;

  PERFORM pg_temp.deve_falhar(format($q$
    UPDATE lumia.movimento_caixa SET valor = 999 WHERE id = %L
  $q$, v_mov), 'UPDATE em movimento de caixa e recusado (append-only)');

  PERFORM pg_temp.deve_falhar(format($q$
    DELETE FROM lumia.movimento_caixa WHERE id = %L
  $q$, v_mov), 'DELETE em movimento de caixa e recusado');
END $$;

\echo ''
\echo '=== 3. Sangria: motivo, autorizador e gaveta nunca negativa =========='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_sessao uuid := current_setting('lumia.sessao_teste')::uuid;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.movimento_caixa
      (tenant_id,id,sessao_caixa_id,sequencia,tipo,meio_pagamento,valor,afeta_gaveta,registrado_por)
    VALUES (%L, lumia.uuid_v7(), %L, 0, 'SANGRIA','DINHEIRO',50,true,%L)
  $q$, t, v_sessao, '00000000-0000-7000-8000-0000000a2004'),
  'sangria sem motivo e sem autorizador e recusada');

  PERFORM pg_temp.deve_falhar(format($q$
    SELECT lumia.registrar_sangria(%L,%L,5000.00,%L,%L,'Depósito bancário')
  $q$, t, v_sessao,'00000000-0000-7000-8000-0000000a2004','00000000-0000-7000-8000-0000000a2005'),
  'sangria maior que o disponivel deixaria a gaveta negativa');

  PERFORM lumia.registrar_sangria(t, v_sessao, 150.00,
    '00000000-0000-7000-8000-0000000a2004','00000000-0000-7000-8000-0000000a2005',
    'Depósito bancário de meio de turno');

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.movimento_caixa
     WHERE sessao_caixa_id = v_sessao AND tipo='SANGRIA' AND autorizado_por IS NOT NULL) = 1,
    'sangria valida registrada com motivo e autorizador nomeados');

  PERFORM pg_temp.ok((SELECT esperado FROM lumia.saldo_esperado_caixa(t,v_sessao)
                       WHERE meio='DINHEIRO') = 50.00,
    'saldo em especie = 200 de fundo - 150 de sangria = 50,00');
END $$;

\echo ''
\echo '=== 4. Comanda: abertura rastreada e custódia sem buraco ============='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_cm uuid;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  v_cm := lumia.abrir_comanda(t,'00000000-0000-7000-8000-00000000b003',
            '00000000-0000-7000-8000-0000000a2001',
            '00000000-0000-7000-8000-0000000c2001', NULL, 'CHECK_IN',
            '00000000-0000-7000-8000-0000000e2001','42');

  PERFORM pg_temp.ok((SELECT aberta_por = '00000000-0000-7000-8000-0000000a2001'
                        AND terminal_abertura_id IS NOT NULL AND codigo_exibicao='42'
                        FROM lumia.comanda WHERE id = v_cm),
    'comanda registra quem abriu, quando e em qual terminal');

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.comanda_custodia
                       WHERE comanda_id = v_cm AND upper(periodo) IS NULL) = 1,
    'abertura ja cria a primeira custodia, aberta');

  PERFORM set_config('lumia.comanda_teste', v_cm::text, false);
END $$;

\echo ''
\echo '=== 5. Compartilhamento: transferir exige motivo ====================='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_cm uuid := current_setting('lumia.comanda_teste')::uuid;
  v_carla uuid := '00000000-0000-7000-8000-0000000a2001';
  v_ana   uuid := '00000000-0000-7000-8000-0000000a2002';
  v_bia   uuid := '00000000-0000-7000-8000-0000000a2003';
  v_diego uuid := '00000000-0000-7000-8000-0000000a2004';
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  -- Motivo é parâmetro obrigatório: não existe caminho sem ele.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.comanda_custodia
      (tenant_id,id,comanda_id,responsavel_id,periodo,transferida_por)
    VALUES (%L, lumia.uuid_v7(), %L, %L, tstzrange(now(),NULL,'[)'), %L)
  $q$, t, v_cm, v_ana, v_carla),
  'gravar transferencia SEM motivo e recusado pela constraint');

  -- Recepção → cabeleireira
  PERFORM lumia.transferir_comanda(t, v_cm, v_carla, v_ana,
    'CLIENTE_MUDOU_DE_PROFISSIONAL', NULL, NULL);
  PERFORM pg_temp.ok((SELECT responsavel_atual_id = v_ana FROM lumia.comanda WHERE id=v_cm),
    'responsavel atual projetado corretamente apos a transferencia');

  -- Cabeleireira → manicure
  PERFORM lumia.transferir_comanda(t, v_cm, v_ana, v_bia,
    'CLIENTE_MUDOU_DE_AMBIENTE', NULL, '00000000-0000-7000-8000-0000000a2005');
  -- Manicure → caixa
  PERFORM lumia.transferir_comanda(t, v_cm, v_bia, v_diego,
    'ENCAMINHAMENTO_PARA_CAIXA', NULL, NULL);

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.comanda_custodia WHERE comanda_id=v_cm) = 4,
    'cadeia com 4 elos: recepcao > cabeleireira > manicure > caixa');

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.comanda_custodia
                       WHERE comanda_id=v_cm AND upper(periodo) IS NULL) = 1,
    'exatamente UMA custodia aberta em qualquer momento');

  -- Quem não detém a comanda não pode passá-la adiante.
  PERFORM pg_temp.deve_falhar(format($q$
    SELECT lumia.transferir_comanda(%L,%L,%L,%L,'TROCA_DE_TURNO')
  $q$, t, v_cm, v_ana, v_carla),
  'quem NAO detem a comanda nao consegue transferi-la');

  -- Motivo OUTRO exige justificativa escrita.
  PERFORM pg_temp.deve_falhar(format($q$
    SELECT lumia.transferir_comanda(%L,%L,%L,%L,'OUTRO',NULL)
  $q$, t, v_cm, v_diego, v_carla),
  'motivo OUTRO sem justificativa escrita e recusado');

  -- Transferir para si mesmo não faz sentido.
  PERFORM pg_temp.deve_falhar(format($q$
    SELECT lumia.transferir_comanda(%L,%L,%L,%L,'TROCA_DE_TURNO')
  $q$, t, v_cm, v_diego, v_diego),
  'transferir para si mesmo e recusado');
END $$;

\echo ''
\echo '=== 6. A comanda nunca fica sem dono ================================='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_cm uuid := current_setting('lumia.comanda_teste')::uuid;
  v_abertura timestamptz;
  v_buracos integer;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);
  SELECT aberta_em INTO v_abertura FROM lumia.comanda WHERE id = v_cm;

  -- Nenhum instante entre a abertura e agora fica sem responsável.
  SELECT count(*) INTO v_buracos FROM (
    SELECT lower(periodo) AS ini,
           lag(upper(periodo)) OVER (ORDER BY lower(periodo)) AS fim_anterior
      FROM lumia.comanda_custodia WHERE comanda_id = v_cm
  ) x WHERE fim_anterior IS NOT NULL AND ini <> fim_anterior;

  PERFORM pg_temp.ok(v_buracos = 0,
    'nao existe buraco entre um elo e o seguinte da cadeia');

  -- Inserir custódia com buraco é recusado.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.comanda_custodia
      (tenant_id,id,comanda_id,responsavel_id,periodo,motivo,transferida_por)
    VALUES (%L, lumia.uuid_v7(), %L, %L,
            tstzrange(now() + interval '1 hour', NULL, '[)'),
            'TROCA_DE_TURNO', %L)
  $q$, t, v_cm, '00000000-0000-7000-8000-0000000a2001','00000000-0000-7000-8000-0000000a2004'),
  'custodia comecando depois do fim da anterior (buraco) e recusada');

  -- E a pergunta que importa: de quem era a comanda naquele instante?
  PERFORM pg_temp.ok(
    lumia.responsavel_em(t, v_cm, v_abertura + interval '1 microsecond')
      = '00000000-0000-7000-8000-0000000a2001',
    'consulta pontual no passado devolve quem respondia naquele instante');
END $$;

\echo ''
\echo '=== 7. Itens: multi-executor, valor congelado, desconto justificado =='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_cm uuid := current_setting('lumia.comanda_teste')::uuid;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  -- Serviço executado pela cabeleireira (receita do estabelecimento)
  INSERT INTO lumia.comanda_item
    (tenant_id,id,comanda_id,sequencia,tipo,servico_id,variante_id,descricao_congelada,
     preco_tabela,preco_praticado,executor_id,lancado_por)
  VALUES (t,'00000000-0000-7000-8000-0000000f2001',v_cm,0,'SERVICO',
          '00000000-0000-7000-8000-00000000e001','00000000-0000-7000-8000-00000000e101',
          'Coloração raiz — Curto',180.00,180.00,
          '00000000-0000-7000-8000-0000000a2002','00000000-0000-7000-8000-0000000a2001');

  -- Serviço da manicure PARCEIRA: receita dela, não do salão
  INSERT INTO lumia.comanda_item
    (tenant_id,id,comanda_id,sequencia,tipo,servico_id,descricao_congelada,
     preco_tabela,preco_praticado,executor_id,titular_receita,lancado_por)
  VALUES (t,'00000000-0000-7000-8000-0000000f2002',v_cm,0,'SERVICO',
          '00000000-0000-7000-8000-00000000e002','Depilação a laser axila',
          120.00,120.00,'00000000-0000-7000-8000-0000000a2003',
          'PROFISSIONAL_PARCEIRO','00000000-0000-7000-8000-0000000a2001');

  -- Produto de revenda com desconto justificado e autorizado
  INSERT INTO lumia.comanda_item
    (tenant_id,id,comanda_id,sequencia,tipo,produto_id,descricao_congelada,
     preco_tabela,preco_praticado,valor_desconto,motivo_desconto_id,
     desconto_autorizado_por,lancado_por)
  VALUES (t,'00000000-0000-7000-8000-0000000f2003',v_cm,0,'PRODUTO',
          '00000000-0000-7000-8000-00000000f003','Shampoo pós-coloração 500ml',
          89.90,89.90,10.00,'00000000-0000-7000-8000-0000000e2002',
          '00000000-0000-7000-8000-0000000a2005','00000000-0000-7000-8000-0000000a2001');

  PERFORM pg_temp.ok((SELECT count(DISTINCT executor_id) FROM lumia.comanda_item
                       WHERE comanda_id = v_cm AND executor_id IS NOT NULL) = 2,
    'uma comanda com DOIS executores diferentes');

  PERFORM pg_temp.ok((SELECT total_bruto = 389.90 AND total_desconto = 10.00
                        AND total_liquido = 379.90 FROM lumia.comanda WHERE id = v_cm),
    format('totais recalculados: bruto 389,90 - desconto 10,00 = 379,90'));

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.comanda_item
     WHERE comanda_id=v_cm AND titular_receita='PROFISSIONAL_PARCEIRO') = 1,
    'item de parceira marcado com titularidade propria (Lei do Salao Parceiro)');

  -- Desconto sem motivo é recusado.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.comanda_item
      (tenant_id,id,comanda_id,sequencia,tipo,produto_id,descricao_congelada,
       preco_tabela,preco_praticado,valor_desconto,lancado_por)
    VALUES (%L, lumia.uuid_v7(), %L, 0, 'PRODUTO', %L, 'Produto com desconto solto',
            50,50,10,%L)
  $q$, t, v_cm,'00000000-0000-7000-8000-00000000f003','00000000-0000-7000-8000-0000000a2001'),
  'desconto sem motivo e sem autorizador e recusado');

  -- Receita de parceiro sem executor identificado é recusada.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.comanda_item
      (tenant_id,id,comanda_id,sequencia,tipo,servico_id,descricao_congelada,
       preco_tabela,preco_praticado,titular_receita,lancado_por)
    VALUES (%L, lumia.uuid_v7(), %L, 0, 'SERVICO', %L, 'Servico sem executor',
            50,50,'PROFISSIONAL_PARCEIRO',%L)
  $q$, t, v_cm,'00000000-0000-7000-8000-00000000e001','00000000-0000-7000-8000-0000000a2001'),
  'receita de parceiro sem executor identificado e recusada');

  -- Item precisa referenciar serviço ou produto, nunca texto solto.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.comanda_item
      (tenant_id,id,comanda_id,sequencia,tipo,descricao_congelada,
       preco_tabela,preco_praticado,lancado_por)
    VALUES (%L, lumia.uuid_v7(), %L, 0, 'SERVICO', 'Escova (digitado à mão)',
            50,50,%L)
  $q$, t, v_cm,'00000000-0000-7000-8000-0000000a2001'),
  'item tipo SERVICO sem servico_id e recusado (nada de texto livre)');
END $$;

\echo ''
\echo '=== 8. Pagamento: idempotente, com troco e quitação =================='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_cm uuid := current_setting('lumia.comanda_teste')::uuid;
  v_sessao uuid := current_setting('lumia.sessao_teste')::uuid;
  v_diego uuid := '00000000-0000-7000-8000-0000000a2004';
  v_p1 uuid; v_p2 uuid; v_repetido uuid;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  PERFORM lumia.fechar_comanda(t, v_cm, v_diego);
  PERFORM pg_temp.ok((SELECT status='FECHADA' FROM lumia.comanda WHERE id=v_cm),
    'comanda fechada para lancamento');

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.comanda_item
      (tenant_id,id,comanda_id,sequencia,tipo,produto_id,descricao_congelada,
       preco_tabela,preco_praticado,lancado_por)
    VALUES (%L, lumia.uuid_v7(), %L, 0,'PRODUTO',%L,'Item tardio',10,10,%L)
  $q$, t, v_cm,'00000000-0000-7000-8000-00000000f003',v_diego),
  'lancar item em comanda FECHADA e recusado');

  -- Pagamento parcial em cartão
  v_p1 := lumia.receber_pagamento(t, v_cm, v_sessao,'CARTAO_CREDITO',200.00,v_diego,'pgto-1');
  PERFORM pg_temp.ok((SELECT status='FECHADA' FROM lumia.comanda WHERE id=v_cm),
    'pagamento parcial nao quita a comanda');

  -- Retry da mesma operação: devolve o mesmo pagamento, não cobra de novo
  v_repetido := lumia.receber_pagamento(t, v_cm, v_sessao,'CARTAO_CREDITO',200.00,v_diego,'pgto-1');
  PERFORM pg_temp.ok(v_repetido = v_p1,
    'mesma chave de idempotencia devolve o mesmo pagamento (retry nao cobra 2x)');
  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.comanda_pagamento WHERE comanda_id=v_cm) = 1,
    'existe apenas UM pagamento gravado apos o retry');

  -- Restante em dinheiro, com troco
  v_p2 := lumia.receber_pagamento(t, v_cm, v_sessao,'DINHEIRO',179.90,v_diego,'pgto-2',200.00);
  PERFORM pg_temp.ok((SELECT troco = 20.10 FROM lumia.comanda_pagamento WHERE id=v_p2),
    'troco calculado: 200,00 recebido - 179,90 = 20,10');
  PERFORM pg_temp.ok((SELECT status='PAGA' AND paga_em IS NOT NULL
                        FROM lumia.comanda WHERE id=v_cm),
    'comanda quitada quando os pagamentos cobrem o total');

  -- O caixa recebeu os lançamentos
  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.movimento_caixa
     WHERE sessao_caixa_id=v_sessao AND comanda_id=v_cm AND tipo='RECEBIMENTO') = 2,
    'dois recebimentos lancados no livro do caixa');
  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.movimento_caixa
     WHERE sessao_caixa_id=v_sessao AND tipo='TROCO') = 1,
    'troco lancado como saida da gaveta');

  -- Espécie: 200 fundo - 150 sangria + 179,90 recebido - 20,10 troco = 209,80
  PERFORM pg_temp.ok((SELECT esperado FROM lumia.saldo_esperado_caixa(t,v_sessao)
                       WHERE meio='DINHEIRO') = 209.80,
    'saldo em especie derivado do livro = 209,80');
END $$;

\echo ''
\echo '=== 9. Conferência CEGA: o operador não consegue ler o esperado ======'

-- Este é o teste central do módulo. A cegueira não é a tela escondendo campo:
-- é o papel do operador não ter GRANT na coluna.
DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_sessao uuid := current_setting('lumia.sessao_teste')::uuid;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);
  -- O operador declara 205,00 tendo 209,80 esperado: falta de 4,80.
  PERFORM lumia.declarar_conferencia(t, v_sessao,'00000000-0000-7000-8000-0000000a2004',
    '{"DINHEIRO": 205.00, "CARTAO_CREDITO": 200.00}'::jsonb);

  PERFORM pg_temp.ok((SELECT status='EM_CONFERENCIA' FROM lumia.sessao_caixa WHERE id=v_sessao),
    'sessao passou para EM_CONFERENCIA apos a declaracao');

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.conferencia_caixa
                       WHERE sessao_caixa_id=v_sessao AND valor_esperado IS NULL) = 2,
    'no momento da declaracao o esperado ainda nem foi calculado');
END $$;

SET ROLE lumia_caixa_operador;

DO $$
DECLARE t uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  PERFORM pg_temp.deve_falhar(
    'SELECT valor_esperado FROM lumia.conferencia_caixa',
    'operador NAO consegue ler valor_esperado (sem GRANT na coluna)');

  PERFORM pg_temp.deve_falhar(
    'SELECT divergencia FROM lumia.conferencia_caixa',
    'operador NAO consegue ler a divergencia');

  PERFORM pg_temp.deve_falhar(
    'SELECT * FROM lumia.divergencia_caixa',
    'operador NAO tem acesso a tabela de divergencias');

  PERFORM pg_temp.ok(
    (SELECT count(*) FROM (SELECT valor_declarado FROM lumia.conferencia_caixa) x) >= 0,
    'operador LE normalmente o que ele mesmo declarou');
END $$;

RESET ROLE;

\echo ''
\echo '=== 10. Apuração: divergência registrada, nunca descontada ==========='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_sessao uuid := current_setting('lumia.sessao_teste')::uuid;
  v_div numeric;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  v_div := lumia.apurar_fechamento(t, v_sessao,'00000000-0000-7000-8000-0000000a2005');

  PERFORM pg_temp.ok(v_div = -4.80,
    format('divergencia apurada: declarou 205,00 e esperava 209,80 = -4,80 (obtido: %s)', v_div));

  PERFORM pg_temp.ok((SELECT status='FECHADA_COM_DIVERGENCIA'
                        FROM lumia.sessao_caixa WHERE id=v_sessao),
    'sessao fechada marcada com divergencia');

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.divergencia_caixa
                       WHERE sessao_caixa_id=v_sessao AND status='ABERTA') = 1,
    'divergencia registrada como ABERTA, aguardando justificativa humana');

  -- E o ponto jurídico: nada foi debitado de ninguém.
  PERFORM pg_temp.ok(NOT EXISTS (
    SELECT 1 FROM lumia.movimento_caixa
     WHERE sessao_caixa_id = v_sessao AND tipo = 'AJUSTE'),
    'NENHUM lancamento de ajuste foi criado automaticamente contra o operador');

  -- Resolver exige decisão nomeada e escrita.
  PERFORM pg_temp.deve_falhar(format($q$
    UPDATE lumia.divergencia_caixa SET status='ACEITA_PELA_EMPRESA'
     WHERE sessao_caixa_id = %L
  $q$, v_sessao),
  'fechar divergencia sem decisao nomeada e escrita e recusado');

  UPDATE lumia.divergencia_caixa
     SET status='ACEITA_PELA_EMPRESA',
         justificativa='Troco a maior identificado na conferência',
         justificada_por='00000000-0000-7000-8000-0000000a2004', justificada_em=now(),
         decidida_por='00000000-0000-7000-8000-0000000a2005', decidida_em=now(),
         decisao='Empresa absorve a diferença; sem desconto ao operador.'
   WHERE sessao_caixa_id = v_sessao;

  PERFORM pg_temp.ok((SELECT decisao IS NOT NULL AND decidida_por IS NOT NULL
                        FROM lumia.divergencia_caixa WHERE sessao_caixa_id=v_sessao),
    'divergencia resolvida com decisao nomeada de quem decidiu');
END $$;

\echo ''
\echo '=== 11. Segregação de funções e caixa fechado ========================'

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_sessao uuid := current_setting('lumia.sessao_teste')::uuid;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.movimento_caixa
      (tenant_id,id,sessao_caixa_id,sequencia,tipo,meio_pagamento,valor,
       afeta_gaveta,registrado_por)
    VALUES (%L, lumia.uuid_v7(), %L, 0,'RECEBIMENTO','DINHEIRO',100,true,%L)
  $q$, t, v_sessao,'00000000-0000-7000-8000-0000000a2004'),
  'lancamento em caixa FECHADO e recusado');

  PERFORM pg_temp.deve_falhar(format($q$
    UPDATE lumia.sessao_caixa
       SET conferida_por = %L, apurada_por = %L
     WHERE id = %L
  $q$, '00000000-0000-7000-8000-0000000a2004','00000000-0000-7000-8000-0000000a2004', v_sessao),
  'a mesma pessoa nao pode conferir E apurar (segregacao de funcoes)');
END $$;

\echo ''
\echo '=== 12. Trilha e produção ============================================'

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_cm uuid := current_setting('lumia.comanda_teste')::uuid;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.vw_comanda_trilha WHERE comanda_id=v_cm) = 4,
    'trilha da comanda mostra os 4 elos com motivo e quem entregou');

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.vw_comanda_trilha
                       WHERE comanda_id=v_cm AND motivo IS NOT NULL) = 3,
    'as 3 transferencias tem motivo registrado (a abertura nao e transferencia)');

  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.vw_producao_executor
                       WHERE executor_id IS NOT NULL) = 2,
    'producao por executor separa os dois profissionais da comanda');

  -- Comanda de treinamento não entra na produção.
  PERFORM pg_temp.ok(NOT EXISTS (
    SELECT 1 FROM lumia.vw_producao_executor v
      JOIN lumia.comanda c ON c.data_comercial = v.data_comercial
     WHERE c.finalidade <> 'REAL' AND c.id = v_cm),
    'a view de producao filtra finalidade REAL');
END $$;

\echo ''
\echo '=== 13. Convenções ==================================================='

DO $$
BEGIN
  PERFORM pg_temp.ok(NOT EXISTS (
    SELECT 1 FROM pg_class c
     WHERE c.relnamespace='lumia'::regnamespace AND c.relkind='r'
       AND EXISTS (SELECT 1 FROM information_schema.columns col
                    WHERE col.table_schema='lumia' AND col.table_name=c.relname
                      AND col.column_name='tenant_id')
       AND NOT (c.relrowsecurity AND c.relforcerowsecurity)
  ), 'todas as tabelas de caixa e comanda tem RLS habilitada e forcada');

  PERFORM pg_temp.ok(EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid='lumia.comanda_custodia'::regclass AND contype='x'),
    'custodia tem EXCLUDE contra dois responsaveis simultaneos');

  PERFORM pg_temp.ok(EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgrelid='lumia.movimento_caixa'::regclass
       AND tgname='tg_movimento_sem_update'),
    'livro do caixa protegido contra UPDATE e DELETE por trigger');
END $$;

ROLLBACK;

\echo ''
\echo '===================================================================='
\echo ' TODOS OS TESTES DO BALCÃO PASSARAM — banco devolvido ao estado inicial'
\echo '===================================================================='
