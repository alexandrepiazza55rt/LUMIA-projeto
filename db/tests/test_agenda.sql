-- =============================================================================
-- LUMIA · Testes da agenda
-- =============================================================================
-- Prova que o double-booking é impossível POR CONSTRAINT, não por disciplina —
-- e que a pausa química libera o profissional sem liberar a cadeira.
--
-- Pré-requisito: migrations 0001–0007 + seed_demo.sql.
-- A suíte termina em ROLLBACK: idempotente, não deixa resíduo.
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
    RAISE NOTICE '  OK   % (bloqueado: %)', p_nome, left(SQLERRM, 55); RETURN;
  END;
  RAISE EXCEPTION 'FALHOU: % — deveria ter sido bloqueado e passou', p_nome;
END; $$;

-- ---------------------------------------------------------------- cenário --
-- Studio Aurora Pinheiros (America/Sao_Paulo), com:
--   • 2 profissionais: Ana e Bruno
--   • Cadeira 1 (capacidade 1) e Sala Colorimetria (capacidade 2)
--   • Coloração raiz: 40 ativos + 30 de pausa química + 20 de finalização
--     + 10 de higienização; libera o profissional na pausa, não a cadeira.
\echo ''
\echo '=== preparação do cenário ==========================================='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  INSERT INTO lumia.profissional (tenant_id, id, numero, nome, vinculo, nivel) VALUES
    (t,'00000000-0000-7000-8000-0000000a1001', 1, 'Ana',   'CLT',      4),
    (t,'00000000-0000-7000-8000-0000000a1002', 2, 'Bruno', 'PARCEIRO', 3);

  INSERT INTO lumia.cliente (tenant_id, id, numero, nome) VALUES
    (t,'00000000-0000-7000-8000-0000000c1001', 1, 'Marina'),
    (t,'00000000-0000-7000-8000-0000000c1002', 2, 'Júlia'),
    (t,'00000000-0000-7000-8000-0000000c1003', 3, 'Paula');

  -- recursos: 2 profissionais + cadeira (cap 1) + sala (cap 2)
  INSERT INTO lumia.recurso_agendavel
    (tenant_id, id, estabelecimento_id, tipo, profissional_id, unidade_id, capacidade) VALUES
    (t,'00000000-0000-7000-8000-0000000d1001','00000000-0000-7000-8000-00000000b003','PROFISSIONAL','00000000-0000-7000-8000-0000000a1001',NULL,1),
    (t,'00000000-0000-7000-8000-0000000d1002','00000000-0000-7000-8000-00000000b003','PROFISSIONAL','00000000-0000-7000-8000-0000000a1002',NULL,1),
    (t,'00000000-0000-7000-8000-0000000d1003','00000000-0000-7000-8000-00000000b003','UNIDADE',NULL,'00000000-0000-7000-8000-00000000b006',1),
    (t,'00000000-0000-7000-8000-0000000d1004','00000000-0000-7000-8000-00000000b003','UNIDADE',NULL,'00000000-0000-7000-8000-00000000b005',2);

  PERFORM pg_temp.ok(true, 'cenario montado: 2 profissionais, cadeira (cap 1), sala (cap 2)');
END $$;

\echo ''
\echo '=== 1. Pausa química: profissional livre, cadeira ocupada ==========='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_ag uuid := '00000000-0000-7000-8000-0000000e1001';
  v_it uuid := '00000000-0000-7000-8000-0000000f1001';
  v_ini timestamptz := '2026-03-10 13:00:00+00';  -- 10h em SP
  v_n integer;
  v_prof_janelas integer;
  v_local_janelas integer;
  v_prof_total interval;
  v_local_total interval;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  INSERT INTO lumia.agendamento
    (tenant_id, id, estabelecimento_id, cliente_id, numero, inicio_previsto, fim_previsto, data_comercial)
  VALUES (t, v_ag, '00000000-0000-7000-8000-00000000b003',
          '00000000-0000-7000-8000-0000000c1001', 1, v_ini, v_ini + interval '100 min', '2000-01-01');

  INSERT INTO lumia.agendamento_item
    (tenant_id, id, agendamento_id, servico_id, variante_id, profissional_id, inicio_previsto, fim_previsto)
  VALUES (t, v_it, v_ag, '00000000-0000-7000-8000-00000000e001',
          '00000000-0000-7000-8000-00000000e101', '00000000-0000-7000-8000-0000000a1001',
          v_ini, v_ini + interval '100 min');

  -- cadeira como local
  v_n := lumia.reservar_item(t, v_it, '00000000-0000-7000-8000-0000000d1003');

  PERFORM pg_temp.ok(v_n = 3,
    format('item gerou 3 reservas: 2 do profissional + 1 da cadeira (obtido: %s)', v_n));

  SELECT count(*), sum(upper(periodo)-lower(periodo)) INTO v_prof_janelas, v_prof_total
    FROM lumia.reserva WHERE agendamento_item_id = v_it AND papel = 'EXECUTOR';
  SELECT count(*), sum(upper(periodo)-lower(periodo)) INTO v_local_janelas, v_local_total
    FROM lumia.reserva WHERE agendamento_item_id = v_it AND papel = 'LOCAL';

  PERFORM pg_temp.ok(v_prof_janelas = 2,
    'profissional tem DUAS janelas (antes e depois da pausa quimica)');
  PERFORM pg_temp.ok(v_local_janelas = 1,
    'cadeira tem UMA janela contigua (segue ocupada durante a pausa)');
  PERFORM pg_temp.ok(v_prof_total = interval '70 min',
    format('profissional ocupado 70 min = 40 ativos + 20 final + 10 higien. (obtido: %s)', v_prof_total));
  PERFORM pg_temp.ok(v_local_total = interval '100 min',
    format('cadeira ocupada 100 min = 70 + 30 de pausa (obtido: %s)', v_local_total));
END $$;

\echo ''
\echo '=== 2. A pausa é aproveitável: outro cliente entra na janela ========'

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_ag uuid := '00000000-0000-7000-8000-0000000e1002';
  v_it uuid := '00000000-0000-7000-8000-0000000f1002';
  -- A pausa da Marina vai das 13:40 às 14:10 UTC. Agendamos a Júlia às 13:40
  -- com a MESMA Ana, em OUTRA cadeira (a sala, capacidade 2).
  v_ini timestamptz := '2026-03-10 13:40:00+00';
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  INSERT INTO lumia.agendamento
    (tenant_id, id, estabelecimento_id, cliente_id, numero, inicio_previsto, fim_previsto, data_comercial)
  VALUES (t, v_ag, '00000000-0000-7000-8000-00000000b003',
          '00000000-0000-7000-8000-0000000c1002', 2, v_ini, v_ini + interval '30 min', '2000-01-01');

  -- Serviço curto sem pausa: depilação a laser (20 ativos + 10 higienização).
  INSERT INTO lumia.agendamento_item
    (tenant_id, id, agendamento_id, servico_id, profissional_id, inicio_previsto, fim_previsto)
  VALUES (t, v_it, v_ag, '00000000-0000-7000-8000-00000000e002',
          '00000000-0000-7000-8000-0000000a1001', v_ini, v_ini + interval '30 min');

  PERFORM lumia.reservar_item(t, v_it, '00000000-0000-7000-8000-0000000d1004');

  PERFORM pg_temp.ok(true,
    'a MESMA profissional atende outra cliente durante a pausa quimica');

  -- E o total de reservas ativas dela agora é 3 (2 da Marina + 1 da Júlia)
  PERFORM pg_temp.ok((
    SELECT count(*) FROM lumia.reserva
     WHERE recurso_id = '00000000-0000-7000-8000-0000000d1001' AND ativa) = 3,
    'Ana tem 3 reservas ativas sem nenhuma sobreposicao');
END $$;

\echo ''
\echo '=== 3. Double-booking é impossível =================================='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  -- Mesma cadeira, horário sobreposto ao da Marina (13:00–14:40).
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
    VALUES (%L, lumia.uuid_v7(), %L, 1,
            tstzrange('2026-03-10 14:00:00+00','2026-03-10 15:00:00+00','[)'),
            'LOCAL', %L)
  $q$, t, '00000000-0000-7000-8000-0000000d1003', '00000000-0000-7000-8000-0000000f1002'),
  'segunda reserva na MESMA cadeira em horario sobreposto');

  -- Mesma profissional, sobrepondo a primeira janela dela (13:00–13:40).
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
    VALUES (%L, lumia.uuid_v7(), %L, 1,
            tstzrange('2026-03-10 13:20:00+00','2026-03-10 13:50:00+00','[)'),
            'EXECUTOR', %L)
  $q$, t, '00000000-0000-7000-8000-0000000d1001', '00000000-0000-7000-8000-0000000f1002'),
  'mesma profissional em dois atendimentos sobrepostos');

  -- Encostar sem sobrepor é permitido: [)  fecha à esquerda, abre à direita.
  PERFORM pg_temp.ok((
    SELECT lumia.slot_livre(t, '00000000-0000-7000-8000-0000000d1003',
      tstzrange('2026-03-10 14:40:00+00','2026-03-10 15:40:00+00','[)')) = 1),
    'horario imediatamente APOS o anterior fica livre (intervalo semiaberto)');
END $$;

\echo ''
\echo '=== 4. Capacidade da sala: 2 sim, 3 não ============================='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_p tstzrange := tstzrange('2026-03-11 17:00:00+00','2026-03-11 18:00:00+00','[)');
  v_s1 smallint; v_s2 smallint; v_s3 smallint;
  -- Itens dedicados a este teste: reaproveitar itens de outros blocos
  -- contaminaria a contagem de reservas do teste de cancelamento.
  v_ag uuid := '00000000-0000-7000-8000-0000000e1003';
  v_i1 uuid := '00000000-0000-7000-8000-0000000f1003';
  v_i2 uuid := '00000000-0000-7000-8000-0000000f1004';
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  INSERT INTO lumia.agendamento
    (tenant_id, id, estabelecimento_id, cliente_id, numero, inicio_previsto, fim_previsto, data_comercial)
  VALUES (t, v_ag, '00000000-0000-7000-8000-00000000b003',
          '00000000-0000-7000-8000-0000000c1003', 3, lower(v_p), upper(v_p), '2000-01-01');
  INSERT INTO lumia.agendamento_item
    (tenant_id, id, agendamento_id, servico_id, inicio_previsto, fim_previsto) VALUES
    (t, v_i1, v_ag, '00000000-0000-7000-8000-00000000e002', lower(v_p), upper(v_p)),
    (t, v_i2, v_ag, '00000000-0000-7000-8000-00000000e002', lower(v_p), upper(v_p));

  v_s1 := lumia.slot_livre(t,'00000000-0000-7000-8000-0000000d1004', v_p);
  INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
  VALUES (t, lumia.uuid_v7(), '00000000-0000-7000-8000-0000000d1004', v_s1, v_p, 'LOCAL', v_i1);

  v_s2 := lumia.slot_livre(t,'00000000-0000-7000-8000-0000000d1004', v_p);
  INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
  VALUES (t, lumia.uuid_v7(), '00000000-0000-7000-8000-0000000d1004', v_s2, v_p, 'LOCAL', v_i2);

  PERFORM pg_temp.ok(v_s1 = 1 AND v_s2 = 2,
    format('sala de capacidade 2 aceita dois atendimentos simultaneos (slots %s e %s)', v_s1, v_s2));

  v_s3 := lumia.slot_livre(t,'00000000-0000-7000-8000-0000000d1004', v_p);
  PERFORM pg_temp.ok(v_s3 IS NULL, 'nao ha terceiro slot livre na sala');

  -- Forçar o slot 3 é recusado pelo trigger de capacidade...
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
    VALUES (%L, lumia.uuid_v7(), %L, 3, %L, 'LOCAL', %L)
  $q$, t, '00000000-0000-7000-8000-0000000d1004', v_p, v_i1),
  'slot 3 excede a capacidade da sala');

  -- ...e reusar o slot 1 é recusado pelo EXCLUDE.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
    VALUES (%L, lumia.uuid_v7(), %L, 1, %L, 'LOCAL', %L)
  $q$, t, '00000000-0000-7000-8000-0000000d1004', v_p, v_i1),
  'reusar o slot 1 ocupado e recusado pelo EXCLUDE');
END $$;

\echo ''
\echo '=== 5. Cancelamento libera o horário sem apagar histórico ==========='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_ag uuid := '00000000-0000-7000-8000-0000000e1001';
  v_liberadas integer;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  v_liberadas := lumia.cancelar_agendamento(t, v_ag, 'Cliente remarcou');
  PERFORM pg_temp.ok(v_liberadas = 3,
    format('cancelamento liberou as 3 reservas do agendamento (obtido: %s)', v_liberadas));

  PERFORM pg_temp.ok((
    SELECT count(*) FROM lumia.reserva WHERE agendamento_item_id = '00000000-0000-7000-8000-0000000f1001') = 3,
    'as linhas de reserva permanecem: ocupacao historica continua auditavel');

  -- Agora a cadeira está livre no horário que estava ocupado.
  PERFORM pg_temp.ok((
    SELECT lumia.slot_livre(t, '00000000-0000-7000-8000-0000000d1003',
      tstzrange('2026-03-10 13:00:00+00','2026-03-10 14:40:00+00','[)')) = 1),
    'a cadeira voltou a ficar livre no horario cancelado');

  PERFORM pg_temp.ok((
    SELECT status = 'CANCELADO' AND cancelado_em IS NOT NULL
      FROM lumia.agendamento WHERE id = v_ag),
    'agendamento marcado como CANCELADO com data');
END $$;

\echo ''
\echo '=== 6. Bloqueio de agenda ocupa recurso como um atendimento ========='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_bl uuid := '00000000-0000-7000-8000-0000000b1001';
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  INSERT INTO lumia.bloqueio_agenda (tenant_id, id, estabelecimento_id, tipo, descricao, inicio, fim)
  VALUES (t, v_bl, '00000000-0000-7000-8000-00000000b003', 'ALMOCO', 'Almoço da Ana',
          '2026-03-12 15:00:00+00', '2026-03-12 16:00:00+00');

  INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, bloqueio_id)
  VALUES (t, lumia.uuid_v7(), '00000000-0000-7000-8000-0000000d1001', 1,
          tstzrange('2026-03-12 15:00:00+00','2026-03-12 16:00:00+00','[)'), 'BLOQUEIO', v_bl);

  PERFORM pg_temp.ok((
    SELECT lumia.slot_livre(t, '00000000-0000-7000-8000-0000000d1001',
      tstzrange('2026-03-12 15:30:00+00','2026-03-12 16:30:00+00','[)')) IS NULL),
    'almoco bloqueia o horario da profissional');

  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
    VALUES (%L, lumia.uuid_v7(), %L, 1,
            tstzrange('2026-03-12 15:30:00+00','2026-03-12 16:30:00+00','[)'),
            'EXECUTOR', %L)
  $q$, t, '00000000-0000-7000-8000-0000000d1001', '00000000-0000-7000-8000-0000000f1002'),
  'agendar em cima do almoco e recusado pela mesma constraint');

  -- Reserva de bloqueio precisa de bloqueio_id, nunca de item.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
    VALUES (%L, lumia.uuid_v7(), %L, 1,
            tstzrange('2026-04-01 10:00:00+00','2026-04-01 11:00:00+00','[)'),
            'BLOQUEIO', %L)
  $q$, t, '00000000-0000-7000-8000-0000000d1001', '00000000-0000-7000-8000-0000000f1002'),
  'reserva com papel BLOQUEIO exige bloqueio_id (XOR de origem)');
END $$;

\echo ''
\echo '=== 7. Data comercial no fuso do estabelecimento ===================='

-- O ponto que só aparece em operação nacional: 03:30 UTC de 11/mar é
-- 00:30 de 11/mar em São Paulo (UTC-3) mas ainda 23:30 de 10/mar em Manaus
-- (UTC-4). O mesmo instante cai em DIAS COMERCIAIS DIFERENTES.
DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
  v_instante timestamptz := '2026-03-11 03:30:00+00';
  v_sp date; v_am date;
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  INSERT INTO lumia.agendamento
    (tenant_id, id, estabelecimento_id, cliente_id, numero, inicio_previsto, fim_previsto, data_comercial)
  VALUES (t,'00000000-0000-7000-8000-0000000e1010','00000000-0000-7000-8000-00000000b003',
          '00000000-0000-7000-8000-0000000c1003', 10, v_instante, v_instante + interval '30 min','2000-01-01'),
         (t,'00000000-0000-7000-8000-0000000e1011','00000000-0000-7000-8000-00000000b004',
          '00000000-0000-7000-8000-0000000c1003', 11, v_instante, v_instante + interval '30 min','2000-01-01');

  SELECT data_comercial INTO v_sp FROM lumia.agendamento WHERE id='00000000-0000-7000-8000-0000000e1010';
  SELECT data_comercial INTO v_am FROM lumia.agendamento WHERE id='00000000-0000-7000-8000-0000000e1011';

  PERFORM pg_temp.ok(v_sp = date '2026-03-11',
    format('Sao Paulo (UTC-3): 03:30 UTC cai em 11/mar (obtido: %s)', v_sp));
  PERFORM pg_temp.ok(v_am = date '2026-03-10',
    format('Manaus (UTC-4): o MESMO instante cai em 10/mar (obtido: %s)', v_am));
  PERFORM pg_temp.ok(v_sp <> v_am,
    'o mesmo instante UTC cai em dias comerciais diferentes — por isso o fuso e por estabelecimento');
END $$;

\echo ''
\echo '=== 8. Integridade estrutural da agenda ============================='

DO $$
DECLARE
  t uuid := '00000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM set_config('lumia.tenant_id', t::text, true);

  -- Nenhum profissional em dois lugares ao mesmo tempo.
  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.vw_conflito_profissional) = 0,
    'vw_conflito_profissional esta vazia (ninguem em dois lugares ao mesmo tempo)');

  -- Recurso de profissional não pode ter capacidade > 1.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.recurso_agendavel
      (tenant_id, id, estabelecimento_id, tipo, profissional_id, capacidade)
    VALUES (%L, lumia.uuid_v7(), %L, 'PROFISSIONAL', %L, 2)
  $q$, t, '00000000-0000-7000-8000-00000000b004', '00000000-0000-7000-8000-0000000a1002'),
  'profissional com capacidade 2 e rejeitado');

  -- Recurso precisa ser profissional OU unidade, nunca ambos.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.recurso_agendavel
      (tenant_id, id, estabelecimento_id, tipo, profissional_id, unidade_id)
    VALUES (%L, lumia.uuid_v7(), %L, 'UNIDADE', %L, %L)
  $q$, t, '00000000-0000-7000-8000-00000000b003',
       '00000000-0000-7000-8000-0000000a1002','00000000-0000-7000-8000-00000000b007'),
  'recurso com profissional E unidade e rejeitado');

  -- Período invertido.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
    VALUES (%L, lumia.uuid_v7(), %L, 1,
            tstzrange('2026-05-01 12:00:00+00','2026-05-01 11:00:00+00','[)'),
            'LOCAL', %L)
  $q$, t, '00000000-0000-7000-8000-0000000d1003', '00000000-0000-7000-8000-0000000f1002'),
  'periodo invertido e rejeitado');

  -- Período sem fim (reserva infinita) é rejeitado.
  PERFORM pg_temp.deve_falhar(format($q$
    INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
    VALUES (%L, lumia.uuid_v7(), %L, 1,
            tstzrange('2026-05-01 12:00:00+00', NULL, '[)'), 'LOCAL', %L)
  $q$, t, '00000000-0000-7000-8000-0000000d1003', '00000000-0000-7000-8000-0000000f1002'),
  'reserva sem fim e rejeitada (ocuparia o recurso para sempre)');

  -- Toda reserva ativa pertence a um recurso ativo.
  PERFORM pg_temp.ok(NOT EXISTS (
    SELECT 1 FROM lumia.reserva r
      JOIN lumia.recurso_agendavel ra ON (ra.tenant_id,ra.id)=(r.tenant_id,r.recurso_id)
     WHERE r.ativa AND NOT ra.ativo),
    'nenhuma reserva ativa aponta para recurso inativo');
END $$;

\echo ''
\echo '=== 9. Isolamento entre tenants na agenda ==========================='

SET ROLE lumia_app;

DO $$
DECLARE
  t1 uuid := '00000000-0000-7000-8000-00000000a001';
  t2 uuid := '00000000-0000-7000-8000-00000000a002';
BEGIN
  PERFORM set_config('lumia.tenant_id', t1::text, true);
  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.reserva) > 0, 'tenant 1 ve suas reservas');

  PERFORM set_config('lumia.tenant_id', t2::text, true);
  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.reserva) = 0,
    'tenant 2 nao ve nenhuma reserva do tenant 1');
  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.agendamento) = 0,
    'tenant 2 nao ve nenhum agendamento do tenant 1');

  PERFORM set_config('lumia.tenant_id', '', true);
  PERFORM pg_temp.ok((SELECT count(*) FROM lumia.reserva) = 0,
    'sem contexto de tenant, zero reservas visiveis');
END $$;

RESET ROLE;

\echo ''
\echo '=== 10. Convenções aplicadas às tabelas novas ======================='

DO $$
BEGIN
  PERFORM pg_temp.ok(NOT EXISTS (
    SELECT 1 FROM pg_class c
     WHERE c.relnamespace='lumia'::regnamespace AND c.relkind='r'
       AND EXISTS (SELECT 1 FROM information_schema.columns col
                    WHERE col.table_schema='lumia' AND col.table_name=c.relname
                      AND col.column_name='tenant_id')
       AND NOT (c.relrowsecurity AND c.relforcerowsecurity)
  ), 'todas as tabelas da agenda tem RLS habilitada e forcada');

  PERFORM pg_temp.ok(EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid='lumia.reserva'::regclass AND contype='x'
       AND conname='rs_sem_sobreposicao'),
    'a constraint de nao-sobreposicao existe e e do tipo EXCLUDE');
END $$;

ROLLBACK;

\echo ''
\echo '===================================================================='
\echo ' TODOS OS TESTES DA AGENDA PASSARAM — banco devolvido ao estado inicial'
\echo '===================================================================='
