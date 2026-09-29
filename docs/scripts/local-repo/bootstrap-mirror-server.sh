#!/bin/bash
# Первичная подготовка сервера-зеркала РЕД ОС 8 (минимальный сервер).
# Запуск от root на сервере, который станет локальным репозиторием:
#   REPO_NET=10.0.0.0/8 bash bootstrap-mirror-server.sh
#
# Скрипт:
#  - ставит httpd, createrepo_c, dnf-utils
#  - открывает HTTP для REPO_NET
#  - создаёт каталоги
#  - кладёт source .repo (если рядом есть каталог sources/)
#  - НЕ запускает полный reposync (это долго — сделайте вручную или через sync-скрипт)

set -euo pipefail

REPO_NET="${REPO_NET:-10.0.0.0/8}"
# По умолчанию пакеты на /opt (крупный раздел), наружу — через /var/www/html/repos
STORAGE_ROOT="${STORAGE_ROOT:-/opt/repos}"
WEB_REPOS="${WEB_REPOS:-/var/www/html/repos}"
DESTDIR="${DESTDIR:-${STORAGE_ROOT}/redos8}"
INTERNAL="${INTERNAL:-${STORAGE_ROOT}/internal}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$(cd "${SCRIPT_DIR}/../../configs/local-repo/sources" 2>/dev/null && pwd || true)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите от root" >&2
  exit 1
fi

echo "== Установка пакетов =="
dnf install -y httpd createrepo_c dnf-utils policycoreutils-python-utils

echo "== httpd =="
systemctl enable --now httpd

echo "== firewalld (${REPO_NET} → http) =="
systemctl enable --now firewalld
firewall-cmd --permanent --remove-service=http 2>/dev/null || true
firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"${REPO_NET}\" service name=\"http\" accept"
firewall-cmd --reload

echo "== Каталоги (STORAGE_ROOT=${STORAGE_ROOT}) =="
mkdir -p "$DESTDIR" "$INTERNAL/rpms" /var/log/local-repo /var/www/html
if [[ "$(readlink -f "$WEB_REPOS" 2>/dev/null || true)" != "$(readlink -f "$STORAGE_ROOT")" ]]; then
  if [[ -e "$WEB_REPOS" && ! -L "$WEB_REPOS" ]]; then
    echo "Внимание: $WEB_REPOS уже существует и не symlink — не перезаписываем" >&2
  else
    ln -sfn "$STORAGE_ROOT" "$WEB_REPOS"
  fi
fi
semanage fcontext -a -t httpd_sys_content_t "${STORAGE_ROOT}(/.*)?" 2>/dev/null \
  || semanage fcontext -m -t httpd_sys_content_t "${STORAGE_ROOT}(/.*)?" 2>/dev/null \
  || true
restorecon -Rv "$STORAGE_ROOT" || true
chown -R root:apache "$STORAGE_ROOT"
chmod -R 755 "$STORAGE_ROOT"

if [[ -n "${SOURCES_DIR}" && -d "${SOURCES_DIR}" ]]; then
  echo "== Копирование source .repo из ${SOURCES_DIR} =="
  install -m 644 "${SOURCES_DIR}/redos8_base_src.repo" /etc/yum.repos.d/
  install -m 644 "${SOURCES_DIR}/redos8_updates_src.repo" /etc/yum.repos.d/
  install -m 644 "${SOURCES_DIR}/redos8_extras_src.repo" /etc/yum.repos.d/
else
  echo "== Source .repo: каталог sources не найден — создайте вручную (см. гайд) =="
fi

if [[ -f "${SCRIPT_DIR}/sync-redos8-repos.sh" ]]; then
  install -m 750 "${SCRIPT_DIR}/sync-redos8-repos.sh" /usr/local/sbin/sync-redos8-repos.sh
  cat > /etc/cron.d/redos8-local-repo << 'EOF'
30 2 * * * root /usr/local/sbin/sync-redos8-repos.sh
EOF
  chmod 644 /etc/cron.d/redos8-local-repo
  echo "== sync-скрипт установлен в /usr/local/sbin/sync-redos8-repos.sh + cron 02:30 =="
fi

HTTPD_SNIPPET="$(cd "${SCRIPT_DIR}/../../configs/local-repo" 2>/dev/null && pwd || true)"
if [[ -n "${HTTPD_SNIPPET}" && -f "${HTTPD_SNIPPET}/httpd-local-repo.conf" ]]; then
  install -m 644 "${HTTPD_SNIPPET}/httpd-local-repo.conf" /etc/httpd/conf.d/local-repo.conf
  # подставить сеть
  sed -i "s|10.0.0.0/8|${REPO_NET}|g" /etc/httpd/conf.d/local-repo.conf
  apachectl configtest
  systemctl reload httpd
fi

echo
echo "Готово. Дальше выполните первичное зеркалирование:"
echo "  /usr/local/sbin/sync-redos8-repos.sh"
echo "  # или NEWEST=0 для полного зеркала без --newest-only"
echo "  NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh"
echo
echo "Проверка: curl -I http://$(hostname -I | awk '{print $1}')/repos/redos8/"
