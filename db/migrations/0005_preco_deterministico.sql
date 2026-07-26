-- =============================================================================
-- LUMIA · 0005 — Resolução de preço determinística
-- =============================================================================
-- Encontrado pelo próprio teste de fundação: lumia.tabela_preco permitia que
-- duas tabelas com a MESMA prioridade, mesmo estabelecimento e mesmo canal
-- tivessem vigências sobrepostas. Nesse caso lumia.preco_vigente() escolheria
-- uma das duas de forma arbitrária — dois atendentes lançariam preços
-- diferentes para o mesmo serviço no mesmo dia, e o desconto apareceria como
-- não explicado na auditoria de margem.
--
-- A sobreposição ENTRE PRIORIDADES DIFERENTES continua permitida: é justamente
-- assim que uma tabela de convênio (prioridade maior) convive com a tabela
-- geral. O que passa a ser impossível é o empate ambíguo.
-- =============================================================================

BEGIN;

ALTER TABLE lumia.tabela_preco
  ADD CONSTRAINT tp_sem_empate_ambiguo
  EXCLUDE USING gist (
    tenant_id WITH =,
    coalesce(estabelecimento_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    canal WITH =,
    prioridade WITH =,
    vigencia WITH &&
  ) WHERE (ativa);

COMMENT ON CONSTRAINT tp_sem_empate_ambiguo ON lumia.tabela_preco IS
  'Duas tabelas ativas com a mesma prioridade, mesmo escopo de estabelecimento e '
  'mesmo canal não podem ter vigências sobrepostas — isso tornaria a resolução '
  'de preço arbitrária. Prioridades distintas podem e devem se sobrepor.';

COMMIT;
