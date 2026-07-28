#!/usr/bin/env bash
# =============================================================================
# LUMIA · Teste de concorrência da agenda
# =============================================================================
# A afirmação que este teste sustenta é forte e precisa de prova empírica:
#
#   "Disponibilidade multi-recurso garantida pelo banco, não por lock em Redis."
#
# N sessões PostgreSQL independentes tentam reservar o MESMO recurso no MESMO
# período, simultaneamente. O resultado correto é: exatamente UMA grava, todas
# as outras são recusadas pela exclusion constraint, e o banco termina com uma
# única reserva. Nenhum lock distribuído participa.
#
# Uso:  ./db/tests/test_concorrencia.sh [num_sessoes]
# =============================================================================
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-lumia}"

N="${1:-30}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TENANT='00000000-0000-7000-8000-00000000a001'
ESTAB='00000000-0000-7000-8000-00000000b003'
PROF='00000000-0000-7000-8000-0000000a9001'
REC='00000000-0000-7000-8000-0000000d9001'
CLI='00000000-0000-7000-8000-0000000c9001'
AG='00000000-0000-7000-8000-0000000e9001'
SERV='00000000-0000-7000-8000-00000000e002'
PERIODO="tstzrange('2026-06-01 14:00:00+00','2026-06-01 15:00:00+00','[)')"

echo "→ preparando disputa: $N sessões para o mesmo recurso e horário"

psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc <<SQL
BEGIN;
SET LOCAL lumia.tenant_id = '$TENANT';
-- limpa execução anterior
DELETE FROM lumia.reserva WHERE recurso_id = '$REC';
DELETE FROM lumia.agendamento_item WHERE agendamento_id = '$AG';
DELETE FROM lumia.agendamento WHERE id = '$AG';
DELETE FROM lumia.recurso_agendavel WHERE id = '$REC';
DELETE FROM lumia.profissional WHERE id = '$PROF';
DELETE FROM lumia.cliente WHERE id = '$CLI';

INSERT INTO lumia.profissional (tenant_id,id,numero,nome,vinculo)
 VALUES ('$TENANT','$PROF',9001,'Profissional da disputa','CLT');
INSERT INTO lumia.recurso_agendavel (tenant_id,id,estabelecimento_id,tipo,profissional_id,capacidade)
 VALUES ('$TENANT','$REC','$ESTAB','PROFISSIONAL','$PROF',1);
INSERT INTO lumia.cliente (tenant_id,id,numero,nome)
 VALUES ('$TENANT','$CLI',9001,'Cliente da disputa');
INSERT INTO lumia.agendamento
  (tenant_id,id,estabelecimento_id,cliente_id,numero,inicio_previsto,fim_previsto,data_comercial)
 VALUES ('$TENANT','$AG','$ESTAB','$CLI',9001,
         '2026-06-01 14:00:00+00','2026-06-01 15:00:00+00','2000-01-01');
INSERT INTO lumia.agendamento_item (tenant_id,id,agendamento_id,servico_id,inicio_previsto,fim_previsto)
 SELECT '$TENANT', ('00000000-0000-7000-8000-0000000f9'||lpad(n::text,3,'0'))::uuid,
        '$AG','$SERV','2026-06-01 14:00:00+00','2026-06-01 15:00:00+00'
   FROM generate_series(1,$N) n;
COMMIT;
SQL

echo "→ disparando $N sessões simultâneas"

for i in $(seq 1 "$N"); do
  item=$(printf '00000000-0000-7000-8000-0000000f9%03d' "$i")
  (
    psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc >"$TMP/s$i.out" 2>&1 <<SQL
BEGIN;
SET LOCAL lumia.tenant_id = '$TENANT';
-- todas as sessões acordam praticamente ao mesmo tempo
SELECT pg_sleep(0.30 + random()*0.05);
INSERT INTO lumia.reserva (tenant_id, id, recurso_id, slot, periodo, papel, agendamento_item_id)
VALUES ('$TENANT', lumia.uuid_v7(), '$REC', 1, $PERIODO, 'EXECUTOR', '$item');
COMMIT;
SQL
    echo "rc=$?" >>"$TMP/s$i.out"
  ) &
done
wait

ganhou=$(grep -l 'rc=0' "$TMP"/s*.out | wc -l | tr -d ' ')
recusou=$(grep -c 'rs_sem_sobreposicao' "$TMP"/s*.out | grep -v ':0$' | wc -l | tr -d ' ')
no_banco=$(psql -tAc "SET lumia.tenant_id='$TENANT';
  SELECT count(*) FROM lumia.reserva
   WHERE recurso_id='$REC' AND ativa AND periodo && $PERIODO;" | tail -1)

echo ""
echo "   sessões que gravaram ......... $ganhou"
echo "   recusadas pela constraint .... $recusou"
echo "   reservas no banco ............ $no_banco"
echo ""

falhou=0
[ "$ganhou"   = "1" ] || { echo "FALHOU: esperava exatamente 1 vencedora, obtive $ganhou"; falhou=1; }
[ "$no_banco" = "1" ] || { echo "FALHOU: esperava 1 reserva no banco, obtive $no_banco"; falhou=1; }
[ "$recusou" = "$((N-1))" ] || { echo "FALHOU: esperava $((N-1)) recusas por exclusão, obtive $recusou"; falhou=1; }

# limpa
psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc >/dev/null <<SQL
BEGIN;
SET LOCAL lumia.tenant_id = '$TENANT';
DELETE FROM lumia.reserva WHERE recurso_id = '$REC';
DELETE FROM lumia.agendamento_item WHERE agendamento_id = '$AG';
DELETE FROM lumia.agendamento WHERE id = '$AG';
DELETE FROM lumia.recurso_agendavel WHERE id = '$REC';
DELETE FROM lumia.profissional WHERE id = '$PROF';
DELETE FROM lumia.cliente WHERE id = '$CLI';
COMMIT;
SQL

if [ "$falhou" -eq 0 ]; then
  echo "  OK   $N sessões simultâneas, exatamente 1 reserva — sem lock distribuído"
  exit 0
fi
exit 1
