#!/usr/bin/env bash
# =============================================================================
# Установка NetBox в Docker на РЕД ОС 8 (пустой сервер → HTTPS)
# Каталог проекта: /opt/netbox-docker
# IP по умолчанию: 10.0.130.10
# Стек: netbox-community/netbox-docker + nginx (TLS на хосте)
#
# Запуск (от root):
#   bash install-netbox-docker-redos8.sh
# =============================================================================
set -euo pipefail

NETBOX_DOCKER_HOME="/opt/netbox-docker"
DEFAULT_NETBOX_IP="10.0.130.10"
DEFAULT_GIT_BRANCH="release"
DEFAULT_GIT_URL="https://github.com/netbox-community/netbox-docker.git"
GUNICORN_PUBLISH="127.0.0.1:8080"
STATE_DIR="/var/lib/netbox-docker-install"
ANSWERS_FILE="${STATE_DIR}/answers.env"
LOG_FILE="${STATE_DIR}/install.log"

C_RESET='\033[0m'
C_BLUE='\033[1;34m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_CYAN='\033[1;36m'

die()  { echo -e "${C_RED}[ОШИБКА]${C_RESET} $*" >&2; exit 1; }
info() { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[ВНИМАНИЕ]${C_RESET} $*"; }

banner() {
  echo
  echo -e "${C_CYAN}=================================================================${C_RESET}"
  echo -e "${C_CYAN} $*${C_RESET}"
  echo -e "${C_CYAN}=================================================================${C_RESET}"
  echo
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"
}

pause_continue() {
  local msg="${1:-Нажмите Enter для продолжения...}"
  read -r -p "$(echo -e "${C_YELLOW}${msg}${C_RESET} ")" _
}

rand_secret() {
  local n="${1:-32}"
  openssl rand -base64 $((n * 2)) | tr -d '/+=\n' | head -c "${n}"
}

ask() {
  local var="$1"
  local prompt="$2"
  local default="${3-}"
  local secret="${4-}"
  local reply

  if [[ -n "${default}" ]]; then
    if [[ "${secret}" == "secret" ]]; then
      read -r -s -p "$(echo -e "${C_GREEN}?${C_RESET} ${prompt} [${default}]: ")" reply
      echo
    else
      read -r -p "$(echo -e "${C_GREEN}?${C_RESET} ${prompt} [${default}]: ")" reply
    fi
    reply="${reply:-${default}}"
  else
    while true; do
      if [[ "${secret}" == "secret" ]]; then
        read -r -s -p "$(echo -e "${C_GREEN}?${C_RESET} ${prompt}: ")" reply
        echo
      else
        read -r -p "$(echo -e "${C_GREEN}?${C_RESET} ${prompt}: ")" reply
      fi
      [[ -n "${reply}" ]] && break
      warn "Значение обязательно."
    done
  fi
  printf -v "${var}" '%s' "${reply}"
}

ask_yes_no() {
  local var="$1"
  local prompt="$2"
  local default="${3:-y}"
  local reply
  local hint="y/n"
  [[ "${default}" == "y" ]] && hint="Y/n"
  [[ "${default}" == "n" ]] && hint="y/N"

  while true; do
    read -r -p "$(echo -e "${C_GREEN}?${C_RESET} ${prompt} [${hint}]: ")" reply
    reply="${reply:-${default}}"
    case "${reply}" in
      y|Y|yes|YES) printf -v "${var}" 'y'; return ;;
      n|N|no|NO)   printf -v "${var}" 'n'; return ;;
      *) warn "Ответьте y или n." ;;
    esac
  done
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "docker compose / docker-compose не найден"
  fi
}

compose_bin_path() {
  if docker compose version >/dev/null 2>&1; then
    echo "/usr/bin/docker compose"
  else
    command -v docker-compose
  fi
}

save_answers() {
  mkdir -p "${STATE_DIR}"
  umask 077
  cat > "${ANSWERS_FILE}" <<EOF
# Сгенерировано $(date -Is)
NETBOX_IP='${NETBOX_IP}'
ALLOWED_CLIENT_IP='${ALLOWED_CLIENT_IP}'
NETBOX_FQDN='${NETBOX_FQDN}'
GIT_URL='${GIT_URL}'
GIT_BRANCH='${GIT_BRANCH}'
DB_PASSWORD='${DB_PASSWORD}'
REDIS_PASSWORD='${REDIS_PASSWORD}'
REDIS_CACHE_PASSWORD='${REDIS_CACHE_PASSWORD}'
SECRET_KEY='${SECRET_KEY}'
API_TOKEN_PEPPER='${API_TOKEN_PEPPER}'
ADMIN_USER='${ADMIN_USER}'
ADMIN_EMAIL='${ADMIN_EMAIL}'
ADMIN_PASSWORD='${ADMIN_PASSWORD}'
TLS_MODE='${TLS_MODE}'
TLS_CERT='${TLS_CERT}'
TLS_KEY='${TLS_KEY}'
SELINUX_MODE='${SELINUX_MODE}'
NETBOX_DOCKER_HOME='${NETBOX_DOCKER_HOME}'
EOF
  chmod 600 "${ANSWERS_FILE}"
  ok "Ответы сохранены в ${ANSWERS_FILE}"
}

# -----------------------------------------------------------------------------
# Этап 0
# -----------------------------------------------------------------------------
stage_collect_answers() {
  banner "Этап 0/11 — Параметры Docker-установки"

  echo "Установка NetBox через официальный netbox-docker в ${NETBOX_DOCKER_HOME}."
  echo "HTTPS на хосте (nginx), контейнеры только на ${GUNICORN_PUBLISH}."
  echo

  ask NETBOX_IP "IP-адрес сервера NetBox" "${DEFAULT_NETBOX_IP}"
  ask ALLOWED_CLIENT_IP "IP клиента для HTTPS-доступа" ""
  while [[ -z "${ALLOWED_CLIENT_IP}" ]]; do
    warn "Укажите IP, с которого будет доступ по HTTPS."
    ask ALLOWED_CLIENT_IP "IP клиента для HTTPS-доступа" ""
  done

  ask NETBOX_FQDN "Имя хоста / FQDN для сертификата" "${NETBOX_IP}"
  ask GIT_URL "URL репозитория netbox-docker" "${DEFAULT_GIT_URL}"
  ask GIT_BRANCH "Ветка netbox-docker" "${DEFAULT_GIT_BRANCH}"

  echo
  info "Секреты (Enter = сгенерировать случайные)"
  ask DB_PASSWORD "Пароль PostgreSQL" "$(rand_secret 24)" "secret"
  ask REDIS_PASSWORD "Пароль Redis (tasks)" "$(rand_secret 24)" "secret"
  ask REDIS_CACHE_PASSWORD "Пароль Redis (cache)" "$(rand_secret 24)" "secret"
  ask SECRET_KEY "SECRET_KEY NetBox" "$(rand_secret 50)" "secret"
  ask API_TOKEN_PEPPER "API_TOKEN_PEPPER_1" "$(rand_secret 40)" "secret"

  echo
  info "Суперпользователь NetBox"
  ask ADMIN_USER "Логин администратора" "admin"
  ask ADMIN_EMAIL "E-mail администратора" "admin@example.local"
  ask ADMIN_PASSWORD "Пароль администратора" "$(rand_secret 16)" "secret"

  echo
  info "TLS / HTTPS"
  echo "  self-signed | files"
  ask TLS_MODE "Режим TLS" "self-signed"
  TLS_CERT="/etc/pki/tls/certs/netbox.crt"
  TLS_KEY="/etc/pki/tls/private/netbox.key"
  if [[ "${TLS_MODE}" == "files" ]]; then
    ask TLS_CERT "Путь к сертификату" "${TLS_CERT}"
    ask TLS_KEY "Путь к ключу" "${TLS_KEY}"
    [[ -f "${TLS_CERT}" ]] || die "Сертификат не найден: ${TLS_CERT}"
    [[ -f "${TLS_KEY}" ]] || die "Ключ не найден: ${TLS_KEY}"
  fi

  ask SELINUX_MODE "Режим SELinux после установки (enforcing|permissive)" "enforcing"

  echo
  banner "Сводка"
  cat <<EOF
  NetBox IP:       ${NETBOX_IP}
  HTTPS с IP:      ${ALLOWED_CLIENT_IP}
  FQDN:            ${NETBOX_FQDN}
  Каталог:         ${NETBOX_DOCKER_HOME}
  Git:             ${GIT_URL} (${GIT_BRANCH})
  Админ:           ${ADMIN_USER} <${ADMIN_EMAIL}>
  TLS:             ${TLS_MODE}
  SELinux:         ${SELINUX_MODE}
EOF
  echo
  ask_yes_no CONFIRM "Всё верно, продолжить?" "y"
  [[ "${CONFIRM}" == "y" ]] || die "Отменено"

  save_answers
  pause_continue "Этап 0 готов. Enter → обновление системы..."
}

# -----------------------------------------------------------------------------
# Этап 1
# -----------------------------------------------------------------------------
stage_system_update() {
  banner "Этап 1/11 — Обновление РЕД ОС 8"

  ask_yes_no DO_UPDATE "Выполнить dnf update -y?" "y"
  if [[ "${DO_UPDATE}" == "y" ]]; then
    dnf -y update
    ok "Система обновлена"
  else
    warn "Обновление пропущено"
  fi

  dnf -y install \
    curl wget git tar unzip openssl ca-certificates \
    policycoreutils policycoreutils-python-utils setools-console \
    firewalld chrony which \
    yum-utils device-mapper-persistent-data lvm2 \
    dnf-plugins-core || true

  systemctl enable --now chronyd || true
  systemctl enable --now firewalld || true
  ok "Базовые пакеты установлены"
  pause_continue "Enter → установка Docker..."
}

# -----------------------------------------------------------------------------
# Этап 2 — Docker
# -----------------------------------------------------------------------------
stage_docker_engine() {
  banner "Этап 2/11 — Docker Engine + Compose"

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker уже работает: $(docker --version)"
    ask_yes_no REINSTALL_DOCKER "Переустановить/доустановить пакеты Docker?" "n"
  else
    REINSTALL_DOCKER="y"
  fi

  if [[ "${REINSTALL_DOCKER}" == "y" ]]; then
    info "Установка пакетов Docker (несколько вариантов)..."
    local installed=0

    if dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
      installed=1
    elif dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
      installed=1
    elif dnf -y install docker docker-compose-plugin; then
      installed=1
    elif dnf -y install docker docker-compose; then
      installed=1
    elif dnf -y install moby-engine docker-compose; then
      installed=1
    else
      die "Не удалось установить Docker из доступных репозиториев. Подключите docker-ce или пакеты РЕД ОС."
    fi

    [[ "${installed}" -eq 1 ]] || die "Docker не установлен"
  fi

  systemctl enable --now docker
  sleep 2
  docker info >/dev/null || die "docker info не удался — проверьте службу docker"

  if docker compose version >/dev/null 2>&1; then
    ok "Compose plugin: $(docker compose version)"
  elif command -v docker-compose >/dev/null 2>&1; then
    ok "docker-compose: $(docker-compose version --short 2>/dev/null || docker-compose --version)"
  else
    dnf -y install docker-compose-plugin || dnf -y install docker-compose || \
      die "Нужен docker compose plugin или docker-compose"
  fi

  ask_yes_no RUN_HELLO "Проверить docker run hello-world?" "y"
  if [[ "${RUN_HELLO}" == "y" ]]; then
    docker run --rm hello-world || warn "hello-world не запустился (сеть/реестр?)"
  fi

  ok "Docker готов"
  pause_continue "Enter → SELinux (Docker)..."
}

# -----------------------------------------------------------------------------
# Этап 3 — SELinux prelim
# -----------------------------------------------------------------------------
stage_selinux_docker() {
  banner "Этап 3/11 — SELinux для Docker"

  if ! command -v getenforce >/dev/null 2>&1; then
    warn "SELinux utilities нет — пропуск"
    pause_continue "Enter → клонирование netbox-docker..."
    return
  fi

  info "Текущий режим: $(getenforce)"
  ask_yes_no SEL_NOW "Применить boolean'ы для Docker/nginx сейчас?" "y"
  if [[ "${SEL_NOW}" == "y" ]]; then
    setsebool -P container_manage_cgroup 1 2>/dev/null || true
    setsebool -P httpd_can_network_connect 1
    setsebool -P httpd_can_network_relay 1 2>/dev/null || true
    ok "boolean'ы установлены"
  fi

  pause_continue "Enter → клонирование проекта в /opt..."
}

# -----------------------------------------------------------------------------
# Этап 4 — clone
# -----------------------------------------------------------------------------
stage_clone() {
  banner "Этап 4/11 — Клонирование в ${NETBOX_DOCKER_HOME}"

  mkdir -p /opt
  if [[ -d "${NETBOX_DOCKER_HOME}/.git" ]]; then
    ask_yes_no RECLONE "Каталог уже есть. Удалить и клонировать заново?" "n"
    if [[ "${RECLONE}" == "y" ]]; then
      ask_yes_no STOP_OLD "Остановить текущий compose перед удалением?" "y"
      if [[ "${STOP_OLD}" == "y" ]]; then
        (cd "${NETBOX_DOCKER_HOME}" && compose down) || true
      fi
      rm -rf "${NETBOX_DOCKER_HOME}"
    else
      info "Обновление существующего клона..."
      git -C "${NETBOX_DOCKER_HOME}" fetch --all --tags
      git -C "${NETBOX_DOCKER_HOME}" checkout "${GIT_BRANCH}"
      git -C "${NETBOX_DOCKER_HOME}" pull --ff-only origin "${GIT_BRANCH}" || true
      pause_continue "Enter → настройка env..."
      return
    fi
  fi

  git clone -b "${GIT_BRANCH}" "${GIT_URL}" "${NETBOX_DOCKER_HOME}"
  ok "Репозиторий: ${NETBOX_DOCKER_HOME}"
  pause_continue "Enter → секреты env..."
}

# -----------------------------------------------------------------------------
# Этап 5 — env files
# -----------------------------------------------------------------------------
set_env_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "${file}" ]] && grep -qE "^${key}=" "${file}"; then
    # сохраняем остальные строки, заменяем ключ
    awk -v k="${key}" -v v="${value}" '
      BEGIN { done=0 }
      index($0, k "=") == 1 && !done { print k "=" v; done=1; next }
      { print }
      END { if (!done) print k "=" v }
    ' "${file}" > "${tmp}"
  else
    if [[ -f "${file}" ]]; then
      cat "${file}" > "${tmp}"
    else
      : > "${tmp}"
    fi
    echo "${key}=${value}" >> "${tmp}"
  fi
  mv "${tmp}" "${file}"
}

stage_env_files() {
  banner "Этап 5/11 — Секреты в env/"

  local env_dir="${NETBOX_DOCKER_HOME}/env"
  [[ -d "${env_dir}" ]] || die "Нет каталога ${env_dir}"

  # postgres
  if [[ -f "${env_dir}/postgres.env" ]]; then
    set_env_kv "${env_dir}/postgres.env" "POSTGRES_DB" "netbox"
    set_env_kv "${env_dir}/postgres.env" "POSTGRES_USER" "netbox"
    set_env_kv "${env_dir}/postgres.env" "POSTGRES_PASSWORD" "${DB_PASSWORD}"
  else
    cat > "${env_dir}/postgres.env" <<EOF
POSTGRES_DB=netbox
POSTGRES_USER=netbox
POSTGRES_PASSWORD=${DB_PASSWORD}
EOF
  fi

  # redis
  if [[ -f "${env_dir}/redis.env" ]]; then
    set_env_kv "${env_dir}/redis.env" "REDIS_PASSWORD" "${REDIS_PASSWORD}"
  else
    echo "REDIS_PASSWORD=${REDIS_PASSWORD}" > "${env_dir}/redis.env"
  fi

  if [[ -f "${env_dir}/redis-cache.env" ]]; then
    set_env_kv "${env_dir}/redis-cache.env" "REDIS_PASSWORD" "${REDIS_CACHE_PASSWORD}"
  else
    echo "REDIS_PASSWORD=${REDIS_CACHE_PASSWORD}" > "${env_dir}/redis-cache.env"
  fi

  # netbox.env — обновить ключевые поля, не ломая остальное
  local nb="${env_dir}/netbox.env"
  [[ -f "${nb}" ]] || die "Нет ${nb}"

  set_env_kv "${nb}" "DB_HOST" "postgres"
  set_env_kv "${nb}" "DB_NAME" "netbox"
  set_env_kv "${nb}" "DB_USER" "netbox"
  set_env_kv "${nb}" "DB_PASSWORD" "${DB_PASSWORD}"
  set_env_kv "${nb}" "REDIS_HOST" "redis"
  set_env_kv "${nb}" "REDIS_PASSWORD" "${REDIS_PASSWORD}"
  set_env_kv "${nb}" "REDIS_CACHE_HOST" "redis-cache"
  set_env_kv "${nb}" "REDIS_CACHE_PASSWORD" "${REDIS_CACHE_PASSWORD}"
  set_env_kv "${nb}" "SECRET_KEY" "'${SECRET_KEY}'"
  set_env_kv "${nb}" "API_TOKEN_PEPPER_1" "'${API_TOKEN_PEPPER}'"
  set_env_kv "${nb}" "SKIP_SUPERUSER" "true"

  chmod 600 "${env_dir}"/*.env
  ok "env-файлы обновлены"
  pause_continue "Enter → docker-compose.override.yml..."
}

# -----------------------------------------------------------------------------
# Этап 6 — override
# -----------------------------------------------------------------------------
stage_override() {
  banner "Этап 6/11 — docker-compose.override.yml"

  local override="${NETBOX_DOCKER_HOME}/docker-compose.override.yml"
  if [[ -f "${override}" ]]; then
    ask_yes_no OW "Перезаписать существующий override?" "y"
    [[ "${OW}" == "y" ]] || { warn "Оставлен текущий override"; pause_continue "Enter → pull/up..."; return; }
  fi

  cat > "${override}" <<EOF
services:
  netbox:
    ports:
      - "${GUNICORN_PUBLISH}:8080"
    environment:
      SKIP_SUPERUSER: "false"
      SUPERUSER_NAME: "${ADMIN_USER}"
      SUPERUSER_EMAIL: "${ADMIN_EMAIL}"
      SUPERUSER_PASSWORD: "${ADMIN_PASSWORD}"
EOF

  chmod 600 "${override}"
  ok "Записан ${override}"
  pause_continue "Enter → docker compose pull && up..."
}

# -----------------------------------------------------------------------------
# Этап 7 — pull & up
# -----------------------------------------------------------------------------
stage_compose_up() {
  banner "Этап 7/11 — Запуск контейнеров"

  cd "${NETBOX_DOCKER_HOME}"
  info "docker compose pull..."
  compose pull
  info "docker compose up -d..."
  compose up -d --remove-orphans

  info "Ожидание healthcheck NetBox (до ~3 мин)..."
  local i
  for i in $(seq 1 36); do
    if curl -sf -o /dev/null "http://127.0.0.1:8080/login/"; then
      ok "NetBox отвечает на http://127.0.0.1:8080/login/"
      break
    fi
    # статус контейнера
    if compose ps 2>/dev/null | grep -qi 'unhealthy'; then
      warn "Есть unhealthy — смотрите логи: docker compose logs netbox"
    fi
    sleep 5
    if [[ "${i}" -eq 36 ]]; then
      warn "Таймаут ожидания HTTP. Логи:"
      compose logs --tail=80 netbox || true
      ask_yes_no CONT "Продолжить (nginx/firewall) несмотря на это?" "y"
      [[ "${CONT}" == "y" ]] || die "Остановлено"
    fi
  done

  compose ps
  pause_continue "Enter → nginx HTTPS..."
}

# -----------------------------------------------------------------------------
# Этап 8 — nginx
# -----------------------------------------------------------------------------
stage_nginx() {
  banner "Этап 8/11 — nginx HTTPS на хосте"

  dnf -y install nginx || die "Не удалось установить nginx"
  mkdir -p /etc/pki/tls/certs /etc/pki/tls/private

  if [[ "${TLS_MODE}" == "self-signed" ]]; then
    ask_yes_no GEN "Сгенерировать самоподписанный сертификат?" "y"
    if [[ "${GEN}" == "y" ]]; then
      openssl req -x509 -nodes -newkey rsa:4096 -days 825 \
        -keyout "${TLS_KEY}" \
        -out "${TLS_CERT}" \
        -subj "/CN=${NETBOX_FQDN}/O=NetBox-Docker/C=RU" \
        -addext "subjectAltName=IP:${NETBOX_IP},DNS:${NETBOX_FQDN},DNS:localhost"
      chmod 600 "${TLS_KEY}"
      chmod 644 "${TLS_CERT}"
    fi
  fi

  [[ -f "${TLS_CERT}" && -f "${TLS_KEY}" ]] || die "Нет TLS-файлов"
  restorecon -v "${TLS_CERT}" "${TLS_KEY}" 2>/dev/null || true

  cat > /etc/nginx/conf.d/netbox.conf <<EOF
upstream netbox_docker {
    server 127.0.0.1:8080 fail_timeout=0;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${NETBOX_FQDN} ${NETBOX_IP};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name ${NETBOX_FQDN} ${NETBOX_IP};

    ssl_certificate     ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 25m;

    allow ${ALLOWED_CLIENT_IP};
    allow 127.0.0.1;
    deny all;

    location / {
        proxy_pass http://netbox_docker;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300;
        proxy_redirect off;
    }
}
EOF

  [[ -f /etc/nginx/conf.d/default.conf ]] && \
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled || true

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx || systemctl restart nginx
  ok "nginx → ${GUNICORN_PUBLISH}"
  pause_continue "Enter → firewalld..."
}

# -----------------------------------------------------------------------------
# Этап 9 — firewall
# -----------------------------------------------------------------------------
stage_firewall() {
  banner "Этап 9/11 — firewalld (HTTPS только с ${ALLOWED_CLIENT_IP})"

  systemctl enable --now firewalld

  ask_yes_no FW "Открыть 443/tcp только для ${ALLOWED_CLIENT_IP}?" "y"
  if [[ "${FW}" == "y" ]]; then
    firewall-cmd --permanent --remove-service=https 2>/dev/null || true
    firewall-cmd --permanent --remove-port=443/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ALLOWED_CLIENT_IP} port port=443 protocol=tcp accept"
    ask_yes_no FW80 "Разрешить 80/tcp с того же IP (редирект)?" "y"
    if [[ "${FW80}" == "y" ]]; then
      firewall-cmd --permanent --remove-service=http 2>/dev/null || true
      firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ALLOWED_CLIENT_IP} port port=80 protocol=tcp accept"
    fi
  else
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-service=http
  fi

  ask_yes_no FW_SSH "Оставить SSH открытым?" "y"
  [[ "${FW_SSH}" == "y" ]] && firewall-cmd --permanent --add-service=ssh || true

  firewall-cmd --reload
  firewall-cmd --list-all
  ok "firewalld настроен"
  pause_continue "Enter → systemd unit..."
}

# -----------------------------------------------------------------------------
# Этап 10 — systemd
# -----------------------------------------------------------------------------
stage_systemd_unit() {
  banner "Этап 10/11 — systemd: netbox-docker.service"

  local cbin
  if docker compose version >/dev/null 2>&1; then
    cat > /etc/systemd/system/netbox-docker.service <<EOF
[Unit]
Description=NetBox Docker Compose stack
Documentation=https://github.com/netbox-community/netbox-docker
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${NETBOX_DOCKER_HOME}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  else
    cbin="$(command -v docker-compose)"
    cat > /etc/systemd/system/netbox-docker.service <<EOF
[Unit]
Description=NetBox Docker Compose stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${NETBOX_DOCKER_HOME}
ExecStart=${cbin} up -d --remove-orphans
ExecStop=${cbin} stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
  systemctl enable netbox-docker.service
  systemctl start netbox-docker.service || true
  ok "unit netbox-docker.service включён"
  pause_continue "Enter → финал SELinux + проверка..."
}

# -----------------------------------------------------------------------------
# Этап 11 — SELinux final + summary
# -----------------------------------------------------------------------------
stage_finalize() {
  banner "Этап 11/11 — SELinux (итог) и проверка"

  if command -v getenforce >/dev/null 2>&1; then
    ask_yes_no SEL_MOD "Установить локальный модуль nginx→highport (netbox_local)?" "y"
    if [[ "${SEL_MOD}" == "y" ]]; then
      mkdir -p "${STATE_DIR}/selinux"
      cat > "${STATE_DIR}/selinux/netbox_local.te" <<'EOF'
module netbox_local 1.0;
require {
    type httpd_t;
    type unreserved_port_t;
    class tcp_socket name_connect;
}
allow httpd_t unreserved_port_t:tcp_socket name_connect;
EOF
      dnf -y install checkpolicy policycoreutils || true
      if command -v checkmodule >/dev/null 2>&1; then
        checkmodule -M -m -o "${STATE_DIR}/selinux/netbox_local.mod" "${STATE_DIR}/selinux/netbox_local.te"
        semodule_package -o "${STATE_DIR}/selinux/netbox_local.pp" -m "${STATE_DIR}/selinux/netbox_local.mod"
        semodule -i "${STATE_DIR}/selinux/netbox_local.pp" || semodule -u "${STATE_DIR}/selinux/netbox_local.pp" || true
        ok "netbox_local.pp установлен"
      fi
    fi

    case "${SELINUX_MODE}" in
      enforcing|Enforcing)
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
        setenforce 1 2>/dev/null || warn "setenforce 1 не удался (возможен reboot)"
        ;;
      permissive|Permissive)
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
        setenforce 0 2>/dev/null || true
        ;;
    esac
    info "getenforce → $(getenforce)"
  fi

  ask_yes_no SET_IP "Настроить IPv4 ${NETBOX_IP} на интерфейсе?" "n"
  if [[ "${SET_IP}" == "y" ]]; then
    ip -br link
    ask IFACE "Интерфейс" ""
    ask PREFIX "Префикс" "24"
    ask GATEWAY "Шлюз (Enter = пропуск)" ""
    ask CON_NAME "Имя connection NM (пусто = ip addr)" ""
    if [[ -n "${CON_NAME}" ]]; then
      nmcli con mod "${CON_NAME}" ipv4.addresses "${NETBOX_IP}/${PREFIX}" ipv4.method manual
      [[ -n "${GATEWAY}" ]] && nmcli con mod "${CON_NAME}" ipv4.gateway "${GATEWAY}"
      nmcli con up "${CON_NAME}"
    else
      ip addr add "${NETBOX_IP}/${PREFIX}" dev "${IFACE}" || warn "Адрес уже есть или ошибка"
      [[ -n "${GATEWAY}" ]] && ip route replace default via "${GATEWAY}" || true
    fi
  fi

  save_answers

  cat <<EOF

$(echo -e "${C_GREEN}======== DOCKER-УСТАНОВКА ЗАВЕРШЕНА ========${C_RESET}")

  URL:              https://${NETBOX_IP}/
  Доступ с IP:      ${ALLOWED_CLIENT_IP}
  Проект:           ${NETBOX_DOCKER_HOME}
  Контейнер HTTP:   http://127.0.0.1:8080/
  Админ:            ${ADMIN_USER}
  Секреты:          ${ANSWERS_FILE}
  Лог:              ${LOG_FILE}

  Команды:
    cd ${NETBOX_DOCKER_HOME} && docker compose ps
    docker compose logs -f netbox
    systemctl status netbox-docker nginx docker
    curl -kI https://${NETBOX_IP}/

$(echo -e "${C_YELLOW}Храните ${ANSWERS_FILE} в безопасном месте (chmod 600).${C_RESET}")

EOF
}

main() {
  require_root
  mkdir -p "${STATE_DIR}"
  : >> "${LOG_FILE}"

  banner "NetBox Docker на РЕД ОС 8 — интерактивная установка"

  if [[ -f /etc/red-release ]]; then
    ok "РЕД ОС: $(cat /etc/red-release)"
  elif [[ -f /etc/redhat-release ]]; then
    warn "RHEL-подобная ОС: $(cat /etc/redhat-release)"
    ask_yes_no CONT_OS "Продолжить?" "y"
    [[ "${CONT_OS}" == "y" ]] || die "Отменено"
  else
    ask_yes_no CONT_OS "ОС не распознана. Продолжить?" "n"
    [[ "${CONT_OS}" == "y" ]] || die "Отменено"
  fi

  stage_collect_answers
  stage_system_update
  stage_docker_engine
  stage_selinux_docker
  stage_clone
  stage_env_files
  stage_override
  stage_compose_up
  stage_nginx
  stage_firewall
  stage_systemd_unit
  stage_finalize
}

main "$@"
