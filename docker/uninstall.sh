#!/usr/bin/env bash
# =============================================================================
# Полное удаление NetBox + MediaWiki, установленных через docker/install.sh
#
# Что удаляет по умолчанию:
#   - контейнеры compose-стека
#   - volumes (БД PostgreSQL/MariaDB, Redis, media, wiki)
#   - сети проекта
#   - каталог установки (/opt/netbox-wiki): .env, CREDENTIALS.txt, сертификаты, конфиги
#   - правила firewalld для портов NetBox/MediaWiki
#
# Опционально:
#   REMOVE_IMAGES=1  — удалить docker-образы стека
#   REMOVE_DOCKER=1  — остановить и удалить Docker/Compose с сервера
#   ASSUME_YES=1     — без интерактивного подтверждения
#
# Запуск (от root):
#   bash uninstall.sh
#   ASSUME_YES=1 REMOVE_IMAGES=1 bash uninstall.sh
#   ASSUME_YES=1 REMOVE_IMAGES=1 REMOVE_DOCKER=1 bash uninstall.sh
#
# Переменные:
#   INSTALL_DIR=/opt/netbox-wiki
#   NETBOX_HTTPS_PORT=443
#   MEDIAWIKI_HTTPS_PORT=8443
# =============================================================================

set -euo pipefail

export LANG=C.UTF-8

INSTALL_DIR="${INSTALL_DIR:-/opt/netbox-wiki}"
NETBOX_HTTPS_PORT="${NETBOX_HTTPS_PORT:-443}"
MEDIAWIKI_HTTPS_PORT="${MEDIAWIKI_HTTPS_PORT:-8443}"
REMOVE_IMAGES="${REMOVE_IMAGES:-0}"
REMOVE_DOCKER="${REMOVE_DOCKER:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# Образы, которые поднимает install.sh (для REMOVE_IMAGES=1)
STACK_IMAGE_PATTERNS=(
  "netboxcommunity/netbox"
  "docker.io/netboxcommunity/netbox"
  "mediawiki"
  "docker.io/mediawiki"
  "postgres:15"
  "docker.io/postgres:15"
  "redis:7"
  "docker.io/redis:7"
  "mariadb:10.11"
  "docker.io/mariadb:10.11"
  "nginx:1.25"
  "docker.io/nginx:1.25"
)

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID} -eq 0 ]] || die "Запустите скрипт от root (sudo)."; }

compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    return 1
  fi
}

confirm() {
  if [[ "${ASSUME_YES}" == "1" ]]; then
    return 0
  fi
  echo
  echo "Будет удалено:"
  echo "  - стек Docker в ${INSTALL_DIR}"
  echo "  - все volumes (данные БД и файлы приложений)"
  echo "  - каталог ${INSTALL_DIR}"
  echo "  - порты firewalld ${NETBOX_HTTPS_PORT}/tcp и ${MEDIAWIKI_HTTPS_PORT}/tcp"
  [[ "${REMOVE_IMAGES}" == "1" ]] && echo "  - docker-образы стека (REMOVE_IMAGES=1)"
  [[ "${REMOVE_DOCKER}" == "1" ]] && echo "  - пакеты Docker с сервера (REMOVE_DOCKER=1)"
  echo
  read -r -p "Продолжить? [y/N] " ans
  case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    *) die "Отменено пользователем" ;;
  esac
}

load_ports_from_env() {
  local envf="${INSTALL_DIR}/.env"
  if [[ -f "${envf}" ]]; then
    local p1 p2
    p1="$(grep -E '^NETBOX_HTTPS_PORT=' "${envf}" | tail -1 | cut -d= -f2- || true)"
    p2="$(grep -E '^MEDIAWIKI_HTTPS_PORT=' "${envf}" | tail -1 | cut -d= -f2- || true)"
    [[ -n "${p1}" ]] && NETBOX_HTTPS_PORT="${p1}"
    [[ -n "${p2}" ]] && MEDIAWIKI_HTTPS_PORT="${p2}"
  fi
}

stop_stack() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker не установлен — пропуск остановки контейнеров"
    return 0
  fi

  if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
    log "Остановка compose-стека и удаление volumes..."
    local env_args=()
    [[ -f "${INSTALL_DIR}/.env" ]] && env_args=(--env-file "${INSTALL_DIR}/.env")
    (
      cd "${INSTALL_DIR}"
      compose "${env_args[@]}" down -v --remove-orphans --rmi local 2>/dev/null \
        || compose "${env_args[@]}" down -v --remove-orphans 2>/dev/null \
        || true
    )
  else
    log "Файл ${INSTALL_DIR}/docker-compose.yml не найден — ищем контейнеры по имени проекта"
  fi

  # На случай, если каталог уже частично удалён / compose недоступен
  local project
  project="$(basename "${INSTALL_DIR}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  if docker info >/dev/null 2>&1; then
    local ids
    ids="$(docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true)"
    if [[ -n "${ids}" ]]; then
      log "Удаление оставшихся контейнеров проекта ${project}..."
      # shellcheck disable=SC2086
      docker rm -f ${ids} 2>/dev/null || true
    fi

    # Volumes проекта
    local vols
    vols="$(docker volume ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true)"
    if [[ -n "${vols}" ]]; then
      log "Удаление volumes проекта ${project}..."
      # shellcheck disable=SC2086
      docker volume rm -f ${vols} 2>/dev/null || true
    fi

    # Сети проекта
    local nets
    nets="$(docker network ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true)"
    if [[ -n "${nets}" ]]; then
      log "Удаление сетей проекта ${project}..."
      # shellcheck disable=SC2086
      docker network rm ${nets} 2>/dev/null || true
    fi
  fi
}

remove_images() {
  [[ "${REMOVE_IMAGES}" == "1" ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  log "Удаление docker-образов стека..."
  local img pattern
  for pattern in "${STACK_IMAGE_PATTERNS[@]}"; do
    while read -r img; do
      [[ -z "${img}" ]] && continue
      log "  docker rmi ${img}"
      docker rmi -f "${img}" 2>/dev/null || true
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "${pattern}" || true)
  done

  # Подчистка висячих слоёв после rmi
  docker image prune -f >/dev/null 2>&1 || true
}

remove_install_dir() {
  if [[ -d "${INSTALL_DIR}" ]]; then
    log "Удаление каталога ${INSTALL_DIR}..."
    rm -rf "${INSTALL_DIR}"
  else
    log "Каталог ${INSTALL_DIR} уже отсутствует"
  fi
}

close_firewall() {
  if command -v firewall-cmd >/dev/null 2>&1; then
    log "Закрытие портов firewalld ${NETBOX_HTTPS_PORT}/tcp и ${MEDIAWIKI_HTTPS_PORT}/tcp"
    firewall-cmd --permanent --remove-port="${NETBOX_HTTPS_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --permanent --remove-port="${MEDIAWIKI_HTTPS_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  else
    log "firewalld не найден — пропуск"
  fi
}

remove_docker() {
  [[ "${REMOVE_DOCKER}" == "1" ]] || return 0

  log "Удаление Docker с сервера (REMOVE_DOCKER=1)..."
  systemctl stop docker.socket docker containerd 2>/dev/null || true
  systemctl disable docker.socket docker containerd 2>/dev/null || true

  if command -v dnf >/dev/null 2>&1; then
    dnf remove -y docker docker-client docker-client-latest docker-common \
      docker-latest docker-latest-logrotate docker-logrotate docker-engine \
      docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose \
      moby-engine 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then
    yum remove -y docker docker-client docker-client-latest docker-common \
      docker-latest docker-engine docker-compose 2>/dev/null || true
  fi

  rm -f /usr/local/bin/docker-compose 2>/dev/null || true
  # Данные Docker (образы/volumes всех проектов на хосте!)
  if [[ -d /var/lib/docker ]]; then
    log "Удаление /var/lib/docker ..."
    rm -rf /var/lib/docker
  fi
  rm -rf /var/lib/containerd 2>/dev/null || true
}

main() {
  need_root
  load_ports_from_env
  confirm

  log "=== Удаление NetBox + MediaWiki (Docker) ==="
  stop_stack
  remove_images
  remove_install_dir
  close_firewall
  remove_docker

  echo
  echo "================================================================"
  echo " Удаление завершено"
  echo " Каталог: ${INSTALL_DIR} — удалён (если существовал)"
  if [[ "${REMOVE_DOCKER}" == "1" ]]; then
    echo " Docker удалён с сервера"
  else
    echo " Docker на сервере сохранён (для удаления: REMOVE_DOCKER=1)"
  fi
  echo "================================================================"
}

main "$@"
