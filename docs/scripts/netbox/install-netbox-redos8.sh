#!/usr/bin/env bash
# =============================================================================
# Установка NetBox на РЕД ОС 8 (пустой сервер → готовый HTTPS-комплекс)
# Каталог приложения: /opt/netbox
# IP по умолчанию: 10.0.130.10
#
# Запуск (от root):
#   bash install-netbox-redos8.sh
#
# На каждом этапе скрипт запрашивает нужные данные (Enter = значение по умолчанию).
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Константы / значения по умолчанию
# -----------------------------------------------------------------------------
NETBOX_HOME="/opt/netbox"
NETBOX_USER="netbox"
NETBOX_GROUP="netbox"
DEFAULT_NETBOX_IP="10.0.130.10"
DEFAULT_NETBOX_VERSION="v4.2.9"
DEFAULT_ALLOWED_CLIENT_IP=""
DEFAULT_DB_NAME="netbox"
DEFAULT_DB_USER="netbox"
DEFAULT_REDIS_HOST="127.0.0.1"
DEFAULT_REDIS_PORT="6379"
GUNICORN_BIND="127.0.0.1:8001"
STATE_DIR="/var/lib/netbox-install"
ANSWERS_FILE="${STATE_DIR}/answers.env"
LOG_FILE="${STATE_DIR}/install.log"

# -----------------------------------------------------------------------------
# Вывод
# -----------------------------------------------------------------------------
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

ask() {
  # ask VAR "Вопрос" "значение_по_умолчанию" [secret]
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
  # ask_yes_no VAR "Вопрос" "y|n"
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

save_answers() {
  mkdir -p "${STATE_DIR}"
  umask 077
  cat > "${ANSWERS_FILE}" <<EOF
# Сгенерировано $(date -Is)
NETBOX_IP='${NETBOX_IP}'
ALLOWED_CLIENT_IP='${ALLOWED_CLIENT_IP}'
NETBOX_FQDN='${NETBOX_FQDN}'
NETBOX_VERSION='${NETBOX_VERSION}'
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASSWORD='${DB_PASSWORD}'
REDIS_HOST='${REDIS_HOST}'
REDIS_PORT='${REDIS_PORT}'
REDIS_PASSWORD='${REDIS_PASSWORD}'
ADMIN_USER='${ADMIN_USER}'
ADMIN_EMAIL='${ADMIN_EMAIL}'
ADMIN_PASSWORD='${ADMIN_PASSWORD}'
TLS_MODE='${TLS_MODE}'
TLS_CERT='${TLS_CERT}'
TLS_KEY='${TLS_KEY}'
SELINUX_MODE='${SELINUX_MODE}'
PYTHON_BIN='${PYTHON_BIN}'
EOF
  chmod 600 "${ANSWERS_FILE}"
  ok "Ответы сохранены в ${ANSWERS_FILE}"
}

log_cmd() {
  mkdir -p "${STATE_DIR}"
  echo "+ $*" >> "${LOG_FILE}"
  "$@" 2>&1 | tee -a "${LOG_FILE}"
}

# -----------------------------------------------------------------------------
# Этап 0: сбор параметров
# -----------------------------------------------------------------------------
stage_collect_answers() {
  banner "Этап 0/10 — Параметры установки"

  echo "Скрипт установит NetBox в ${NETBOX_HOME} на РЕД ОС 8."
  echo "На каждом этапе потребуются подтверждения и данные."
  echo

  ask NETBOX_IP "IP-адрес сервера NetBox" "${DEFAULT_NETBOX_IP}"
  ask ALLOWED_CLIENT_IP "IP клиента, которому разрешён HTTPS-доступ к NetBox (firewall)" "${DEFAULT_ALLOWED_CLIENT_IP}"
  while [[ -z "${ALLOWED_CLIENT_IP}" ]]; do
    warn "Укажите IP, с которого будет доступ к NetBox по HTTPS."
    ask ALLOWED_CLIENT_IP "IP клиента для HTTPS-доступа" ""
  done

  ask NETBOX_FQDN "Имя хоста / FQDN для сертификата и ALLOWED_HOSTS (можно IP)" "${NETBOX_IP}"
  ask NETBOX_VERSION "Версия NetBox (тег GitHub, напр. v4.2.9 / v4.1.11)" "${DEFAULT_NETBOX_VERSION}"

  echo
  info "Параметры PostgreSQL"
  ask DB_NAME "Имя БД" "${DEFAULT_DB_NAME}"
  ask DB_USER "Пользователь БД" "${DEFAULT_DB_USER}"
  ask DB_PASSWORD "Пароль пользователя БД" "$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)" "secret"

  echo
  info "Параметры Redis"
  ask REDIS_HOST "Хост Redis" "${DEFAULT_REDIS_HOST}"
  ask REDIS_PORT "Порт Redis" "${DEFAULT_REDIS_PORT}"
  ask_yes_no USE_REDIS_PASS "Задать пароль Redis?" "n"
  if [[ "${USE_REDIS_PASS}" == "y" ]]; then
    ask REDIS_PASSWORD "Пароль Redis" "$(openssl rand -base64 18 | tr -d '/+=' | head -c 18)" "secret"
  else
    REDIS_PASSWORD=""
  fi

  echo
  info "Учётная запись суперпользователя NetBox"
  ask ADMIN_USER "Логин администратора" "admin"
  ask ADMIN_EMAIL "E-mail администратора" "admin@example.local"
  ask ADMIN_PASSWORD "Пароль администратора" "$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)" "secret"

  echo
  info "TLS / HTTPS"
  echo "  1) self-signed  — самоподписанный сертификат (для лаборатории)"
  echo "  2) files        — указать готовые .crt/.key"
  ask TLS_MODE "Режим TLS (self-signed|files)" "self-signed"
  TLS_CERT="/etc/pki/tls/certs/netbox.crt"
  TLS_KEY="/etc/pki/tls/private/netbox.key"
  if [[ "${TLS_MODE}" == "files" ]]; then
    ask TLS_CERT "Путь к сертификату (.crt/.pem)" "${TLS_CERT}"
    ask TLS_KEY "Путь к приватному ключу (.key)" "${TLS_KEY}"
    [[ -f "${TLS_CERT}" ]] || die "Файл сертификата не найден: ${TLS_CERT}"
    [[ -f "${TLS_KEY}" ]] || die "Файл ключа не найден: ${TLS_KEY}"
  fi

  echo
  info "SELinux"
  echo "  Рекомендуется: enforcing (скрипт настроит контексты и boolean)."
  ask SELINUX_MODE "Режим SELinux после установки (enforcing|permissive)" "enforcing"

  echo
  banner "Сводка параметров"
  cat <<EOF
  NetBox IP:          ${NETBOX_IP}
  HTTPS только с:     ${ALLOWED_CLIENT_IP}
  FQDN/Host:          ${NETBOX_FQDN}
  Версия NetBox:      ${NETBOX_VERSION}
  Каталог:            ${NETBOX_HOME}
  БД:                 ${DB_NAME} / ${DB_USER}
  Redis:              ${REDIS_HOST}:${REDIS_PORT}
  Админ:              ${ADMIN_USER} <${ADMIN_EMAIL}>
  TLS:                ${TLS_MODE}
  SELinux:            ${SELINUX_MODE}
EOF
  echo
  ask_yes_no CONFIRM "Всё верно, продолжить установку?" "y"
  [[ "${CONFIRM}" == "y" ]] || die "Установка отменена пользователем."

  PYTHON_BIN=""
  save_answers
  pause_continue "Этап 0 завершён. Enter → обновление системы..."
}

# -----------------------------------------------------------------------------
# Этап 1: система и обновления
# -----------------------------------------------------------------------------
stage_system_update() {
  banner "Этап 1/10 — Обновление РЕД ОС 8 и базовые пакеты"

  ask_yes_no DO_UPDATE "Выполнить dnf update -y (все доступные обновления)?" "y"
  if [[ "${DO_UPDATE}" == "y" ]]; then
    info "Обновление пакетов (может занять время)..."
    dnf -y update
    ok "Система обновлена"
  else
    warn "Обновление пропущено по запросу."
  fi

  info "Установка утилит..."
  dnf -y install \
    curl wget git tar unzip openssl \
    ca-certificates \
    policycoreutils policycoreutils-python-utils \
    setools-console \
    firewalld \
    chrony \
    which \
    gcc gcc-c++ make \
    libffi-devel openssl-devel \
    bzip2-devel readline-devel sqlite-devel \
    zlib-devel libjpeg-turbo-devel \
    libxml2-devel libxslt-devel \
    openldap-devel \
    redhat-rpm-config

  systemctl enable --now chronyd || true
  systemctl enable --now firewalld || true

  ok "Базовые пакеты установлены"
  pause_continue "Этап 1 завершён. Enter → Python..."
}

# -----------------------------------------------------------------------------
# Этап 2: Python
# -----------------------------------------------------------------------------
detect_python() {
  local candidates=(python3.12 python3.11 python3.10 python3)
  local c
  for c in "${candidates[@]}"; do
    if command -v "${c}" >/dev/null 2>&1; then
      local ver
      ver="$("${c}" -c 'import sys; print("%d.%d"%sys.version_info[:2])')"
      case "${ver}" in
        3.10|3.11|3.12|3.13|3.14)
          PYTHON_BIN="$(command -v "${c}")"
          echo "${ver}"
          return 0
          ;;
      esac
    fi
  done
  return 1
}

stage_python() {
  banner "Этап 2/10 — Python для NetBox"

  info "Установка доступных пакетов Python 3.x..."
  # РЕД ОС 8: набор пакетов может отличаться — ставим всё, что есть в репозитории.
  dnf -y install python3 python3-pip python3-devel python3-virtualenv || true
  dnf -y install python3.11 python3.11-devel python3.11-pip || true
  dnf -y install python3.12 python3.12-devel python3.12-pip || true

  local pyver=""
  if pyver="$(detect_python)"; then
    ok "Найден Python ${pyver}: ${PYTHON_BIN}"
  else
    die "Не найден Python ≥ 3.10. Подключите репозиторий с python3.11/3.12 и повторите."
  fi

  # NetBox 4.2+ обычно ок на 3.10/3.11; 4.5+ требует 3.12+
  case "${pyver}" in
    3.10|3.11)
      if [[ "${NETBOX_VERSION}" =~ ^v4\.[5-9] ]] || [[ "${NETBOX_VERSION}" =~ ^v[5-9] ]]; then
        warn "Версия ${NETBOX_VERSION} может требовать Python 3.12+."
        ask_yes_no DOWNGRADE "Сменить версию NetBox на v4.2.9 (совместима с Python ${pyver})?" "y"
        if [[ "${DOWNGRADE}" == "y" ]]; then
          NETBOX_VERSION="v4.2.9"
          save_answers
        fi
      fi
      ;;
  esac

  "${PYTHON_BIN}" -m pip install --upgrade pip setuptools wheel
  ok "Python готов: ${PYTHON_BIN}"
  pause_continue "Этап 2 завершён. Enter → PostgreSQL..."
}

# -----------------------------------------------------------------------------
# Этап 3: PostgreSQL
# -----------------------------------------------------------------------------
stage_postgresql() {
  banner "Этап 3/10 — PostgreSQL"

  ask_yes_no INSTALL_PG "Установить и настроить PostgreSQL на этом сервере?" "y"
  if [[ "${INSTALL_PG}" != "y" ]]; then
    warn "Пропуск установки PostgreSQL. Убедитесь, что БД уже доступна."
    ask DB_HOST "Хост PostgreSQL" "127.0.0.1"
    ask DB_PORT "Порт PostgreSQL" "5432"
    pause_continue "Enter → Redis..."
    return
  fi
  DB_HOST="127.0.0.1"
  DB_PORT="5432"

  info "Поиск пакетов PostgreSQL..."
  if dnf list --available postgresql15-server >/dev/null 2>&1 || rpm -q postgresql15-server >/dev/null 2>&1; then
    dnf -y install postgresql15-server postgresql15 postgresql15-contrib || \
      dnf -y install postgresql15-server postgresql15
    PGSETUP="/usr/pgsql-15/bin/postgresql-15-setup"
    PGSERVICE="postgresql-15"
  elif dnf list --available postgresql16-server >/dev/null 2>&1 || rpm -q postgresql16-server >/dev/null 2>&1; then
    dnf -y install postgresql16-server postgresql16 postgresql16-contrib || \
      dnf -y install postgresql16-server postgresql16
    PGSETUP="/usr/pgsql-16/bin/postgresql-16-setup"
    PGSERVICE="postgresql-16"
  elif dnf list --available postgresql14-server >/dev/null 2>&1 || rpm -q postgresql14-server >/dev/null 2>&1; then
    dnf -y install postgresql14-server postgresql14 postgresql14-contrib || \
      dnf -y install postgresql14-server postgresql14
    PGSETUP="/usr/pgsql-14/bin/postgresql-14-setup"
    PGSERVICE="postgresql-14"
  else
    dnf -y install postgresql-server postgresql postgresql-contrib
    PGSETUP="postgresql-setup"
    PGSERVICE="postgresql"
  fi

  if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]] && [[ ! -f /var/lib/pgsql/*/data/PG_VERSION ]]; then
    if [[ -x "${PGSETUP}" ]]; then
      "${PGSETUP}" initdb
    elif command -v postgresql-setup >/dev/null 2>&1; then
      postgresql-setup --initdb
    elif [[ -x /usr/bin/postgresql-setup ]]; then
      /usr/bin/postgresql-setup --initdb
    else
      # пути модулей PostgreSQL на RHEL-подобных
      for s in /usr/pgsql-*/bin/*-setup; do
        [[ -x "$s" ]] && { "$s" initdb; break; }
      done
    fi
  else
    info "Кластер PostgreSQL уже инициализирован."
  fi

  systemctl enable --now "${PGSERVICE}"
  sleep 2
  systemctl is-active --quiet "${PGSERVICE}" || die "Служба ${PGSERVICE} не запустилась"

  info "Создание роли и БД NetBox..."
  # Экранирование одинарных кавычек в пароле для SQL
  local db_password_sql="${DB_PASSWORD//\'/\'\'}"

  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${db_password_sql}';
  ELSE
    ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${db_password_sql}';
  END IF;
END
\$\$;
SQL

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}"
  fi
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER}"

  # Для PostgreSQL 15+: права на схему public
  sudo -u postgres psql -d "${DB_NAME}" -v ON_ERROR_STOP=1 <<SQL || true
GRANT ALL ON SCHEMA public TO ${DB_USER};
ALTER SCHEMA public OWNER TO ${DB_USER};
SQL

  ok "PostgreSQL настроен (${PGSERVICE})"
  pause_continue "Этап 3 завершён. Enter → Redis..."
}

# -----------------------------------------------------------------------------
# Этап 4: Redis
# -----------------------------------------------------------------------------
stage_redis() {
  banner "Этап 4/10 — Redis"

  ask_yes_no INSTALL_REDIS "Установить Redis на этом сервере?" "y"
  if [[ "${INSTALL_REDIS}" != "y" ]]; then
    warn "Пропуск установки Redis."
    pause_continue "Enter → пользователь и каталог NetBox..."
    return
  fi

  dnf -y install redis || dnf -y install redis6 || die "Не удалось установить Redis"

  # Слушать localhost
  if [[ -f /etc/redis/redis.conf ]]; then
    REDIS_CONF="/etc/redis/redis.conf"
  elif [[ -f /etc/redis.conf ]]; then
    REDIS_CONF="/etc/redis.conf"
  else
    die "Не найден redis.conf"
  fi

  sed -i 's/^bind .*/bind 127.0.0.1/' "${REDIS_CONF}" || true
  grep -q '^bind 127.0.0.1' "${REDIS_CONF}" || echo 'bind 127.0.0.1' >> "${REDIS_CONF}"

  if [[ -n "${REDIS_PASSWORD}" ]]; then
    if grep -qE '^#? *requirepass ' "${REDIS_CONF}"; then
      sed -i "s|^#\\? *requirepass .*|requirepass ${REDIS_PASSWORD}|" "${REDIS_CONF}"
    else
      echo "requirepass ${REDIS_PASSWORD}" >> "${REDIS_CONF}"
    fi
  fi

  # supervised systemd
  sed -i 's/^supervised .*/supervised systemd/' "${REDIS_CONF}" || true

  systemctl enable --now redis || systemctl enable --now redis6
  sleep 1
  if [[ -n "${REDIS_PASSWORD}" ]]; then
    redis-cli -a "${REDIS_PASSWORD}" ping | grep -q PONG || die "Redis не отвечает (с паролем)"
  else
    redis-cli ping | grep -q PONG || die "Redis не отвечает"
  fi

  ok "Redis запущен"
  pause_continue "Этап 4 завершён. Enter → установка NetBox в /opt..."
}

# -----------------------------------------------------------------------------
# Этап 5: пользователь и загрузка NetBox
# -----------------------------------------------------------------------------
stage_netbox_app() {
  banner "Этап 5/10 — NetBox в ${NETBOX_HOME}"

  if ! getent group "${NETBOX_GROUP}" >/dev/null; then
    groupadd --system "${NETBOX_GROUP}"
  fi
  if ! id "${NETBOX_USER}" >/dev/null 2>&1; then
    useradd --system --gid "${NETBOX_GROUP}" --home-dir "${NETBOX_HOME}" \
      --shell /sbin/nologin --comment "NetBox application" "${NETBOX_USER}"
  fi

  mkdir -p /opt
  ask_yes_no REINSTALL "Каталог ${NETBOX_HOME} будет (пере)создан. Продолжить?" "y"
  [[ "${REINSTALL}" == "y" ]] || die "Отменено"

  local tmp
  tmp="$(mktemp -d /tmp/netbox-XXXXXX)"
  info "Скачивание NetBox ${NETBOX_VERSION}..."
  local url="https://github.com/netbox-community/netbox/archive/refs/tags/${NETBOX_VERSION}.tar.gz"
  if ! curl -fL --retry 3 -o "${tmp}/netbox.tgz" "${url}"; then
    die "Не удалось скачать ${url}. Проверьте версию и доступ в интернет/прокси."
  fi

  rm -rf "${NETBOX_HOME}"
  mkdir -p "${NETBOX_HOME}"
  tar -xzf "${tmp}/netbox.tgz" -C "${tmp}"
  local extracted
  extracted="$(find "${tmp}" -maxdepth 1 -type d -name 'netbox-*' | head -n1)"
  [[ -n "${extracted}" ]] || die "Архив NetBox распакован некорректно"
  # Официальная раскладка: /opt/netbox/netbox/... и /opt/netbox/upgrade.sh
  shopt -s dotglob
  mv "${extracted}"/* "${NETBOX_HOME}/"
  shopt -u dotglob
  rm -rf "${tmp}"

  chown -R "${NETBOX_USER}:${NETBOX_GROUP}" "${NETBOX_HOME}"
  ok "NetBox ${NETBOX_VERSION} развёрнут в ${NETBOX_HOME}"
  pause_continue "Этап 5 завершён. Enter → configuration.py и зависимости..."
}

# -----------------------------------------------------------------------------
# Этап 6: конфигурация и upgrade.sh
# -----------------------------------------------------------------------------
generate_secret_key() {
  "${PYTHON_BIN}" - <<'PY'
import secrets
alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*(-_=+)'
print(''.join(secrets.choice(alphabet) for _ in range(50)))
PY
}

stage_configure_netbox() {
  banner "Этап 6/10 — configuration.py, venv, миграции"

  local conf_dir="${NETBOX_HOME}/netbox/netbox"
  local conf_example="${conf_dir}/configuration_example.py"
  local conf_file="${conf_dir}/configuration.py"

  [[ -f "${conf_example}" ]] || conf_example="${conf_dir}/configuration.py.example"
  [[ -f "${conf_example}" ]] || die "Не найден configuration_example.py в ${conf_dir}"

  SECRET_KEY="$(generate_secret_key)"
  local redis_pass_py="''"
  [[ -n "${REDIS_PASSWORD}" ]] && redis_pass_py="'${REDIS_PASSWORD}'"

  cat > "${conf_file}" <<EOF
#########################
# NetBox configuration  #
# Сгенерировано install-netbox-redos8.sh
#########################

ALLOWED_HOSTS = ['${NETBOX_FQDN}', '${NETBOX_IP}', 'localhost', '127.0.0.1']

DATABASE = {
    'NAME': '${DB_NAME}',
    'USER': '${DB_USER}',
    'PASSWORD': '${DB_PASSWORD}',
    'HOST': '${DB_HOST:-127.0.0.1}',
    'PORT': '${DB_PORT:-5432}',
    'CONN_MAX_AGE': 300,
}

# NetBox 4.x также понимает DATABASES; оставляем оба варианта совместимости
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': '${DB_NAME}',
        'USER': '${DB_USER}',
        'PASSWORD': '${DB_PASSWORD}',
        'HOST': '${DB_HOST:-127.0.0.1}',
        'PORT': '${DB_PORT:-5432}',
        'CONN_MAX_AGE': 300,
    }
}

REDIS = {
    'tasks': {
        'HOST': '${REDIS_HOST}',
        'PORT': ${REDIS_PORT},
        'PASSWORD': ${redis_pass_py},
        'DATABASE': 0,
        'SSL': False,
    },
    'caching': {
        'HOST': '${REDIS_HOST}',
        'PORT': ${REDIS_PORT},
        'PASSWORD': ${redis_pass_py},
        'DATABASE': 1,
        'SSL': False,
    }
}

SECRET_KEY = '${SECRET_KEY}'

# За прокси nginx
USE_X_FORWARDED_HOST = True
USE_X_FORWARDED_PORT = True
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
EOF

  chmod 640 "${conf_file}"
  chown "${NETBOX_USER}:${NETBOX_GROUP}" "${conf_file}"

  # local_requirements (gunicorn уже в requirements у многих версий, но фиксируем)
  echo "gunicorn" >> "${NETBOX_HOME}/local_requirements.txt"

  info "Запуск upgrade.sh (venv + зависимости + миграции)..."
  cd "${NETBOX_HOME}"
  PYTHON="${PYTHON_BIN}" ./upgrade.sh

  info "Создание суперпользователя..."
  # Неинтерактивно через Django shell
  sudo -u "${NETBOX_USER}" "${NETBOX_HOME}/venv/bin/python" \
    "${NETBOX_HOME}/netbox/manage.py" shell <<PY
from django.contrib.auth import get_user_model
User = get_user_model()
u, created = User.objects.get_or_create(username='${ADMIN_USER}', defaults={
    'email': '${ADMIN_EMAIL}',
    'is_staff': True,
    'is_superuser': True,
})
u.email = '${ADMIN_EMAIL}'
u.is_staff = True
u.is_superuser = True
u.set_password('${ADMIN_PASSWORD}')
u.save()
print('admin ready:', u.username, 'created=' + str(created))
PY

  # gunicorn config
  if [[ -f "${NETBOX_HOME}/contrib/gunicorn.py" ]]; then
    cp -f "${NETBOX_HOME}/contrib/gunicorn.py" "${NETBOX_HOME}/gunicorn.py"
    sed -i "s|^bind = .*|bind = '${GUNICORN_BIND}'|" "${NETBOX_HOME}/gunicorn.py" || \
      echo "bind = '${GUNICORN_BIND}'" >> "${NETBOX_HOME}/gunicorn.py"
  else
    cat > "${NETBOX_HOME}/gunicorn.py" <<EOF
bind = '${GUNICORN_BIND}'
workers = 5
threads = 3
timeout = 120
user = '${NETBOX_USER}'
EOF
  fi
  chown "${NETBOX_USER}:${NETBOX_GROUP}" "${NETBOX_HOME}/gunicorn.py"

  ok "NetBox сконфигурирован и мигрирован"
  pause_continue "Этап 6 завершён. Enter → systemd (gunicorn / rq)..."
}

# -----------------------------------------------------------------------------
# Этап 7: systemd
# -----------------------------------------------------------------------------
stage_systemd() {
  banner "Этап 7/10 — systemd: netbox + netbox-rq"

  if [[ -f "${NETBOX_HOME}/contrib/netbox.service" ]]; then
    cp -f "${NETBOX_HOME}/contrib/netbox.service" /etc/systemd/system/netbox.service
    cp -f "${NETBOX_HOME}/contrib/netbox-rq.service" /etc/systemd/system/netbox-rq.service
  else
    cat > /etc/systemd/system/netbox.service <<EOF
[Unit]
Description=NetBox WSGI Service
Documentation=https://docs.netbox.dev/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${NETBOX_USER}
Group=${NETBOX_GROUP}
WorkingDirectory=${NETBOX_HOME}/netbox
ExecStart=${NETBOX_HOME}/venv/bin/gunicorn --pid /var/tmp/netbox.pid --pythonpath ${NETBOX_HOME}/netbox --config ${NETBOX_HOME}/gunicorn.py netbox.wsgi
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/netbox-rq.service <<EOF
[Unit]
Description=NetBox Request Queue Worker
Documentation=https://docs.netbox.dev/
After=network-online.target netbox.service
Wants=network-online.target

[Service]
Type=simple
User=${NETBOX_USER}
Group=${NETBOX_GROUP}
WorkingDirectory=${NETBOX_HOME}/netbox
ExecStart=${NETBOX_HOME}/venv/bin/python ${NETBOX_HOME}/netbox/manage.py rqworker
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
  fi

  # Гарантируем пути WorkingDirectory / ExecStart под /opt/netbox
  sed -i "s|/opt/netbox|${NETBOX_HOME}|g" /etc/systemd/system/netbox.service
  sed -i "s|/opt/netbox|${NETBOX_HOME}|g" /etc/systemd/system/netbox-rq.service

  systemctl daemon-reload
  systemctl enable --now netbox netbox-rq
  sleep 2
  systemctl --no-pager --full status netbox || true
  systemctl is-active --quiet netbox || {
    warn "netbox.service не активен — смотрите: journalctl -eu netbox"
    journalctl -eu netbox -n 40 --no-pager || true
    ask_yes_no CONT "Продолжить установку nginx несмотря на ошибку?" "n"
    [[ "${CONT}" == "y" ]] || die "Остановлено из-за ошибки netbox.service"
  }

  ok "systemd-сервисы включены"
  pause_continue "Этап 7 завершён. Enter → nginx + HTTPS..."
}

# -----------------------------------------------------------------------------
# Этап 8: nginx + TLS
# -----------------------------------------------------------------------------
stage_nginx_tls() {
  banner "Этап 8/10 — nginx (HTTPS) + сертификат"

  dnf -y install nginx || die "Не удалось установить nginx"

  mkdir -p /etc/pki/tls/certs /etc/pki/tls/private

  if [[ "${TLS_MODE}" == "self-signed" ]]; then
    ask_yes_no GEN_CERT "Сгенерировать самоподписанный сертификат для ${NETBOX_FQDN}?" "y"
    if [[ "${GEN_CERT}" == "y" ]]; then
      openssl req -x509 -nodes -newkey rsa:4096 -days 825 \
        -keyout "${TLS_KEY}" \
        -out "${TLS_CERT}" \
        -subj "/CN=${NETBOX_FQDN}/O=NetBox/C=RU" \
        -addext "subjectAltName=IP:${NETBOX_IP},DNS:${NETBOX_FQDN},DNS:localhost"
      chmod 600 "${TLS_KEY}"
      chmod 644 "${TLS_CERT}"
      ok "Сертификат: ${TLS_CERT}"
    fi
  fi

  [[ -f "${TLS_CERT}" ]] || die "Нет сертификата: ${TLS_CERT}"
  [[ -f "${TLS_KEY}" ]] || die "Нет ключа: ${TLS_KEY}"

  # SELinux-контексты для ключей (если SELinux on)
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -v "${TLS_CERT}" "${TLS_KEY}" 2>/dev/null || true
  fi

  mkdir -p /etc/nginx/conf.d
  # Отключаем дефолтный server, если мешает
  if [[ -f /etc/nginx/nginx.conf ]]; then
    # на РЕД ОС часто уже есть include conf.d
    true
  fi

  cat > /etc/nginx/conf.d/netbox.conf <<EOF
# NetBox — доступ только с разрешённого IP (дополнительно к firewalld)
upstream netbox {
    server ${GUNICORN_BIND} fail_timeout=0;
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

    # Ограничение по IP на уровне nginx
    allow ${ALLOWED_CLIENT_IP};
    allow 127.0.0.1;
    deny all;

    location /static/ {
        alias ${NETBOX_HOME}/netbox/static/;
    }

    location / {
        proxy_pass http://netbox;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect off;
    }
}
EOF

  # Убрать конфликтующий default server, если есть
  if [[ -f /etc/nginx/conf.d/default.conf ]]; then
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled || true
  fi

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx || systemctl restart nginx

  ok "nginx слушает HTTPS :443"
  pause_continue "Этап 8 завершён. Enter → firewalld..."
}

# -----------------------------------------------------------------------------
# Этап 9: firewalld
# -----------------------------------------------------------------------------
stage_firewall() {
  banner "Этап 9/10 — firewalld (HTTPS только с ${ALLOWED_CLIENT_IP})"

  systemctl enable --now firewalld

  ask_yes_no FW_STRICT "Открыть 443/tcp только для ${ALLOWED_CLIENT_IP} (rich rule)?" "y"
  if [[ "${FW_STRICT}" == "y" ]]; then
    # Убираем широкий https, добавляем точечное правило
    firewall-cmd --permanent --remove-service=https 2>/dev/null || true
    firewall-cmd --permanent --remove-port=443/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ALLOWED_CLIENT_IP} port port=443 protocol=tcp accept"
    # HTTP → редирект (опционально с того же IP)
    ask_yes_no FW_HTTP "Также разрешить 80/tcp с ${ALLOWED_CLIENT_IP} (редирект на HTTPS)?" "y"
    if [[ "${FW_HTTP}" == "y" ]]; then
      firewall-cmd --permanent --remove-service=http 2>/dev/null || true
      firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ALLOWED_CLIENT_IP} port port=80 protocol=tcp accept"
    fi
  else
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-service=http
  fi

  # SSH не трогаем, но спросим
  ask_yes_no FW_SSH "Оставить SSH (22/tcp) открытым для всех?" "y"
  if [[ "${FW_SSH}" == "y" ]]; then
    firewall-cmd --permanent --add-service=ssh || true
  fi

  firewall-cmd --reload
  firewall-cmd --list-all
  ok "firewalld настроен"
  pause_continue "Этап 9 завершён. Enter → SELinux..."
}

# -----------------------------------------------------------------------------
# Этап 10: SELinux
# -----------------------------------------------------------------------------
stage_selinux() {
  banner "Этап 10/10 — SELinux"

  if ! command -v getenforce >/dev/null 2>&1; then
    warn "SELinux utilities не найдены — пропуск."
    return
  fi

  local current
  current="$(getenforce)"
  info "Текущий режим: ${current}"

  ask_yes_no SEL_CFG "Настроить SELinux для NetBox/nginx/PostgreSQL/Redis?" "y"
  if [[ "${SEL_CFG}" != "y" ]]; then
    warn "Настройка SELinux пропущена."
    return
  fi

  # Boolean'ы, типичные для nginx → gunicorn на localhost
  setsebool -P httpd_can_network_connect 1
  setsebool -P httpd_can_network_relay 1 || true
  setsebool -P nis_enabled 1 || true

  # Контексты для статики и кода под /opt/netbox
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t httpd_sys_content_t "${NETBOX_HOME}/netbox/static(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t httpd_sys_content_t "${NETBOX_HOME}/netbox/static(/.*)?" 2>/dev/null \
      || true
    semanage fcontext -a -t bin_t "${NETBOX_HOME}/venv/bin(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t bin_t "${NETBOX_HOME}/venv/bin(/.*)?" 2>/dev/null \
      || true
    restorecon -Rv "${NETBOX_HOME}/netbox/static" "${NETBOX_HOME}/venv/bin" 2>/dev/null || true
  else
    warn "semanage недоступен — установите policycoreutils-python-utils"
  fi

  # Разрешить nginx читать сертификаты
  restorecon -v "${TLS_CERT}" "${TLS_KEY}" 2>/dev/null || true

  # Локальный модуль на случай AVC при proxy к gunicorn
  ask_yes_no SEL_MODULE "Собрать локальный SELinux-модуль netbox_local (если были AVC)?" "y"
  if [[ "${SEL_MODULE}" == "y" ]]; then
    mkdir -p "${STATE_DIR}/selinux"
    cat > "${STATE_DIR}/selinux/netbox_local.te" <<'EOF'
module netbox_local 1.0;

require {
    type httpd_t;
    type unreserved_port_t;
    type var_t;
    type usr_t;
    type bin_t;
    class tcp_socket name_connect;
    class file { read getattr open execute execute_no_trans map };
    class dir { search read };
}

# nginx (httpd_t) → gunicorn на высокономерном порту
allow httpd_t unreserved_port_t:tcp_socket name_connect;
EOF
    if command -v checkmodule >/dev/null 2>&1; then
      dnf -y install checkpolicy policycoreutils || true
      checkmodule -M -m -o "${STATE_DIR}/selinux/netbox_local.mod" "${STATE_DIR}/selinux/netbox_local.te"
      semodule_package -o "${STATE_DIR}/selinux/netbox_local.pp" -m "${STATE_DIR}/selinux/netbox_local.mod"
      semodule -i "${STATE_DIR}/selinux/netbox_local.pp"
      ok "Модуль netbox_local установлен"
    else
      dnf -y install checkpolicy || warn "checkpolicy не установлен — модуль не собран"
      if command -v checkmodule >/dev/null 2>&1; then
        checkmodule -M -m -o "${STATE_DIR}/selinux/netbox_local.mod" "${STATE_DIR}/selinux/netbox_local.te"
        semodule_package -o "${STATE_DIR}/selinux/netbox_local.pp" -m "${STATE_DIR}/selinux/netbox_local.mod"
        semodule -i "${STATE_DIR}/selinux/netbox_local.pp"
        ok "Модуль netbox_local установлен"
      fi
    fi
  fi

  # Режим
  case "${SELINUX_MODE}" in
    enforcing|Enforcing)
      if [[ -f /etc/selinux/config ]]; then
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
      fi
      setenforce 1 2>/dev/null || warn "Не удалось setenforce 1 (нужен reboot после смены с disabled)"
      ;;
    permissive|Permissive)
      if [[ -f /etc/selinux/config ]]; then
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
      fi
      setenforce 0 2>/dev/null || true
      ;;
    *)
      warn "Неизвестный режим SELinux: ${SELINUX_MODE}"
      ;;
  esac

  info "getenforce → $(getenforce)"
  info "При AVC: ausearch -m avc -ts recent | audit2allow -M netbox_fix && semodule -i netbox_fix.pp"
  ok "SELinux настроен"
}

# -----------------------------------------------------------------------------
# Финал: проверка IP и сервисов
# -----------------------------------------------------------------------------
stage_finalize() {
  banner "Проверка и итог"

  ask_yes_no SET_IP "Настроить IPv4 ${NETBOX_IP} на интерфейсе?" "n"
  if [[ "${SET_IP}" == "y" ]]; then
    ip -br link
    ask IFACE "Имя интерфейса (например eth0 / ens192)" ""
    ask PREFIX "Префикс маски (например 24)" "24"
    ask GATEWAY "Шлюз (Enter = не задавать)" ""
    nmcli con show || true
    ask CON_NAME "Имя connection NetworkManager (или оставить пустым для временного адреса)" ""
    if [[ -n "${CON_NAME}" ]]; then
      nmcli con mod "${CON_NAME}" ipv4.addresses "${NETBOX_IP}/${PREFIX}" ipv4.method manual
      [[ -n "${GATEWAY}" ]] && nmcli con mod "${CON_NAME}" ipv4.gateway "${GATEWAY}"
      nmcli con up "${CON_NAME}"
    else
      ip addr add "${NETBOX_IP}/${PREFIX}" dev "${IFACE}" || warn "Адрес уже назначен или ошибка ip addr"
      [[ -n "${GATEWAY}" ]] && ip route replace default via "${GATEWAY}" || true
    fi
  fi

  systemctl restart netbox netbox-rq nginx || true
  sleep 2

  echo
  echo "Статус служб:"
  systemctl is-active netbox netbox-rq nginx redis redis6 postgresql postgresql-14 postgresql-15 postgresql-16 2>/dev/null || true
  systemctl --no-pager -n 0 status netbox nginx 2>/dev/null || true

  save_answers

  cat <<EOF

$(echo -e "${C_GREEN}======== УСТАНОВКА ЗАВЕРШЕНА ========${C_RESET}")

  URL:              https://${NETBOX_IP}/
  (или)             https://${NETBOX_FQDN}/
  Доступ с IP:      ${ALLOWED_CLIENT_IP}
  Каталог:          ${NETBOX_HOME}
  Админ:            ${ADMIN_USER}
  Пароль админа:    (см. ${ANSWERS_FILE})
  Ответы/секреты:   ${ANSWERS_FILE}
  Лог:              ${LOG_FILE}

  Полезные команды:
    systemctl status netbox netbox-rq nginx
    journalctl -eu netbox
    firewall-cmd --list-all
    getenforce

  С клиента ${ALLOWED_CLIENT_IP}:
    curl -k https://${NETBOX_IP}/

$(echo -e "${C_YELLOW}Сохраните ${ANSWERS_FILE} в сейф и ограничьте доступ (chmod 600).${C_RESET}")

EOF
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
  require_root
  mkdir -p "${STATE_DIR}"
  touch "${LOG_FILE}"

  banner "NetBox на РЕД ОС 8 — интерактивная установка"
  echo "Лог: ${LOG_FILE}"
  echo

  # Проверка ОС (мягкая)
  if [[ -f /etc/red-release ]]; then
    ok "Обнаружен РЕД ОС: $(cat /etc/red-release)"
  elif [[ -f /etc/redhat-release ]]; then
    warn "РЕД ОС не обнаружен явно, но система RHEL-подобная: $(cat /etc/redhat-release)"
    ask_yes_no CONT_OS "Продолжить?" "y"
    [[ "${CONT_OS}" == "y" ]] || die "Отменено"
  else
    warn "Не похоже на РЕД ОС / RHEL."
    ask_yes_no CONT_OS "Продолжить на свой страх и риск?" "n"
    [[ "${CONT_OS}" == "y" ]] || die "Отменено"
  fi

  stage_collect_answers
  stage_system_update
  stage_python
  stage_postgresql
  stage_redis
  stage_netbox_app
  stage_configure_netbox
  stage_systemd
  stage_nginx_tls
  stage_firewall
  stage_selinux
  stage_finalize
}

main "$@"
