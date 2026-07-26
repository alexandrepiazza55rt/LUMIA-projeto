-- =============================================================================
-- LUMIA · 0003 — Meu Catálogo
-- =============================================================================
-- Implementa a decisão irreversível nº 2 ("Catálogo antes de agenda e comanda")
-- e a nº 5 ("Vigência em preço, comissão, custo e alíquota").
--
-- Regra que este schema torna impossível violar:
--   nenhum item de agenda ou de comanda grava "descrição do atendimento" em
--   texto livre nem preço solto. Item referencia servico_id ou produto_id.
--
-- Vigência (SCD-2): preço, custo e base de comissão nunca sofrem UPDATE de
-- valor. Cria-se nova versão e fecha-se a anterior. A operação lê a versão
-- vigente na data do fato; a auditoria lê a versão que valia naquela data.
-- Sobreposição de vigência é impedida por EXCLUDE, não por disciplina.
-- =============================================================================

BEGIN;

-- =============================================================================
-- PARTE 1 — Taxonomia canônica (fora do escopo de tenant)
-- =============================================================================
-- Permite comparar "Escova" do salão A com "Escova modeladora" do salão B no
-- benchmark setorial. Referência versionada e compartilhada: sem tenant_id.

CREATE TABLE referencia.taxonomia_versao (
  id            uuid PRIMARY KEY,
  versao        text NOT NULL UNIQUE,
  vigente_desde date NOT NULL,
  publicada_em  timestamptz NOT NULL DEFAULT now(),
  notas         text
);

CREATE TYPE referencia.vertical AS ENUM (
  'SALAO', 'BARBEARIA', 'CLINICA_ESTETICA', 'STUDIO_UNHAS',
  'STUDIO_CILIOS', 'STUDIO_SOBRANCELHAS', 'DEPILACAO', 'SPA', 'MAQUIAGEM'
);

CREATE TABLE referencia.servico_canonico (
  id                uuid PRIMARY KEY,
  taxonomia_versao_id uuid NOT NULL REFERENCES referencia.taxonomia_versao(id),
  codigo            lumia.slug NOT NULL,
  nome              text NOT NULL,
  vertical          referencia.vertical NOT NULL,
  categoria_pai     lumia.slug,
  -- Referências fiscais sugeridas para o serviço canônico. O tenant pode
  -- sobrescrever: a lei é do município dele, não do nosso dicionário.
  item_lc116_sugerido   text,
  codigo_nbs_sugerido   text,
  duracao_tipica_min    smallint,
  UNIQUE (taxonomia_versao_id, codigo)
);

CREATE TABLE referencia.produto_canonico (
  id                uuid PRIMARY KEY,
  taxonomia_versao_id uuid NOT NULL REFERENCES referencia.taxonomia_versao(id),
  codigo            lumia.slug NOT NULL,
  nome              text NOT NULL,
  categoria         text NOT NULL,
  ncm_sugerido      char(8),
  UNIQUE (taxonomia_versao_id, codigo)
);

COMMENT ON TABLE referencia.servico_canonico IS
  'Dicionário LUMIA de serviços. Alimenta (a) catálogo inicial por vertical no '
  'onboarding, (b) sugestão assistida por IA no mapeamento e (c) comparabilidade '
  'do benchmark setorial. Versionado: mudar o dicionário não reescreve o '
  'histórico já classificado.';

-- =============================================================================
-- PARTE 2 — Categorias e serviços
-- =============================================================================

CREATE TABLE lumia.categoria_catalogo (
  tenant_id     uuid NOT NULL REFERENCES lumia.tenant(id),
  id            uuid NOT NULL,
  pai_id        uuid,
  caminho       ltree NOT NULL,
  nome          text NOT NULL,
  ordem         smallint NOT NULL DEFAULT 0,
  aplica_servico boolean NOT NULL DEFAULT true,
  aplica_produto boolean NOT NULL DEFAULT false,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  removido_em   timestamptz,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_categoria_pai FOREIGN KEY (tenant_id, pai_id)
    REFERENCES lumia.categoria_catalogo (tenant_id, id)
);

CREATE INDEX ix_categoria_pai     ON lumia.categoria_catalogo (tenant_id, pai_id);
CREATE INDEX ix_categoria_caminho ON lumia.categoria_catalogo USING gist (caminho);
CREATE INDEX ix_categoria_sync    ON lumia.categoria_catalogo (tenant_id, atualizado_em);

SELECT lumia.aplicar_rls('lumia.categoria_catalogo');

CREATE OR REPLACE FUNCTION lumia.tg_categoria_caminho() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_pai_caminho ltree;
  v_rotulo text := 'c' || replace(NEW.id::text, '-', '');
BEGIN
  IF NEW.pai_id IS NULL THEN
    NEW.caminho := v_rotulo::ltree;
  ELSE
    SELECT caminho INTO v_pai_caminho FROM lumia.categoria_catalogo
      WHERE tenant_id = NEW.tenant_id AND id = NEW.pai_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Categoria pai % não existe no tenant %', NEW.pai_id, NEW.tenant_id;
    END IF;
    NEW.caminho := v_pai_caminho || v_rotulo::ltree;
  END IF;
  NEW.atualizado_em := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER tg_categoria_caminho
  BEFORE INSERT OR UPDATE OF pai_id ON lumia.categoria_catalogo
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_categoria_caminho();

-- -----------------------------------------------------------------------------
-- Serviço
-- -----------------------------------------------------------------------------
CREATE TABLE lumia.servico (
  tenant_id           uuid NOT NULL REFERENCES lumia.tenant(id),
  id                  uuid NOT NULL,
  categoria_id        uuid,
  numero              integer NOT NULL,
  nome                text NOT NULL,
  descricao_publica   text,
  -- ---- Tempo por etapa: o que torna o motor de disponibilidade utilizável ----
  -- Uma coloração ocupa o profissional 40 min, depois 30 min de pausa química
  -- (em que ele PODE atender outra pessoa), depois 20 min de finalização.
  duracao_ativa_min       smallint NOT NULL,
  duracao_processamento_min smallint NOT NULL DEFAULT 0,
  duracao_finalizacao_min smallint NOT NULL DEFAULT 0,
  duracao_setup_min       smallint NOT NULL DEFAULT 0,
  duracao_higienizacao_min smallint NOT NULL DEFAULT 0,
  -- Durante a pausa química o recurso continua ocupado, o profissional não.
  libera_profissional_no_processamento boolean NOT NULL DEFAULT true,
  libera_recurso_no_processamento      boolean NOT NULL DEFAULT false,
  -- ---- Regras clínicas e de recorrência ----
  intervalo_minimo_entre_sessoes_dias smallint,
  exige_anamnese      boolean NOT NULL DEFAULT false,
  exige_termo_consentimento boolean NOT NULL DEFAULT false,
  exige_responsavel_tecnico boolean NOT NULL DEFAULT false,
  -- ---- Canais ----
  publicavel_online   boolean NOT NULL DEFAULT false,
  exige_sinal_online  boolean NOT NULL DEFAULT false,
  -- ---- Classificação canônica ----
  servico_canonico_id uuid REFERENCES referencia.servico_canonico(id),
  canonico_confirmado_por_humano boolean NOT NULL DEFAULT false,
  -- ---- Ciclo de vida e importação ----
  ativo               boolean NOT NULL DEFAULT true,
  sistema_origem      text,
  id_externo          text,
  origem              lumia.origem_registro NOT NULL DEFAULT 'MANUAL',
  criado_em           timestamptz NOT NULL DEFAULT now(),
  atualizado_em       timestamptz NOT NULL DEFAULT now(),
  removido_em         timestamptz,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_servico_categoria FOREIGN KEY (tenant_id, categoria_id)
    REFERENCES lumia.categoria_catalogo (tenant_id, id),
  CONSTRAINT servico_duracao_ativa_positiva CHECK (duracao_ativa_min > 0),
  CONSTRAINT servico_duracoes_nao_negativas CHECK (
    duracao_processamento_min >= 0 AND duracao_finalizacao_min >= 0
    AND duracao_setup_min >= 0 AND duracao_higienizacao_min >= 0
  ),
  CONSTRAINT servico_finalizacao_exige_processamento CHECK (
    duracao_finalizacao_min = 0 OR duracao_processamento_min > 0
  ),
  CONSTRAINT servico_importacao_completa CHECK (
    (sistema_origem IS NULL) = (id_externo IS NULL)
  )
);

CREATE UNIQUE INDEX ux_servico_numero ON lumia.servico (tenant_id, numero);
CREATE INDEX ix_servico_categoria ON lumia.servico (tenant_id, categoria_id)
  WHERE removido_em IS NULL;
CREATE INDEX ix_servico_online ON lumia.servico (tenant_id)
  WHERE publicavel_online AND ativo AND removido_em IS NULL;
CREATE INDEX ix_servico_sync ON lumia.servico (tenant_id, atualizado_em);
CREATE INDEX ix_servico_canonico ON lumia.servico (tenant_id, servico_canonico_id)
  WHERE servico_canonico_id IS NOT NULL;
CREATE UNIQUE INDEX ux_servico_externo
  ON lumia.servico (tenant_id, sistema_origem, id_externo) WHERE id_externo IS NOT NULL;
-- Busca por nome em base grande, sem derrubar o transacional.
CREATE INDEX ix_servico_nome_trgm ON lumia.servico (tenant_id, lower(nome));

SELECT lumia.aplicar_rls('lumia.servico');

COMMENT ON TABLE lumia.servico IS
  'O nó raiz do sistema. Agenda agenda um serviço; comanda lança um serviço; '
  'comissão incide sobre um serviço; DRE apura margem por serviço; a Bússola de '
  'Preços precifica um serviço. Sem FK para cá, o histórico não se reamarra.';
COMMENT ON COLUMN lumia.servico.duracao_processamento_min IS
  'Pausa química (coloração, alisamento, permanente). Regra de domínio específica '
  'do setor: durante a pausa o profissional pode atender outro cliente, mas a '
  'cadeira segue ocupada. Sem modelar isto, a agenda perde 30% da capacidade real.';
COMMENT ON COLUMN lumia.servico.canonico_confirmado_por_humano IS
  'Distingue mapeamento sugerido por IA de mapeamento confirmado por pessoa. O '
  'benchmark setorial só considera o que foi confirmado.';

-- -----------------------------------------------------------------------------
-- Variantes: "escova curta / média / longa" é o MESMO serviço com preço e
-- tempo diferentes — não três serviços distintos, ou o histórico fragmenta.
-- -----------------------------------------------------------------------------
CREATE TABLE lumia.servico_variante (
  tenant_id      uuid NOT NULL,
  id             uuid NOT NULL,
  servico_id     uuid NOT NULL,
  nome           text NOT NULL,
  ordem          smallint NOT NULL DEFAULT 0,
  -- Ajustes relativos ao serviço base.
  delta_duracao_ativa_min smallint NOT NULL DEFAULT 0,
  fator_consumo  numeric(6,3) NOT NULL DEFAULT 1.000,
  padrao         boolean NOT NULL DEFAULT false,
  ativo          boolean NOT NULL DEFAULT true,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_variante_servico FOREIGN KEY (tenant_id, servico_id)
    REFERENCES lumia.servico (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT variante_fator_positivo CHECK (fator_consumo > 0)
);

CREATE INDEX ix_variante_servico ON lumia.servico_variante (tenant_id, servico_id);
CREATE UNIQUE INDEX ux_variante_padrao
  ON lumia.servico_variante (tenant_id, servico_id) WHERE padrao;

SELECT lumia.aplicar_rls('lumia.servico_variante');

COMMENT ON COLUMN lumia.servico_variante.fator_consumo IS
  'Multiplica as doses da ficha técnica: cabelo longo gasta 1,8x a tinta do '
  'curto. É daqui que sai o custo direto correto por variante.';

-- -----------------------------------------------------------------------------
-- Recursos exigidos pelo serviço
-- -----------------------------------------------------------------------------
CREATE TABLE lumia.servico_recurso_exigido (
  tenant_id      uuid NOT NULL,
  id             uuid NOT NULL,
  servico_id     uuid NOT NULL,
  tipo_unidade   lumia.tipo_unidade NOT NULL,
  quantidade     smallint NOT NULL DEFAULT 1,
  -- Quando o serviço exige um recurso ESPECÍFICO (o laser, não "um equipamento").
  unidade_especifica_id uuid,
  etapa_ocupacao text NOT NULL DEFAULT 'TODA',
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_sre_servico FOREIGN KEY (tenant_id, servico_id)
    REFERENCES lumia.servico (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_sre_unidade FOREIGN KEY (tenant_id, unidade_especifica_id)
    REFERENCES lumia.unidade_operacional (tenant_id, no_org_id),
  CONSTRAINT sre_quantidade_positiva CHECK (quantidade > 0),
  CONSTRAINT sre_etapa_valida CHECK (etapa_ocupacao IN ('TODA','ATIVA','PROCESSAMENTO','FINALIZACAO'))
);

CREATE INDEX ix_sre_servico ON lumia.servico_recurso_exigido (tenant_id, servico_id);

SELECT lumia.aplicar_rls('lumia.servico_recurso_exigido');

COMMENT ON TABLE lumia.servico_recurso_exigido IS
  'Alimenta a resolução de conflito multi-recurso da agenda: profissional × sala '
  '× cadeira × equipamento ao mesmo tempo. A garantia de não-sobreposição fica '
  'no banco (migration da agenda), não em lock de Redis.';

-- -----------------------------------------------------------------------------
-- Habilidade exigida (o vínculo com profissional vive no módulo Minha Equipe)
-- -----------------------------------------------------------------------------
CREATE TABLE lumia.habilidade (
  tenant_id     uuid NOT NULL REFERENCES lumia.tenant(id),
  id            uuid NOT NULL,
  nome          text NOT NULL,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id)
);
CREATE UNIQUE INDEX ux_habilidade_nome ON lumia.habilidade (tenant_id, lower(nome));
SELECT lumia.aplicar_rls('lumia.habilidade');

CREATE TABLE lumia.servico_habilidade_exigida (
  tenant_id     uuid NOT NULL,
  id            uuid NOT NULL,
  servico_id    uuid NOT NULL,
  habilidade_id uuid NOT NULL,
  nivel_minimo  smallint NOT NULL DEFAULT 1,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_she_servico FOREIGN KEY (tenant_id, servico_id)
    REFERENCES lumia.servico (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_she_habilidade FOREIGN KEY (tenant_id, habilidade_id)
    REFERENCES lumia.habilidade (tenant_id, id),
  CONSTRAINT she_nivel_faixa CHECK (nivel_minimo BETWEEN 1 AND 5)
);
CREATE UNIQUE INDEX ux_she ON lumia.servico_habilidade_exigida (tenant_id, servico_id, habilidade_id);
SELECT lumia.aplicar_rls('lumia.servico_habilidade_exigida');

-- -----------------------------------------------------------------------------
-- Composição: combos, pacotes e serviços encadeados
-- -----------------------------------------------------------------------------
CREATE TYPE lumia.tipo_composicao AS ENUM (
  'COMBO',      -- vendidos juntos, executados na mesma visita
  'PACOTE',     -- N sessões vendidas antecipadamente (gera passivo no Financeiro)
  'ENCADEADO',  -- ordem obrigatória (ex.: hidratação antes da escova)
  'ADDON'       -- opcional agregado a um serviço principal
);

CREATE TABLE lumia.composicao_servico (
  tenant_id      uuid NOT NULL,
  id             uuid NOT NULL,
  servico_pai_id uuid NOT NULL,
  servico_filho_id uuid NOT NULL,
  tipo           lumia.tipo_composicao NOT NULL,
  quantidade     smallint NOT NULL DEFAULT 1,
  ordem          smallint NOT NULL DEFAULT 0,
  obrigatorio    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_comp_pai FOREIGN KEY (tenant_id, servico_pai_id)
    REFERENCES lumia.servico (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_comp_filho FOREIGN KEY (tenant_id, servico_filho_id)
    REFERENCES lumia.servico (tenant_id, id),
  CONSTRAINT comp_nao_recursiva CHECK (servico_pai_id <> servico_filho_id),
  CONSTRAINT comp_quantidade_positiva CHECK (quantidade > 0)
);

CREATE INDEX ix_comp_pai ON lumia.composicao_servico (tenant_id, servico_pai_id);
CREATE UNIQUE INDEX ux_comp ON lumia.composicao_servico
  (tenant_id, servico_pai_id, servico_filho_id, tipo);

SELECT lumia.aplicar_rls('lumia.composicao_servico');

COMMENT ON COLUMN lumia.composicao_servico.tipo IS
  'PACOTE é o caso sensível: dinheiro recebido antes da execução é PASSIVO, não '
  'faturamento (decisão irreversível nº 7). O saldo de sessões vive no Financeiro; '
  'aqui fica apenas a definição do que o pacote contém.';

-- =============================================================================
-- PARTE 3 — Produtos
-- =============================================================================

-- A natureza declarada na origem é o que permite separar receita de serviço
-- (ISS/NFS-e) de receita de mercadoria (ICMS/NFC-e) e CMV de insumo de cabine.
CREATE TYPE lumia.natureza_produto AS ENUM ('REVENDA', 'INSUMO', 'MISTO');

CREATE TABLE lumia.unidade_medida (
  codigo      lumia.slug PRIMARY KEY,
  nome        text NOT NULL,
  grandeza    text NOT NULL,
  fator_para_base numeric(18,9) NOT NULL,
  unidade_base lumia.slug NOT NULL,
  CONSTRAINT um_fator_positivo CHECK (fator_para_base > 0),
  CONSTRAINT um_grandeza_valida CHECK (grandeza IN ('VOLUME','MASSA','UNIDADE','COMPRIMENTO','TEMPO'))
);

COMMENT ON TABLE lumia.unidade_medida IS
  'Normalização de unidades (convenção da taxonomia canônica). Sem tabela de '
  'conversão, "frasco de 1 L" e "dose de 30 ml" não fecham e o CMV mente.';

INSERT INTO lumia.unidade_medida (codigo, nome, grandeza, fator_para_base, unidade_base) VALUES
  ('ml','Mililitro','VOLUME',1,'ml'), ('l','Litro','VOLUME',1000,'ml'),
  ('g','Gramas','MASSA',1,'g'),       ('kg','Quilograma','MASSA',1000,'g'),
  ('un','Unidade','UNIDADE',1,'un'),  ('par','Par','UNIDADE',2,'un'),
  ('cm','Centímetro','COMPRIMENTO',1,'cm'), ('m','Metro','COMPRIMENTO',100,'cm'),
  ('disparo','Disparo','UNIDADE',1,'disparo'),
  ('min','Minuto','TEMPO',1,'min'),   ('h','Hora','TEMPO',60,'min');

CREATE TABLE lumia.produto (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  categoria_id    uuid,
  numero          integer NOT NULL,
  natureza        lumia.natureza_produto NOT NULL,
  sku             text NOT NULL,
  gtin            text,
  nome            text NOT NULL,
  marca           text,
  linha           text,
  -- Compra em frasco, consome em dose: o fator é o que liga os dois mundos.
  unidade_compra_codigo   lumia.slug NOT NULL REFERENCES lumia.unidade_medida(codigo),
  unidade_consumo_codigo  lumia.slug NOT NULL REFERENCES lumia.unidade_medida(codigo),
  fator_conversao numeric(18,6) NOT NULL DEFAULT 1,
  -- Rastreabilidade sanitária: cosmético é perecível e com lote rastreável.
  controla_lote     boolean NOT NULL DEFAULT false,
  controla_validade boolean NOT NULL DEFAULT false,
  registro_anvisa   text,
  notificacao_anvisa text,
  produto_canonico_id uuid REFERENCES referencia.produto_canonico(id),
  canonico_confirmado_por_humano boolean NOT NULL DEFAULT false,
  ativo           boolean NOT NULL DEFAULT true,
  sistema_origem  text,
  id_externo      text,
  origem          lumia.origem_registro NOT NULL DEFAULT 'MANUAL',
  criado_em       timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now(),
  removido_em     timestamptz,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_produto_categoria FOREIGN KEY (tenant_id, categoria_id)
    REFERENCES lumia.categoria_catalogo (tenant_id, id),
  CONSTRAINT produto_fator_positivo CHECK (fator_conversao > 0),
  CONSTRAINT produto_gtin_digitos CHECK (gtin IS NULL OR gtin ~ '^[0-9]{8,14}$'),
  CONSTRAINT produto_validade_exige_lote CHECK (NOT controla_validade OR controla_lote),
  CONSTRAINT produto_importacao_completa CHECK (
    (sistema_origem IS NULL) = (id_externo IS NULL)
  )
);

CREATE UNIQUE INDEX ux_produto_numero ON lumia.produto (tenant_id, numero);
CREATE UNIQUE INDEX ux_produto_sku ON lumia.produto (tenant_id, lower(sku))
  WHERE removido_em IS NULL;
CREATE INDEX ix_produto_gtin ON lumia.produto (tenant_id, gtin) WHERE gtin IS NOT NULL;
CREATE INDEX ix_produto_natureza ON lumia.produto (tenant_id, natureza)
  WHERE ativo AND removido_em IS NULL;
CREATE INDEX ix_produto_sync ON lumia.produto (tenant_id, atualizado_em);
CREATE UNIQUE INDEX ux_produto_externo
  ON lumia.produto (tenant_id, sistema_origem, id_externo) WHERE id_externo IS NOT NULL;

SELECT lumia.aplicar_rls('lumia.produto');

COMMENT ON COLUMN lumia.produto.natureza IS
  'REVENDA = venda no balcão (mercadoria, NFC-e/ICMS). INSUMO = consumido no '
  'atendimento (compõe custo do serviço). MISTO = ambos. Declarar na origem é o '
  'que impede o DRE, o CMV e os dois regimes de nota de nascerem errados.';
COMMENT ON COLUMN lumia.produto.fator_conversao IS
  'Quantas unidades de consumo cabem em uma unidade de compra. Frasco de 1 L '
  'consumido em ml: unidade_compra=l, unidade_consumo=ml, fator=1000.';

-- -----------------------------------------------------------------------------
-- Custo do produto — SCD-2. Nunca UPDATE de valor.
-- -----------------------------------------------------------------------------
CREATE TABLE lumia.produto_custo_versao (
  tenant_id     uuid NOT NULL,
  id            uuid NOT NULL,
  produto_id    uuid NOT NULL,
  -- Custo pode diferir por estabelecimento (frete, ICMS-ST, fornecedor local).
  estabelecimento_id uuid,
  custo_unitario_compra lumia.valor_monetario NOT NULL,
  moeda         lumia.moeda NOT NULL DEFAULT 'BRL',
  vigencia      daterange NOT NULL,
  vigente_de    date GENERATED ALWAYS AS (lower(vigencia)) STORED,
  vigente_ate   date GENERATED ALWAYS AS (upper(vigencia)) STORED,
  motivo        text,
  registrado_em timestamptz NOT NULL DEFAULT now(),
  registrado_por uuid,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_pcv_produto FOREIGN KEY (tenant_id, produto_id)
    REFERENCES lumia.produto (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_pcv_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT pcv_custo_nao_negativo CHECK (custo_unitario_compra >= 0),
  CONSTRAINT pcv_vigencia_fechada_a_esquerda CHECK (lower_inc(vigencia) AND NOT upper_inc(vigencia)),
  CONSTRAINT pcv_vigencia_nao_vazia CHECK (NOT isempty(vigencia)),
  -- Duas versões do mesmo custo não podem valer ao mesmo tempo. Garantido pelo
  -- banco: nenhuma condição de corrida na aplicação consegue furar isto.
  EXCLUDE USING gist (
    tenant_id WITH =, produto_id WITH =,
    coalesce(estabelecimento_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    vigencia WITH &&
  )
);

CREATE INDEX ix_pcv_lookup ON lumia.produto_custo_versao
  (tenant_id, produto_id, vigente_de DESC);

SELECT lumia.aplicar_rls('lumia.produto_custo_versao');

COMMENT ON TABLE lumia.produto_custo_versao IS
  'SCD-2 do custo (decisão irreversível nº 5). O reajuste de julho NÃO pode '
  'reescrever o relatório de março: a operação lê a versão vigente na data do '
  'fato. Um UPDATE de valor destruiria a informação da vigência sem backfill '
  'possível.';

-- =============================================================================
-- PARTE 4 — Ficha técnica de consumo (a ponte serviço → produto)
-- =============================================================================
-- É a ÚNICA fonte possível do custo direto do serviço. Sem ela, a Bússola de
-- Preços e o Mapa da Lucratividade precificam sobre custo estimado no chute.

CREATE TABLE lumia.ficha_tecnica (
  tenant_id     uuid NOT NULL,
  id            uuid NOT NULL,
  servico_id    uuid NOT NULL,
  -- NULL = vale para todas as variantes; preenchido = específica da variante.
  variante_id   uuid,
  versao        integer NOT NULL DEFAULT 1,
  vigencia      daterange NOT NULL,
  observacao    text,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_ft_servico FOREIGN KEY (tenant_id, servico_id)
    REFERENCES lumia.servico (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_ft_variante FOREIGN KEY (tenant_id, variante_id)
    REFERENCES lumia.servico_variante (tenant_id, id),
  CONSTRAINT ft_vigencia_nao_vazia CHECK (NOT isempty(vigencia)),
  EXCLUDE USING gist (
    tenant_id WITH =, servico_id WITH =,
    coalesce(variante_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    vigencia WITH &&
  )
);

CREATE INDEX ix_ft_servico ON lumia.ficha_tecnica (tenant_id, servico_id);
SELECT lumia.aplicar_rls('lumia.ficha_tecnica');

CREATE TABLE lumia.ficha_tecnica_item (
  tenant_id       uuid NOT NULL,
  id              uuid NOT NULL,
  ficha_tecnica_id uuid NOT NULL,
  produto_id      uuid NOT NULL,
  -- Dose na unidade de CONSUMO do produto (ml, g, disparo, ...).
  quantidade      numeric(14,4) NOT NULL,
  unidade_codigo  lumia.slug NOT NULL REFERENCES lumia.unidade_medida(codigo),
  -- Insumo cuja baixa é obrigatória vs. opcional (luva pode não ser controlada).
  baixa_automatica boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_fti_ficha FOREIGN KEY (tenant_id, ficha_tecnica_id)
    REFERENCES lumia.ficha_tecnica (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_fti_produto FOREIGN KEY (tenant_id, produto_id)
    REFERENCES lumia.produto (tenant_id, id),
  CONSTRAINT fti_quantidade_positiva CHECK (quantidade > 0)
);

CREATE UNIQUE INDEX ux_fti ON lumia.ficha_tecnica_item (tenant_id, ficha_tecnica_id, produto_id);
CREATE INDEX ix_fti_produto ON lumia.ficha_tecnica_item (tenant_id, produto_id);
SELECT lumia.aplicar_rls('lumia.ficha_tecnica_item');

COMMENT ON TABLE lumia.ficha_tecnica_item IS
  'Doses padrão. O consumo REAL lançado no atendimento vive no módulo Meu Estoque '
  '(movimentação) — a comparação padrão × real é o que revela desperdício de cabine.';

-- Custo por disparo / hora de lâmpada / ponteira: consumível de equipamento,
-- não de prateleira. Modelado como custo por uso do recurso.
CREATE TABLE lumia.custo_uso_recurso (
  tenant_id     uuid NOT NULL,
  id            uuid NOT NULL,
  unidade_id    uuid NOT NULL,
  base_medida   text NOT NULL,
  custo_por_unidade lumia.valor_monetario NOT NULL,
  moeda         lumia.moeda NOT NULL DEFAULT 'BRL',
  vida_util_total numeric(14,4),
  vigencia      daterange NOT NULL,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_cur_unidade FOREIGN KEY (tenant_id, unidade_id)
    REFERENCES lumia.unidade_operacional (tenant_id, no_org_id) ON DELETE CASCADE,
  CONSTRAINT cur_base_valida CHECK (base_medida IN ('DISPARO','HORA_LAMPADA','PONTEIRA','SESSAO','MINUTO')),
  CONSTRAINT cur_custo_nao_negativo CHECK (custo_por_unidade >= 0),
  EXCLUDE USING gist (tenant_id WITH =, unidade_id WITH =, base_medida WITH =, vigencia WITH &&)
);
SELECT lumia.aplicar_rls('lumia.custo_uso_recurso');

COMMENT ON TABLE lumia.custo_uso_recurso IS
  'Depilação a laser custa por disparo; luz pulsada por hora de lâmpada; '
  'microagulhamento por ponteira. Sem isto o custo do procedimento de aparelho '
  'aparece como zero e a Bússola de Preços recomenda preço abaixo do custo.';

-- =============================================================================
-- PARTE 5 — Política comercial e preços (SCD-2)
-- =============================================================================

CREATE TYPE lumia.canal_venda AS ENUM ('BALCAO', 'ONLINE', 'APP_CLIENTE', 'PARCERIA', 'TODOS');

CREATE TABLE lumia.tabela_preco (
  tenant_id     uuid NOT NULL REFERENCES lumia.tenant(id),
  id            uuid NOT NULL,
  nome          text NOT NULL,
  -- NULL = vale para todos os estabelecimentos do tenant.
  estabelecimento_id uuid,
  canal         lumia.canal_venda NOT NULL DEFAULT 'TODOS',
  moeda         lumia.moeda NOT NULL DEFAULT 'BRL',
  prioridade    smallint NOT NULL DEFAULT 0,
  vigencia      daterange NOT NULL,
  ativa         boolean NOT NULL DEFAULT true,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_tp_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT tp_vigencia_nao_vazia CHECK (NOT isempty(vigencia))
);

CREATE INDEX ix_tp_lookup ON lumia.tabela_preco
  (tenant_id, estabelecimento_id, canal, prioridade DESC) WHERE ativa;
SELECT lumia.aplicar_rls('lumia.tabela_preco');

COMMENT ON COLUMN lumia.tabela_preco.prioridade IS
  'Resolve empate quando mais de uma tabela se aplica (ex.: tabela de convênio '
  'vence a tabela geral). Determinístico: maior prioridade ganha.';

-- Item de preço: um por (tabela, serviço|produto, nível, faixa horária).
CREATE TABLE lumia.tabela_preco_item (
  tenant_id       uuid NOT NULL,
  id              uuid NOT NULL,
  tabela_preco_id uuid NOT NULL,
  -- Exatamente um dos dois: serviço OU produto.
  servico_id      uuid,
  variante_id     uuid,
  produto_id      uuid,
  -- Preço por senioridade do executor.
  nivel_profissional smallint,
  -- Faixa horária: happy hour / tarifa de baixa demanda. Hora de parede local.
  hora_inicio     time,
  hora_fim        time,
  dias_semana     smallint[],
  preco           lumia.valor_monetario NOT NULL,
  -- Base de comissionamento: sobre o bruto ou líquido de insumo.
  base_comissao   text NOT NULL DEFAULT 'BRUTO',
  vigencia        daterange NOT NULL,
  vigente_de      date GENERATED ALWAYS AS (lower(vigencia)) STORED,
  registrado_em   timestamptz NOT NULL DEFAULT now(),
  registrado_por  uuid,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_tpi_tabela FOREIGN KEY (tenant_id, tabela_preco_id)
    REFERENCES lumia.tabela_preco (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_tpi_servico FOREIGN KEY (tenant_id, servico_id)
    REFERENCES lumia.servico (tenant_id, id),
  CONSTRAINT fk_tpi_variante FOREIGN KEY (tenant_id, variante_id)
    REFERENCES lumia.servico_variante (tenant_id, id),
  CONSTRAINT fk_tpi_produto FOREIGN KEY (tenant_id, produto_id)
    REFERENCES lumia.produto (tenant_id, id),
  CONSTRAINT tpi_servico_xor_produto CHECK (
    (servico_id IS NOT NULL AND produto_id IS NULL)
    OR (servico_id IS NULL AND produto_id IS NOT NULL)
  ),
  CONSTRAINT tpi_variante_exige_servico CHECK (variante_id IS NULL OR servico_id IS NOT NULL),
  CONSTRAINT tpi_preco_nao_negativo CHECK (preco >= 0),
  CONSTRAINT tpi_faixa_horaria_completa CHECK ((hora_inicio IS NULL) = (hora_fim IS NULL)),
  CONSTRAINT tpi_base_comissao_valida CHECK (base_comissao IN ('BRUTO','LIQUIDO_INSUMO','LIQUIDO_TAXA','NAO_COMISSIONAVEL')),
  CONSTRAINT tpi_nivel_faixa CHECK (nivel_profissional IS NULL OR nivel_profissional BETWEEN 1 AND 5),
  CONSTRAINT tpi_vigencia_nao_vazia CHECK (NOT isempty(vigencia)),
  -- Nenhuma sobreposição de vigência para a mesma combinação de chaves.
  EXCLUDE USING gist (
    tenant_id WITH =, tabela_preco_id WITH =,
    coalesce(servico_id,  '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    coalesce(variante_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    coalesce(produto_id,  '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    coalesce(nivel_profissional, -1) WITH =,
    coalesce(hora_inicio, '00:00'::time) WITH =,
    vigencia WITH &&
  )
);

CREATE INDEX ix_tpi_servico ON lumia.tabela_preco_item (tenant_id, servico_id, vigente_de DESC)
  WHERE servico_id IS NOT NULL;
CREATE INDEX ix_tpi_produto ON lumia.tabela_preco_item (tenant_id, produto_id, vigente_de DESC)
  WHERE produto_id IS NOT NULL;

SELECT lumia.aplicar_rls('lumia.tabela_preco_item');

COMMENT ON TABLE lumia.tabela_preco_item IS
  'Preço NÃO é atributo do serviço: é uma linha com vigência. O preço praticado '
  'na comanda é congelado no item da comanda (migration do Balcão); aqui vive o '
  'preço de tabela, que a auditoria consulta para explicar o desconto.';
COMMENT ON COLUMN lumia.tabela_preco_item.base_comissao IS
  'LIQUIDO_INSUMO é modelo comum no setor: o profissional comissiona sobre o '
  'preço menos o custo do material. Depende da ficha técnica existir.';
COMMENT ON COLUMN lumia.tabela_preco_item.dias_semana IS
  'ISO-8601: 1=segunda ... 7=domingo. Hora de parede local do estabelecimento, '
  'não UTC — a regra "happy hour das 14h" é 14h no relógio da parede.';

-- Desconto exige motivo e autorizador — auditabilidade de margem.
CREATE TABLE lumia.motivo_desconto (
  tenant_id       uuid NOT NULL REFERENCES lumia.tenant(id),
  id              uuid NOT NULL,
  nome            text NOT NULL,
  limite_percentual lumia.percentual,
  exige_autorizacao boolean NOT NULL DEFAULT true,
  ativo           boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, id)
);
CREATE UNIQUE INDEX ux_motivo_desconto ON lumia.motivo_desconto (tenant_id, lower(nome));
SELECT lumia.aplicar_rls('lumia.motivo_desconto');

-- =============================================================================
-- PARTE 6 — Atributos fiscais (a memória de cálculo vive no Meu Fiscal)
-- =============================================================================

CREATE TABLE lumia.servico_atributo_fiscal (
  tenant_id       uuid NOT NULL,
  id              uuid NOT NULL,
  servico_id      uuid NOT NULL,
  -- NULL = vale para todos os estabelecimentos; a lista LC 116 é federal mas o
  -- código de tributação é MUNICIPAL, então varia por estabelecimento.
  estabelecimento_id uuid,
  item_lc116      text NOT NULL,
  codigo_tributacao_municipal text,
  codigo_nbs      text,
  cnae            char(7),
  -- Transição IBS/CBS: classificação tributária do novo sistema.
  cclasstrib      text,
  aliquota_iss    lumia.percentual,
  iss_retido_padrao boolean NOT NULL DEFAULT false,
  vigencia        daterange NOT NULL,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_saf_servico FOREIGN KEY (tenant_id, servico_id)
    REFERENCES lumia.servico (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_saf_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT saf_vigencia_nao_vazia CHECK (NOT isempty(vigencia)),
  EXCLUDE USING gist (
    tenant_id WITH =, servico_id WITH =,
    coalesce(estabelecimento_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    vigencia WITH &&
  )
);
SELECT lumia.aplicar_rls('lumia.servico_atributo_fiscal');

COMMENT ON TABLE lumia.servico_atributo_fiscal IS
  'Parâmetro legal também tem vigência (decisão nº 5): alíquota e classificação '
  'mudam por lei. A memória de cálculo IMUTÁVEL de cada documento emitido vive '
  'no Meu Fiscal — aqui está apenas o parâmetro corrente por vigência.';

CREATE TABLE lumia.produto_atributo_fiscal (
  tenant_id       uuid NOT NULL,
  id              uuid NOT NULL,
  produto_id      uuid NOT NULL,
  estabelecimento_id uuid,
  ncm             char(8) NOT NULL,
  cest            char(7),
  origem_mercadoria smallint NOT NULL DEFAULT 0,
  cst             char(2),
  csosn           char(3),
  cclasstrib      text,
  aliquota_icms   lumia.percentual,
  icms_st         boolean NOT NULL DEFAULT false,
  mva_percentual  lumia.percentual,
  unidade_comercial lumia.slug NOT NULL REFERENCES lumia.unidade_medida(codigo),
  unidade_tributavel lumia.slug NOT NULL REFERENCES lumia.unidade_medida(codigo),
  vigencia        daterange NOT NULL,
  PRIMARY KEY (tenant_id, id),
  CONSTRAINT fk_paf_produto FOREIGN KEY (tenant_id, produto_id)
    REFERENCES lumia.produto (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_paf_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT paf_origem_faixa CHECK (origem_mercadoria BETWEEN 0 AND 8),
  CONSTRAINT paf_st_exige_mva CHECK (NOT icms_st OR mva_percentual IS NOT NULL),
  CONSTRAINT paf_vigencia_nao_vazia CHECK (NOT isempty(vigencia)),
  EXCLUDE USING gist (
    tenant_id WITH =, produto_id WITH =,
    coalesce(estabelecimento_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    vigencia WITH &&
  )
);
SELECT lumia.aplicar_rls('lumia.produto_atributo_fiscal');

-- =============================================================================
-- PARTE 7 — Leitura: resolução de preço vigente e custo direto
-- =============================================================================

-- Preço vigente na DATA DO FATO, com desempate determinístico por prioridade.
CREATE OR REPLACE FUNCTION lumia.preco_vigente(
  p_tenant_id     uuid,
  p_data          date,
  p_estabelecimento_id uuid,
  p_canal         lumia.canal_venda,
  p_servico_id    uuid DEFAULT NULL,
  p_variante_id   uuid DEFAULT NULL,
  p_produto_id    uuid DEFAULT NULL,
  p_nivel         smallint DEFAULT NULL,
  p_hora          time DEFAULT NULL
) RETURNS TABLE (preco lumia.valor_monetario, moeda lumia.moeda,
                 base_comissao text, tabela_preco_id uuid, item_id uuid)
LANGUAGE sql STABLE AS $$
  SELECT i.preco, t.moeda, i.base_comissao, t.id, i.id
    FROM lumia.tabela_preco_item i
    JOIN lumia.tabela_preco t
      ON (t.tenant_id, t.id) = (i.tenant_id, i.tabela_preco_id)
   WHERE i.tenant_id = p_tenant_id
     AND t.ativa
     AND t.vigencia @> p_data
     AND i.vigencia @> p_data
     AND (t.estabelecimento_id IS NULL OR t.estabelecimento_id = p_estabelecimento_id)
     AND (t.canal = 'TODOS' OR t.canal = p_canal)
     AND (p_servico_id  IS NULL OR i.servico_id  = p_servico_id)
     AND (p_produto_id  IS NULL OR i.produto_id  = p_produto_id)
     AND (i.variante_id IS NULL OR i.variante_id = p_variante_id)
     AND (i.nivel_profissional IS NULL OR i.nivel_profissional = p_nivel)
     AND (i.hora_inicio IS NULL
          OR (p_hora IS NOT NULL AND p_hora >= i.hora_inicio AND p_hora < i.hora_fim))
   ORDER BY t.prioridade DESC,
            -- Regra mais específica ganha da mais genérica.
            (t.estabelecimento_id IS NOT NULL) DESC,
            (i.variante_id IS NOT NULL) DESC,
            (i.nivel_profissional IS NOT NULL) DESC,
            (i.hora_inicio IS NOT NULL) DESC,
            lower(i.vigencia) DESC
   LIMIT 1;
$$;

COMMENT ON FUNCTION lumia.preco_vigente IS
  'Resolve o preço de tabela na data do fato. Determinístico: prioridade da '
  'tabela, depois especificidade (estabelecimento > variante > nível > faixa '
  'horária), depois vigência mais recente. A comanda congela o resultado.';

-- Custo direto do serviço = insumos da ficha técnica (na dose da variante)
-- avaliados pelo custo VIGENTE NA DATA, mais custo de uso de recurso.
CREATE OR REPLACE FUNCTION lumia.custo_direto_servico(
  p_tenant_id   uuid,
  p_servico_id  uuid,
  p_variante_id uuid,
  p_data        date,
  p_estabelecimento_id uuid DEFAULT NULL
) RETURNS lumia.valor_monetario
LANGUAGE sql STABLE AS $$
  WITH fator AS (
    SELECT coalesce((SELECT v.fator_consumo FROM lumia.servico_variante v
                      WHERE v.tenant_id = p_tenant_id AND v.id = p_variante_id), 1) AS f
  ),
  ficha AS (
    SELECT ft.id
      FROM lumia.ficha_tecnica ft
     WHERE ft.tenant_id = p_tenant_id
       AND ft.servico_id = p_servico_id
       AND ft.vigencia @> p_data
       AND (ft.variante_id = p_variante_id OR ft.variante_id IS NULL)
     ORDER BY (ft.variante_id IS NOT NULL) DESC
     LIMIT 1
  )
  SELECT coalesce(sum(
           -- dose na unidade de consumo, convertida para a unidade de compra
           (i.quantidade * (SELECT f FROM fator))
           / p.fator_conversao
           * c.custo_unitario_compra
         ), 0)::lumia.valor_monetario
    FROM lumia.ficha_tecnica_item i
    JOIN lumia.produto p ON (p.tenant_id, p.id) = (i.tenant_id, i.produto_id)
    LEFT JOIN lumia.produto_custo_versao c
      ON c.tenant_id = i.tenant_id
     AND c.produto_id = i.produto_id
     AND c.vigencia @> p_data
     AND (c.estabelecimento_id IS NULL OR c.estabelecimento_id = p_estabelecimento_id)
   WHERE i.tenant_id = p_tenant_id
     AND i.ficha_tecnica_id = (SELECT id FROM ficha);
$$;

COMMENT ON FUNCTION lumia.custo_direto_servico IS
  'Base do Mapa da Lucratividade e da Bússola de Preços. Lê o custo VIGENTE NA '
  'DATA — é por isso que a margem de março continua igual depois do reajuste de '
  'julho.';

COMMIT;
