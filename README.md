# 🧩 n8n Easy Installer

An **automated shell installer** for setting up **n8n** with Docker, PostgreSQL, Redis, and Nginx — featuring built-in SSL support, Cloudflare compatibility, and safe configuration handling.

This version includes **safety patches** to prevent crashes when the domain or certificate paths are missing or mistyped.

## ⚙️ Features

- One-command setup for Docker, Docker Compose, and supporting packages
- n8n + Postgres + Redis (queue mode) in Docker
- Nginx reverse proxy with HTTP → HTTPS
- 3 SSL modes (Cloudflare Origin, Custom paths, Let's Encrypt)
- Basic hardening (UFW, fail2ban, unattended-upgrades)
- Optional 443 lock to Cloudflare IPs

## 🚀 Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/ReyadWeb/n8n-easy-install/main/scripts/n8n-install.sh -o n8n-install.sh
chmod +x n8n-install.sh
sudo ./n8n-install.sh
```

## 🔒 Adding SSL Certificates (Cloudflare mode)

```bash
sudo mkdir -p /etc/ssl/cloudflare
sudo nano /etc/ssl/cloudflare/yourdomain.com.origin.crt
sudo nano /etc/ssl/cloudflare/yourdomain.com.origin.key
sudo chown root:root /etc/ssl/cloudflare/yourdomain.com.origin.*
sudo chmod 600 /etc/ssl/cloudflare/yourdomain.com.origin.key
sudo nginx -t && sudo systemctl reload nginx
```

## 🧰 Managing n8n

```bash
cd /opt/n8n
docker compose ps
docker compose logs -f n8n
docker compose restart n8n
```

Visit: `https://yourdomain.com/`

## 🧠 Troubleshooting

- If you see "Welcome to nginx!" → fix `server_name` in `/etc/nginx/sites-available/n8n`
- If nginx cannot load certificate → create the files under `/etc/ssl/cloudflare/...` and reload

## 🪪 License

MIT License © 2025 ReyadWeb
