#!/usr/bin/env bash
# n8n-install-v2.sh
# patched installer (domain confirm + safe nginx + cloudflare dir)

set -euo pipefail

# ===== defaults =====
DEFAULT_TZ="America/Edmonton"
DEFAULT_DOMAIN="demo.demostest.org"
DEFAULT_N8N_DIR="/opt/n8n"
DEFAULT_N8N_USER="deploy"
DEFAULT_DB_PASS="$(openssl rand -hex 16)"
DEFAULT_ENC_KEY="$(openssl rand -base64 48)"

# ===== ui =====
c() { printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
h1(){ c "1;36" "== $* =="; }
ok(){ c "1;32" "✔ $*"; }
warn(){ c "1;33" "!  $*"; }
err(){ c "1;31" "✖  $*"; }

ask(){
  local q="$1" d="$2" a
  read -r -p "$q [$d]: " a
  echo "${a:-$d}"
}

need_root(){
  if [ "$EUID" -ne 0 ]; then
    err "Run as root: sudo bash $0"
    exit 1
  fi
}

need_root

h1 "n8n Easy Installer (patched)"

# --- timezone ---
TZ_CHOICE=$(ask "Timezone" "$DEFAULT_TZ")

# --- domain with confirmation ---
while true; do
  DOMAIN_CHOICE=$(ask "n8n domain (FQDN)" "$DEFAULT_DOMAIN")
  c "1;37" "You entered: $DOMAIN_CHOICE"
  CONFIRM=$(ask "Is this correct? (y/N)" "y")
  case "$CONFIRM" in
    y|Y) break ;;
    *) warn "Let's try again…" ;;
  esac
done

# --- basic stuff ---
N8N_DIR=$(ask "n8n install directory" "$DEFAULT_N8N_DIR")
N8N_SYSUSER=$(ask "Create/use non-root user" "$DEFAULT_N8N_USER")

echo
echo "SSL options:"
echo "  1) Cloudflare Origin cert (we will NOT reload if missing)"
echo "  2) Custom cert/key paths"
echo "  3) Let's Encrypt (certbot)"
SSL_MODE=$(ask "Choose SSL mode (1/2/3)" "1")

LOCK_443=$(ask "Restrict 443 to Cloudflare IPs? (y/N)" "N")

# ===== 1. system prep =====
h1 "1) System prep"
timedatectl set-timezone "$TZ_CHOICE"
apt update
apt -y upgrade
apt -y install curl ca-certificates gnupg lsb-release unzip jq htop
apt -y install ufw fail2ban unattended-upgrades
ufw allow OpenSSH
ufw allow 80,443/tcp
ufw --force enable
dpkg-reconfigure --priority=low unattended-upgrades || true
ok "Base system ready."

# ===== 2. user =====
h1 "2) User"
if id "$N8N_SYSUSER" >/dev/null 2>&1; then
  ok "User $N8N_SYSUSER exists."
else
  adduser --disabled-password --gecos "" "$N8N_SYSUSER"
  ok "User $N8N_SYSUSER created."
fi
usermod -aG sudo "$N8N_SYSUSER"

# ===== 3. docker =====
h1 "3) Docker"
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
ARCH="$(dpkg --print-architecture)"
. /etc/os-release
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt update
apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "$N8N_SYSUSER"
ok "Docker installed & enabled."

# ===== 4. n8n directory / env =====
h1 "4) n8n directory & .env"
mkdir -p "$N8N_DIR"
chown "$N8N_SYSUSER:$N8N_SYSUSER" "$N8N_DIR"
cd "$N8N_DIR"

cat > "$N8N_DIR/.env" <<EOF
N8N_HOST=${DOMAIN_CHOICE}
N8N_PROTOCOL=https
WEBHOOK_URL=https://${DOMAIN_CHOICE}/
N8N_ENCRYPTION_KEY=${DEFAULT_ENC_KEY}
GENERIC_TIMEZONE=${TZ_CHOICE}
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${DEFAULT_DB_PASS}
EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
EOF
ok ".env created at $N8N_DIR/.env"

# ===== 5. docker compose =====
h1 "5) docker-compose.yml"
cat > "$N8N_DIR/docker-compose.yml" <<'YML'
services:
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: n8n
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${DB_POSTGRESDB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: ["redis-server", "--save", "60", "1", "--loglevel", "warning"]
    volumes:
      - redis_data:/data

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "5678:5678"
    depends_on:
      - postgres
      - redis
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  postgres_data:
  redis_data:
  n8n_data:
YML

# strip legacy 'version:'
sed -i '/^version:/d' "$N8N_DIR/docker-compose.yml"

# ===== 6. start stack =====
h1 "6) Start n8n stack"
docker compose pull
docker compose up -d
docker compose ps
ok "n8n running on http://127.0.0.1:5678/"

# ===== 7. nginx & ssl =====
h1 "7) Nginx & SSL"
apt -y install nginx
mkdir -p /etc/ssl/cloudflare

CERT_PATH=""
KEY_PATH=""
ENABLE_NGINX=1   # we'll flip to 0 if certs missing

case "$SSL_MODE" in
  1)
    # Cloudflare
    curl -fsSL https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem \
      -o /etc/ssl/cloudflare/cloudflare_origin_ca.pem || true
    CERT_PATH="/etc/ssl/cloudflare/${DOMAIN_CHOICE}.origin.crt"
    KEY_PATH="/etc/ssl/cloudflare/${DOMAIN_CHOICE}.origin.key"

    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
      ENABLE_NGINX=0
      warn "Cloudflare mode: cert/key NOT found."
      warn "Create them with:"
      warn "  sudo nano $CERT_PATH"
      warn "  sudo nano $KEY_PATH"
      warn "then: sudo nginx -t && sudo systemctl reload nginx"
    fi
    ;;
  2)
    CERT_PATH=$(ask "Full path to SSL certificate" "/etc/ssl/private/${DOMAIN_CHOICE}.crt")
    KEY_PATH=$(ask "Full path to SSL private key" "/etc/ssl/private/${DOMAIN_CHOICE}.key")
    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
      ENABLE_NGINX=0
      warn "Custom mode: one of the paths does not exist. Nginx will NOT reload."
    fi
    ;;
  3)
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/bin/certbot
    mkdir -p /var/www/html
    cat > /etc/nginx/sites-available/n8n-le <<NGH
server {
  listen 80;
  server_name ${DOMAIN_CHOICE};
  location /.well-known/acme-challenge/ {
    root /var/www/html;
  }
  location / {
    return 301 https://\$host\$request_uri;
  }
}
NGH
    ln -sf /etc/nginx/sites-available/n8n-le /etc/nginx/sites-enabled/n8n-le
    nginx -t && systemctl reload nginx
    certbot certonly --nginx -d "${DOMAIN_CHOICE}" --non-interactive --agree-tos -m admin@"${DOMAIN_CHOICE}" || true
    CERT_PATH="/etc/letsencrypt/live/${DOMAIN_CHOICE}/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/${DOMAIN_CHOICE}/privkey.pem"
    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
      ENABLE_NGINX=0
      warn "Let's Encrypt did not issue cert. Check DNS or Cloudflare proxy."
    fi
    ;;
  *)
    err "Unknown SSL mode."
    exit 1
    ;;
esac

# write site regardless, but only enable if certs exist
cat > /etc/nginx/sites-available/n8n <<NGINX
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

server {
  listen 80;
  server_name ${DOMAIN_CHOICE};
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name ${DOMAIN_CHOICE};

  ssl_certificate     ${CERT_PATH};
  ssl_certificate_key ${KEY_PATH};

  # okay to leave even if file missing; we disable reload when missing
  ssl_client_certificate /etc/ssl/cloudflare/cloudflare_origin_ca.pem;
  ssl_verify_client off;

  ssl_protocols TLSv1.2 TLSv1.3;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;

  location / {
    proxy_pass http://127.0.0.1:5678;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    client_max_body_size 20m;
  }
}
NGINX

ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n

if [ "$ENABLE_NGINX" -eq 1 ]; then
  nginx -t && systemctl reload nginx
  ok "Nginx configured and reloaded for ${DOMAIN_CHOICE}"
else
  warn "Nginx config written, but NOT reloaded because cert/key missing."
  warn "After you paste certs, run:"
  warn "  sudo nginx -t && sudo systemctl reload nginx"
fi

# ===== 8. optional 443 lock =====
if [[ "${LOCK_443^^}" == "Y" ]]; then
  h1 "8) Lock 443 to Cloudflare"
  cat > /usr/local/sbin/lock-443-to-cloudflare.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y ipset netfilter-persistent >/dev/null 2>&1
ipset create cf4 hash:net -exist
ipset create cf6 hash:net family inet6 -exist
ipset flush cf4
ipset flush cf6
curl -fsSL https://www.cloudflare.com/ips-v4 | while read -r net; do [ -n "$net" ] && ipset add cf4 "$net"; done
curl -fsSL https://www.cloudflare.com/ips-v6 | while read -r net; do [ -n "$net" ] && ipset add cf6 "$net"; done
iptables  -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables  -I INPUT -p tcp --dport 22 -j ACCEPT
iptables  -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables  -I INPUT -p tcp --dport 80 -j ACCEPT
ip6tables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables  -C INPUT -p tcp --dport 443 -m set --match-set cf4 src -j ACCEPT 2>/dev/null || iptables  -I INPUT -p tcp --dport 443 -m set --match-set cf4 src -j ACCEPT
ip6tables -C INPUT -p tcp --dport 443 -m set --match-set cf6 src -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport 443 -m set --match-set cf6 src -j ACCEPT
iptables  -C INPUT -p tcp --dport 443 -j DROP 2>/dev/null || iptables  -A INPUT -p tcp --dport 443 -j DROP
ip6tables -C INPUT -p tcp --dport 443 -j DROP 2>/dev/null || ip6tables -A INPUT -p tcp --dport 443 -j DROP
netfilter-persistent save >/dev/null 2>&1 || true
BASH
  chmod +x /usr/local/sbin/lock-443-to-cloudflare.sh
  /usr/local/sbin/lock-443-to-cloudflare.sh
  cat > /etc/cron.d/refresh-cf-ipsets <<'CRON'
17 3 * * * root /usr/local/sbin/lock-443-to-cloudflare.sh >/var/log/lock-443-to-cloudflare.log 2>&1
CRON
  ok "443 locked to Cloudflare."
fi

h1 "DONE ✅"
echo "n8n URL (once cert is in place): https://${DOMAIN_CHOICE}/"
echo "n8n dir: ${N8N_DIR}"
echo "DB password (in .env): ${DEFAULT_DB_PASS}"
if [ "$ENABLE_NGINX" -eq 0 ]; then
  warn "Remember to paste certs and run: sudo nginx -t && sudo systemctl reload nginx"
fi
