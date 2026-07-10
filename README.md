# platform

Plataforma personal para desplegar N SaaS en un único VPS (Hetzner/Debian) con la propiedad central de diseño: **mejorar una pieza compartida una vez afecta a todos los proyectos**, sin crear canales de interferencia entre ellos.

Principio rector: **se comparten definiciones, no instancias**. Solo hay instancia compartida donde es irreducible (Traefik, el host) o read-only respecto a las apps (Loki, Grafana, Prometheus).

## Estructura

```
platform/
├── .github/workflows/deploy.yml   # Reusable workflow: build -> GHCR -> deploy SSH
├── platform/                      # Compose de infraestructura (-> /srv/platform)
│   ├── docker-compose.yml         # Traefik, Loki, Alloy, Grafana, Prometheus, cAdvisor
│   ├── loki/  alloy/  prometheus/  grafana/
│   └── .env.example
├── template/                      # Plantilla de proyecto (el "contrato")
│   ├── docker-compose.yml         # app + Postgres propio, redes aisladas, limits
│   ├── github-workflow-deploy.yml # caller de 10 líneas para cada repo de proyecto
│   ├── .env.example
│   └── allowed_hosts.example
├── scripts/
│   ├── bootstrap-vps.sh           # hardening + Docker + usuario deploy (una vez)
│   ├── deploy-app.sh              # comando SSH forzado: valida y despliega
│   └── dump-databases.sh          # hook de backup: pg_dump de todos los *-db
└── borgmatic/config.yaml          # backups a Hetzner Storage Box + dead man's switch
```

## El contrato de proyecto

Un proyecto es desplegable en la plataforma si cumple exactamente esto:

1. Se expone vía labels de Traefik en la red `proxy` (nunca puertos publicados).
2. Loguea **JSON a stdout**. Sin ficheros de log.
3. Expone `GET /health` (el deploy espera al healthcheck antes de dar OK).
4. Lee su configuración de variables de entorno.
5. Recibe `DATABASE_URL` apuntando a **su** Postgres (red interna propia).
6. Declara limits de CPU/RAM (vienen en la plantilla).

Nada más. El proyecto no sabe que existe Loki, ni Let's Encrypt, ni borgmatic.

## Orden de montaje

1. **VPS**: ejecutar `scripts/bootstrap-vps.sh` como root. Seguir los pasos manuales que imprime al final (clave de deploy con `command=`, login en GHCR).
2. **Plataforma**: clonar este repo en `/srv/platform`, copiar `platform/.env.example` a `.env`, rellenar, y `docker compose up -d` dentro de `platform/`. Verificar Grafana en `https://grafana.tudominio.com`.
3. **Primer proyecto**: ver siguiente sección.
4. **Backups**: instalar borgmatic, adaptar `borgmatic/config.yaml`, crear check en healthchecks.io, `borgmatic init`, activar el timer. Probar un restore.
5. **Fase 2** (cuando todo ruede): migrar secretos de `.env` a SOPS+age para que la plataforma entera sea reproducible desde este repo.

## Añadir un proyecto nuevo

En el VPS:

```bash
mkdir /srv/apps/mi-saas && cd /srv/apps/mi-saas
cp /srv/platform/template/docker-compose.yml .
cp /srv/platform/template/.env.example .env        # rellenar
cp /srv/platform/template/allowed_hosts.example allowed_hosts  # sus dominios
```

En el repo del proyecto (GitHub):

1. Copiar `template/github-workflow-deploy.yml` a `.github/workflows/deploy.yml` y poner su `app_name`.
2. Secrets del repo: `DEPLOY_SSH_KEY` (clave privada del usuario deploy) y `DEPLOY_HOST` (IP del VPS).
3. Apuntar el DNS del dominio al VPS.
4. Push a `main`. El reusable testea, construye, publica en GHCR y despliega. Traefik descubre la app y pide el certificado solo.

## Dónde se mejora cada cosa (la tabla que justifica el diseño)

| Quiero mejorar...            | Toco...                                   | Afecta a |
| ---------------------------- | ----------------------------------------- | -------- |
| Pipeline CI/CD               | `.github/workflows/deploy.yml`            | todos    |
| Parseo/retención de logs     | `platform/alloy/config.alloy`, `loki/`    | todos    |
| Política TLS / headers       | `platform/docker-compose.yml` (Traefik)   | todos    |
| Alertas y dashboards         | Grafana / `prometheus/`                   | todos    |
| Estrategia de backup         | `borgmatic/config.yaml`                   | todos    |
| Config base de proyectos     | `template/docker-compose.yml`             | próximos deploys de cada app al re-copiarla |
| Código de un SaaS            | su propio repo                            | solo él  |

## Decisiones de diseño (resumen)

- **Postgres por proyecto**, no compartido: se comparte la plantilla y el mecanismo de backup, no el proceso. Cero interferencia lateral (queries, conexiones, disco, versiones).
- **Alloy lee contenedores por fuera**, no logging driver de Loki: Loki caído = apps intactas.
- **Deploy por SSH con comando forzado**: la clave en GitHub solo puede ejecutar `deploy-app.sh`, que valida nombre, tag y dominios (`allowed_hosts`) antes de tocar nada.
- **Redes internas por proyecto** (`internal: true`): el contenedor de A no puede ni resolver la base de datos de B.
- **Limits en la plantilla**: la protección contra el OOM-killer viene de serie.
- **Sin k8s, sin PaaS**: a esta escala, toda la propiedad de mejora central la dan los reusable workflows y las plantillas. La plataforma debe ser aburrida para que los productos puedan ser interesantes.
