-- =============================================================================
-- LUMIA · 0004 — Papéis e concessões
-- =============================================================================
-- A aplicação NUNCA conecta como superusuário nem como owner das tabelas:
-- superusuário ignora RLS por definição, e owner só é contido por FORCE ROW
-- LEVEL SECURITY. O papel abaixo é contido pela política em qualquer cenário.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lumia_app') THEN
    CREATE ROLE lumia_app NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lumia_leitura') THEN
    CREATE ROLE lumia_leitura NOLOGIN;
  END IF;
END $$;

COMMENT ON ROLE lumia_app IS
  'Papel da aplicação. Sem BYPASSRLS e sem ser owner: toda consulta passa pela '
  'política de isolamento por tenant_id.';
COMMENT ON ROLE lumia_leitura IS
  'Papel somente-leitura para relatórios operacionais. Também sujeito à RLS.';

GRANT USAGE ON SCHEMA lumia, referencia TO lumia_app, lumia_leitura;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA lumia TO lumia_app;
GRANT SELECT ON ALL TABLES IN SCHEMA referencia TO lumia_app, lumia_leitura;
GRANT SELECT ON ALL TABLES IN SCHEMA lumia TO lumia_leitura;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA lumia TO lumia_app, lumia_leitura;

-- Tabelas criadas em migrations futuras herdam as concessões.
ALTER DEFAULT PRIVILEGES IN SCHEMA lumia
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO lumia_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA lumia
  GRANT SELECT ON TABLES TO lumia_leitura;
ALTER DEFAULT PRIVILEGES IN SCHEMA lumia
  GRANT EXECUTE ON FUNCTIONS TO lumia_app, lumia_leitura;
ALTER DEFAULT PRIVILEGES IN SCHEMA referencia
  GRANT SELECT ON TABLES TO lumia_app, lumia_leitura;

-- A tabela de tenant e de célula são de administração da plataforma: a
-- aplicação de negócio lê, mas não escreve.
REVOKE INSERT, UPDATE, DELETE ON lumia.tenant, lumia.celula FROM lumia_app;

COMMIT;
