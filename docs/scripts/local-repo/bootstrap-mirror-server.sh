#!/bin/bash
# Первичная подготовка сервера-зеркала РЕД ОС 8 (минимальный сервер).
# Запуск от root:
#   REPO_NET=10.0.0.0/8 bash bootstrap-mirror-server.sh
#
# Делает:
#  - ставит httpd, createrepo_c, dnf-utils
#  - открывает HTTP для REPO_NET
#  - создаёт /opt/repos + symlink /var/www/html/repos
#  - кладёт source .repo (если есть configs/local-repo/sources)
#  - ставит sync-скрипт и cron
#  - НЕ запускает reposync (это долго — вручную или sync-скриптом)

set -euo pipefail

REPO_NET="${REPO_NET:-10.0.0.0/8}"
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
# не открываем http всему миру — только REPO_NET через rich-rule
firewall-cmd --permanent --remove-service=http 2>/dev/null || true
firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"${REPO_NET}\" service name=\"http\" accept"
firewall-cmd --reload

echo "== Каталоги: ${STORAGE_ROOT} → ${WEB_REPOS} =="
mkdir -p "$DESTDIR" "$INTERNAL/rpms" /var/log/local-repo /var/www/html

if [[ -e "$WEB_REPOS" && ! -L "$WEB_REPOS" ]]; then
  echo "Ошибка: ${WEB_REPOS} существует и не является symlink." >&2
  echo "Перенесите данные или удалите каталог, затем повторите:" >&2
  echo "  mv ${WEB_REPOS} ${WEB_REPOS}.bak && ln -sfn ${STORAGE_ROOT} ${WEB_REPOS}" >&2
  exit 1
fi
ln -sfn "$STORAGE_ROOT" "$WEB_REPOS"

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
  echo "== Source .repo не найдены рядом со скриптом — создайте вручную (см. гайд) =="
fi

if [[ -f "${SCRIPT_DIR}/sync-redos8-repos.sh" ]]; then
  install -m 750 "${SCRIPT_DIR}/sync-redos8-repos.sh" /usr/local/sbin/sync-redos8-repos.sh
  cat > /etc/cron.d/redos8-local-repo << 'EOF'
30 2 * * * root /usr/local/sbin/sync-redos8-repos.sh
EOF
  chmod 644 /etc/cron.d/redos8-local-repo
  echo "== sync → /usr/local/sbin/sync-redos8-repos.sh, cron 02:30 =="
fi

HTTPD_SNIPPET="$(cd "${SCRIPT_DIR}/../../configs/local-repo" 2>/dev/null && pwd || true)"
if [[ -n "${HTTPD_SNIPPET}" && -f "${HTTPD_SNIPPET}/httpd-local-repo.conf" ]]; then
  install -m 644 "${HTTPD_SNIPPET}/httpd-local-repo.conf" /etc/httpd/conf.d/local-repo.conf
  sed -i "s|10.0.0.0/8|${REPO_NET}|g" /etc/httpd/conf.d/local-repo.conf
  # путь хранилища в Directory, если переопределён STORAGE_ROOT
  if [[ "$STORAGE_ROOT" != "/opt/repos" ]]; then
    sed -i "s|/opt/repos|${STORAGE_ROOT}|g" /etc/httpd/conf.d/local-repo.conf
  fi
  apachectl configtest
  systemctl reload httpd
fi

MIRROR_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "Готово."
echo "  Хранилище: ${STORAGE_ROOT}"
echo "  Web path:  ${WEB_REPOS} -> $(readlink -f "$WEB_REPOS" 2>/dev/null || echo '?')"
echo
echo "Первичное зеркалирование (долго, много места):"
echo "  NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh"
echo "  # или только новейшие пакеты:"
echo "  /usr/local/sbin/sync-redos8-repos.sh"
echo
echo "Проверка после sync:"
echo "  curl -I http://${MIRROR_IP:-10.0.0.10}/repos/redos8/redos8_base_src/repodata/repomd.xml"
echo "  df -h ${STORAGE_ROOT}"
