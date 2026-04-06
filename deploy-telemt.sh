#!/usr/bin/env bash
#===============================================================================
# TeleMT (Fake TLS / EE) — развёртывание через Docker Compose на Ubuntu 24.04
# Образ: ghcr.io/telemt/telemt:latest
#
# Безопасность для остального Docker:
#   - Только docker compose -f /opt/telemt/docker-compose.yml -p telemt_proxy …
#   - Нет docker prune, нет остановки «чужих» контейнеров/volumes
#   - Публикуется только 8443 (прокси) и 127.0.0.1:19091 (API для снятия ссылок)
#===============================================================================
set -euo pipefail

readonly TELEMT_ROOT="/opt/telemt"
readonly CFG_DIR="${TELEMT_ROOT}/config"
readonly TLS_DIR="${TELEMT_ROOT}/tlsfront"
readonly COMPOSE_FILE="${TELEMT_ROOT}/docker-compose.yml"
readonly CONFIG_FILE="${CFG_DIR}/config.toml"
readonly LINKS_MD="${TELEMT_ROOT}/MTProto_Links.md"
readonly PROXY_PORT="8443"
readonly API_HOST_PORT="19091"
readonly COMPOSE_PROJECT="telemt_proxy"
readonly TELEMT_USER_COUNT_MIN=1
readonly TELEMT_USER_COUNT_MAX=100

# Заполняется в detect_docker_compose(): ("docker" "compose") или ("docker-compose")
COMPOSE_CMD_WORDS=()

# Имена пользователей после prompt_user_count_and_names()
TELEMT_USERNAMES=()

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Ошибка: не найдена команда '$1'." >&2; exit 1; }
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Запустите скрипт от root (sudo)." >&2
    exit 1
  fi
}

prompt_nonempty() {
  local var_name="$1" prompt_text="$2" val=""
  while [[ -z "${val}" ]]; do
    read -r -p "${prompt_text} " val
    val="$(echo -n "${val}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  done
  printf -v "$var_name" '%s' "${val}"
}

# Публичный IPv4 (исходящий) через внешние сервисы; только IPv4 (-4)
detect_public_ipv4() {
  local ip="" url
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com" \
    "https://checkip.amazonaws.com"
  do
    ip="$(curl -4 -fsS --connect-timeout 4 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# Авто-IP с сервера; при отказе или сбое — ввод IPv4 или hostname
prompt_public_ip_or_host() {
  local var_name="$1"
  local detected ans

  echo "Определение публичного IPv4 (исходящий запрос с сервера)…"
  if detected="$(detect_public_ipv4)"; then
    echo "Обнаружен публичный IPv4: ${detected}"
    read -r -p "Использовать его в ссылках tg://proxy? [Y/n]: " ans
    ans="$(echo "${ans:-Y}" | tr '[:upper:]' '[:lower:]')"
    case "${ans}" in
      ""|y|yes|д|да)
        printf -v "$var_name" '%s' "${detected}"
        return 0
        ;;
    esac
    echo "Введите другой публичный IPv4 или hostname для клиентов."
  else
    echo "Автоопределение не удалось (сеть, файрвол или сервис недоступен)."
    echo "Введите публичный IPv4 или hostname вручную."
  fi
  prompt_nonempty "$var_name" "Публичный адрес для клиентов:"
}

# Сколько пользователей и имена (Enter = user001, user002, … по номеру слота)
prompt_user_count_and_names() {
  local n raw name i j duplicate
  TELEMT_USERNAMES=()

  while true; do
    read -r -p "Сколько пользователей создать (${TELEMT_USER_COUNT_MIN}–${TELEMT_USER_COUNT_MAX})? " n
    n="$(echo -n "${n}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= TELEMT_USER_COUNT_MIN && n <= TELEMT_USER_COUNT_MAX )); then
      break
    fi
    echo "Введите целое число от ${TELEMT_USER_COUNT_MIN} до ${TELEMT_USER_COUNT_MAX}."
  done

  echo
  echo "Имена (как в TeleMT: буквы, цифры, _, точка, дефис; длина 1–64). Пустой Enter — авто: user001, user002, …"
  for ((i=1; i<=n; i++)); do
    while true; do
      read -r -p "Пользователь #${i} [Enter = user$(printf '%03d' "${i}")]: " raw
      raw="$(echo -n "${raw}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [[ -z "${raw}" ]]; then
        name="$(printf 'user%03d' "${i}")"
      else
        name="${raw}"
      fi
      if (( ${#name} < 1 || ${#name} > 64 )); then
        echo "Длина имени должна быть от 1 до 64 символов."
        continue
      fi
      if [[ ! "${name}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "Допустимы только символы: A–Z, a–z, 0–9, _, ., -"
        continue
      fi
      duplicate=0
      for ((j=0; j<${#TELEMT_USERNAMES[@]}; j++)); do
        if [[ "${TELEMT_USERNAMES[j]}" == "${name}" ]]; then
          duplicate=1
          break
        fi
      done
      if (( duplicate )); then
        echo "Имя «${name}» уже занято — введите другое или оставьте Enter для автогенерации."
        continue
      fi
      TELEMT_USERNAMES+=("${name}")
      break
    done
  done
  echo
}

# Пересоздание артефактов при оборванной установке (только наша директория)
reset_local_artifacts() {
  mkdir -p "${CFG_DIR}" "${TLS_DIR}"
  rm -f "${COMPOSE_FILE}" "${CONFIG_FILE}" "${LINKS_MD}"
  find "${TLS_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

gen_hex_secret() {
  openssl rand -hex 16
}

# Аргументы: домен, публичный хост, файл секретов, затем список имён пользователей
write_config_toml() {
  local fake_tls_domain="$1" public_ip="$2" secrets_out="$3"
  shift 3
  local name sec

  if [[ $# -lt 1 ]]; then
    echo "Внутренняя ошибка: список пользователей пуст." >&2
    exit 1
  fi

  : > "${secrets_out}"
  cat > "${CONFIG_FILE}" <<EOF
### TeleMT — автогенерация (Fake TLS, порт ${PROXY_PORT})
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${public_ip}"
public_port = ${PROXY_PORT}

[server]
port = ${PROXY_PORT}

[server.api]
enabled = true
listen = "0.0.0.0:9091"
# Пустой whitelist = разрешить все источники (см. docs/API.md TeleMT).
# API наружу не публикуем — только 127.0.0.1:${API_HOST_PORT} на хосте.
whitelist = []
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${fake_tls_domain}"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
EOF

  for name in "$@"; do
    sec="$(gen_hex_secret)"
    echo "${name} ${sec}" >> "${secrets_out}"
    # Ключ в кавычках — допустима точка в имени (TeleMT), без конфликта с синтаксисом TOML
    printf '"%s" = "%s"\n' "${name}" "${sec}" >> "${CONFIG_FILE}"
  done
}

write_compose() {
  cat > "${COMPOSE_FILE}" <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt_proxy
    restart: unless-stopped
    working_dir: /run/telemt
    ports:
      - "${PROXY_PORT}:${PROXY_PORT}"
      - "127.0.0.1:${API_HOST_PORT}:9091"
    volumes:
      - ${TELEMT_ROOT}/config/config.toml:/run/telemt/config.toml:ro
      - ${TELEMT_ROOT}/tlsfront:/run/telemt/tlsfront
    tmpfs:
      - /run/telemt:rw,mode=1777,size=16m
    environment:
      - RUST_LOG=info
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
EOF
}

# Поддержка Docker Compose v2 (плагин `docker compose`) и бинаря `docker-compose`
detect_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD_WORDS=(docker compose)
    echo "Используется Docker Compose: docker compose (плагин v2)"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD_WORDS=(docker-compose)
    echo "Используется Docker Compose: docker-compose (отдельный бинарь)"
    return 0
  fi
  echo "Ошибка: не найден Docker Compose." >&2
  echo "Установите плагин v2 (Ubuntu/Debian):" >&2
  echo "  apt-get update && apt-get install -y docker-compose-plugin" >&2
  echo "или пакет docker-compose, затем снова запустите этот скрипт." >&2
  exit 1
}

compose() {
  "${COMPOSE_CMD_WORDS[@]}" -f "${COMPOSE_FILE}" -p "${COMPOSE_PROJECT}" "$@"
}

wait_for_api() {
  local url="http://127.0.0.1:${API_HOST_PORT}/v1/health"
  local n=0
  echo "Ожидание готовности API (${url})…"
  while (( n < 60 )); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      echo "API отвечает."
      return 0
    fi
    sleep 1
    ((n++)) || true
  done
  echo "Таймаут: API не поднялся за 60 с. Смотрите логи сервиса telemt (compose logs)." >&2
  return 1
}

fetch_users_json() {
  curl -fsS "http://127.0.0.1:${API_HOST_PORT}/v1/users"
}

write_markdown() {
  local fake_tls_domain="$1" public_ip="$2" users_json="$3" secrets_file="$4"
  local ts
  ts="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

  python3 - "${LINKS_MD}" "${fake_tls_domain}" "${public_ip}" "${PROXY_PORT}" "${ts}" "${secrets_file}" "${users_json}" <<'PY'
import json, sys, pathlib

_, out, domain, pub_ip, port, ts, sec_path, users_json = sys.argv[:8]
users = json.loads(users_json)
if not users.get("ok"):
    print("Неожиданный ответ API /v1/users", file=sys.stderr)
    sys.exit(1)
rows = users["data"]

secrets = {}
for line in pathlib.Path(sec_path).read_text(encoding="utf-8").splitlines():
    parts = line.split(None, 1)
    if len(parts) == 2:
        secrets[parts[0]] = parts[1]

lines = []
lines.append("# MTProto (TeleMT, Fake TLS / EE)")
lines.append("")
lines.append(f"- **Сгенерировано:** {ts}")
lines.append(f"- **Публичный адрес прокси:** `{pub_ip}:{port}`")
lines.append(f"- **Fake TLS (SNI / tls_domain):** `{domain}`")
lines.append(f"- **Образ:** `ghcr.io/telemt/telemt:latest`")
lines.append("")
lines.append("## Пользователи и ссылки `tg://proxy`")
lines.append("")
lines.append(
    "Ссылки ниже взяты из **Control API** (`GET /v1/users`, поле `links.tls`) — "
    "рекомендуемый способ; не собирайте EE-ссылки вручную, если не уверены в формате."
)
lines.append("")

for u in sorted(rows, key=lambda x: x["username"]):
    uname = u["username"]
    sec = secrets.get(uname, "")
    tls_links = u.get("links", {}).get("tls") or []
    lines.append(f"### `{uname}`")
    lines.append("")
    lines.append(f"- **Секрет (32 hex, из config.toml):** `{sec}`")
    lines.append("")
    if not tls_links:
        lines.append("_API не вернул TLS-ссылок для этого пользователя._")
        lines.append("")
        continue
    for i, link in enumerate(tls_links, 1):
        lines.append(f"{i}. `{link}`")
    lines.append("")

pathlib.Path(out).write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
}

configure_firewall() {
  echo "Настройка firewall для TCP ${PROXY_PORT}…"
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi 'Status: active'; then
      ufw allow "${PROXY_PORT}/tcp" comment 'TeleMT MTProto' >/dev/null || true
      echo "Правило UFW добавлено: ${PROXY_PORT}/tcp"
    else
      echo "UFW не активен — правило не добавлялось. При включении UFW выполните: ufw allow ${PROXY_PORT}/tcp"
    fi
  else
    echo "UFW не найден. При использовании nftables/iptables откройте порт ${PROXY_PORT}/tcp вручную."
  fi
}

main() {
  require_root
  need_cmd docker
  need_cmd openssl
  need_cmd curl
  need_cmd python3

  detect_docker_compose

  local FAKE_TLS_DOMAIN PUBLIC_IP
  local secrets_tmp

  echo "=== TeleMT + Fake TLS (EE), порт ${PROXY_PORT} ==="
  prompt_nonempty FAKE_TLS_DOMAIN "Введите домен для Fake TLS (пример: cdn.example.com):"
  prompt_public_ip_or_host PUBLIC_IP
  prompt_user_count_and_names

  echo
  echo "Создаю/очищаю только ${TELEMT_ROOT} (остальные контейнеры не трогаю)…"
  reset_local_artifacts

  secrets_tmp="$(mktemp)"
  trap 'rm -f "${secrets_tmp}"' EXIT

  write_config_toml "${FAKE_TLS_DOMAIN}" "${PUBLIC_IP}" "${secrets_tmp}" "${TELEMT_USERNAMES[@]}"
  write_compose

  echo
  echo "Запуск только проекта '${COMPOSE_PROJECT}' (pull + detach)…"
  compose down --remove-orphans 2>/dev/null || true
  compose pull
  compose up --detach --force-recreate

  wait_for_api

  echo "Получаю список пользователей и ссылки из API…"
  USERS_JSON="$(fetch_users_json)"
  write_markdown "${FAKE_TLS_DOMAIN}" "${PUBLIC_IP}" "${USERS_JSON}" "${secrets_tmp}"

  rm -f "${secrets_tmp}"
  trap - EXIT

  configure_firewall

  echo
  echo "Готово."
  echo "  Конфиг:     ${CONFIG_FILE}"
  echo "  Compose:    ${COMPOSE_FILE}"
  echo "  TLS cache:  ${TLS_DIR}"
  echo "  Ссылки:     ${LINKS_MD}"
  echo "  Логи:       ${COMPOSE_CMD_WORDS[*]} -f ${COMPOSE_FILE} -p ${COMPOSE_PROJECT} logs -f telemt"
}

main "$@"
