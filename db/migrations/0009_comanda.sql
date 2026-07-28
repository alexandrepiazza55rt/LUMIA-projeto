-- =============================================================================
-- LUMIA · 0009 — Comanda: custódia rastreável e itens multi-executor
-- =============================================================================
-- A comanda é o documento que carrega dinheiro de verdade antes de virar
-- pagamento. Três exigências moldam o modelo:
--
-- 1. RASTREABILIDADE TOTAL. Quem abriu, quando, em qual terminal, e toda
--    passagem de mão desde então. A responsabilidade nunca é ambígua: em
--    qualquer instante do passado é possível dizer QUEM respondia pela comanda.
--
-- 2. COMPARTILHAMENTO COM MOTIVO. Passar comanda adiante é rotina em salão
--    (troca de turno, profissional saiu, cliente mudou de cadeira). O que não
--    pode é passar sem deixar rastro do PORQUÊ — é exatamente aí que some item
--    e aparece divergência sem dono.
--
-- 3. VALOR CONGELADO NO ITEM. O preço praticado é gravado no item no momento do
--    lançamento. Reajuste posterior de tabela não reescreve comanda passada.
--
-- A custódia usa o MESMO mecanismo da agenda: períodos com EXCLUDE. Duas
-- pessoas não podem responder pela mesma comanda ao mesmo tempo, e o banco é
-- quem garante — não a disciplina de quem escreve o endpoint.
-- =============================================================================

BEGIN;

-- =============================================================================
-- PARTE 1 — Comanda
-- =============================================================================

CREATE TYPE lumia.status_comanda AS ENUM (
  'ABERTA',       -- recebendo itens
  'FECHADA',      -- fechada para lançamento, aguardando pagamento
  'PAGA',         -- quitada
  'CANCELADA'     -- cancelada com motivo
);

CREATE TYPE lumia.origem_comanda AS ENUM (
  'CHECK_IN', 'BALCAO', 'ENCAIXE', 'VENDA_AVULSA', 'IMPORTACAO'
);

CREATE TABLE lumia.comanda (
  tenant_id          uuid NOT NULL REFERENCES lumia.tenant(id),
  id                 uuid NOT NULL,
  estabelecimento_id uuid NOT NULL,
  numero             integer NOT NULL,
  -- Código curto impresso/falado no balcão ("comanda 42"), reciclado por dia.
  codigo_exibicao    text,
  status             lumia.status_comanda NOT NULL DEFAULT 'ABERTA',
  origem             lumia.origem_comanda NOT NULL DEFAULT 'BALCAO',
  cliente_id         uuid,
  agendamento_id     uuid,
  -- ---- rastreabilidade da abertura -------------------------------------
  aberta_por         uuid NOT NULL,
  aberta_em          timestamptz NOT NULL DEFAULT now(),
  terminal_abertura_id uuid,
  -- ---- responsável ATUAL (projeção da custódia vigente) ------------------
  responsavel_atual_id uuid NOT NULL,
  -- ---- fechamento e pagamento -------------------------------------------
  fechada_por        uuid,
  fechada_em         timestamptz,
  paga_em            timestamptz,
  cancelada_por      uuid,
  cancelada_em       timestamptz,
  motivo_cancelamento text,
  -- ---- totais congelados no fechamento -----------------------------------
  total_bruto        lumia.valor_monetario NOT NULL DEFAULT 0,
  total_desconto     lumia.valor_monetario NOT NULL DEFAULT 0,
  total_liquido      lumia.valor_monetario NOT NULL DEFAULT 0,
  moeda              lumia.moeda NOT NULL DEFAULT 'BRL',
  data_comercial     date NOT NULL,
  finalidade         lumia.finalidade_dado NOT NULL DEFAULT 'REAL',
  observacao         text,
  criado_em          timestamptz NOT NULL DEFAULT now(),
  atualizado_em      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_cm_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT fk_cm_cliente FOREIGN KEY (tenant_id, cliente_id)
    REFERENCES lumia.cliente (tenant_id, id),
  CONSTRAINT fk_cm_agendamento FOREIGN KEY (tenant_id, agendamento_id)
    REFERENCES lumia.agendamento (tenant_id, id),
  CONSTRAINT fk_cm_abriu FOREIGN KEY (tenant_id, aberta_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_cm_responsavel FOREIGN KEY (tenant_id, responsavel_atual_id)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_cm_fechou FOREIGN KEY (tenant_id, fechada_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_cm_cancelou FOREIGN KEY (tenant_id, cancelada_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_cm_terminal FOREIGN KEY (tenant_id, terminal_abertura_id)
    REFERENCES lumia.terminal_caixa (tenant_id, id),
  CONSTRAINT cm_totais_nao_negativos CHECK (
    total_bruto >= 0 AND total_desconto >= 0 AND total_liquido >= 0
  ),
  CONSTRAINT cm_liquido_coerente CHECK (total_liquido = total_bruto - total_desconto),
  CONSTRAINT cm_fechada_nomeada CHECK ((fechada_por IS NULL) = (fechada_em IS NULL)),
  CONSTRAINT cm_cancelamento_justificado CHECK (
    (status <> 'CANCELADA')
    OR (cancelada_por IS NOT NULL AND cancelada_em IS NOT NULL
        AND motivo_cancelamento IS NOT NULL AND length(btrim(motivo_cancelamento)) >= 5)
  ),
  CONSTRAINT cm_paga_exige_fechamento CHECK (status <> 'PAGA' OR fechada_em IS NOT NULL)
);

CREATE UNIQUE INDEX ux_cm_numero ON lumia.comanda (tenant_id, numero);
CREATE UNIQUE INDEX ux_cm_codigo_dia ON lumia.comanda
  (tenant_id, estabelecimento_id, data_comercial, codigo_exibicao)
  WHERE codigo_exibicao IS NOT NULL AND status <> 'CANCELADA';
CREATE INDEX ix_cm_abertas ON lumia.comanda (tenant_id, estabelecimento_id, status)
  WHERE status = 'ABERTA';
CREATE INDEX ix_cm_responsavel ON lumia.comanda (tenant_id, responsavel_atual_id)
  WHERE status IN ('ABERTA','FECHADA');
CREATE INDEX ix_cm_dia ON lumia.comanda (tenant_id, estabelecimento_id, data_comercial);
CREATE INDEX ix_cm_sync ON lumia.comanda (tenant_id, atualizado_em);
SELECT lumia.aplicar_rls('lumia.comanda');

COMMENT ON COLUMN lumia.comanda.responsavel_atual_id IS
  'Projeção da custódia vigente, mantida por trigger a partir de '
  'comanda_custodia. Existe para a tela "minhas comandas" não precisar de '
  'subconsulta — a verdade continua sendo a cadeia de custódia.';
COMMENT ON COLUMN lumia.comanda.codigo_exibicao IS
  'O "42" que a recepção fala em voz alta. Reciclado por dia comercial, ao '
  'contrário do número sequencial, que nunca se repete.';

CREATE OR REPLACE FUNCTION lumia.tg_comanda_data() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_fuso text;
BEGIN
  SELECT fuso INTO v_fuso FROM lumia.estabelecimento
   WHERE tenant_id = NEW.tenant_id AND no_org_id = NEW.estabelecimento_id;
  NEW.data_comercial := (NEW.aberta_em AT TIME ZONE v_fuso)::date;
  NEW.atualizado_em  := now();
  RETURN NEW;
END; $$;

CREATE TRIGGER tg_comanda_data
  BEFORE INSERT OR UPDATE OF aberta_em, estabelecimento_id ON lumia.comanda
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_comanda_data();

-- =============================================================================
-- PARTE 2 — Cadeia de custódia
-- =============================================================================
-- Quem respondia pela comanda em cada instante. Mesmo mecanismo da agenda:
-- períodos sem sobreposição garantidos por EXCLUDE.

CREATE TYPE lumia.motivo_transferencia AS ENUM (
  'TROCA_DE_TURNO',
  'PROFISSIONAL_AUSENTE',
  'CLIENTE_MUDOU_DE_PROFISSIONAL',
  'CLIENTE_MUDOU_DE_AMBIENTE',
  'ENCAMINHAMENTO_PARA_CAIXA',
  'DIVISAO_DE_COMANDA',
  'JUNCAO_DE_COMANDA',
  'CORRECAO_DE_LANCAMENTO',
  'SOLICITACAO_DA_GERENCIA',
  'OUTRO'
);

CREATE TABLE lumia.comanda_custodia (
  tenant_id      uuid NOT NULL REFERENCES lumia.tenant(id),
  id             uuid NOT NULL,
  comanda_id     uuid NOT NULL,
  responsavel_id uuid NOT NULL,
  periodo        tstzrange NOT NULL,
  -- Como a custódia começou.
  motivo         lumia.motivo_transferencia,
  justificativa  text,
  -- Quem entregou e quem recebeu: transferência tem dois lados nomeados.
  transferida_por uuid,
  recebida_por    uuid,
  -- Transferência entre profissionais de comissões diferentes muda o dono da
  -- receita; por isso pode exigir aval.
  autorizada_por  uuid,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_cu_comanda FOREIGN KEY (tenant_id, comanda_id)
    REFERENCES lumia.comanda (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_cu_resp FOREIGN KEY (tenant_id, responsavel_id)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_cu_transferiu FOREIGN KEY (tenant_id, transferida_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_cu_recebeu FOREIGN KEY (tenant_id, recebida_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_cu_autorizou FOREIGN KEY (tenant_id, autorizada_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT cu_periodo_nao_vazio CHECK (NOT isempty(periodo)),
  CONSTRAINT cu_periodo_fechado_esquerda CHECK (lower(periodo) IS NOT NULL),
  -- Toda custódia que NÃO é a primeira precisa dizer por que mudou de mão.
  CONSTRAINT cu_transferencia_justificada CHECK (
    transferida_por IS NULL
    OR (motivo IS NOT NULL
        AND (motivo <> 'OUTRO' OR (justificativa IS NOT NULL AND length(btrim(justificativa)) >= 5)))
  ),
  -- Duas pessoas não respondem pela mesma comanda ao mesmo tempo.
  CONSTRAINT cu_sem_sobreposicao EXCLUDE USING gist (
    tenant_id WITH =, comanda_id WITH =, periodo WITH &&
  )
);

CREATE INDEX ix_cu_comanda ON lumia.comanda_custodia (tenant_id, comanda_id, lower(periodo));
CREATE INDEX ix_cu_resp ON lumia.comanda_custodia USING gist (tenant_id, responsavel_id, periodo);
SELECT lumia.aplicar_rls('lumia.comanda_custodia');

COMMENT ON TABLE lumia.comanda_custodia IS
  'Quem respondia pela comanda em cada instante do tempo. Responder "de quem '
  'era a comanda às 15h40 de terça?" é uma consulta, não uma investigação. O '
  'EXCLUDE impede dois responsáveis simultâneos; o trigger impede buraco entre '
  'um período e o seguinte.';
COMMENT ON COLUMN lumia.comanda_custodia.motivo IS
  'Passar comanda adiante é rotina; passar sem dizer por quê é como some item e '
  'aparece divergência sem dono. Por isso o motivo é obrigatório em toda '
  'transferência, e justificativa livre é exigida quando o motivo é OUTRO.';

-- A cadeia não pode ter buraco: a custódia nova começa exatamente onde a
-- anterior terminou.
CREATE OR REPLACE FUNCTION lumia.tg_custodia_sem_buraco() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_fim_anterior timestamptz;
BEGIN
  SELECT upper(periodo) INTO v_fim_anterior
    FROM lumia.comanda_custodia
   WHERE tenant_id = NEW.tenant_id AND comanda_id = NEW.comanda_id
     AND id <> NEW.id
   ORDER BY lower(periodo) DESC
   LIMIT 1;

  IF v_fim_anterior IS NULL THEN
    RETURN NEW;  -- primeira custódia da comanda
  END IF;

  IF lower(NEW.periodo) <> v_fim_anterior THEN
    RAISE EXCEPTION 'Buraco na cadeia de custódia: a anterior terminou em %, esta começa em %',
      v_fim_anterior, lower(NEW.periodo)
      USING HINT = 'A responsabilidade pela comanda não pode ficar sem dono nem por um instante.';
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER tg_custodia_sem_buraco
  BEFORE INSERT ON lumia.comanda_custodia
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_custodia_sem_buraco();

-- Mantém comanda.responsavel_atual_id coerente com a custódia aberta.
CREATE OR REPLACE FUNCTION lumia.tg_custodia_projeta_responsavel() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF upper(NEW.periodo) IS NULL THEN
    UPDATE lumia.comanda
       SET responsavel_atual_id = NEW.responsavel_id, atualizado_em = now()
     WHERE tenant_id = NEW.tenant_id AND id = NEW.comanda_id
       AND responsavel_atual_id IS DISTINCT FROM NEW.responsavel_id;
  END IF;
  RETURN NULL;
END; $$;

CREATE TRIGGER tg_custodia_projeta_responsavel
  AFTER INSERT ON lumia.comanda_custodia
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_custodia_projeta_responsavel();

-- =============================================================================
-- PARTE 3 — Itens: polimórficos, multi-executor, com dono de receita
-- =============================================================================

CREATE TYPE lumia.tipo_item_comanda AS ENUM ('SERVICO', 'PRODUTO', 'TAXA', 'PACOTE');

-- Lei do Salão Parceiro: a receita do item pode ser do salão ou do parceiro. O
-- salão centraliza o recebimento e retém tributos, mas a titularidade precisa
-- estar declarada NO ITEM para a nota discriminar e o repasse fechar.
CREATE TYPE lumia.titular_receita AS ENUM ('ESTABELECIMENTO', 'PROFISSIONAL_PARCEIRO');

CREATE TABLE lumia.comanda_item (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  comanda_id      uuid NOT NULL,
  sequencia       smallint NOT NULL,
  tipo            lumia.tipo_item_comanda NOT NULL,
  -- Exatamente um: serviço OU produto. Nunca texto livre.
  servico_id      uuid,
  variante_id     uuid,
  produto_id      uuid,
  descricao_congelada text NOT NULL,
  quantidade      numeric(12,3) NOT NULL DEFAULT 1,
  -- ---- valores CONGELADOS no lançamento ---------------------------------
  preco_tabela    lumia.valor_monetario NOT NULL,
  preco_praticado lumia.valor_monetario NOT NULL,
  valor_desconto  lumia.valor_monetario NOT NULL DEFAULT 0,
  valor_total     lumia.valor_monetario
    GENERATED ALWAYS AS (preco_praticado * quantidade - valor_desconto) STORED,
  moeda           lumia.moeda NOT NULL DEFAULT 'BRL',
  -- ---- quem executou: pode ser diferente de quem abriu a comanda --------
  executor_id     uuid,
  titular_receita lumia.titular_receita NOT NULL DEFAULT 'ESTABELECIMENTO',
  base_comissao   text NOT NULL DEFAULT 'BRUTO',
  -- ---- desconto exige motivo e autorizador -------------------------------
  motivo_desconto_id uuid,
  desconto_autorizado_por uuid,
  -- ---- rastro -----------------------------------------------------------
  lancado_por     uuid NOT NULL,
  lancado_em      timestamptz NOT NULL DEFAULT now(),
  agendamento_item_id uuid,
  cancelado_em    timestamptz,
  cancelado_por   uuid,
  motivo_cancelamento text,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_ci_comanda FOREIGN KEY (tenant_id, comanda_id)
    REFERENCES lumia.comanda (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_ci_servico FOREIGN KEY (tenant_id, servico_id)
    REFERENCES lumia.servico (tenant_id, id),
  CONSTRAINT fk_ci_variante FOREIGN KEY (tenant_id, variante_id)
    REFERENCES lumia.servico_variante (tenant_id, id),
  CONSTRAINT fk_ci_produto FOREIGN KEY (tenant_id, produto_id)
    REFERENCES lumia.produto (tenant_id, id),
  CONSTRAINT fk_ci_executor FOREIGN KEY (tenant_id, executor_id)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_ci_lancou FOREIGN KEY (tenant_id, lancado_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_ci_motivo_desc FOREIGN KEY (tenant_id, motivo_desconto_id)
    REFERENCES lumia.motivo_desconto (tenant_id, id),
  CONSTRAINT fk_ci_autorizou_desc FOREIGN KEY (tenant_id, desconto_autorizado_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_ci_agitem FOREIGN KEY (tenant_id, agendamento_item_id)
    REFERENCES lumia.agendamento_item (tenant_id, id),
  CONSTRAINT fk_ci_cancelou FOREIGN KEY (tenant_id, cancelado_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT ci_referencia_coerente CHECK (
    (tipo = 'SERVICO' AND servico_id IS NOT NULL AND produto_id IS NULL)
    OR (tipo = 'PRODUTO' AND produto_id IS NOT NULL AND servico_id IS NULL)
    OR (tipo IN ('TAXA','PACOTE') AND servico_id IS NULL AND produto_id IS NULL)
  ),
  CONSTRAINT ci_quantidade_positiva CHECK (quantidade > 0),
  CONSTRAINT ci_valores_nao_negativos CHECK (
    preco_tabela >= 0 AND preco_praticado >= 0 AND valor_desconto >= 0
  ),
  -- Desconto sem motivo e sem autorizador é margem que evapora sem explicação.
  CONSTRAINT ci_desconto_justificado CHECK (
    valor_desconto = 0
    OR (motivo_desconto_id IS NOT NULL AND desconto_autorizado_por IS NOT NULL)
  ),
  CONSTRAINT ci_cancelamento_justificado CHECK (
    cancelado_em IS NULL
    OR (cancelado_por IS NOT NULL AND motivo_cancelamento IS NOT NULL
        AND length(btrim(motivo_cancelamento)) >= 5)
  ),
  -- Receita de parceiro exige executor identificado: é dele a nota.
  CONSTRAINT ci_parceiro_tem_executor CHECK (
    titular_receita <> 'PROFISSIONAL_PARCEIRO' OR executor_id IS NOT NULL
  ),
  CONSTRAINT ci_base_comissao_valida CHECK (
    base_comissao IN ('BRUTO','LIQUIDO_INSUMO','LIQUIDO_TAXA','NAO_COMISSIONAVEL')
  )
);

CREATE UNIQUE INDEX ux_ci_sequencia ON lumia.comanda_item (tenant_id, comanda_id, sequencia);
CREATE INDEX ix_ci_comanda ON lumia.comanda_item (tenant_id, comanda_id) WHERE cancelado_em IS NULL;
CREATE INDEX ix_ci_executor ON lumia.comanda_item (tenant_id, executor_id, lancado_em)
  WHERE cancelado_em IS NULL;
SELECT lumia.aplicar_rls('lumia.comanda_item');

COMMENT ON TABLE lumia.comanda_item IS
  'Um item pode ter executor diferente de quem abriu a comanda e de quem a '
  'detém agora — é o caso normal: a recepção abre, a manicure executa um item, '
  'a cabeleireira executa outro, o caixa recebe. Cada papel fica nomeado.';
COMMENT ON COLUMN lumia.comanda_item.preco_praticado IS
  'Congelado no lançamento. preco_tabela guarda o valor cheio no mesmo instante, '
  'de modo que a auditoria de margem consegue explicar cada centavo de desconto '
  'sem depender da tabela de preços de hoje.';
COMMENT ON COLUMN lumia.comanda_item.titular_receita IS
  'Lei 13.352/2016 (Salão Parceiro): o salão centraliza o recebimento e retém '
  'tributos, mas a nota discrimina a parte do parceiro. Sem a titularidade '
  'declarada no item, o repasse e a nota não fecham.';

-- Itens só entram em comanda ABERTA.
CREATE OR REPLACE FUNCTION lumia.tg_item_comanda_aberta() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status lumia.status_comanda;
BEGIN
  SELECT status INTO v_status FROM lumia.comanda
   WHERE tenant_id = NEW.tenant_id AND id = NEW.comanda_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Comanda % não existe', NEW.comanda_id;
  END IF;
  IF TG_OP = 'INSERT' AND v_status <> 'ABERTA' THEN
    RAISE EXCEPTION 'Não é possível lançar item em comanda %', v_status
      USING HINT = 'Reabra a comanda com justificativa antes de lançar.';
  END IF;
  IF TG_OP = 'INSERT' THEN
    SELECT coalesce(max(sequencia),0) + 1 INTO NEW.sequencia
      FROM lumia.comanda_item
     WHERE tenant_id = NEW.tenant_id AND comanda_id = NEW.comanda_id;
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER tg_item_comanda_aberta
  BEFORE INSERT ON lumia.comanda_item
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_item_comanda_aberta();

-- Recalcula os totais da comanda a cada mudança de item.
CREATE OR REPLACE FUNCTION lumia.tg_recalcula_totais() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_comanda uuid := coalesce(NEW.comanda_id, OLD.comanda_id);
        v_tenant  uuid := coalesce(NEW.tenant_id, OLD.tenant_id);
BEGIN
  UPDATE lumia.comanda c
     SET total_bruto    = t.bruto,
         total_desconto = t.desconto,
         total_liquido  = t.bruto - t.desconto,
         atualizado_em  = now()
    FROM (SELECT coalesce(sum(preco_praticado * quantidade),0) AS bruto,
                 coalesce(sum(valor_desconto),0) AS desconto
            FROM lumia.comanda_item
           WHERE tenant_id = v_tenant AND comanda_id = v_comanda
             AND cancelado_em IS NULL) t
   WHERE c.tenant_id = v_tenant AND c.id = v_comanda;
  RETURN NULL;
END; $$;

CREATE TRIGGER tg_recalcula_totais
  AFTER INSERT OR UPDATE OR DELETE ON lumia.comanda_item
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_recalcula_totais();

-- =============================================================================
-- PARTE 4 — Pagamento
-- =============================================================================

CREATE TABLE lumia.comanda_pagamento (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  comanda_id      uuid NOT NULL,
  sessao_caixa_id uuid NOT NULL,
  meio_pagamento  lumia.meio_pagamento NOT NULL,
  valor           lumia.valor_monetario NOT NULL,
  moeda           lumia.moeda NOT NULL DEFAULT 'BRL',
  -- Pagamento em dinheiro pode gerar troco.
  valor_recebido  lumia.valor_monetario,
  troco           lumia.valor_monetario,
  parcelas        smallint NOT NULL DEFAULT 1,
  autorizacao     text,
  recebido_por    uuid NOT NULL,
  recebido_em     timestamptz NOT NULL DEFAULT now(),
  -- Chave de idempotência: retry de rede nunca cobra duas vezes.
  chave_idempotencia text NOT NULL,
  estornado_em    timestamptz,
  estornado_por   uuid,
  motivo_estorno  text,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_cp_comanda FOREIGN KEY (tenant_id, comanda_id)
    REFERENCES lumia.comanda (tenant_id, id),
  CONSTRAINT fk_cp_sessao FOREIGN KEY (tenant_id, sessao_caixa_id)
    REFERENCES lumia.sessao_caixa (tenant_id, id),
  CONSTRAINT fk_cp_recebeu FOREIGN KEY (tenant_id, recebido_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_cp_estornou FOREIGN KEY (tenant_id, estornado_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT cp_valor_positivo CHECK (valor > 0),
  CONSTRAINT cp_parcelas_positivas CHECK (parcelas >= 1),
  CONSTRAINT cp_troco_so_dinheiro CHECK (
    troco IS NULL OR (meio_pagamento = 'DINHEIRO' AND valor_recebido IS NOT NULL)
  ),
  CONSTRAINT cp_troco_coerente CHECK (
    troco IS NULL OR troco = valor_recebido - valor
  ),
  CONSTRAINT cp_estorno_justificado CHECK (
    estornado_em IS NULL
    OR (estornado_por IS NOT NULL AND motivo_estorno IS NOT NULL
        AND length(btrim(motivo_estorno)) >= 5)
  )
);

CREATE UNIQUE INDEX ux_cp_idempotencia ON lumia.comanda_pagamento (tenant_id, chave_idempotencia);
CREATE INDEX ix_cp_comanda ON lumia.comanda_pagamento (tenant_id, comanda_id) WHERE estornado_em IS NULL;
CREATE INDEX ix_cp_sessao ON lumia.comanda_pagamento (tenant_id, sessao_caixa_id);
SELECT lumia.aplicar_rls('lumia.comanda_pagamento');

COMMENT ON COLUMN lumia.comanda_pagamento.chave_idempotencia IS
  'Único por tenant. O botão "receber" clicado duas vezes, ou o retry após '
  'timeout de rede, resulta em UM pagamento — não em cobrança dobrada.';

-- =============================================================================
-- PARTE 5 — Operações
-- =============================================================================

CREATE OR REPLACE FUNCTION lumia.abrir_comanda(
  p_tenant_id uuid, p_estabelecimento_id uuid, p_responsavel_id uuid,
  p_cliente_id uuid DEFAULT NULL, p_agendamento_id uuid DEFAULT NULL,
  p_origem lumia.origem_comanda DEFAULT 'BALCAO',
  p_terminal_id uuid DEFAULT NULL, p_codigo text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := lumia.uuid_v7(); v_numero integer; v_agora timestamptz := now();
BEGIN
  SELECT coalesce(max(numero),0) + 1 INTO v_numero
    FROM lumia.comanda WHERE tenant_id = p_tenant_id;

  INSERT INTO lumia.comanda
    (tenant_id, id, estabelecimento_id, numero, codigo_exibicao, origem,
     cliente_id, agendamento_id, aberta_por, aberta_em, terminal_abertura_id,
     responsavel_atual_id, data_comercial)
  VALUES (p_tenant_id, v_id, p_estabelecimento_id, v_numero, p_codigo, p_origem,
          p_cliente_id, p_agendamento_id, p_responsavel_id, v_agora, p_terminal_id,
          p_responsavel_id, '2000-01-01');

  -- Primeira custódia: quem abriu responde a partir de agora, sem fim definido.
  INSERT INTO lumia.comanda_custodia
    (tenant_id, id, comanda_id, responsavel_id, periodo)
  VALUES (p_tenant_id, lumia.uuid_v7(), v_id, p_responsavel_id,
          tstzrange(v_agora, NULL, '[)'));

  RETURN v_id;
END; $$;

-- Passar a comanda adiante. O motivo é obrigatório por assinatura, não por
-- convenção: não existe caminho no código que transfira sem dizer por quê.
CREATE OR REPLACE FUNCTION lumia.transferir_comanda(
  p_tenant_id     uuid,
  p_comanda_id    uuid,
  p_de_id         uuid,
  p_para_id       uuid,
  p_motivo        lumia.motivo_transferencia,
  p_justificativa text DEFAULT NULL,
  p_autorizado_por uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_agora timestamptz := clock_timestamp();
  v_atual lumia.comanda_custodia;
  v_novo  uuid := lumia.uuid_v7();
  v_status lumia.status_comanda;
BEGIN
  SELECT status INTO v_status FROM lumia.comanda
   WHERE tenant_id = p_tenant_id AND id = p_comanda_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Comanda % não existe', p_comanda_id;
  END IF;
  IF v_status IN ('PAGA','CANCELADA') THEN
    RAISE EXCEPTION 'Comanda % não pode ser transferida', v_status;
  END IF;

  SELECT * INTO v_atual FROM lumia.comanda_custodia
   WHERE tenant_id = p_tenant_id AND comanda_id = p_comanda_id
     AND upper(periodo) IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comanda % está sem custódia aberta', p_comanda_id;
  END IF;

  IF v_atual.responsavel_id <> p_de_id THEN
    RAISE EXCEPTION 'A comanda está com % , não com %',
      v_atual.responsavel_id, p_de_id
      USING HINT = 'Só quem detém a comanda pode passá-la adiante.';
  END IF;
  IF p_de_id = p_para_id THEN
    RAISE EXCEPTION 'Origem e destino da transferência são a mesma pessoa';
  END IF;

  -- Fecha a custódia atual exatamente no instante da passagem...
  UPDATE lumia.comanda_custodia
     SET periodo = tstzrange(lower(periodo), v_agora, '[)')
   WHERE tenant_id = p_tenant_id AND id = v_atual.id;

  -- ...e abre a nova no mesmo instante: sem buraco, sem sobreposição.
  INSERT INTO lumia.comanda_custodia
    (tenant_id, id, comanda_id, responsavel_id, periodo,
     motivo, justificativa, transferida_por, recebida_por, autorizada_por)
  VALUES (p_tenant_id, v_novo, p_comanda_id, p_para_id,
          tstzrange(v_agora, NULL, '[)'),
          p_motivo, p_justificativa, p_de_id, p_para_id, p_autorizado_por);

  RETURN v_novo;
END; $$;

COMMENT ON FUNCTION lumia.transferir_comanda IS
  'Passagem de mão com os dois lados nomeados e motivo obrigatório. Fecha a '
  'custódia vigente e abre a nova no MESMO instante — o EXCLUDE impede '
  'sobreposição e o trigger impede buraco, então a responsabilidade nunca fica '
  'sem dono nem por um microssegundo.';

-- Quem respondia pela comanda em um instante qualquer do passado.
CREATE OR REPLACE FUNCTION lumia.responsavel_em(
  p_tenant_id uuid, p_comanda_id uuid, p_instante timestamptz
) RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT responsavel_id FROM lumia.comanda_custodia
   WHERE tenant_id = p_tenant_id AND comanda_id = p_comanda_id
     AND periodo @> p_instante
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION lumia.fechar_comanda(
  p_tenant_id uuid, p_comanda_id uuid, p_fechada_por uuid
) RETURNS lumia.valor_monetario
LANGUAGE plpgsql AS $$
DECLARE v_total lumia.valor_monetario; v_status lumia.status_comanda;
BEGIN
  SELECT status, total_liquido INTO v_status, v_total FROM lumia.comanda
   WHERE tenant_id = p_tenant_id AND id = p_comanda_id FOR UPDATE;
  IF v_status <> 'ABERTA' THEN
    RAISE EXCEPTION 'Só comanda ABERTA pode ser fechada (status atual: %)', v_status;
  END IF;

  UPDATE lumia.comanda
     SET status = 'FECHADA', fechada_por = p_fechada_por, fechada_em = now(),
         atualizado_em = now()
   WHERE tenant_id = p_tenant_id AND id = p_comanda_id;
  RETURN v_total;
END; $$;

-- Pagamento: grava o recebimento, lança no caixa e quita quando cobre o total.
CREATE OR REPLACE FUNCTION lumia.receber_pagamento(
  p_tenant_id uuid, p_comanda_id uuid, p_sessao_id uuid,
  p_meio lumia.meio_pagamento, p_valor lumia.valor_monetario,
  p_recebido_por uuid, p_chave_idempotencia text,
  p_valor_recebido lumia.valor_monetario DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid := lumia.uuid_v7();
  v_status lumia.status_comanda;
  v_total  numeric;
  v_pago   numeric;
  v_troco  numeric;
  v_existente uuid;
BEGIN
  -- Idempotência: mesma chave devolve o pagamento já gravado.
  SELECT id INTO v_existente FROM lumia.comanda_pagamento
   WHERE tenant_id = p_tenant_id AND chave_idempotencia = p_chave_idempotencia;
  IF v_existente IS NOT NULL THEN
    RETURN v_existente;
  END IF;

  SELECT status, total_liquido INTO v_status, v_total FROM lumia.comanda
   WHERE tenant_id = p_tenant_id AND id = p_comanda_id FOR UPDATE;
  IF v_status NOT IN ('FECHADA','ABERTA') THEN
    RAISE EXCEPTION 'Comanda % não aceita pagamento', v_status;
  END IF;

  IF p_meio = 'DINHEIRO' AND p_valor_recebido IS NOT NULL THEN
    v_troco := p_valor_recebido - p_valor;
    IF v_troco < 0 THEN
      RAISE EXCEPTION 'Valor recebido (%) menor que o valor do pagamento (%)',
        p_valor_recebido, p_valor;
    END IF;
  END IF;

  INSERT INTO lumia.comanda_pagamento
    (tenant_id, id, comanda_id, sessao_caixa_id, meio_pagamento, valor,
     valor_recebido, troco, recebido_por, chave_idempotencia)
  VALUES (p_tenant_id, v_id, p_comanda_id, p_sessao_id, p_meio, p_valor,
          p_valor_recebido, v_troco, p_recebido_por, p_chave_idempotencia);

  -- Lança no livro do caixa.
  INSERT INTO lumia.movimento_caixa
    (tenant_id, id, sessao_caixa_id, sequencia, tipo, meio_pagamento, valor,
     afeta_gaveta, registrado_por, comanda_id)
  VALUES (p_tenant_id, lumia.uuid_v7(), p_sessao_id, 0, 'RECEBIMENTO', p_meio,
          p_valor, p_meio = 'DINHEIRO', p_recebido_por, p_comanda_id);

  IF v_troco IS NOT NULL AND v_troco > 0 THEN
    INSERT INTO lumia.movimento_caixa
      (tenant_id, id, sessao_caixa_id, sequencia, tipo, meio_pagamento, valor,
       afeta_gaveta, registrado_por, comanda_id)
    VALUES (p_tenant_id, lumia.uuid_v7(), p_sessao_id, 0, 'TROCO', 'DINHEIRO',
            v_troco, true, p_recebido_por, p_comanda_id);
  END IF;

  -- Quita a comanda quando os pagamentos cobrem o total.
  SELECT coalesce(sum(valor),0) INTO v_pago FROM lumia.comanda_pagamento
   WHERE tenant_id = p_tenant_id AND comanda_id = p_comanda_id AND estornado_em IS NULL;

  IF v_pago >= v_total THEN
    UPDATE lumia.comanda
       SET status = 'PAGA', paga_em = now(),
           fechada_em = coalesce(fechada_em, now()),
           fechada_por = coalesce(fechada_por, p_recebido_por),
           atualizado_em = now()
     WHERE tenant_id = p_tenant_id AND id = p_comanda_id;
  END IF;

  RETURN v_id;
END; $$;

-- =============================================================================
-- PARTE 6 — Junção e divisão
-- =============================================================================
-- Cliente que chega junto e paga separado; casal que paga uma conta só. Ambos
-- os casos deixam rastro: a comanda de origem registra para onde o item foi.

CREATE TABLE lumia.comanda_vinculo (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  comanda_origem_id uuid NOT NULL,
  comanda_destino_id uuid NOT NULL,
  tipo            text NOT NULL,
  motivo          text NOT NULL,
  executado_por   uuid NOT NULL,
  executado_em    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_cv_origem FOREIGN KEY (tenant_id, comanda_origem_id)
    REFERENCES lumia.comanda (tenant_id, id),
  CONSTRAINT fk_cv_destino FOREIGN KEY (tenant_id, comanda_destino_id)
    REFERENCES lumia.comanda (tenant_id, id),
  CONSTRAINT fk_cv_executou FOREIGN KEY (tenant_id, executado_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT cv_tipo_valido CHECK (tipo IN ('JUNCAO','DIVISAO')),
  CONSTRAINT cv_nao_reflexivo CHECK (comanda_origem_id <> comanda_destino_id),
  CONSTRAINT cv_motivo_escrito CHECK (length(btrim(motivo)) >= 5)
);
CREATE INDEX ix_cv_origem ON lumia.comanda_vinculo (tenant_id, comanda_origem_id);
CREATE INDEX ix_cv_destino ON lumia.comanda_vinculo (tenant_id, comanda_destino_id);
SELECT lumia.aplicar_rls('lumia.comanda_vinculo');

COMMENT ON TABLE lumia.comanda_vinculo IS
  'Junção e divisão deixam rastro nos dois lados. Sem isso, um item que muda de '
  'comanda vira item que "sumiu" de uma e "apareceu" em outra.';

-- =============================================================================
-- PARTE 7 — Leitura
-- =============================================================================

CREATE VIEW lumia.vw_comanda_trilha AS
SELECT c.tenant_id,
       c.id AS comanda_id,
       c.numero,
       c.codigo_exibicao,
       c.status,
       c.data_comercial,
       cu.periodo,
       lower(cu.periodo) AS assumida_em,
       upper(cu.periodo) AS entregue_em,
       p.nome  AS responsavel,
       cu.motivo,
       cu.justificativa,
       pde.nome  AS transferida_por,
       paut.nome AS autorizada_por,
       upper(cu.periodo) IS NULL AS custodia_vigente
  FROM lumia.comanda c
  JOIN lumia.comanda_custodia cu
    ON (cu.tenant_id, cu.comanda_id) = (c.tenant_id, c.id)
  JOIN lumia.profissional p
    ON (p.tenant_id, p.id) = (cu.tenant_id, cu.responsavel_id)
  LEFT JOIN lumia.profissional pde
    ON (pde.tenant_id, pde.id) = (cu.tenant_id, cu.transferida_por)
  LEFT JOIN lumia.profissional paut
    ON (paut.tenant_id, paut.id) = (cu.tenant_id, cu.autorizada_por);

COMMENT ON VIEW lumia.vw_comanda_trilha IS
  'A história completa de uma comanda em uma consulta: cada passagem de mão, '
  'com quem entregou, quem recebeu, por quê e quem autorizou.';

-- Produção por executor: a base do fechamento de comissão.
CREATE VIEW lumia.vw_producao_executor AS
SELECT i.tenant_id,
       c.estabelecimento_id,
       c.data_comercial,
       i.executor_id,
       p.nome AS executor,
       i.titular_receita,
       count(*) FILTER (WHERE i.tipo = 'SERVICO') AS servicos,
       count(*) FILTER (WHERE i.tipo = 'PRODUTO') AS produtos,
       sum(i.valor_total) AS total_produzido,
       sum(i.valor_desconto) AS total_desconto
  FROM lumia.comanda_item i
  JOIN lumia.comanda c ON (c.tenant_id, c.id) = (i.tenant_id, i.comanda_id)
  LEFT JOIN lumia.profissional p ON (p.tenant_id, p.id) = (i.tenant_id, i.executor_id)
 WHERE i.cancelado_em IS NULL
   AND c.status = 'PAGA'
   AND c.finalidade = 'REAL'
 GROUP BY i.tenant_id, c.estabelecimento_id, c.data_comercial,
          i.executor_id, p.nome, i.titular_receita;

COMMENT ON VIEW lumia.vw_producao_executor IS
  'Filtra finalidade = REAL: comanda de treinamento nunca entra no fechamento '
  'de comissão, no DRE nem no benchmark.';

GRANT SELECT, INSERT, UPDATE, DELETE ON lumia.comanda, lumia.comanda_custodia,
  lumia.comanda_item, lumia.comanda_pagamento, lumia.comanda_vinculo TO lumia_app;
GRANT SELECT ON lumia.vw_comanda_trilha, lumia.vw_producao_executor
  TO lumia_app, lumia_leitura;

COMMIT;
