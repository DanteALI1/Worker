#!/bin/bash
# Первичная подготовка сервера-зеркала РЕД ОС 8 с HTTPS (сертификаты УЦ).
# Запуск от root:
#   REPO_NET=10.0.0.0/8 \
#   REPO_FQDN=repo.example.ru \
#   SSL_CRT=/path/server.crt SSL_KEY=/path/server.key \
#   SSL_CHAIN=/path/ca-chain.crt \
#   bash bootstrap-mirror-server.sh
#
# Без SSL_CRT/SSL_KEY — поднимет только зеркало+httpd (HTTPS настроите install-ssl-certs.sh).

set -euo pipefail

REPO_NET="${REPO_NET:-10.0.0.0/8}"
REPO_FQDN="${REPO_FQDN:-repo.example.ru}"
STORAGE_ROOT="${STORAGE_ROOT:-/opt/repos}"
WEB_REPOS="${WEB_REPOS:-/var/www/html/repos}"
DESTDIR="${DESTDIR:-${STORAGE_ROOT}/redos8}"
INTERNAL="${INTERNAL:-${STORAGE_ROOT}/internal}"
SSL_CRT="${SSL_CRT:-}"
SSL_KEY="${SSL_KEY:-}"
SSL_CHAIN="${SSL_CHAIN:-}"
CA_CERT="${CA_CERT:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$(cd "${SCRIPT_DIR}/../../configs/local-repo/sources" 2>/dev/null && pwd || true)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите от root" >&2
  exit 1
fi

echo "== Установка пакетов =="
dnf install -y httpd mod_ssl createrepo_c dnf-utils policycoreutils-python-utils

echo "== httpd =="
systemctl enable --now httpd

echo "== firewalld (${REPO_NET} → https) =="
systemctl enable --now firewalld
firewall-cmd --permanent --remove-service=http 2>/dev/null || true
firewall-cmd --permanent --remove-service=https 2>/dev/null || true
firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"${REPO_NET}\" service name=\"https\" accept"
firewall-cmd --reload

echo "== Каталоги: ${STORAGE_ROOT} → ${WEB_REPOS} =="
mkdir -p "$DESTDIR" "$INTERNAL/rpms" /var/log/local-repo /var/www/html

if [[ -e "$WEB_REPOS" && ! -L "$WEB_REPOS" ]]; then
  echo "Ошибка: ${WEB_REPOS} существует и не является symlink." >&2
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

# hosts: FQDN → первый IP хоста (если записи ещё нет)
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -n "$HOST_IP" ]] && ! grep -qE "[[:space:]]${REPO_FQDN}([[:space:]]|\$)" /etc/hosts; then
  echo "${HOST_IP} ${REPO_FQDN}" >> /etc/hosts
  echo "== /etc/hosts: ${HOST_IP} ${REPO_FQDN} =="
fi

if [[ -n "${SOURCES_DIR}" && -d "${SOURCES_DIR}" ]]; then
  echo "== Source .repo =="
  install -m 644 "${SOURCES_DIR}/redos8_base_src.repo" /etc/yum.repos.d/
  install -m 644 "${SOURCES_DIR}/redos8_updates_src.repo" /etc/yum.repos.d/
  install -m 644 "${SOURCES_DIR}/redos8_extras_src.repo" /etc/yum.repos.d/
else
  echo "== Source .repo не найдены рядом — создайте вручную =="
fi

if [[ -f "${SCRIPT_DIR}/sync-redos8-repos.sh" ]]; then
  install -m 750 "${SCRIPT_DIR}/sync-redos8-repos.sh" /usr/local/sbin/sync-redos8-repos.sh
  cat > /etc/cron.d/redos8-local-repo << 'EOF'
30 2 * * * root /usr/local/sbin/sync-redos8-repos.sh
EOF
  chmod 644 /etc/cron.d/redos8-local-repo
fi

if [[ -n "$SSL_CRT" && -n "$SSL_KEY" && -f "${SCRIPT_DIR}/install-ssl-certs.sh" ]]; then
  echo "== SSL (сертификаты УЦ) =="
  SSL_CRT="$SSL_CRT" SSL_KEY="$SSL_KEY" SSL_CHAIN="$SSL_CHAIN" \
  CA_CERT="$CA_CERT" REPO_FQDN="$REPO_FQDN" REPO_NET="$REPO_NET" \
    bash "${SCRIPT_DIR}/install-ssl-certs.sh"
else
  echo "== SSL пропущен: задайте SSL_CRT и SSL_KEY, затем:"
  echo "   SSL_CRT=... SSL_KEY=... REPO_FQDN=${REPO_FQDN} bash ${SCRIPT_DIR}/install-ssl-certs.sh"
  HTTPD_SNIPPET="$(cd "${SCRIPT_DIR}/../../configs/local-repo" 2>/dev/null && pwd || true)"
  if [[ -n "${HTTPD_SNIPPET}" && -f "${HTTPD_SNIPPET}/httpd-local-repo.conf" ]]; then
    install -m 644 "${HTTPD_SNIPPET}/httpd-local-repo.conf" /etc/httpd/conf.d/local-repo.conf
    sed -i "s|10.0.0.0/8|${REPO_NET}|g" /etc/httpd/conf.d/local-repo.conf
    apachectl configtest
    systemctl reload httpd
  fi
fi

echo
echo "Готово."
echo "  Хранилище: ${STORAGE_ROOT}"
echo "  FQDN:      ${REPO_FQDN}"
echo "  URL:       https://${REPO_FQDN}/repos/redos8/"
echo
echo "Зеркалирование:"
echo "  NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh"
echo
echo "Клиенты:"
echo "  REPO_HOST=${REPO_FQDN} PROTO=https CA_CERT=/path/ca-root.crt bash configure-client.sh"
