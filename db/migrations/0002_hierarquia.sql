-- =============================================================================
-- LUMIA · 0002 — Tenant, célula e hierarquia organizacional
-- =============================================================================
-- Implementa a decisão irreversível nº 1:
--   grupo econômico → pessoa jurídica (CNPJ) → estabelecimento → unidade operacional
--
-- Regra de fronteira gravada no modelo:
--   • FRANQUEADO  = tenant próprio (controlador LGPD distinto, CNPJ próprio,
--                   numeração fiscal própria). Nunca compartilha linha com o
--                   franqueador.
--   • FILIAL      = estabelecimento do MESMO tenant.
--
-- Isolamento é UMA política de RLS por tenant_id. Visibilidade por
-- estabelecimento é RBAC e chave de particionamento — nunca uma segunda
-- política de RLS.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Células (shards lógicos): limitam o raio de um incidente sistêmico
-- -----------------------------------------------------------------------------
CREATE TABLE lumia.celula (
  id            uuid PRIMARY KEY,
  codigo        lumia.slug  NOT NULL UNIQUE,
  regiao_aws    text        NOT NULL DEFAULT 'sa-east-1',
  ativa         boolean     NOT NULL DEFAULT true,
  aceita_novos  boolean     NOT NULL DEFAULT true,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE lumia.celula IS
  'Célula = domínio de falha. Sem célula, o primeiro incidente sistêmico é um '
  'evento de 100% da base num sábado de Dia das Mães. Nenhuma FK, sequência ou '
  'job pode atravessar célula — verificado por teste no CI.';
COMMENT ON COLUMN lumia.celula.aceita_novos IS
  'Permite drenar uma célula (parar de alocar tenants novos) sem desativá-la.';

-- -----------------------------------------------------------------------------
-- Tenant: a fronteira de isolamento
-- -----------------------------------------------------------------------------
CREATE TYPE lumia.status_tenant AS ENUM (
  'TRIAL', 'ATIVO', 'INADIMPLENTE', 'SUSPENSO', 'ENCERRADO'
);

CREATE TABLE lumia.tenant (
  id                uuid PRIMARY KEY,
  celula_id         uuid NOT NULL REFERENCES lumia.celula(id),
  slug              lumia.slug NOT NULL UNIQUE,
  nome_exibicao     text NOT NULL,
  status            lumia.status_tenant NOT NULL DEFAULT 'TRIAL',
  finalidade        lumia.finalidade_dado NOT NULL DEFAULT 'REAL',
  pais              char(2) NOT NULL DEFAULT 'BR',
  moeda_padrao      lumia.moeda NOT NULL DEFAULT 'BRL',
  fuso_padrao       lumia.fuso_iana NOT NULL DEFAULT 'America/Sao_Paulo',
  locale_padrao     text NOT NULL DEFAULT 'pt-BR',
  -- Franquia: o franqueador é outro TENANT, não um nó acima na árvore.
  franqueador_id    uuid REFERENCES lumia.tenant(id),
  criado_em         timestamptz NOT NULL DEFAULT now(),
  atualizado_em     timestamptz NOT NULL DEFAULT now(),
  encerrado_em      timestamptz,
  CONSTRAINT tenant_nao_e_franqueador_de_si CHECK (franqueador_id IS DISTINCT FROM id),
  CONSTRAINT tenant_encerrado_tem_data CHECK (
    (status = 'ENCERRADO') = (encerrado_em IS NOT NULL)
  )
);

CREATE INDEX ix_tenant_celula  ON lumia.tenant (celula_id) WHERE status <> 'ENCERRADO';
CREATE INDEX ix_tenant_franqueador ON lumia.tenant (franqueador_id) WHERE franqueador_id IS NOT NULL;

COMMENT ON TABLE lumia.tenant IS
  'Fronteira de isolamento e de controladoria LGPD. Um franqueado é um tenant '
  'próprio: CNPJ, numeração fiscal e base de clientes próprios. O vínculo com o '
  'franqueador é referência entre tenants, com escopo de visibilidade acordado '
  'por classe de dado — jamais acesso direto à linha.';
COMMENT ON COLUMN lumia.tenant.finalidade IS
  'Um tenant inteiro pode ser DEMONSTRACAO ou HOMOLOGACAO. Toda projeção '
  'analítica filtra por finalidade = REAL por padrão.';

CREATE TRIGGER tg_tenant_fuso
  BEFORE INSERT OR UPDATE OF fuso_padrao ON lumia.tenant
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_valida_fuso('fuso_padrao');

-- -----------------------------------------------------------------------------
-- Contexto de sessão e RLS
-- -----------------------------------------------------------------------------
-- A aplicação abre a transação com SET LOCAL lumia.tenant_id = '<uuid>'.
-- Toda política de RLS lê daqui. Sem contexto, nenhuma linha é visível.
CREATE OR REPLACE FUNCTION lumia.tenant_atual() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v text := current_setting('lumia.tenant_id', true);
BEGIN
  IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
  RETURN v::uuid;
END;
$$;

COMMENT ON FUNCTION lumia.tenant_atual() IS
  'Tenant do contexto da transação. Retorna NULL quando não definido, o que faz '
  'toda política de RLS negar acesso — falha fechada, nunca aberta.';

-- Aplica a política padrão de isolamento a uma tabela de tenant.
-- Política ÚNICA por tabela: o filtro por estabelecimento é RBAC na aplicação.
CREATE OR REPLACE FUNCTION lumia.aplicar_rls(p_tabela regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_tabela);
  EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', p_tabela);
  EXECUTE format($f$
    CREATE POLICY isolamento_tenant ON %s
      USING (tenant_id = lumia.tenant_atual())
      WITH CHECK (tenant_id = lumia.tenant_atual())
  $f$, p_tabela);
END;
$$;

COMMENT ON FUNCTION lumia.aplicar_rls(regclass) IS
  'FORCE ROW LEVEL SECURITY é deliberado: aplica a política também ao dono da '
  'tabela, de modo que um bug de migration ou um job rodando como owner não '
  'atravesse tenants.';

-- -----------------------------------------------------------------------------
-- Árvore organizacional
-- -----------------------------------------------------------------------------
CREATE TYPE lumia.tipo_no_org AS ENUM (
  'GRUPO',            -- grupo econômico / rede
  'PESSOA_JURIDICA',  -- CNPJ
  'ESTABELECIMENTO',  -- sujeito passivo fiscal, com IE/IM próprias
  'UNIDADE'           -- unidade operacional: sala, cabine, cadeira, maca
);

CREATE TABLE lumia.no_org (
  tenant_id     uuid NOT NULL REFERENCES lumia.tenant(id),
  id            uuid NOT NULL,
  tipo          lumia.tipo_no_org NOT NULL,
  pai_id        uuid,
  -- Caminho materializado: consulta de ancestral/descendente sem recursão.
  -- Mantido por trigger; rótulo = 'n' + uuid sem hífen (ltree não aceita hífen).
  caminho       ltree NOT NULL,
  profundidade  smallint NOT NULL,
  nome          text NOT NULL,
  codigo        lumia.slug,
  ativo         boolean NOT NULL DEFAULT true,
  -- Rastro de importação: permite reimportar sem duplicar a base.
  sistema_origem text,
  id_externo     text,
  origem        lumia.origem_registro NOT NULL DEFAULT 'MANUAL',
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  removido_em   timestamptz,
  PRIMARY KEY (tenant_id, id),
  -- FK composta com tenant_id: o banco impede que um nó aponte para pai de
  -- outro tenant. Integridade de tenancy deixa de depender de disciplina.
  CONSTRAINT fk_no_org_pai FOREIGN KEY (tenant_id, pai_id)
    REFERENCES lumia.no_org (tenant_id, id),
  CONSTRAINT no_org_grupo_sem_pai CHECK ((tipo = 'GRUPO') = (pai_id IS NULL)),
  CONSTRAINT no_org_importacao_completa CHECK (
    (sistema_origem IS NULL) = (id_externo IS NULL)
  )
);

-- tenant_id é a primeira coluna de todo índice (convenção nº 12).
CREATE INDEX ix_no_org_pai       ON lumia.no_org (tenant_id, pai_id);
CREATE INDEX ix_no_org_tipo      ON lumia.no_org (tenant_id, tipo) WHERE removido_em IS NULL;
CREATE INDEX ix_no_org_caminho   ON lumia.no_org USING gist (caminho);
-- updated_at indexado: alimenta sincronização incremental (inclui tombstones).
CREATE INDEX ix_no_org_sync      ON lumia.no_org (tenant_id, atualizado_em);
CREATE UNIQUE INDEX ux_no_org_externo
  ON lumia.no_org (tenant_id, sistema_origem, id_externo)
  WHERE id_externo IS NOT NULL;
CREATE UNIQUE INDEX ux_no_org_codigo
  ON lumia.no_org (tenant_id, codigo) WHERE codigo IS NOT NULL AND removido_em IS NULL;

COMMENT ON TABLE lumia.no_org IS
  'Árvore organizacional do tenant. Um nó por grupo, CNPJ, estabelecimento e '
  'unidade operacional. Enxertar um nível aqui depois de existir volume '
  'transacional significaria reescrever RLS, permissões, particionamento e toda '
  'query de apuração — por isso a árvore nasce completa na primeira migration.';
COMMENT ON COLUMN lumia.no_org.caminho IS
  'Caminho materializado em ltree. Descendentes de X: caminho <@ (select caminho '
  'from no_org where id = X). Ancestrais: caminho @> ...';
COMMENT ON COLUMN lumia.no_org.removido_em IS
  'Soft delete com tombstone: a linha permanece para que o app móvel receba a '
  'remoção na próxima sincronização. Sem isto, a agenda do celular mostra '
  'atendimento fantasma.';

SELECT lumia.aplicar_rls('lumia.no_org');

-- Hierarquia de tipos permitida: nenhum caminho inesperado entra na árvore.
CREATE OR REPLACE FUNCTION lumia.tg_no_org_caminho() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_pai         lumia.no_org;
  v_rotulo      text := 'n' || replace(NEW.id::text, '-', '');
  v_permitido   boolean;
BEGIN
  IF NEW.pai_id IS NULL THEN
    NEW.caminho      := v_rotulo::ltree;
    NEW.profundidade := 0;
  ELSE
    SELECT * INTO v_pai FROM lumia.no_org
      WHERE tenant_id = NEW.tenant_id AND id = NEW.pai_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Nó pai % não existe no tenant %', NEW.pai_id, NEW.tenant_id;
    END IF;

    v_permitido := (v_pai.tipo, NEW.tipo) IN (
      ('GRUPO',           'PESSOA_JURIDICA'),
      ('PESSOA_JURIDICA', 'ESTABELECIMENTO'),
      ('ESTABELECIMENTO', 'UNIDADE'),
      ('UNIDADE',         'UNIDADE')  -- cadeira dentro de sala
    );
    IF NOT v_permitido THEN
      RAISE EXCEPTION 'Hierarquia inválida: % não pode ser filho de %',
        NEW.tipo, v_pai.tipo
        USING HINT = 'Ordem: GRUPO > PESSOA_JURIDICA > ESTABELECIMENTO > UNIDADE.';
    END IF;

    NEW.caminho      := v_pai.caminho || v_rotulo::ltree;
    NEW.profundidade := v_pai.profundidade + 1;
  END IF;
  NEW.atualizado_em := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER tg_no_org_caminho
  BEFORE INSERT OR UPDATE OF pai_id ON lumia.no_org
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_no_org_caminho();

-- Reposiciona a subárvore quando um nó troca de pai.
CREATE OR REPLACE FUNCTION lumia.tg_no_org_move_subarvore() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.caminho IS DISTINCT FROM OLD.caminho THEN
    UPDATE lumia.no_org
       SET caminho      = NEW.caminho || subpath(caminho, nlevel(OLD.caminho)),
           profundidade = nlevel(NEW.caminho) + (nlevel(caminho) - nlevel(OLD.caminho)),
           atualizado_em = now()
     WHERE tenant_id = NEW.tenant_id
       AND caminho <@ OLD.caminho
       AND id <> NEW.id;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER tg_no_org_move_subarvore
  AFTER UPDATE OF pai_id ON lumia.no_org
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_no_org_move_subarvore();

-- -----------------------------------------------------------------------------
-- Especialização: pessoa jurídica (o CNPJ)
-- -----------------------------------------------------------------------------
CREATE TABLE lumia.pessoa_juridica (
  tenant_id       uuid NOT NULL,
  no_org_id       uuid NOT NULL,
  cnpj            lumia.cnpj NOT NULL,
  razao_social    text NOT NULL,
  nome_fantasia   text,
  natureza_juridica text,
  data_abertura   date,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, no_org_id),
  CONSTRAINT fk_pj_no FOREIGN KEY (tenant_id, no_org_id)
    REFERENCES lumia.no_org (tenant_id, id) ON DELETE CASCADE
);

-- CNPJ é único dentro do tenant, não globalmente: o mesmo CNPJ pode aparecer em
-- tenants distintos (contador que administra várias empresas, migração, teste).
CREATE UNIQUE INDEX ux_pj_cnpj ON lumia.pessoa_juridica (tenant_id, cnpj);

SELECT lumia.aplicar_rls('lumia.pessoa_juridica');

COMMENT ON TABLE lumia.pessoa_juridica IS
  'Atributos do nó de tipo PESSOA_JURIDICA. O regime tributário NÃO vive aqui: '
  'é versionado por vigência no módulo Meu Fiscal (migration 0004).';

-- -----------------------------------------------------------------------------
-- Especialização: estabelecimento (o sujeito passivo fiscal)
-- -----------------------------------------------------------------------------
CREATE TABLE lumia.estabelecimento (
  tenant_id            uuid NOT NULL,
  no_org_id            uuid NOT NULL,
  pessoa_juridica_id   uuid NOT NULL,
  -- Numeração humana sequencial por tenant, ao lado da PK técnica UUID.
  numero               integer NOT NULL,
  inscricao_estadual   text,
  inscricao_municipal  text,
  cnae_principal       char(7),
  codigo_municipio_ibge char(7) NOT NULL,
  uf                   char(2) NOT NULL,
  fuso                 lumia.fuso_iana NOT NULL,
  matriz               boolean NOT NULL DEFAULT false,
  endereco             jsonb NOT NULL DEFAULT '{}'::jsonb,
  criado_em            timestamptz NOT NULL DEFAULT now(),
  atualizado_em        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, no_org_id),
  CONSTRAINT fk_estab_no FOREIGN KEY (tenant_id, no_org_id)
    REFERENCES lumia.no_org (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_estab_pj FOREIGN KEY (tenant_id, pessoa_juridica_id)
    REFERENCES lumia.pessoa_juridica (tenant_id, no_org_id),
  CONSTRAINT estab_uf_maiuscula CHECK (uf ~ '^[A-Z]{2}$')
);

CREATE UNIQUE INDEX ux_estab_numero ON lumia.estabelecimento (tenant_id, numero);
CREATE INDEX ix_estab_pj ON lumia.estabelecimento (tenant_id, pessoa_juridica_id);
-- Uma única matriz por pessoa jurídica.
CREATE UNIQUE INDEX ux_estab_matriz
  ON lumia.estabelecimento (tenant_id, pessoa_juridica_id) WHERE matriz;

SELECT lumia.aplicar_rls('lumia.estabelecimento');

CREATE TRIGGER tg_estab_fuso
  BEFORE INSERT OR UPDATE OF fuso ON lumia.estabelecimento
  FOR EACH ROW EXECUTE FUNCTION lumia.tg_valida_fuso('fuso');

COMMENT ON TABLE lumia.estabelecimento IS
  'Sujeito passivo fiscal. TODA linha transacional do sistema carrega '
  'estabelecimento_id NOT NULL: é ele que define alíquota, município de '
  'incidência, série de numeração fiscal e fuso do fato.';
COMMENT ON COLUMN lumia.estabelecimento.numero IS
  'Numeração humana sequencial por tenant, exigida pela convenção nº 12: o dono '
  'do salão fala "unidade 2", não um UUID.';
COMMENT ON COLUMN lumia.estabelecimento.fuso IS
  'Fuso do local físico. É a referência para converter occurred_at (UTC) em '
  'business_date — sem isso, o fechamento de caixa da virada vaza para o dia '
  'seguinte em Manaus e no Acre.';

-- -----------------------------------------------------------------------------
-- Especialização: unidade operacional (o recurso físico)
-- -----------------------------------------------------------------------------
CREATE TYPE lumia.tipo_unidade AS ENUM (
  'SALA', 'CABINE', 'CADEIRA', 'MACA', 'LAVATORIO', 'ESTACAO', 'EQUIPAMENTO'
);

CREATE TABLE lumia.unidade_operacional (
  tenant_id          uuid NOT NULL,
  no_org_id          uuid NOT NULL,
  estabelecimento_id uuid NOT NULL,
  tipo               lumia.tipo_unidade NOT NULL,
  -- Capacidade simultânea: uma sala pode atender 2 pessoas ao mesmo tempo.
  capacidade         smallint NOT NULL DEFAULT 1,
  -- Agendável = pode ser reservado pela agenda. Um lavatório de apoio pode
  -- existir no patrimônio sem entrar no motor de disponibilidade.
  agendavel          boolean NOT NULL DEFAULT true,
  criado_em          timestamptz NOT NULL DEFAULT now(),
  atualizado_em      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, no_org_id),
  CONSTRAINT fk_unid_no FOREIGN KEY (tenant_id, no_org_id)
    REFERENCES lumia.no_org (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_unid_estab FOREIGN KEY (tenant_id, estabelecimento_id)
    REFERENCES lumia.estabelecimento (tenant_id, no_org_id),
  CONSTRAINT unid_capacidade_positiva CHECK (capacidade > 0)
);

CREATE INDEX ix_unid_estab ON lumia.unidade_operacional (tenant_id, estabelecimento_id)
  WHERE agendavel;
CREATE INDEX ix_unid_tipo  ON lumia.unidade_operacional (tenant_id, tipo);

SELECT lumia.aplicar_rls('lumia.unidade_operacional');

COMMENT ON TABLE lumia.unidade_operacional IS
  'Recurso físico agendável: sala, cabine, cadeira, maca, equipamento. É o que '
  'o catálogo referencia em "recursos exigidos" e o que a agenda reserva.';

-- -----------------------------------------------------------------------------
-- Visões de conveniência
-- -----------------------------------------------------------------------------
CREATE VIEW lumia.vw_arvore_org AS
SELECT n.tenant_id,
       n.id,
       n.tipo,
       n.nome,
       n.profundidade,
       n.caminho,
       repeat('  ', n.profundidade) || n.nome AS nome_indentado,
       pj.cnpj,
       e.numero      AS numero_estabelecimento,
       e.fuso        AS fuso_estabelecimento,
       u.tipo::text  AS tipo_unidade,
       n.ativo,
       n.removido_em
  FROM lumia.no_org n
  LEFT JOIN lumia.pessoa_juridica     pj ON (pj.tenant_id, pj.no_org_id) = (n.tenant_id, n.id)
  LEFT JOIN lumia.estabelecimento     e  ON (e.tenant_id,  e.no_org_id)  = (n.tenant_id, n.id)
  LEFT JOIN lumia.unidade_operacional u  ON (u.tenant_id,  u.no_org_id)  = (n.tenant_id, n.id);

COMMENT ON VIEW lumia.vw_arvore_org IS
  'Árvore achatada para telas de configuração e conferência. Herda a RLS das '
  'tabelas de base (as views respeitam a política do invocador por padrão).';

COMMIT;
