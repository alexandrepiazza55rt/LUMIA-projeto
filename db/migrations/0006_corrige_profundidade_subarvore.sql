-- =============================================================================
-- LUMIA · 0006 — Correção: profundidade ao mover subárvore
-- =============================================================================
-- Bug encontrado pelo teste 9 da suíte de fundação.
--
-- O trigger de reposicionamento calculava:
--     profundidade = nlevel(NEW.caminho) + (nlevel(caminho) - nlevel(OLD.caminho))
--
-- misturando duas escalas diferentes: nlevel() conta rótulos (1-based) e
-- profundidade é a distância até a raiz (0-based). Mover a sala de Pinheiros
-- para Manaus — dois estabelecimentos na MESMA profundidade — deixava a cadeira
-- com profundidade 5 em vez de 4, embora seu caminho estivesse correto.
--
-- Consequência se não corrigido: qualquer relatório ou tela que agrupe por
-- profundidade (indentação da árvore, "unidades de primeiro nível", limites de
-- aninhamento por plano) passaria a mentir depois da primeira reorganização de
-- estrutura — que é justamente o que acontece quando o salão reforma ou muda
-- uma sala de unidade.
--
-- A correção deriva a profundidade do PRÓPRIO caminho novo da linha, que é a
-- única fonte de verdade: profundidade = nlevel(caminho) - 1.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION lumia.tg_no_org_move_subarvore() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.caminho IS DISTINCT FROM OLD.caminho THEN
    UPDATE lumia.no_org d
       SET caminho      = NEW.caminho || subpath(d.caminho, nlevel(OLD.caminho)),
           profundidade = nlevel(NEW.caminho || subpath(d.caminho, nlevel(OLD.caminho))) - 1,
           atualizado_em = now()
     WHERE d.tenant_id = NEW.tenant_id
       AND d.caminho <@ OLD.caminho
       AND d.id <> NEW.id;
  END IF;
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION lumia.tg_no_org_move_subarvore() IS
  'Reposiciona a subárvore quando um nó troca de pai. A profundidade é derivada '
  'do caminho novo de cada descendente (nlevel - 1), nunca de aritmética entre '
  'profundidades antigas — foi essa aritmética que introduziu o erro de 1 '
  'corrigido nesta migration.';

-- Reparo de dados: recalcula a profundidade de toda a árvore a partir do
-- caminho, corrigindo qualquer linha já gravada com o valor errado.
UPDATE lumia.no_org SET profundidade = nlevel(caminho) - 1
 WHERE profundidade <> nlevel(caminho) - 1;

COMMIT;
