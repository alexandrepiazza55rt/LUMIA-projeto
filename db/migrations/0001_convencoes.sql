-- =============================================================================
-- LUMIA · 0001 — Convenções de fundação
-- =============================================================================
-- Implementa a decisão irreversível nº 12 ("Convenções de DDL do dia 1"):
-- toda tabela do sistema nasce com PK (tenant_id, id), chave UUIDv7 gerada no
-- cliente, soft delete com tombstone, updated_at indexado, dinheiro com moeda,
-- fuso IANA e finalidade do dado. O que não estiver aqui não entra em migration.
--
-- Ordem: este arquivo roda antes de qualquer outro.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Extensões
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_bytes: geração de UUIDv7
CREATE EXTENSION IF NOT EXISTS btree_gist; -- EXCLUDE de vigências sem sobreposição
CREATE EXTENSION IF NOT EXISTS ltree;      -- caminho materializado da hierarquia

CREATE SCHEMA IF NOT EXISTS lumia;
CREATE SCHEMA IF NOT EXISTS referencia;  -- dados canônicos FORA do escopo de tenant

COMMENT ON SCHEMA lumia IS
  'Dados de tenant. Toda tabela aqui tem tenant_id e política de RLS.';
COMMENT ON SCHEMA referencia IS
  'Tabelas de referência versionadas e compartilhadas (taxonomia canônica, listas '
  'legais). Sem tenant_id e sem RLS: são leitura pública para a aplicação.';

-- -----------------------------------------------------------------------------
-- Chaves: UUIDv7 gerado no cliente
-- -----------------------------------------------------------------------------
-- Em produção a PK vem da aplicação (ordenável por tempo, sem round-trip e
-- compatível com sincronização offline). Esta função existe para seeds, testes
-- e importação — não como DEFAULT de coluna, para que o padrão fique explícito.
CREATE OR REPLACE FUNCTION lumia.uuid_v7() RETURNS uuid
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
  v_ts_ms bigint := (extract(epoch FROM clock_timestamp()) * 1000)::bigint;
  v_bytes bytea  := gen_random_bytes(16);
BEGIN
  -- 48 bits de timestamp em milissegundos (big-endian)
  v_bytes := set_byte(v_bytes, 0, ((v_ts_ms >> 40) & 255)::int);
  v_bytes := set_byte(v_bytes, 1, ((v_ts_ms >> 32) & 255)::int);
  v_bytes := set_byte(v_bytes, 2, ((v_ts_ms >> 24) & 255)::int);
  v_bytes := set_byte(v_bytes, 3, ((v_ts_ms >> 16) & 255)::int);
  v_bytes := set_byte(v_bytes, 4, ((v_ts_ms >>  8) & 255)::int);
  v_bytes := set_byte(v_bytes, 5, ( v_ts_ms        & 255)::int);
  -- versão 7 nos 4 bits altos do byte 6
  v_bytes := set_byte(v_bytes, 6, ((get_byte(v_bytes, 6) & 15) | 112));
  -- variante RFC 4122 (10xx) nos 2 bits altos do byte 8
  v_bytes := set_byte(v_bytes, 8, ((get_byte(v_bytes, 8) & 63) | 128));
  RETURN encode(v_bytes, 'hex')::uuid;
END;
$$;

COMMENT ON FUNCTION lumia.uuid_v7() IS
  'UUIDv7 (RFC 9562): 48 bits de timestamp + aleatório. Ordenável por tempo, o '
  'que preserva localidade de índice. Uso previsto: seed, teste e importação — '
  'em produção a aplicação gera a chave.';

-- -----------------------------------------------------------------------------
-- Domínios: tornam a convenção verificável pelo banco
-- -----------------------------------------------------------------------------
CREATE DOMAIN lumia.valor_monetario AS numeric(14,4);
COMMENT ON DOMAIN lumia.valor_monetario IS
  'Escala 4 para suportar rateio e dose fracionada sem perda de centavo. '
  'Todo valor monetário anda acompanhado de uma coluna de moeda.';

CREATE DOMAIN lumia.moeda AS char(3)
  CONSTRAINT moeda_iso4217 CHECK (VALUE ~ '^[A-Z]{3}$');

CREATE DOMAIN lumia.percentual AS numeric(7,4)
  CONSTRAINT percentual_faixa CHECK (VALUE >= 0 AND VALUE <= 100);

-- O formato fica no domínio (verificável e imutável); a existência do fuso no
-- catálogo IANA fica em trigger, porque CHECK não pode consultar tabela e uma
-- função marcada IMMUTABLE que lê pg_timezone_names quebraria dump/restore
-- quando a lista de fusos do servidor mudasse.
CREATE DOMAIN lumia.fuso_iana AS text
  CONSTRAINT fuso_formato CHECK (VALUE ~ '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$');
COMMENT ON DOMAIN lumia.fuso_iana IS
  'Fuso IANA (ex.: America/Sao_Paulo). O Brasil tem múltiplos fusos '
  '(America/Sao_Paulo, America/Manaus, America/Rio_Branco, America/Belem, ...): '
  'agenda, lembrete e fechamento de caixa dependem do fuso do estabelecimento, '
  'nunca do fuso do servidor.';

CREATE OR REPLACE FUNCTION lumia.fuso_existe(p_fuso text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = p_fuso);
$$;

-- Trigger reutilizável: recebe o nome da coluna de fuso como argumento.
CREATE OR REPLACE FUNCTION lumia.tg_valida_fuso() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_coluna text := TG_ARGV[0];
  v_valor  text;
BEGIN
  EXECUTE format('SELECT ($1).%I::text', v_coluna) INTO v_valor USING NEW;
  IF v_valor IS NOT NULL AND NOT lumia.fuso_existe(v_valor) THEN
    RAISE EXCEPTION 'Fuso IANA desconhecido: %', v_valor
      USING HINT = 'Consulte pg_timezone_names para os valores aceitos.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE DOMAIN lumia.slug AS text
  CONSTRAINT slug_formato CHECK (VALUE ~ '^[a-z0-9]+(-[a-z0-9]+)*$');

CREATE DOMAIN lumia.cnpj AS char(14)
  CONSTRAINT cnpj_digitos CHECK (VALUE ~ '^[0-9]{14}$');
COMMENT ON DOMAIN lumia.cnpj IS
  'Somente dígitos. A validação de dígito verificador fica na aplicação: '
  'CNPJ alfanumérico entra em vigor e o formato aqui é deliberadamente permissivo '
  'quanto a isso, mas rígido quanto a tamanho e ausência de máscara.';

-- -----------------------------------------------------------------------------
-- Enums de convenção
-- -----------------------------------------------------------------------------
-- Finalidade do dado: sem isto, a comanda de treinamento da recepcionista nova
-- entra no DRE, no benchmark e na média que alimenta a Bússola — para sempre.
CREATE TYPE lumia.finalidade_dado AS ENUM (
  'REAL', 'TREINAMENTO', 'DEMONSTRACAO', 'HOMOLOGACAO'
);

CREATE TYPE lumia.origem_registro AS ENUM (
  'MANUAL', 'IMPORTACAO', 'API', 'AGENDAMENTO_ONLINE', 'INTEGRACAO', 'SEED'
);

COMMIT;
