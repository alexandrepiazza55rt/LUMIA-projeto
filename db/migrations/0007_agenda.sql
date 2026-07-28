-- =============================================================================
-- LUMIA · 0007 — Minha Agenda: reservas com garantia no banco
-- =============================================================================
-- Implementa a decisão irreversível nº 8:
--   "Disponibilidade multi-recurso garantida pelo banco, não por lock em Redis."
--
-- A ideia central é simples e é o que torna o double-booking impossível:
-- em vez de "um agendamento tem um horário", modelamos RESERVAS — uma linha por
-- (recurso, intervalo de tempo). Um único EXCLUDE USING gist sobre
-- (tenant_id, recurso, slot, período) faz o PostgreSQL recusar qualquer
-- sobreposição, sob qualquer concorrência, sem lock distribuído e sem
-- cooperação da aplicação.
--
-- Disso decorre de graça a regra mais específica do setor: durante a pausa
-- química o profissional está livre mas a cadeira não. Basta que o profissional
-- gere DUAS reservas (antes e depois da pausa) enquanto a cadeira gera UMA
-- contígua. A não-sobreposição continua sendo a mesma constraint.
--
-- Este arquivo cria também as versões mínimas de `profissional` e `cliente`
-- exigidas pela agenda. Os módulos Minha Equipe e Meus Clientes vão ESTENDER
-- essas tabelas — não recriá-las.
-- =============================================================================

BEGIN;

-- =============================================================================
-- PARTE 1 — Entidades mínimas exigidas pela agenda
-- =============================================================================

CREATE TYPE lumia.vinculo_profissional AS ENUM (
  'CLT', 'PARCEIRO', 'PRESTADOR', 'ESTAGIARIO', 'SOCIO'
);

CREATE TABLE lumia.profissional (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  numero          integer NOT NULL,
  nome            text NOT NULL,
  nome_exibicao   text,
  vinculo         lumia.vinculo_profissional NOT NULL,
  nivel           smallint NOT NULL DEFAULT 1,
  -- Um mesmo CPF pode atuar em vários tenants (profissional que trabalha em
  -- dois salões). Por isso a unicidade é POR TENANT, nunca global: não existe
  -- chave global de pessoa atravessando a fronteira de controladoria.
  cpf             char(11),
  ativo           boolean NOT NULL DEFAULT true,
  sistema_origem  text,
  id_externo      text,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now(),
  removido_em     timestamptz,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT prof_nivel_faixa CHECK (nivel BETWEEN 1 AND 5),
  CONSTRAINT prof_cpf_digitos CHECK (cpf IS NULL OR cpf ~ '^[0-9]{11}$'),
  CONSTRAINT prof_importacao_completa CHECK ((sistema_origem IS NULL) = (id_externo IS NULL))
);
CREATE UNIQUE INDEX ux_prof_numero ON lumia.profissional (tenant_id, numero);
CREATE UNIQUE INDEX ux_prof_cpf ON lumia.profissional (tenant_id, cpf)
  WHERE cpf IS NOT NULL AND removido_em IS NULL;
CREATE INDEX ix_prof_sync ON lumia.profissional (tenant_id, atualizado_em);
SELECT lumia.aplicar_rls('lumia.profissional');

COMMENT ON TABLE lumia.profissional IS
  'Versão mínima exigida pela agenda. Minha Equipe estende com jornada, '
  'comissão, documentos e desenvolvimento. O CPF é único POR TENANT: o mesmo '
  'profissional atuando em dois salões são dois registros, sob controladores '
  'distintos.';

CREATE TABLE lumia.profissional_habilidade (
  tenant_id      uuid NOT NULL,
  id             uuid NOT NULL,
  profissional_id uuid NOT NULL,
  habilidade_id  uuid NOT NULL,
  nivel          smallint NOT NULL DEFAULT 1,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_ph_prof FOREIGN KEY (tenant_id, profissional_id)
    REFERENCES lumia.profissional (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_ph_hab FOREIGN KEY (tenant_id, habilidade_id)
    REFERENCES lumia.habilidade (tenant_id, id),
  CONSTRAINT ph_nivel_faixa CHECK (nivel BETWEEN 1 AND 5)
);
CREATE UNIQUE INDEX ux_ph ON lumia.profissional_habilidade (tenant_id, profissional_id, habilidade_id);
SELECT lumia.aplicar_rls('lumia.profissional_habilidade');

CREATE TABLE lumia.cliente (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  numero          integer NOT NULL,
  nome            text NOT NULL,
  telefone_e164   text,
  email           text,
  ativo           boolean NOT NULL DEFAULT true,
  sistema_origem  text,
  id_externo      text,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now(),
  removido_em     timestamptz,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT cli_telefone_e164 CHECK (telefone_e164 IS NULL OR telefone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  CONSTRAINT cli_importacao_completa CHECK ((sistema_origem IS NULL) = (id_externo IS NULL))
);
CREATE UNIQUE INDEX ux_cli_numero ON lumia.cliente (tenant_id, numero);
CREATE INDEX ix_cli_sync ON lumia.cliente (tenant_id, atualizado_em);
CREATE INDEX ix_cli_telefone ON lumia.cliente (tenant_id, telefone_e164) WHERE telefone_e164 IS NOT NULL;
SELECT lumia.aplicar_rls('lumia.cliente');

COMMENT ON TABLE lumia.cliente IS
  'Versão mínima exigida pela agenda. Meus Clientes estende com consentimento '
  'LGPD, segmentação, fidelização e inteligência.';

-- =============================================================================
-- PARTE 2 — Recurso agendável: unifica profissional e unidade operacional
-- =============================================================================
-- Um ÚNICO tipo de recurso permite um ÚNICO EXCLUDE cobrir profissional, sala,
-- cadeira, maca e equipamento. Sem essa unificação seriam constraints
-- separadas, e a garantia deixaria de ser uniforme.

CREATE TYPE lumia.tipo_recurso AS ENUM ('PROFISSIONAL', 'UNIDADE');

CREATE TABLE lumia.recurso_agendavel (
  tenant_id          uuid NOT NULL REFERENCES lumia.tenant(id),
  id                 uuid NOT NULL,
  estabelecimento_id uuid NOT NULL,
  tipo               lumia.tipo_recurso NOT NULL,
  profissional_id    uuid,
  unidade_id         uuid,
  -- Capacidade simultânea. Uma sala para 2 pessoas tem 2 slots; o EXCLUDE atua
  -- por slot, então a 3ª reserva no mesmo horário é recusada pelo banco.
  capacidade         smallint NOT NULL DEFAULT 1,
  ativo              boolean NOT NULL DEFAULT true,
  criado_em          timestamptz NOT NULL DEFAULT now(),
  atualizado_em      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_ra_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT fk_ra_prof FOREIGN KEY (tenant_id, profissional_id)
    REFERENCES lumia.profissional (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_ra_unidade FOREIGN KEY (tenant_id, unidade_id)
    REFERENCES lumia.unidade_operacional (tenant_id, no_org_id) ON DELETE CASCADE,
  CONSTRAINT ra_tipo_coerente CHECK (
    (tipo = 'PROFISSIONAL' AND profissional_id IS NOT NULL AND unidade_id IS NULL)
    OR (tipo = 'UNIDADE' AND unidade_id IS NOT NULL AND profissional_id IS NULL)
  ),
  CONSTRAINT ra_capacidade_positiva CHECK (capacidade > 0),
  -- Profissional tem capacidade 1 por definição: não existe atender duas
  -- pessoas ao mesmo tempo no mesmo minuto ativo.
  CONSTRAINT ra_profissional_capacidade_um CHECK (tipo <> 'PROFISSIONAL' OR capacidade = 1)
);

CREATE UNIQUE INDEX ux_ra_prof ON lumia.recurso_agendavel (tenant_id, profissional_id, estabelecimento_id)
  WHERE profissional_id IS NOT NULL;
CREATE UNIQUE INDEX ux_ra_unidade ON lumia.recurso_agendavel (tenant_id, unidade_id)
  WHERE unidade_id IS NOT NULL;
CREATE INDEX ix_ra_estab ON lumia.recurso_agendavel (tenant_id, estabelecimento_id, tipo) WHERE ativo;
SELECT lumia.aplicar_rls('lumia.recurso_agendavel');

COMMENT ON TABLE lumia.recurso_agendavel IS
  'Identidade única de tudo que pode ser reservado no tempo. Um profissional '
  'que atende em dois estabelecimentos tem um recurso em cada — o EXCLUDE por '
  'recurso impediria, corretamente, que ele estivesse nos dois ao mesmo tempo '
  'apenas se compartilhassem recurso; por isso a checagem de conflito entre '
  'estabelecimentos é feita por profissional (ver vw_conflito_profissional).';

-- =============================================================================
-- PARTE 3 — Agendamento
-- =============================================================================

CREATE TYPE lumia.status_agendamento AS ENUM (
  'AGENDADO', 'CONFIRMADO', 'EM_ATENDIMENTO', 'CONCLUIDO',
  'CANCELADO', 'NAO_COMPARECEU'
);

CREATE TYPE lumia.canal_origem AS ENUM (
  'BALCAO', 'TELEFONE', 'WHATSAPP', 'ONLINE', 'APP_CLIENTE', 'IMPORTACAO'
);

CREATE TABLE lumia.agendamento (
  tenant_id          uuid NOT NULL REFERENCES lumia.tenant(id),
  id                 uuid NOT NULL,
  estabelecimento_id uuid NOT NULL,
  cliente_id         uuid,
  numero             integer NOT NULL,
  status             lumia.status_agendamento NOT NULL DEFAULT 'AGENDADO',
  canal_origem       lumia.canal_origem NOT NULL DEFAULT 'BALCAO',
  -- occurred_at em UTC; business_date derivada do FUSO DO ESTABELECIMENTO.
  -- Sem isso, o fechamento de caixa da virada vaza para o dia seguinte — e em
  -- Manaus (UTC-4) o dia comercial fecha uma hora antes do de São Paulo.
  inicio_previsto    timestamptz NOT NULL,
  fim_previsto       timestamptz NOT NULL,
  data_comercial     date NOT NULL,
  confirmado_em      timestamptz,
  check_in_em        timestamptz,
  check_out_em       timestamptz,
  cancelado_em       timestamptz,
  motivo_cancelamento text,
  observacao         text,
  finalidade         lumia.finalidade_dado NOT NULL DEFAULT 'REAL',
  sistema_origem     text,
  id_externo         text,
  criado_em          timestamptz NOT NULL DEFAULT now(),
  atualizado_em      timestamptz NOT NULL DEFAULT now(),
  removido_em        timestamptz,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_ag_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT fk_ag_cliente FOREIGN KEY (tenant_id, cliente_id)
    REFERENCES lumia.cliente (tenant_id, id),
  CONSTRAINT ag_intervalo_valido CHECK (fim_previsto > inicio_previsto),
  CONSTRAINT ag_cancelado_tem_data CHECK (
    (status IN ('CANCELADO','NAO_COMPARECEU')) = (cancelado_em IS NOT NULL)
  ),
  CONSTRAINT ag_checkout_depois_checkin CHECK (
    check_out_em IS NULL OR (check_in_em IS NOT NULL AND check_out_em >= check_in_em)
  ),
  CONSTRAINT ag_importacao_completa CHECK ((sistema_origem IS NULL) = (id_externo IS NULL))
);

CREATE UNIQUE INDEX ux_ag_numero ON lumia.agendamento (tenant_id, numero);
CREATE INDEX ix_ag_dia ON lumia.agendamento (tenant_id, estabelecimento_id, data_comercial)
  WHERE removido_em IS NULL;
CREATE INDEX ix_ag_cliente ON lumia.agendamento (tenant_id, cliente_id, inicio_previsto DESC);
CREATE INDEX ix_ag_status ON lumia.agendamento (tenant_id, status, inicio_previsto);
CREATE INDEX ix_ag_sync ON lumia.agendamento (tenant_id, atualizado_em);
CREATE UNIQUE INDEX ux_ag_externo ON lumia.agendamento (tenant_id, sistema_origem, id_externo)
  WHERE id_externo IS NOT NULL;
SELECT lumia.aplicar_rls('lumia.agendamento');

COMMENT ON COLUMN lumia.agendamento.data_comercial IS
  'Derivada de inicio_previsto convertido para o fuso do estabelecimento. '
  'Preenchida por trigger porque a conversão consulta o fuso em outra tabela e '
  'não pode ser coluna gerada (a expressão não seria IMMUTABLE).';

-- Deriva a data comercial no fuso do estabelecimento.
CREATE OR REPLACE FUNCTION lumia.tg_agendamento_data_comercial() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_fuso text;
BEGIN
  SELECT fuso INTO v_fuso FROM lumia.estabelecimento
   WHERE tenant_id = NEW.tenant_id AND no_org_id = NEW.estabelecimento_id;
  IF v_fuso IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento % não encontrado no tenant %',
      NEW.estabelecimento_id, NEW.tenant_id;
  END IF;
  NEW.data_comercial := (NEW.inicio_previsto AT TIME ZONE v_fuso)::date;
  NEW.atualizado_em  := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER tg_agendamento_data_comercial
  BEFORE INSERT OR UPDATE OF inicio_previsto, estabelecimento_id ON lumia.agendamento
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_agendamento_data_comercial();

-- -----------------------------------------------------------------------------
-- Item: um serviço dentro da visita. É o item que referencia servico_id — nunca
-- texto livre (decisão nº 2).
-- -----------------------------------------------------------------------------
CREATE TABLE lumia.agendamento_item (
  tenant_id       uuid NOT NULL,
  id              uuid NOT NULL,
  agendamento_id  uuid NOT NULL,
  servico_id      uuid NOT NULL,
  variante_id     uuid,
  profissional_id uuid,
  ordem           smallint NOT NULL DEFAULT 0,
  inicio_previsto timestamptz NOT NULL,
  fim_previsto    timestamptz NOT NULL,
  -- Preço de tabela congelado no momento do agendamento, para que a comanda
  -- saiba explicar a diferença se o preço mudar antes do atendimento.
  preco_estimado  lumia.valor_monetario,
  moeda           lumia.moeda NOT NULL DEFAULT 'BRL',
  criado_em       timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_ai_ag FOREIGN KEY (tenant_id, agendamento_id)
    REFERENCES lumia.agendamento (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_ai_servico FOREIGN KEY (tenant_id, servico_id)
    REFERENCES lumia.servico (tenant_id, id),
  CONSTRAINT fk_ai_variante FOREIGN KEY (tenant_id, variante_id)
    REFERENCES lumia.servico_variante (tenant_id, id),
  CONSTRAINT fk_ai_prof FOREIGN KEY (tenant_id, profissional_id)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT ai_intervalo_valido CHECK (fim_previsto > inicio_previsto)
);
CREATE INDEX ix_ai_ag ON lumia.agendamento_item (tenant_id, agendamento_id);
CREATE INDEX ix_ai_prof ON lumia.agendamento_item (tenant_id, profissional_id, inicio_previsto);
SELECT lumia.aplicar_rls('lumia.agendamento_item');

-- =============================================================================
-- PARTE 4 — Bloqueios de agenda
-- =============================================================================
-- Almoço, férias, manutenção de equipamento, reunião. Consome recurso no tempo
-- exatamente como um atendimento — e por isso gera reserva pela mesma via.

CREATE TYPE lumia.tipo_bloqueio AS ENUM (
  'ALMOCO', 'FOLGA', 'FERIAS', 'ATESTADO', 'MANUTENCAO',
  'REUNIAO', 'TREINAMENTO', 'FECHADO', 'OUTRO'
);

CREATE TABLE lumia.bloqueio_agenda (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  estabelecimento_id uuid NOT NULL,
  tipo            lumia.tipo_bloqueio NOT NULL,
  descricao       text,
  inicio          timestamptz NOT NULL,
  fim             timestamptz NOT NULL,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_bl_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT bl_intervalo_valido CHECK (fim > inicio)
);
CREATE INDEX ix_bl_estab ON lumia.bloqueio_agenda (tenant_id, estabelecimento_id, inicio);
SELECT lumia.aplicar_rls('lumia.bloqueio_agenda');

-- =============================================================================
-- PARTE 5 — A reserva: onde a garantia vive
-- =============================================================================

CREATE TYPE lumia.papel_reserva AS ENUM (
  'EXECUTOR',      -- o profissional que executa
  'LOCAL',         -- sala, cabine, cadeira, maca
  'EQUIPAMENTO',   -- aparelho exigido pelo serviço
  'BLOQUEIO'       -- indisponibilidade, sem atendimento
);

CREATE TABLE lumia.reserva (
  tenant_id            uuid NOT NULL REFERENCES lumia.tenant(id),
  id                   uuid NOT NULL,
  recurso_id           uuid NOT NULL,
  -- Slot dentro da capacidade do recurso. Sala com capacidade 2 aceita slot
  -- 1 e 2 no mesmo horário; a terceira reserva não tem slot livre.
  slot                 smallint NOT NULL DEFAULT 1,
  periodo              tstzrange NOT NULL,
  papel                lumia.papel_reserva NOT NULL,
  agendamento_item_id  uuid,
  bloqueio_id          uuid,
  -- Reserva inativa (agendamento cancelado) libera o horário sem apagar a
  -- linha: o histórico de ocupação continua auditável.
  ativa                boolean NOT NULL DEFAULT true,
  criado_em            timestamptz NOT NULL DEFAULT now(),
  atualizado_em        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_rs_recurso FOREIGN KEY (tenant_id, recurso_id)
    REFERENCES lumia.recurso_agendavel (tenant_id, id),
  CONSTRAINT fk_rs_item FOREIGN KEY (tenant_id, agendamento_item_id)
    REFERENCES lumia.agendamento_item (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_rs_bloqueio FOREIGN KEY (tenant_id, bloqueio_id)
    REFERENCES lumia.bloqueio_agenda (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT rs_origem_xor CHECK (
    (agendamento_item_id IS NOT NULL AND bloqueio_id IS NULL AND papel <> 'BLOQUEIO')
    OR (agendamento_item_id IS NULL AND bloqueio_id IS NOT NULL AND papel = 'BLOQUEIO')
  ),
  CONSTRAINT rs_slot_positivo CHECK (slot > 0),
  CONSTRAINT rs_periodo_fechado CHECK (lower_inc(periodo) AND NOT upper_inc(periodo)),
  CONSTRAINT rs_periodo_nao_vazio CHECK (NOT isempty(periodo)),
  CONSTRAINT rs_periodo_limitado CHECK (lower(periodo) IS NOT NULL AND upper(periodo) IS NOT NULL),

  -- ===========================================================================
  -- A GARANTIA. Uma linha de constraint substitui todo um serviço de lock.
  -- O PostgreSQL recusa qualquer reserva que se sobreponha a outra ativa do
  -- mesmo recurso e slot — em qualquer nível de concorrência, sem cooperação
  -- da aplicação e sem Redis no caminho crítico do agendamento.
  -- ===========================================================================
  CONSTRAINT rs_sem_sobreposicao EXCLUDE USING gist (
    tenant_id WITH =, recurso_id WITH =, slot WITH =, periodo WITH &&
  ) WHERE (ativa)
);

CREATE INDEX ix_rs_item ON lumia.reserva (tenant_id, agendamento_item_id) WHERE agendamento_item_id IS NOT NULL;
CREATE INDEX ix_rs_recurso_periodo ON lumia.reserva USING gist (tenant_id, recurso_id, periodo) WHERE ativa;
CREATE INDEX ix_rs_sync ON lumia.reserva (tenant_id, atualizado_em);
SELECT lumia.aplicar_rls('lumia.reserva');

COMMENT ON TABLE lumia.reserva IS
  'Uma linha por (recurso, intervalo). É aqui que o double-booking se torna '
  'impossível — não por disciplina da aplicação, mas por constraint. Um item de '
  'agendamento com pausa química gera DUAS reservas para o profissional (antes '
  'e depois da pausa) e UMA contígua para a cadeira: a regra de domínio mais '
  'específica do setor cai fora do mesmo mecanismo, sem código especial.';

-- O slot precisa caber na capacidade do recurso.
CREATE OR REPLACE FUNCTION lumia.tg_reserva_valida_slot() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_cap smallint; v_ativo boolean;
BEGIN
  SELECT capacidade, ativo INTO v_cap, v_ativo
    FROM lumia.recurso_agendavel
   WHERE tenant_id = NEW.tenant_id AND id = NEW.recurso_id;
  IF v_cap IS NULL THEN
    RAISE EXCEPTION 'Recurso % não existe no tenant %', NEW.recurso_id, NEW.tenant_id;
  END IF;
  IF NEW.ativa AND NOT v_ativo THEN
    RAISE EXCEPTION 'Recurso % está inativo e não pode ser reservado', NEW.recurso_id;
  END IF;
  IF NEW.slot > v_cap THEN
    RAISE EXCEPTION 'Slot % excede a capacidade % do recurso %',
      NEW.slot, v_cap, NEW.recurso_id
      USING HINT = 'A capacidade do recurso está esgotada nesse horário.';
  END IF;
  NEW.atualizado_em := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER tg_reserva_valida_slot
  BEFORE INSERT OR UPDATE OF slot, recurso_id, ativa ON lumia.reserva
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_reserva_valida_slot();

-- =============================================================================
-- PARTE 6 — Motor de reserva
-- =============================================================================

-- Primeiro slot livre de um recurso em um período. NULL = sem capacidade.
CREATE OR REPLACE FUNCTION lumia.slot_livre(
  p_tenant_id uuid, p_recurso_id uuid, p_periodo tstzrange
) RETURNS smallint
LANGUAGE sql STABLE AS $$
  SELECT s.n::smallint
    FROM lumia.recurso_agendavel r
    CROSS JOIN LATERAL generate_series(1, r.capacidade) AS s(n)
   WHERE r.tenant_id = p_tenant_id AND r.id = p_recurso_id AND r.ativo
     AND NOT EXISTS (
       SELECT 1 FROM lumia.reserva v
        WHERE v.tenant_id = p_tenant_id
          AND v.recurso_id = p_recurso_id
          AND v.slot = s.n
          AND v.ativa
          AND v.periodo && p_periodo)
   ORDER BY s.n
   LIMIT 1;
$$;

COMMENT ON FUNCTION lumia.slot_livre IS
  'Consulta de conveniência para a tela de disponibilidade. NÃO é a garantia: '
  'entre a consulta e a gravação existe uma janela de corrida, e é o EXCLUDE '
  'que a fecha. A aplicação deve tratar a violação de exclusão como "horário '
  'acabou de ser ocupado" e reapresentar a agenda.';

-- Cria as reservas de um item de agendamento a partir das etapas do serviço.
-- É aqui que a pausa química vira duas janelas para o profissional.
CREATE OR REPLACE FUNCTION lumia.reservar_item(
  p_tenant_id       uuid,
  p_item_id         uuid,
  p_recurso_local_id uuid DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_item      lumia.agendamento_item;
  v_srv       lumia.servico;
  v_estab     uuid;
  v_rec_prof  uuid;
  v_ini       timestamptz;
  v_t_setup   interval;
  v_t_ativa   interval;
  v_t_proc    interval;
  v_t_final   interval;
  v_t_higi    interval;
  v_fim_total timestamptz;
  v_marca1    timestamptz;  -- fim da etapa ativa
  v_marca2    timestamptz;  -- fim da pausa química
  v_slot      smallint;
  v_criadas   integer := 0;
BEGIN
  SELECT * INTO v_item FROM lumia.agendamento_item
   WHERE tenant_id = p_tenant_id AND id = p_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item de agendamento % não encontrado', p_item_id;
  END IF;

  SELECT * INTO v_srv FROM lumia.servico
   WHERE tenant_id = p_tenant_id AND id = v_item.servico_id;

  SELECT a.estabelecimento_id INTO v_estab FROM lumia.agendamento a
   WHERE a.tenant_id = p_tenant_id AND a.id = v_item.agendamento_id;

  v_ini     := v_item.inicio_previsto;
  v_t_setup := make_interval(mins => v_srv.duracao_setup_min);
  v_t_ativa := make_interval(mins => v_srv.duracao_ativa_min
                 + coalesce((SELECT delta_duracao_ativa_min FROM lumia.servico_variante
                              WHERE tenant_id = p_tenant_id AND id = v_item.variante_id), 0));
  v_t_proc  := make_interval(mins => v_srv.duracao_processamento_min);
  v_t_final := make_interval(mins => v_srv.duracao_finalizacao_min);
  v_t_higi  := make_interval(mins => v_srv.duracao_higienizacao_min);

  v_marca1    := v_ini + v_t_setup + v_t_ativa;
  v_marca2    := v_marca1 + v_t_proc;
  v_fim_total := v_marca2 + v_t_final + v_t_higi;

  -- ---- executor -----------------------------------------------------------
  IF v_item.profissional_id IS NOT NULL THEN
    SELECT id INTO v_rec_prof FROM lumia.recurso_agendavel
     WHERE tenant_id = p_tenant_id AND profissional_id = v_item.profissional_id
       AND estabelecimento_id = v_estab;
    IF v_rec_prof IS NULL THEN
      RAISE EXCEPTION 'Profissional % não é recurso do estabelecimento %',
        v_item.profissional_id, v_estab;
    END IF;

    IF v_srv.duracao_processamento_min > 0 AND v_srv.libera_profissional_no_processamento THEN
      -- Duas janelas: o profissional atende outra pessoa durante a pausa.
      INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
      VALUES (p_tenant_id, lumia.uuid_v7(), v_rec_prof, 1,
              tstzrange(v_ini, v_marca1, '[)'), 'EXECUTOR', p_item_id);
      INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
      VALUES (p_tenant_id, lumia.uuid_v7(), v_rec_prof, 1,
              tstzrange(v_marca2, v_fim_total, '[)'), 'EXECUTOR', p_item_id);
      v_criadas := v_criadas + 2;
    ELSE
      INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
      VALUES (p_tenant_id, lumia.uuid_v7(), v_rec_prof, 1,
              tstzrange(v_ini, v_fim_total, '[)'), 'EXECUTOR', p_item_id);
      v_criadas := v_criadas + 1;
    END IF;
  END IF;

  -- ---- local / equipamento -------------------------------------------------
  IF p_recurso_local_id IS NOT NULL THEN
    DECLARE
      v_periodo_local tstzrange;
    BEGIN
      -- A cadeira segue ocupada durante a pausa, salvo se o serviço liberar.
      IF v_srv.duracao_processamento_min > 0 AND v_srv.libera_recurso_no_processamento THEN
        v_periodo_local := tstzrange(v_ini, v_marca1, '[)');
        v_slot := lumia.slot_livre(p_tenant_id, p_recurso_local_id, v_periodo_local);
        IF v_slot IS NULL THEN
          RAISE EXCEPTION 'Sem capacidade no recurso % para o período %',
            p_recurso_local_id, v_periodo_local;
        END IF;
        INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
        VALUES (p_tenant_id, lumia.uuid_v7(), p_recurso_local_id, v_slot,
                v_periodo_local, 'LOCAL', p_item_id);
        v_periodo_local := tstzrange(v_marca2, v_fim_total, '[)');
        v_slot := lumia.slot_livre(p_tenant_id, p_recurso_local_id, v_periodo_local);
        IF v_slot IS NULL THEN
          RAISE EXCEPTION 'Sem capacidade no recurso % para o período %',
            p_recurso_local_id, v_periodo_local;
        END IF;
        INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
        VALUES (p_tenant_id, lumia.uuid_v7(), p_recurso_local_id, v_slot,
                v_periodo_local, 'LOCAL', p_item_id);
        v_criadas := v_criadas + 2;
      ELSE
        v_periodo_local := tstzrange(v_ini, v_fim_total, '[)');
        v_slot := lumia.slot_livre(p_tenant_id, p_recurso_local_id, v_periodo_local);
        IF v_slot IS NULL THEN
          RAISE EXCEPTION 'Sem capacidade no recurso % para o período %',
            p_recurso_local_id, v_periodo_local
            USING HINT = 'Todos os slots do recurso estão ocupados nesse horário.';
        END IF;
        INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
        VALUES (p_tenant_id, lumia.uuid_v7(), p_recurso_local_id, v_slot,
                v_periodo_local, 'LOCAL', p_item_id);
        v_criadas := v_criadas + 1;
      END IF;
    END;
  END IF;

  -- Mantém o item coerente com as etapas calculadas.
  UPDATE lumia.agendamento_item
     SET fim_previsto = v_fim_total, atualizado_em = now()
   WHERE tenant_id = p_tenant_id AND id = p_item_id;

  RETURN v_criadas;
END;
$$;

COMMENT ON FUNCTION lumia.reservar_item IS
  'Traduz as etapas do serviço em reservas. A pausa química produz duas janelas '
  'para o executor e uma contígua para o local — que é exatamente a regra que '
  'faz um salão recuperar cerca de 30% da capacidade que uma agenda ingênua '
  'desperdiça.';

-- Cancelamento libera o horário sem apagar histórico.
CREATE OR REPLACE FUNCTION lumia.cancelar_agendamento(
  p_tenant_id uuid, p_agendamento_id uuid, p_motivo text DEFAULT NULL,
  p_nao_compareceu boolean DEFAULT false
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_liberadas integer;
BEGIN
  UPDATE lumia.agendamento
     SET status = CASE WHEN p_nao_compareceu THEN 'NAO_COMPARECEU'::lumia.status_agendamento
                       ELSE 'CANCELADO'::lumia.status_agendamento END,
         cancelado_em = now(),
         motivo_cancelamento = p_motivo,
         atualizado_em = now()
   WHERE tenant_id = p_tenant_id AND id = p_agendamento_id;

  UPDATE lumia.reserva r
     SET ativa = false, atualizado_em = now()
    FROM lumia.agendamento_item i
   WHERE r.tenant_id = p_tenant_id
     AND r.agendamento_item_id = i.id
     AND i.tenant_id = p_tenant_id
     AND i.agendamento_id = p_agendamento_id
     AND r.ativa;
  GET DIAGNOSTICS v_liberadas = ROW_COUNT;
  RETURN v_liberadas;
END;
$$;

-- =============================================================================
-- PARTE 7 — Lista de espera
-- =============================================================================

CREATE TABLE lumia.lista_espera (
  tenant_id          uuid NOT NULL REFERENCES lumia.tenant(id),
  id                 uuid NOT NULL,
  estabelecimento_id uuid NOT NULL,
  cliente_id         uuid NOT NULL,
  servico_id         uuid NOT NULL,
  variante_id        uuid,
  profissional_preferido_id uuid,
  -- Janela em que o cliente aceita ser encaixado.
  janela             tstzrange NOT NULL,
  prioridade         smallint NOT NULL DEFAULT 0,
  atendida_em        timestamptz,
  agendamento_id     uuid,
  criado_em          timestamptz NOT NULL DEFAULT now(),
  atualizado_em      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_le_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT fk_le_cliente FOREIGN KEY (tenant_id, cliente_id)
    REFERENCES lumia.cliente (tenant_id, id),
  CONSTRAINT fk_le_servico FOREIGN KEY (tenant_id, servico_id)
    REFERENCES lumia.servico (tenant_id, id),
  CONSTRAINT fk_le_ag FOREIGN KEY (tenant_id, agendamento_id)
    REFERENCES lumia.agendamento (tenant_id, id),
  CONSTRAINT le_janela_nao_vazia CHECK (NOT isempty(janela)),
  CONSTRAINT le_atendida_tem_agendamento CHECK ((atendida_em IS NULL) = (agendamento_id IS NULL))
);
CREATE INDEX ix_le_aberta ON lumia.lista_espera
  (tenant_id, estabelecimento_id, prioridade DESC, criado_em)
  WHERE atendida_em IS NULL;
CREATE INDEX ix_le_janela ON lumia.lista_espera USING gist (tenant_id, janela)
  WHERE atendida_em IS NULL;
SELECT lumia.aplicar_rls('lumia.lista_espera');

-- =============================================================================
-- PARTE 8 — Leitura
-- =============================================================================

-- Ocupação por recurso: a base da taxa de ocupação em Meus Resultados.
CREATE VIEW lumia.vw_ocupacao AS
SELECT r.tenant_id,
       ra.estabelecimento_id,
       r.recurso_id,
       ra.tipo AS tipo_recurso,
       coalesce(p.nome, u_no.nome) AS recurso,
       (lower(r.periodo) AT TIME ZONE e.fuso)::date AS data_comercial,
       r.papel,
       sum(upper(r.periodo) - lower(r.periodo)) AS tempo_ocupado,
       count(*) AS reservas
  FROM lumia.reserva r
  JOIN lumia.recurso_agendavel ra
    ON (ra.tenant_id, ra.id) = (r.tenant_id, r.recurso_id)
  JOIN lumia.estabelecimento e
    ON (e.tenant_id, e.no_org_id) = (ra.tenant_id, ra.estabelecimento_id)
  LEFT JOIN lumia.profissional p
    ON (p.tenant_id, p.id) = (ra.tenant_id, ra.profissional_id)
  LEFT JOIN lumia.no_org u_no
    ON (u_no.tenant_id, u_no.id) = (ra.tenant_id, ra.unidade_id)
 WHERE r.ativa
 GROUP BY r.tenant_id, ra.estabelecimento_id, r.recurso_id, ra.tipo,
          coalesce(p.nome, u_no.nome), (lower(r.periodo) AT TIME ZONE e.fuso)::date, r.papel;

COMMENT ON VIEW lumia.vw_ocupacao IS
  'Tempo ocupado por recurso e dia comercial (no fuso do estabelecimento). '
  'Denominador da taxa de ocupação e insumo da Bússola do Aluguel de Cadeiras.';

-- Conflito do mesmo profissional entre estabelecimentos diferentes: o EXCLUDE
-- atua por recurso, e o profissional tem um recurso por estabelecimento, então
-- este caso precisa de verificação explícita.
CREATE VIEW lumia.vw_conflito_profissional AS
SELECT a.tenant_id, a.profissional_id, a.id AS reserva_a, b.id AS reserva_b,
       a.periodo * b.periodo AS interseccao
  FROM (SELECT r.*, ra.profissional_id, ra.estabelecimento_id
          FROM lumia.reserva r
          JOIN lumia.recurso_agendavel ra ON (ra.tenant_id, ra.id) = (r.tenant_id, r.recurso_id)
         WHERE r.ativa AND ra.tipo = 'PROFISSIONAL') a
  JOIN (SELECT r.*, ra.profissional_id, ra.estabelecimento_id
          FROM lumia.reserva r
          JOIN lumia.recurso_agendavel ra ON (ra.tenant_id, ra.id) = (r.tenant_id, r.recurso_id)
         WHERE r.ativa AND ra.tipo = 'PROFISSIONAL') b
    ON a.tenant_id = b.tenant_id
   AND a.profissional_id = b.profissional_id
   AND a.id < b.id
   AND a.periodo && b.periodo;

COMMENT ON VIEW lumia.vw_conflito_profissional IS
  'Deve estar sempre vazia. Um profissional agendado em dois estabelecimentos '
  'no mesmo horário passa pelo EXCLUDE (recursos distintos) e é capturado aqui — '
  'a aplicação consulta antes de confirmar e o CI verifica que a view está vazia.';

COMMIT;
