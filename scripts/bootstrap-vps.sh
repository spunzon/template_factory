#!/usr/bin/env bash
# Bootstrap de un VPS Debian limpio. Ejecutar como root UNA vez.
# Idempotente en lo razonable: se puede re-ejecutar sin romper nada.
set -euo pipefail

# ---- 1. Paquetes base y hardening ------------------------------------------
apt-get update
apt-get install -y ufw fail2ban unattended-upgrades ca-certificates curl git

# Firewall: solo SSH, HTTP y HTTPS.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# fail2ban con la jail de sshd por defecto es suficiente.
systemctl enable --now fail2ban

# Actualizaciones de seguridad automáticas.
dpkg-reconfigure -f noninteractive unattended-upgrades

# SSH: sin password, sin root por password. (Asume que YA tienes tu clave puesta.)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh

# ---- 2. Docker ---------------------------------------------------------------
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

# Límite de tamaño de los logs locales de Docker (Loki guarda el histórico;
# esto solo evita que el disco se llene de json-files).
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl restart docker

# ---- 3. Estructura de directorios y red compartida --------------------------
mkdir -p /srv/platform /srv/apps
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

# ---- 4. Usuario de deploy restringido ---------------------------------------
if ! id deploy >/dev/null 2>&1; then
  useradd -m -s /bin/bash deploy
  usermod -aG docker deploy   # necesario para docker compose; el command= limita el resto
fi
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
touch /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

echo
echo "Bootstrap completado. Pasos manuales restantes:"
echo "  1. Clonar el repo platform en /srv/platform y chmod +x scripts/*.sh"
echo "  2. Añadir la clave pública de deploy a authorized_keys CON el prefijo:"
echo '     command="/srv/platform/scripts/deploy-app.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAA...'
echo "  3. Como usuario deploy: docker login ghcr.io (PAT read:packages)"
echo "  4. Copiar platform/.env.example a .env, rellenar y: docker compose up -d"
echo "  5. Configurar borgmatic (ver borgmatic/config.yaml)"
