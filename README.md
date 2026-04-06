# TeleMT — развёртывание MTProto (Fake TLS) на VPS

Скрипт для Ubuntu 24.04 с Docker: поднимает [TeleMT](https://github.com/telemt/telemt) (`ghcr.io/telemt/telemt:latest`) на порту **8443**, создаёт **10** пользователей, сохраняет `tg://proxy` ссылки в `/opt/telemt/MTProto_Links.md`, настраивает UFW (если активен).

**Репозиторий:** [github.com/andycollens/telemt-vps-deploy](https://github.com/andycollens/telemt-vps-deploy)

## Требования на сервере

- Ubuntu 24.04 (или совместимый Debian/Ubuntu)
- Docker и **Docker Compose v2** (`docker compose`)
- `openssl`, `curl`, `python3`
- Запуск от **root** (`sudo`)

## Скачать скрипт на VPS (рекомендуется)

```bash
curl -fsSL "https://raw.githubusercontent.com/andycollens/telemt-vps-deploy/main/deploy-telemt.sh" -o deploy-telemt.sh
chmod +x deploy-telemt.sh
sudo ./deploy-telemt.sh
```

Через `wget`:

```bash
wget -qO deploy-telemt.sh "https://raw.githubusercontent.com/andycollens/telemt-vps-deploy/main/deploy-telemt.sh"
chmod +x deploy-telemt.sh
sudo ./deploy-telemt.sh
```

## Клонирование целиком

```bash
git clone https://github.com/andycollens/telemt-vps-deploy.git
cd telemt-vps-deploy
chmod +x deploy-telemt.sh
sudo ./deploy-telemt.sh
```

## Разработка: push из локальной копии

```bash
git remote add origin https://github.com/andycollens/telemt-vps-deploy.git
git push -u origin main
```

(Если `origin` уже есть: `git remote set-url origin https://github.com/andycollens/telemt-vps-deploy.git`.)

## Что делает скрипт

- Создаёт `/opt/telemt/config`, `/opt/telemt/tlsfront`
- Пересоздаёт `config.toml`, `docker-compose.yml` при повторном запуске (только внутри `/opt/telemt`)
- Запрашивает домен Fake TLS и публичный IP для клиентов
- Поднимает контейнер: `docker compose up --detach --force-recreate` (проект `telemt_proxy`, не трогает остальные контейнеры)
- Открывает порт **8443/tcp** в UFW, если UFW включён
- Ссылки на прокси берёт из Control API TeleMT и пишет в `MTProto_Links.md`

## Безопасность

- Не используйте `curl … | sudo bash` без проверки содержимого скрипта.
- API TeleMT пробрасывается только на **127.0.0.1** на хосте (порт `19091`), наружу не публикуется.

## Лицензия

Скрипт распространяется «как есть». Образ и программа TeleMT — по лицензии проекта [telemt/telemt](https://github.com/telemt/telemt).
