#!/usr/bin/env bash
# Hook pre-backup de borgmatic: hace pg_dump de TODAS las bases de datos
# de proyecto. Encuentra los contenedores por convención de nombre (*-db).
# Compartimos el MECANISMO de backup, no la instancia de Postgres:
# añadir un proyecto nuevo no requiere tocar este script.
set -euo pipefail

for c in $(docker ps --format '{{.Names}}' | grep -- '-db$' || true); do
  app="${c%-db}"
  outdir="/srv/apps/$app/backups"
  mkdir -p "$outdir"

  echo "[dump] $c -> $outdir"
  # pg_dumpall con el usuario definido en el .env del proyecto.
  user="$(docker exec "$c" printenv POSTGRES_USER)"
  docker exec "$c" pg_dumpall -U "$user" | gzip > "$outdir/dump-$(date +%F).sql.gz"

  # Conservar solo los 3 dumps locales más recientes (el histórico vive en Borg).
  ls -t "$outdir"/dump-*.sql.gz 2>/dev/null | tail -n +4 | xargs -r rm --
done
