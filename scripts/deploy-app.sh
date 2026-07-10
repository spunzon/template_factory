#!/usr/bin/env bash
# Comando FORZADO de la clave SSH de deploy. En ~deploy/.ssh/authorized_keys:
#
#   command="/srv/platform/scripts/deploy-app.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... deploy@github
#
# La clave NO puede ejecutar nada más: aunque se filtre en GitHub, el radio
# de explosión es "puede desplegar apps existentes", no "tiene una shell".
set -euo pipefail

log() { echo "[deploy] $*"; }

# ---- 1. Parsear y validar la orden: "deploy <app> <tag>" -------------------
read -r cmd app tag _ <<<"${SSH_ORIGINAL_COMMAND:-}"

[[ "$cmd" == "deploy" ]] || { log "orden desconocida"; exit 1; }
[[ "$app" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] || { log "nombre de app inválido"; exit 1; }
[[ "$tag" =~ ^([a-f0-9]{7,40}|latest)$ ]] || { log "tag inválido"; exit 1; }

dir="/srv/apps/$app"
[[ -d "$dir" && -f "$dir/docker-compose.yml" ]] || { log "app '$app' no existe en /srv/apps"; exit 1; }
cd "$dir"

# ---- 2. Validación de labels: la app solo puede reclamar SUS dominios ------
if [[ -f allowed_hosts ]]; then
  # Extrae todos los Host(`...`) del compose renderizado y compáralos.
  mapfile -t claimed < <(docker compose config 2>/dev/null \
    | grep -oP 'Host\(`\K[^`]+' | sort -u)
  for host in "${claimed[@]:-}"; do
    [[ -z "$host" ]] && continue
    if ! grep -qxF "$host" allowed_hosts; then
      log "RECHAZADO: la app reclama '$host', no está en allowed_hosts"
      exit 1
    fi
  done
else
  log "aviso: sin allowed_hosts, se omite validación de dominios"
fi

# ---- 3. Desplegar -----------------------------------------------------------
log "desplegando $app @ $tag"
export IMAGE_TAG="$tag"
# Persistir el tag desplegado para que un 'up' manual futuro use la misma imagen.
grep -q '^IMAGE_TAG=' .env && sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$tag/" .env || echo "IMAGE_TAG=$tag" >> .env

docker compose pull app
docker compose up -d

# ---- 4. Esperar al healthcheck: deploy en rojo si la app no levanta --------
for _ in $(seq 1 30); do
  status="$(docker inspect --format '{{.State.Health.Status}}' "${app}-app" 2>/dev/null || echo starting)"
  if [[ "$status" == "healthy" ]]; then
    log "OK: $app healthy con $tag"
    exit 0
  fi
  sleep 2
done

log "FALLO: $app no alcanzó estado healthy en 60s"
docker logs --tail 30 "${app}-app" || true
exit 1
