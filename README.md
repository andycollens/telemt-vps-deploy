# TeleMT — развёртывание MTProto (Fake TLS) на VPS

Скрипт для Ubuntu 24.04 с Docker: поднимает [TeleMT](https://github.com/telemt/telemt) (`ghcr.io/telemt/telemt:latest`) на порту **8443**, создаёт **10** пользователей, сохраняет `tg://proxy` ссылки в `/opt/telemt/MTProto_Links.md`, настраивает UFW (если активен).

## Требования на сервере

- Ubuntu 24.04 (или совместимый Debian/Ubuntu)
- Docker и **Docker Compose v2** (`docker compose`)
- `openssl`, `curl`, `python3`
- Запуск от **root** (`sudo`)

## Быстрый старт с GitHub

1. Создайте на GitHub новый репозиторий (можно пустой, без README).
2. На своей машине (где уже есть этот код) добавьте remote и отправьте ветку:

   ```bash
   cd /path/to/telemt
   git init
   git add deploy-telemt.sh README.md .gitignore
   git commit -m "Initial commit: TeleMT deploy script"
   git branch -M main
   git remote add origin https://github.com/<ВАШ_НИК>/<ИМЯ_РЕПО>.git
   git push -u origin main
   ```

3. На **VPS** скачайте скрипт и запустите:

   ```bash
   curl -fsSL "https://raw.githubusercontent.com/<ВАШ_НИК>/<ИМЯ_РЕПО>/main/deploy-telemt.sh" -o deploy-telemt.sh
   chmod +x deploy-telemt.sh
   sudo ./deploy-telemt.sh
   ```

   Либо через `wget`:

   ```bash
   wget -qO deploy-telemt.sh "https://raw.githubusercontent.com/<ВАШ_НИК>/<ИМЯ_РЕПО>/main/deploy-telemt.sh"
   chmod +x deploy-telemt.sh
   sudo ./deploy-telemt.sh
   ```

   Замените `<ВАШ_НИК>` и `<ИМЯ_РЕПО>` на ваши значения. Если основная ветка не `main`, замените её в URL.

## Клонирование целиком (альтернатива)

```bash
git clone https://github.com/<ВАШ_НИК>/<ИМЯ_РЕПО>.git
cd <ИМЯ_РЕПО>
chmod +x deploy-telemt.sh
sudo ./deploy-telemt.sh
```

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
