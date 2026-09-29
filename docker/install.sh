#!/usr/bin/env bash
# =============================================================================
# Полная установка NetBox + MediaWiki в Docker на «голом» сервере (Red OS 8 / RHEL8+)
#
# Что делает скрипт:
#   1) ставит Docker и Docker Compose (если их нет)
#   2) создаёт каталог установки, конфиги Nginx, .env
#   3) генерирует пароли и SECRET_KEY
#   4) подключает ваши сертификаты или выпускает self-signed
#   5) поднимает стек, дожидается готовности
#   6) автоматически ставит MediaWiki (install.php)
#   7) пишет все креды и URL в CREDENTIALS.txt
#
# Запуск (от root):
#   curl -fsSL ... | bash          # или
#   bash install.sh
#
# Опции через переменные окружения:
#   INSTALL_DIR=/opt/netbox-wiki
#   INSTALL_HOST=netbox.example.local
#   NETBOX_HTTPS_PORT=443
#   MEDIAWIKI_HTTPS_PORT=8443
#   CERT_FILE=/path/to/fullchain.crt
#   KEY_FILE=/path/to/privkey.key
#   SKIP_DOCKER_INSTALL=0
# =============================================================================

set -euo pipefail

export LANG=C.UTF-8

# --------------------------- настройки по умолчанию ---------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/netbox-wiki}"
NETBOX_HTTPS_PORT="${NETBOX_HTTPS_PORT:-443}"
MEDIAWIKI_HTTPS_PORT="${MEDIAWIKI_HTTPS_PORT:-8443}"
NETBOX_IMAGE_TAG="${NETBOX_IMAGE_TAG:-v3.7.8}"
MEDIAWIKI_IMAGE_TAG="${MEDIAWIKI_IMAGE_TAG:-1.39.11}"
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-0}"
WIKI_NAME="${WIKI_NAME:-CorpWiki}"
NETBOX_SUPERUSER_NAME="${NETBOX_SUPERUSER_NAME:-admin}"
WIKI_ADMIN_USER="${WIKI_ADMIN_USER:-WikiAdmin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
CREDENTIALS_FILE="${INSTALL_DIR}/CREDENTIALS.txt"
LOG_FILE="${INSTALL_DIR}/install.log"

# --------------------------- утилиты -----------------------------------------
log()  { echo "[$(date '+%F %T')] $*" | tee -a "${LOG_FILE:-/dev/stderr}"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID} -eq 0 ]] || die "Запустите скрипт от root (sudo)."; }

rand_alnum() {
  # безопасно для паролей в .env / URL
  openssl rand -base64 48 | tr -d '\n' | tr '+/' 'Aa' | cut -c1-28
}

rand_secret() {
  # SECRET_KEY NetBox — длиннее
  openssl rand -base64 64 | tr -d '\n' | tr '+/' 'Xx' | cut -c1-64
}

detect_host() {
  if [[ -n "${INSTALL_HOST:-}" ]]; then
    echo "${INSTALL_HOST}"
    return
  fi
  local h
  h="$(hostname -f 2>/dev/null || hostname)"
  if [[ -z "${h}" || "${h}" == "localhost" ]]; then
    h="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  echo "${h:-127.0.0.1}"
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "docker compose не найден"
  fi
}

wait_http() {
  local url="$1" tries="${2:-60}" delay="${3:-5}"
  local i
  for ((i=1; i<=tries; i++)); do
    if curl -kfsS -o /dev/null "${url}"; then
      return 0
    fi
    log "Ожидание ${url} (${i}/${tries})..."
    sleep "${delay}"
  done
  return 1
}

# --------------------------- Docker ------------------------------------------
install_docker() {
  if [[ "${SKIP_DOCKER_INSTALL}" == "1" ]]; then
    log "SKIP_DOCKER_INSTALL=1 — установка Docker пропущена"
    return
  fi

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "Docker уже установлен и работает"
  else
    log "Установка Docker..."
    # Пакеты ОС (Red OS / RHEL / Rocky / Alma)
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y dnf-plugins-core curl wget ca-certificates || true
      # Пробуем пакеты из репозиториев ОС
      if dnf install -y docker docker-compose 2>/dev/null; then
        :
      elif dnf install -y moby-engine docker-compose 2>/dev/null; then
        :
      else
        log "Пакеты docker в ОС не найдены — ставим Docker CE"
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
        dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
          || dnf install -y docker-ce docker-ce-cli containerd.io
      fi
    elif command -v yum >/dev/null 2>&1; then
      yum install -y yum-utils curl wget ca-certificates
      yum install -y docker docker-compose || yum install -y docker
    else
      die "Не найден dnf/yum. Установите Docker вручную и повторите с SKIP_DOCKER_INSTALL=1"
    fi

    systemctl enable --now docker
    # docker-compose plugin, если ещё нет
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
      log "Установка docker-compose (standalone)..."
      local arch
      arch="$(uname -m)"
      case "${arch}" in
        x86_64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
      esac
      curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-${arch}" \
        -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
    fi
  fi

  docker info >/dev/null 2>&1 || die "Docker не запущен (systemctl status docker)"
  compose version >/dev/null || die "docker compose недоступен"
  log "Docker OK: $(docker --version)"
}

open_firewall() {
  if systemctl is-active --quiet firewalld 2>/dev/null || command -v firewall-cmd >/dev/null 2>&1; then
    log "Открытие портов ${NETBOX_HTTPS_PORT} и ${MEDIAWIKI_HTTPS_PORT} в firewalld"
    systemctl enable --now firewalld 2>/dev/null || true
    firewall-cmd --permanent --add-port="${NETBOX_HTTPS_PORT}/tcp" || true
    firewall-cmd --permanent --add-port="${MEDIAWIKI_HTTPS_PORT}/tcp" || true
    firewall-cmd --reload || true
  else
    log "firewalld не найден — пропуск (откройте порты вручную при необходимости)"
  fi
}

# --------------------------- раскладка файлов --------------------------------
prepare_dirs() {
  mkdir -p "${INSTALL_DIR}/nginx" "${INSTALL_DIR}/certs" "${INSTALL_DIR}/scripts"
  touch "${LOG_FILE}"
  log "Каталог установки: ${INSTALL_DIR}"
}

copy_or_write_compose() {
  if [[ -f "${TEMPLATES_DIR}/docker-compose.yml" ]]; then
    cp -f "${TEMPLATES_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
  else
    die "Не найден шаблон ${TEMPLATES_DIR}/docker-compose.yml"
  fi
  if [[ -f "${TEMPLATES_DIR}/nginx/netbox.conf" ]]; then
    cp -f "${TEMPLATES_DIR}/nginx/netbox.conf" "${INSTALL_DIR}/nginx/netbox.conf"
    cp -f "${TEMPLATES_DIR}/nginx/mediawiki.conf" "${INSTALL_DIR}/nginx/mediawiki.conf"
  else
    die "Не найдены шаблоны nginx"
  fi
}

setup_certs() {
  local crt="${INSTALL_DIR}/certs/server.crt"
  local key="${INSTALL_DIR}/certs/server.key"
  local host="$1"

  if [[ -n "${CERT_FILE:-}" && -n "${KEY_FILE:-}" ]]; then
    [[ -f "${CERT_FILE}" ]] || die "CERT_FILE не найден: ${CERT_FILE}"
    [[ -f "${KEY_FILE}" ]] || die "KEY_FILE не найден: ${KEY_FILE}"
    cp -f "${CERT_FILE}" "${crt}"
    cp -f "${KEY_FILE}" "${key}"
    log "Используются ваши сертификаты: ${CERT_FILE}"
  elif [[ -f "${SCRIPT_DIR}/certs/server.crt" && -f "${SCRIPT_DIR}/certs/server.key" ]]; then
    cp -f "${SCRIPT_DIR}/certs/server.crt" "${crt}"
    cp -f "${SCRIPT_DIR}/certs/server.key" "${key}"
    log "Взяты сертификаты из ${SCRIPT_DIR}/certs/"
  elif [[ -f "${crt}" && -f "${key}" ]]; then
    log "Уже есть сертификаты в ${INSTALL_DIR}/certs/"
  else
    log "Сертификаты не переданы — генерирую self-signed для ${host}"
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout "${key}" -out "${crt}" \
      -subj "/CN=${host}/O=NetBox-Wiki/C=RU" \
      -addext "subjectAltName=DNS:${host},DNS:localhost,IP:127.0.0.1"
  fi
  chmod 600 "${key}"
  chmod 644 "${crt}"
}

write_env() {
  local host="$1"
  local nb_db_pass nb_secret nb_admin_pass wiki_db_pass wiki_root_pass wiki_admin_pass

  nb_db_pass="$(rand_alnum)"
  nb_secret="$(rand_secret)"
  nb_admin_pass="$(rand_alnum)"
  wiki_db_pass="$(rand_alnum)"
  wiki_root_pass="$(rand_alnum)"
  wiki_admin_pass="$(rand_alnum)"

  # Экспорт для последующих шагов и CREDENTIALS
  NETBOX_DB_PASSWORD="${nb_db_pass}"
  NETBOX_SECRET_KEY="${nb_secret}"
  NETBOX_SUPERUSER_PASSWORD="${nb_admin_pass}"
  WIKI_DB_PASSWORD="${wiki_db_pass}"
  WIKI_DB_ROOT_PASSWORD="${wiki_root_pass}"
  WIKI_ADMIN_PASSWORD="${wiki_admin_pass}"
  INSTALL_HOST_RESOLVED="${host}"

  cat > "${INSTALL_DIR}/.env" <<EOF
# Сгенерировано install.sh $(date -Is)
INSTALL_HOST=${host}
ALLOWED_HOSTS=*
NETBOX_HTTPS_PORT=${NETBOX_HTTPS_PORT}
MEDIAWIKI_HTTPS_PORT=${MEDIAWIKI_HTTPS_PORT}
NETBOX_IMAGE_TAG=${NETBOX_IMAGE_TAG}
MEDIAWIKI_IMAGE_TAG=${MEDIAWIKI_IMAGE_TAG}

NETBOX_DB_NAME=netbox
NETBOX_DB_USER=netbox
NETBOX_DB_PASSWORD=${nb_db_pass}
NETBOX_SECRET_KEY=${nb_secret}
NETBOX_SUPERUSER_NAME=${NETBOX_SUPERUSER_NAME}
NETBOX_SUPERUSER_EMAIL=admin@${host}
NETBOX_SUPERUSER_PASSWORD=${nb_admin_pass}

WIKI_NAME=${WIKI_NAME}
WIKI_DB_NAME=mediawiki
WIKI_DB_USER=wiki
WIKI_DB_PASSWORD=${wiki_db_pass}
WIKI_DB_ROOT_PASSWORD=${wiki_root_pass}
WIKI_ADMIN_USER=${WIKI_ADMIN_USER}
WIKI_ADMIN_PASSWORD=${wiki_admin_pass}
EOF

  chmod 600 "${INSTALL_DIR}/.env"
  log "Файл .env записан (права 600)"
}

# --------------------------- MediaWiki auto-install --------------------------
install_mediawiki() {
  local host="$1"
  local server_url="https://${host}:${MEDIAWIKI_HTTPS_PORT}"

  log "Ожидание контейнера mediawiki..."
  local i
  for ((i=1; i<=60; i++)); do
    if compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" \
      exec -T mediawiki php -v >/dev/null 2>&1; then
      break
    fi
    sleep 3
  done

  # Уже установлена?
  if compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" \
    exec -T mediawiki test -f /var/www/html/LocalSettings.php 2>/dev/null; then
    log "MediaWiki уже установлена (LocalSettings.php есть)"
  else
    log "Запуск mediawiki maintenance/install.php ..."
    # install.php иногда падает, если images не writable — чиним
    compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" \
      exec -T mediawiki bash -lc 'chown -R www-data:www-data /var/www/html/images || true'

    compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" \
      exec -T mediawiki php maintenance/install.php \
        --server="${server_url}" \
        --scriptpath="" \
        --lang=ru \
        --dbtype=mysql \
        --dbserver=mediawiki-db \
        --dbname=mediawiki \
        --dbuser=wiki \
        --dbpass="${WIKI_DB_PASSWORD}" \
        --pass="${WIKI_ADMIN_PASSWORD}" \
        "${WIKI_NAME}" "${WIKI_ADMIN_USER}"
  fi

  # Фикс $wgServer / HTTPS за reverse proxy
  local snippet="${INSTALL_DIR}/scripts/mediawiki-proxy-snippet.php"
  cat > "${snippet}" <<EOF

# Added by netbox-wiki install.sh
\$wgServer = "${server_url}";
\$wgCanonicalServer = "${server_url}";
\$wgForceHTTPS = true;
\$wgSecureLogin = true;
if (isset(\$_SERVER["HTTP_X_FORWARDED_PROTO"]) && \$_SERVER["HTTP_X_FORWARDED_PROTO"] === "https") {
  \$_SERVER["HTTPS"] = "on";
}
EOF

  compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" \
    cp "${snippet}" mediawiki:/tmp/mediawiki-proxy-snippet.php

  compose -f "${INSTALL_DIR}/docker-compose.yml" --env-file "${INSTALL_DIR}/.env" \
    exec -T mediawiki bash -lc '
LS=/var/www/html/LocalSettings.php
test -f "$LS" || exit 1
if ! grep -q "Added by netbox-wiki install.sh" "$LS"; then
  cat /tmp/mediawiki-proxy-snippet.php >> "$LS"
fi
chown www-data:www-data "$LS" 2>/dev/null || true
'

  log "MediaWiki настроена: ${server_url}"
}

write_credentials() {
  local host="$1"
  local nb_url="https://${host}:${NETBOX_HTTPS_PORT}"
  local wiki_url="https://${host}:${MEDIAWIKI_HTTPS_PORT}"

  cat > "${CREDENTIALS_FILE}" <<EOF
================================================================================
NetBox + MediaWiki — данные установки
Сгенерировано: $(date -Is)
Хост:          ${host}
Каталог:       ${INSTALL_DIR}
================================================================================

URL
----
NetBox:     ${nb_url}
MediaWiki:  ${wiki_url}

NetBox
------
Админ-логин:     ${NETBOX_SUPERUSER_NAME}
Админ-пароль:    ${NETBOX_SUPERUSER_PASSWORD}
Email:           admin@${host}
DB name:         netbox
DB user:         netbox
DB password:     ${NETBOX_DB_PASSWORD}
SECRET_KEY:      ${NETBOX_SECRET_KEY}
Image:           netboxcommunity/netbox:${NETBOX_IMAGE_TAG}

MediaWiki
---------
Название:        ${WIKI_NAME}
Админ-логин:     ${WIKI_ADMIN_USER}
Админ-пароль:    ${WIKI_ADMIN_PASSWORD}
DB name:         mediawiki
DB user:         wiki
DB password:     ${WIKI_DB_PASSWORD}
DB root password:${WIKI_DB_ROOT_PASSWORD}
Image:           mediawiki:${MEDIAWIKI_IMAGE_TAG}

TLS
---
Сертификат: ${INSTALL_DIR}/certs/server.crt
Ключ:       ${INSTALL_DIR}/certs/server.key

Управление
----------
cd ${INSTALL_DIR}
docker compose --env-file .env ps
docker compose --env-file .env logs -f
docker compose --env-file .env down
docker compose --env-file .env up -d

Полный .env (секреты): ${INSTALL_DIR}/.env
Лог установки:         ${LOG_FILE}
================================================================================
EOF

  chmod 600 "${CREDENTIALS_FILE}"
  log "Креды записаны в ${CREDENTIALS_FILE}"
}

# --------------------------- main --------------------------------------------
main() {
  need_root
  prepare_dirs
  local host
  host="$(detect_host)"

  log "=== Старт установки NetBox + MediaWiki (Docker) ==="
  log "Host=${host} NetBox_port=${NETBOX_HTTPS_PORT} Wiki_port=${MEDIAWIKI_HTTPS_PORT}"

  # минимальные утилиты до docker
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y curl openssl ca-certificates 2>/dev/null || true
  fi

  install_docker
  open_firewall
  copy_or_write_compose
  setup_certs "${host}"
  write_env "${host}"

  log "Загрузка образов и запуск контейнеров..."
  cd "${INSTALL_DIR}"
  compose --env-file .env pull
  compose --env-file .env up -d

  log "Ожидание готовности NetBox через Nginx..."
  if ! wait_http "https://127.0.0.1:${NETBOX_HTTPS_PORT}/login/" 60 5; then
    log "WARNING: NetBox ещё не ответил на /login/ — смотрите: docker compose logs netbox"
  fi

  install_mediawiki "${host}"

  log "Перезапуск nginx после установки wiki..."
  compose --env-file .env restart nginx || true

  write_credentials "${host}"

  echo
  echo "================================================================"
  echo " Установка завершена"
  echo " NetBox:    https://${host}:${NETBOX_HTTPS_PORT}"
  echo " MediaWiki: https://${host}:${MEDIAWIKI_HTTPS_PORT}"
  echo " Креды:     ${CREDENTIALS_FILE}"
  echo "================================================================"
  echo
  cat "${CREDENTIALS_FILE}"
}

main "$@"
