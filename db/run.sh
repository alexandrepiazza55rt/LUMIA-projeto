#!/usr/bin/env bash
# =============================================================================
# LUMIA · Aplica migrations, seed e testes de fundação
# =============================================================================
# Uso:
#   ./db/run.sh                      # migrations + seed + testes
#   ./db/run.sh --sem-seed           # apenas migrations + testes de estrutura
#   ./db/run.sh --so-testes          # apenas a suíte de testes
#
# Variáveis (com padrões para desenvolvimento local):
#   PGHOST PGPORT PGUSER PGDATABASE
# =============================================================================
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-lumia}"

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSQL=(psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc)

com_seed=1
so_testes=0
for arg in "$@"; do
  case "$arg" in
    --sem-seed)  com_seed=0 ;;
    --so-testes) so_testes=1 ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

echo "→ banco: $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"

if [[ "$so_testes" -eq 0 ]]; then
  echo ""
  echo "→ migrations"
  for f in "$RAIZ"/migrations/*.sql; do
    printf '   %-46s' "$(basename "$f")"
    "${PSQL[@]}" -f "$f" >/dev/null
    echo "ok"
  done

  if [[ "$com_seed" -eq 1 ]]; then
    echo ""
    echo "→ seed de demonstração"
    printf '   %-46s' "seed_demo.sql"
    "${PSQL[@]}" -f "$RAIZ/seed_demo.sql" >/dev/null
    echo "ok"
  fi
fi

# As suítes SQL terminam em ROLLBACK: podem rodar quantas vezes for preciso.
total=0
for suite in test_fundacao test_agenda test_balcao; do
  echo ""
  echo "→ $suite"
  saida="$("${PSQL[@]}" -f "$RAIZ/tests/$suite.sql" 2>&1)"
  echo "$saida" | sed 's/psql:[^ ]*: NOTICE:  //' | grep -E '^(=== | +OK |====)|PASSARAM' || true
  n="$(echo "$saida" | grep -c 'OK  ' || true)"
  total=$((total + n))
done

if [[ "$com_seed" -eq 1 ]]; then
  echo ""
  echo "→ concorrência (prova que o EXCLUDE dispensa lock distribuído)"
  if "$RAIZ/tests/test_concorrencia.sh" 30 2>&1 | grep -E '^(   |  OK|FALHOU)'; then
    total=$((total + 1))
  else
    echo "FALHOU: teste de concorrência"; exit 1
  fi
fi

echo ""
echo "→ $total asserções passaram"
