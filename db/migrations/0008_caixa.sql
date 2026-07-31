-- =============================================================================
-- LUMIA · 0008 — Caixa: sessão, movimentos e fechamento cego
-- =============================================================================
-- Ponto mais delicado do sistema: é onde dinheiro real encontra responsabilidade
-- pessoal. Três decisões, cada uma vinda de uma restrição concreta:
--
-- 1. LIVRO APPEND-ONLY. Nenhum valor de caixa sofre UPDATE. Sangria, suprimento
--    e pagamento são lançamentos; correção é lançamento novo de sinal oposto,
--    nunca edição do anterior. O saldo é sempre derivado, jamais armazenado.
--
-- 2. CONFERÊNCIA CEGA imposta pelo BANCO, não pela tela. O operador declara o
--    que contou sem ver o que o sistema esperava. Isso não é configuração de
--    interface: é GRANT em nível de coluna — o papel do operador literalmente
--    não consegue ler valor_esperado nem divergencia.
--
-- 3. DIVERGÊNCIA NUNCA VIRA DESCONTO AUTOMÁTICO. O art. 462 da CLT protege a
--    integridade salarial e a jurisprudência sobre desconto de quebra de caixa
--    é dividida. O sistema registra, exige justificativa e aprovação nomeada, e
--    para por aí: a consequência financeira é decisão humana documentada, nunca
--    efeito colateral de software.
-- =============================================================================

BEGIN;

-- =============================================================================
-- PARTE 1 — Terminal e sessão
-- =============================================================================

CREATE TABLE lumia.terminal_caixa (
  tenant_id          uuid NOT NULL REFERENCES lumia.tenant(id),
  id                 uuid NOT NULL,
  estabelecimento_id uuid NOT NULL,
  numero             smallint NOT NULL,
  nome               text NOT NULL,
  ativo              boolean NOT NULL DEFAULT true,
  criado_em          timestamptz NOT NULL DEFAULT now(),
  atualizado_em      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_tc_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id)
);
CREATE UNIQUE INDEX ux_tc_numero ON lumia.terminal_caixa (tenant_id, estabelecimento_id, numero);
SELECT lumia.aplicar_rls('lumia.terminal_caixa');

COMMENT ON TABLE lumia.terminal_caixa IS
  'Ponto de venda físico. A sessão de caixa é sempre de um terminal — é o que '
  'permite dizer "a diferença apareceu no caixa 2" em vez de "apareceu no salão".';

CREATE TYPE lumia.status_sessao_caixa AS ENUM (
  'ABERTA',
  'EM_CONFERENCIA',  -- operador declarou, gestor ainda não apurou
  'FECHADA',
  'FECHADA_COM_DIVERGENCIA'
);

CREATE TABLE lumia.sessao_caixa (
  tenant_id          uuid NOT NULL REFERENCES lumia.tenant(id),
  id                 uuid NOT NULL,
  estabelecimento_id uuid NOT NULL,
  terminal_id        uuid NOT NULL,
  numero             integer NOT NULL,
  status             lumia.status_sessao_caixa NOT NULL DEFAULT 'ABERTA',
  -- Quem abriu, quando, e com quanto de fundo de troco. Tudo nomeado.
  aberta_por         uuid NOT NULL,
  aberta_em          timestamptz NOT NULL DEFAULT now(),
  fundo_troco        lumia.valor_monetario NOT NULL DEFAULT 0,
  moeda              lumia.moeda NOT NULL DEFAULT 'BRL',
  -- Data comercial no fuso do estabelecimento: o turno da virada não vaza.
  data_comercial     date NOT NULL,
  -- Conferência declarada pelo operador; apuração feita pelo gestor.
  conferida_por      uuid,
  conferida_em       timestamptz,
  apurada_por        uuid,
  apurada_em         timestamptz,
  fechada_em         timestamptz,
  observacao_abertura text,
  observacao_fechamento text,
  finalidade         lumia.finalidade_dado NOT NULL DEFAULT 'REAL',
  criado_em          timestamptz NOT NULL DEFAULT now(),
  atualizado_em      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_sc_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT fk_sc_terminal FOREIGN KEY (tenant_id, terminal_id)
    REFERENCES lumia.terminal_caixa (tenant_id, id),
  CONSTRAINT fk_sc_abriu FOREIGN KEY (tenant_id, aberta_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_sc_conferiu FOREIGN KEY (tenant_id, conferida_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_sc_apurou FOREIGN KEY (tenant_id, apurada_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT sc_fundo_nao_negativo CHECK (fundo_troco >= 0),
  CONSTRAINT sc_fechada_tem_data CHECK (
    (status IN ('FECHADA','FECHADA_COM_DIVERGENCIA')) = (fechada_em IS NOT NULL)
  ),
  CONSTRAINT sc_conferencia_completa CHECK ((conferida_por IS NULL) = (conferida_em IS NULL)),
  CONSTRAINT sc_apuracao_completa CHECK ((apurada_por IS NULL) = (apurada_em IS NULL)),
  -- Quem apura não pode ser quem conferiu: segregação de funções.
  CONSTRAINT sc_segregacao_de_funcoes CHECK (
    apurada_por IS NULL OR conferida_por IS NULL OR apurada_por <> conferida_por
  )
);

CREATE UNIQUE INDEX ux_sc_numero ON lumia.sessao_caixa (tenant_id, numero);
-- Um terminal só pode ter UMA sessão aberta por vez. Garantido pelo banco.
CREATE UNIQUE INDEX ux_sc_terminal_aberto ON lumia.sessao_caixa (tenant_id, terminal_id)
  WHERE status IN ('ABERTA','EM_CONFERENCIA');
CREATE INDEX ix_sc_dia ON lumia.sessao_caixa (tenant_id, estabelecimento_id, data_comercial);
CREATE INDEX ix_sc_sync ON lumia.sessao_caixa (tenant_id, atualizado_em);
SELECT lumia.aplicar_rls('lumia.sessao_caixa');

COMMENT ON CONSTRAINT sc_segregacao_de_funcoes ON lumia.sessao_caixa IS
  'Quem contou o dinheiro não pode ser quem confere a contagem contra o '
  'esperado. Sem essa separação, a conferência cega perde o sentido.';

CREATE OR REPLACE FUNCTION lumia.tg_sessao_caixa_data() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_fuso text;
BEGIN
  SELECT fuso INTO v_fuso FROM lumia.estabelecimento
   WHERE tenant_id = NEW.tenant_id AND no_org_id = NEW.estabelecimento_id;
  IF v_fuso IS NULL THEN
    RAISE EXCEPTION 'Estabelecimento % não encontrado', NEW.estabelecimento_id;
  END IF;
  NEW.data_comercial := (NEW.aberta_em AT TIME ZONE v_fuso)::date;
  NEW.atualizado_em  := now();
  RETURN NEW;
END; $$;

CREATE TRIGGER tg_sessao_caixa_data
  BEFORE INSERT OR UPDATE OF aberta_em, estabelecimento_id ON lumia.sessao_caixa
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_sessao_caixa_data();

-- =============================================================================
-- PARTE 2 — Movimentos: o livro append-only
-- =============================================================================

CREATE TYPE lumia.tipo_movimento_caixa AS ENUM (
  'FUNDO_TROCO',   -- abertura: dinheiro que entra para dar troco
  'SUPRIMENTO',    -- reforço de troco durante o turno
  'SANGRIA',       -- retirada por segurança ou depósito
  'RECEBIMENTO',   -- pagamento de comanda
  'TROCO',         -- troco devolvido ao cliente
  'ESTORNO',       -- cancelamento de recebimento: lançamento NOVO, sinal oposto
  'AJUSTE'         -- correção aprovada, sempre justificada
);

CREATE TYPE lumia.meio_pagamento AS ENUM (
  'DINHEIRO', 'PIX', 'CARTAO_DEBITO', 'CARTAO_CREDITO', 'VOUCHER',
  'TRANSFERENCIA', 'CREDITO_CLIENTE', 'GIFT_CARD', 'CORTESIA'
);

CREATE TABLE lumia.movimento_caixa (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  sessao_caixa_id uuid NOT NULL,
  sequencia       integer NOT NULL,
  tipo            lumia.tipo_movimento_caixa NOT NULL,
  meio_pagamento  lumia.meio_pagamento NOT NULL,
  -- Sinal explícito: entra (+) ou sai (-) da gaveta. Guardar o sinal evita
  -- que a interpretação do tipo fique espalhada por dezenas de consultas.
  valor           lumia.valor_monetario NOT NULL,
  moeda           lumia.moeda NOT NULL DEFAULT 'BRL',
  -- Só o dinheiro em espécie está fisicamente na gaveta. Cartão e PIX entram
  -- no total do turno mas são conciliados com o adquirente, não contados.
  afeta_gaveta    boolean NOT NULL,
  ocorrido_em     timestamptz NOT NULL DEFAULT now(),
  registrado_por  uuid NOT NULL,
  -- Sangria e ajuste exigem motivo; sem ele o lançamento não entra.
  motivo          text,
  autorizado_por  uuid,
  -- Rastro de origem
  comanda_id      uuid,
  movimento_estornado_id uuid,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_mc_sessao FOREIGN KEY (tenant_id, sessao_caixa_id)
    REFERENCES lumia.sessao_caixa (tenant_id, id),
  CONSTRAINT fk_mc_registrou FOREIGN KEY (tenant_id, registrado_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_mc_autorizou FOREIGN KEY (tenant_id, autorizado_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_mc_estornado FOREIGN KEY (tenant_id, movimento_estornado_id)
    REFERENCES lumia.movimento_caixa (tenant_id, id),
  CONSTRAINT mc_valor_positivo CHECK (valor > 0),
  -- Sangria, estorno e ajuste sempre com motivo escrito.
  CONSTRAINT mc_motivo_obrigatorio CHECK (
    tipo NOT IN ('SANGRIA','ESTORNO','AJUSTE') OR (motivo IS NOT NULL AND length(btrim(motivo)) >= 5)
  ),
  -- Sangria e ajuste exigem um segundo par de olhos.
  CONSTRAINT mc_autorizacao_obrigatoria CHECK (
    tipo NOT IN ('SANGRIA','AJUSTE') OR autorizado_por IS NOT NULL
  ),
  CONSTRAINT mc_estorno_referencia CHECK (
    (tipo = 'ESTORNO') = (movimento_estornado_id IS NOT NULL)
  ),
  -- Fundo de troco e sangria são sempre espécie.
  CONSTRAINT mc_especie_coerente CHECK (
    tipo NOT IN ('FUNDO_TROCO','SUPRIMENTO','SANGRIA','TROCO')
    OR (meio_pagamento = 'DINHEIRO' AND afeta_gaveta)
  )
);

CREATE UNIQUE INDEX ux_mc_sequencia ON lumia.movimento_caixa (tenant_id, sessao_caixa_id, sequencia);
CREATE INDEX ix_mc_sessao ON lumia.movimento_caixa (tenant_id, sessao_caixa_id, ocorrido_em);
CREATE INDEX ix_mc_comanda ON lumia.movimento_caixa (tenant_id, comanda_id) WHERE comanda_id IS NOT NULL;
SELECT lumia.aplicar_rls('lumia.movimento_caixa');

COMMENT ON TABLE lumia.movimento_caixa IS
  'Livro append-only do caixa. Nenhuma linha é editada ou apagada: corrigir é '
  'lançar um ESTORNO ou AJUSTE apontando para o lançamento original. O saldo é '
  'sempre derivado da soma — nunca uma coluna que alguém possa "acertar".';
COMMENT ON COLUMN lumia.movimento_caixa.afeta_gaveta IS
  'Só espécie está fisicamente na gaveta. Cartão e PIX compõem o faturamento do '
  'turno mas são conferidos contra o adquirente, não contados à mão.';

-- Impede UPDATE e DELETE: o livro é imutável, no banco e não só por convenção.
CREATE OR REPLACE FUNCTION lumia.tg_movimento_imutavel() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'movimento_caixa é append-only: use ESTORNO ou AJUSTE'
    USING HINT = 'Corrigir dinheiro por UPDATE destrói a trilha de auditoria.';
END; $$;

CREATE TRIGGER tg_movimento_sem_update
  BEFORE UPDATE OR DELETE ON lumia.movimento_caixa
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_movimento_imutavel();

-- Numeração sequencial por sessão e bloqueio de lançamento em caixa fechado.
CREATE OR REPLACE FUNCTION lumia.tg_movimento_sequencia() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status lumia.status_sessao_caixa;
BEGIN
  SELECT status INTO v_status FROM lumia.sessao_caixa
   WHERE tenant_id = NEW.tenant_id AND id = NEW.sessao_caixa_id FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Sessão de caixa % não existe', NEW.sessao_caixa_id;
  END IF;
  IF v_status <> 'ABERTA' THEN
    RAISE EXCEPTION 'Sessão de caixa não está aberta (status %)', v_status
      USING HINT = 'Lançamento em caixa fechado exige reabertura autorizada.';
  END IF;
  SELECT coalesce(max(sequencia),0) + 1 INTO NEW.sequencia
    FROM lumia.movimento_caixa
   WHERE tenant_id = NEW.tenant_id AND sessao_caixa_id = NEW.sessao_caixa_id;
  RETURN NEW;
END; $$;

CREATE TRIGGER tg_movimento_sequencia
  BEFORE INSERT ON lumia.movimento_caixa
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_movimento_sequencia();

-- Saldo esperado por meio de pagamento. Sempre derivado do livro.
CREATE OR REPLACE FUNCTION lumia.saldo_esperado_caixa(
  p_tenant_id uuid, p_sessao_id uuid
) RETURNS TABLE (meio lumia.meio_pagamento, esperado lumia.valor_monetario, na_gaveta boolean)
LANGUAGE sql STABLE AS $$
  SELECT m.meio_pagamento,
         sum(CASE WHEN m.tipo IN ('FUNDO_TROCO','SUPRIMENTO','RECEBIMENTO')
                  THEN m.valor
                  WHEN m.tipo IN ('SANGRIA','TROCO','ESTORNO')
                  THEN -m.valor
                  ELSE m.valor  -- AJUSTE já vem com o sinal na intenção do motivo
             END)::lumia.valor_monetario,
         bool_or(m.afeta_gaveta)
    FROM lumia.movimento_caixa m
   WHERE m.tenant_id = p_tenant_id AND m.sessao_caixa_id = p_sessao_id
   GROUP BY m.meio_pagamento;
$$;

COMMENT ON FUNCTION lumia.saldo_esperado_caixa IS
  'Esperado = fundo + suprimentos + recebimentos − sangrias − trocos − estornos, '
  'por meio de pagamento. Derivado do livro a cada chamada: não existe coluna de '
  'saldo para alguém ajustar.';

-- =============================================================================
-- PARTE 3 — Fechamento cego
-- =============================================================================
-- O operador declara o que contou. Não vê o esperado nem a diferença — e isso é
-- imposto por GRANT de coluna, não por esconder campo na tela.

CREATE TABLE lumia.conferencia_caixa (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  sessao_caixa_id uuid NOT NULL,
  meio_pagamento  lumia.meio_pagamento NOT NULL,
  -- Escrito pelo operador, às cegas.
  valor_declarado lumia.valor_monetario NOT NULL,
  -- Escrito pelo sistema na apuração. O operador não lê estas colunas.
  valor_esperado  lumia.valor_monetario,
  divergencia     lumia.valor_monetario
    GENERATED ALWAYS AS (valor_declarado - valor_esperado) STORED,
  -- Recontagem: a boa prática manda contar de novo antes de declarar quebra.
  recontagens     smallint NOT NULL DEFAULT 0,
  declarado_em    timestamptz NOT NULL DEFAULT now(),
  declarado_por   uuid NOT NULL,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_cc_sessao FOREIGN KEY (tenant_id, sessao_caixa_id)
    REFERENCES lumia.sessao_caixa (tenant_id, id),
  CONSTRAINT fk_cc_declarou FOREIGN KEY (tenant_id, declarado_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT cc_declarado_nao_negativo CHECK (valor_declarado >= 0),
  CONSTRAINT cc_recontagens_nao_negativas CHECK (recontagens >= 0)
);
CREATE UNIQUE INDEX ux_cc_meio ON lumia.conferencia_caixa (tenant_id, sessao_caixa_id, meio_pagamento);
SELECT lumia.aplicar_rls('lumia.conferencia_caixa');

COMMENT ON TABLE lumia.conferencia_caixa IS
  'Conferência cega. valor_declarado é do operador; valor_esperado e divergencia '
  'são preenchidos na apuração e ficam ILEGÍVEIS para o papel do operador por '
  'GRANT de coluna. Esconder na interface não seria controle — seria decoração.';

-- =============================================================================
-- PARTE 4 — Divergência: registrada, nunca descontada automaticamente
-- =============================================================================

CREATE TYPE lumia.status_divergencia AS ENUM (
  'ABERTA', 'JUSTIFICADA', 'ACEITA_PELA_EMPRESA', 'EM_NEGOCIACAO', 'RESOLVIDA'
);

CREATE TABLE lumia.divergencia_caixa (
  tenant_id        uuid NOT NULL REFERENCES lumia.tenant(id),
  id               uuid NOT NULL,
  sessao_caixa_id  uuid NOT NULL,
  valor_total      lumia.valor_monetario NOT NULL,
  status           lumia.status_divergencia NOT NULL DEFAULT 'ABERTA',
  justificativa    text,
  justificada_por  uuid,
  justificada_em   timestamptz,
  decidida_por     uuid,
  decidida_em      timestamptz,
  decisao          text,
  criado_em        timestamptz NOT NULL DEFAULT now(),
  atualizado_em    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_dc_sessao FOREIGN KEY (tenant_id, sessao_caixa_id)
    REFERENCES lumia.sessao_caixa (tenant_id, id),
  CONSTRAINT fk_dc_justificou FOREIGN KEY (tenant_id, justificada_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT fk_dc_decidiu FOREIGN KEY (tenant_id, decidida_por)
    REFERENCES lumia.profissional (tenant_id, id),
  CONSTRAINT dc_justificativa_completa CHECK (
    (justificada_por IS NULL) = (justificada_em IS NULL)
  ),
  CONSTRAINT dc_decisao_nomeada CHECK (
    status NOT IN ('ACEITA_PELA_EMPRESA','RESOLVIDA')
    OR (decidida_por IS NOT NULL AND decidida_em IS NOT NULL
        AND decisao IS NOT NULL AND length(btrim(decisao)) >= 5)
  )
);
CREATE UNIQUE INDEX ux_dc_sessao ON lumia.divergencia_caixa (tenant_id, sessao_caixa_id);
SELECT lumia.aplicar_rls('lumia.divergencia_caixa');

COMMENT ON TABLE lumia.divergencia_caixa IS
  'Diferença entre contado e esperado. O sistema NÃO gera desconto em folha, '
  'nem débito contra o operador: o art. 462 da CLT protege a integridade '
  'salarial e a jurisprudência sobre desconto de quebra de caixa é dividida. '
  'Aqui ficam o valor, a justificativa e a decisão nomeada de quem decidiu — '
  'a consequência é ato humano documentado, não efeito colateral de software.';

-- =============================================================================
-- PARTE 5 — Operações de caixa
-- =============================================================================

CREATE OR REPLACE FUNCTION lumia.abrir_caixa(
  p_tenant_id   uuid,
  p_terminal_id uuid,
  p_operador_id uuid,
  p_fundo_troco lumia.valor_monetario DEFAULT 0,
  p_observacao  text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_sessao uuid := lumia.uuid_v7();
  v_estab  uuid;
  v_numero integer;
BEGIN
  SELECT estabelecimento_id INTO v_estab FROM lumia.terminal_caixa
   WHERE tenant_id = p_tenant_id AND id = p_terminal_id AND ativo;
  IF v_estab IS NULL THEN
    RAISE EXCEPTION 'Terminal % não existe ou está inativo', p_terminal_id;
  END IF;

  SELECT coalesce(max(numero),0) + 1 INTO v_numero
    FROM lumia.sessao_caixa WHERE tenant_id = p_tenant_id;

  -- O índice parcial ux_sc_terminal_aberto recusa uma segunda sessão aberta
  -- no mesmo terminal: a garantia é do banco, não da tela.
  INSERT INTO lumia.sessao_caixa
    (tenant_id, id, estabelecimento_id, terminal_id, numero, aberta_por,
     fundo_troco, data_comercial, observacao_abertura)
  VALUES (p_tenant_id, v_sessao, v_estab, p_terminal_id, v_numero, p_operador_id,
          p_fundo_troco, '2000-01-01', p_observacao);

  IF p_fundo_troco > 0 THEN
    INSERT INTO lumia.movimento_caixa
      (tenant_id, id, sessao_caixa_id, sequencia, tipo, meio_pagamento, valor,
       afeta_gaveta, registrado_por, motivo)
    VALUES (p_tenant_id, lumia.uuid_v7(), v_sessao, 0, 'FUNDO_TROCO', 'DINHEIRO',
            p_fundo_troco, true, p_operador_id, 'Fundo de troco da abertura');
  END IF;

  RETURN v_sessao;
END; $$;

CREATE OR REPLACE FUNCTION lumia.registrar_sangria(
  p_tenant_id uuid, p_sessao_id uuid, p_valor lumia.valor_monetario,
  p_operador_id uuid, p_autorizador_id uuid, p_motivo text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid := lumia.uuid_v7();
  v_disponivel numeric;
BEGIN
  SELECT coalesce(sum(CASE WHEN tipo IN ('FUNDO_TROCO','SUPRIMENTO','RECEBIMENTO') THEN valor
                           WHEN tipo IN ('SANGRIA','TROCO','ESTORNO') THEN -valor
                           ELSE valor END), 0)
    INTO v_disponivel
    FROM lumia.movimento_caixa
   WHERE tenant_id = p_tenant_id AND sessao_caixa_id = p_sessao_id
     AND afeta_gaveta AND meio_pagamento = 'DINHEIRO';

  IF p_valor > v_disponivel THEN
    RAISE EXCEPTION 'Sangria de % excede o disponível em espécie (%)', p_valor, v_disponivel
      USING HINT = 'A gaveta não pode ficar negativa.';
  END IF;

  INSERT INTO lumia.movimento_caixa
    (tenant_id, id, sessao_caixa_id, sequencia, tipo, meio_pagamento, valor,
     afeta_gaveta, registrado_por, autorizado_por, motivo)
  VALUES (p_tenant_id, v_id, p_sessao_id, 0, 'SANGRIA', 'DINHEIRO', p_valor,
          true, p_operador_id, p_autorizador_id, p_motivo);
  RETURN v_id;
END; $$;

COMMENT ON FUNCTION lumia.registrar_sangria IS
  'Sangria exige motivo e autorizador (constraints) e nunca deixa a gaveta '
  'negativa. Retirada não registrada é a origem mais comum de quebra de caixa.';

-- Passo 1 do fechamento: o operador declara o que contou, às cegas.
CREATE OR REPLACE FUNCTION lumia.declarar_conferencia(
  p_tenant_id uuid, p_sessao_id uuid, p_operador_id uuid,
  p_declaracoes jsonb  -- {"DINHEIRO": 1234.50, "PIX": 800.00, ...}
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_meio text; v_valor numeric;
BEGIN
  IF (SELECT status FROM lumia.sessao_caixa
       WHERE tenant_id = p_tenant_id AND id = p_sessao_id) <> 'ABERTA' THEN
    RAISE EXCEPTION 'Só é possível declarar conferência em sessão ABERTA';
  END IF;

  FOR v_meio, v_valor IN SELECT * FROM jsonb_each_text(p_declaracoes) LOOP
    INSERT INTO lumia.conferencia_caixa
      (tenant_id, id, sessao_caixa_id, meio_pagamento, valor_declarado, declarado_por)
    VALUES (p_tenant_id, lumia.uuid_v7(), p_sessao_id, v_meio::lumia.meio_pagamento,
            v_valor::numeric, p_operador_id);
  END LOOP;

  UPDATE lumia.sessao_caixa
     SET status = 'EM_CONFERENCIA', conferida_por = p_operador_id,
         conferida_em = now(), atualizado_em = now()
   WHERE tenant_id = p_tenant_id AND id = p_sessao_id;
END; $$;

-- Passo 2: o gestor apura. Só aqui o esperado é revelado e comparado.
CREATE OR REPLACE FUNCTION lumia.apurar_fechamento(
  p_tenant_id uuid, p_sessao_id uuid, p_gestor_id uuid
) RETURNS lumia.valor_monetario
LANGUAGE plpgsql AS $$
DECLARE v_total_div numeric := 0;
BEGIN
  IF (SELECT status FROM lumia.sessao_caixa
       WHERE tenant_id = p_tenant_id AND id = p_sessao_id) <> 'EM_CONFERENCIA' THEN
    RAISE EXCEPTION 'A sessão precisa estar EM_CONFERENCIA para ser apurada';
  END IF;

  -- Preenche o esperado a partir do livro; a divergência é coluna gerada.
  UPDATE lumia.conferencia_caixa c
     SET valor_esperado = coalesce(s.esperado, 0)
    FROM (SELECT * FROM lumia.saldo_esperado_caixa(p_tenant_id, p_sessao_id)) s
   WHERE c.tenant_id = p_tenant_id AND c.sessao_caixa_id = p_sessao_id
     AND c.meio_pagamento = s.meio;

  -- Meios declarados que não tiveram movimento: esperado zero.
  UPDATE lumia.conferencia_caixa
     SET valor_esperado = 0
   WHERE tenant_id = p_tenant_id AND sessao_caixa_id = p_sessao_id
     AND valor_esperado IS NULL;

  SELECT coalesce(sum(divergencia),0) INTO v_total_div
    FROM lumia.conferencia_caixa
   WHERE tenant_id = p_tenant_id AND sessao_caixa_id = p_sessao_id;

  IF v_total_div <> 0 THEN
    INSERT INTO lumia.divergencia_caixa
      (tenant_id, id, sessao_caixa_id, valor_total)
    VALUES (p_tenant_id, lumia.uuid_v7(), p_sessao_id, v_total_div);
  END IF;

  UPDATE lumia.sessao_caixa
     SET status = CASE WHEN v_total_div <> 0
                       THEN 'FECHADA_COM_DIVERGENCIA'::lumia.status_sessao_caixa
                       ELSE 'FECHADA'::lumia.status_sessao_caixa END,
         apurada_por = p_gestor_id, apurada_em = now(),
         fechada_em = now(), atualizado_em = now()
   WHERE tenant_id = p_tenant_id AND id = p_sessao_id;

  RETURN v_total_div;
END; $$;

COMMENT ON FUNCTION lumia.apurar_fechamento IS
  'Revela o esperado e compara com o declarado. Divergência diferente de zero '
  'abre um registro para justificativa e decisão nomeada — e NADA além disso: '
  'nenhum débito é gerado contra ninguém.';

-- =============================================================================
-- PARTE 6 — Papel do operador: a conferência cega imposta por GRANT
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lumia_caixa_operador') THEN
    CREATE ROLE lumia_caixa_operador NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lumia_caixa_gestor') THEN
    CREATE ROLE lumia_caixa_gestor NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA lumia TO lumia_caixa_operador, lumia_caixa_gestor;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA lumia TO lumia_caixa_operador, lumia_caixa_gestor;

-- O operador opera o caixa...
GRANT SELECT, INSERT ON lumia.movimento_caixa TO lumia_caixa_operador;
GRANT SELECT, INSERT, UPDATE ON lumia.sessao_caixa TO lumia_caixa_operador;
GRANT INSERT ON lumia.conferencia_caixa TO lumia_caixa_operador;

-- ...mas na conferência só enxerga o que ele mesmo declarou.
-- Sem SELECT em valor_esperado e divergencia: a cegueira é do banco.
GRANT SELECT (tenant_id, id, sessao_caixa_id, meio_pagamento, valor_declarado,
              recontagens, declarado_em, declarado_por, criado_em)
  ON lumia.conferencia_caixa TO lumia_caixa_operador;

-- O gestor apura e enxerga tudo.
GRANT SELECT, INSERT, UPDATE ON lumia.conferencia_caixa TO lumia_caixa_gestor;
GRANT SELECT, INSERT, UPDATE ON lumia.divergencia_caixa TO lumia_caixa_gestor;
GRANT SELECT, INSERT, UPDATE ON lumia.sessao_caixa TO lumia_caixa_gestor;
GRANT SELECT, INSERT ON lumia.movimento_caixa TO lumia_caixa_gestor;
GRANT SELECT ON ALL TABLES IN SCHEMA lumia TO lumia_caixa_gestor;

-- O operador não vê divergência de jeito nenhum.
REVOKE ALL ON lumia.divergencia_caixa FROM lumia_caixa_operador;

COMMIT;
