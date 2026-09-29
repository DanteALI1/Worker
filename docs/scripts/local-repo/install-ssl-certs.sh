#!/bin/bash
# Установка сертификатов УЦ для локального репозитория РЕД ОС 8 (httpd + mod_ssl).
# По документации:
#   https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/
#   https://redos.red-soft.ru/base/redos-8_0/8_0-security/8_0-ssl/8_0-ssl-for-webserv/
#
# Запуск от root:
#   SSL_CRT=/path/server.crt SSL_KEY=/path/server.key \
#   REPO_FQDN=repo.example.ru bash install-ssl-certs.sh
#
# Опционально:
#   SSL_CHAIN=/path/ca-chain.crt   — промежуточная цепочка для httpd
#   CA_CERT=/path/ca-root.crt      — корневой CA в trust store на ЭТОМ хосте
#   REPO_NET=10.0.0.0/8
#   SKIP_HTTPD_CONF=1              — только положить файлы, не трогать conf.d

set -euo pipefail

REPO_FQDN="${REPO_FQDN:-repo.example.ru}"
REPO_NET="${REPO_NET:-10.0.0.0/8}"
SSL_CRT="${SSL_CRT:-}"
SSL_KEY="${SSL_KEY:-}"
SSL_CHAIN="${SSL_CHAIN:-}"
CA_CERT="${CA_CERT:-}"
DEST_CRT="${DEST_CRT:-/etc/pki/tls/certs/repo.crt}"
DEST_KEY="${DEST_KEY:-/etc/pki/tls/private/repo.key}"
DEST_CHAIN="${DEST_CHAIN:-/etc/pki/tls/certs/repo-chain.crt}"
SKIP_HTTPD_CONF="${SKIP_HTTPD_CONF:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите от root" >&2
  exit 1
fi

if [[ -z "$SSL_CRT" || -z "$SSL_KEY" ]]; then
  echo "Укажите SSL_CRT и SSL_KEY (пути к .crt и .key от УЦ)" >&2
  exit 1
fi
if [[ ! -f "$SSL_CRT" ]]; then
  echo "Нет файла сертификата: $SSL_CRT" >&2
  exit 1
fi
if [[ ! -f "$SSL_KEY" ]]; then
  echo "Нет файла ключа: $SSL_KEY" >&2
  exit 1
fi

echo "== Проверка пары crt/key =="
mod_crt="$(openssl x509 -noout -modulus -in "$SSL_CRT" | openssl md5)"
mod_key="$(openssl rsa  -noout -modulus -in "$SSL_KEY" 2>/dev/null | openssl md5 || true)"
if [[ -z "$mod_key" || "$mod_crt" != "$mod_key" ]]; then
  echo "Ошибка: сертификат и ключ не совпадают (или ключ не RSA/PEM)" >&2
  exit 1
fi
echo "CN/SAN:"
openssl x509 -in "$SSL_CRT" -noout -subject -ext subjectAltName 2>/dev/null || \
  openssl x509 -in "$SSL_CRT" -noout -subject

echo "== Установка mod_ssl =="
dnf install -y mod_ssl httpd

echo "== Размещение сертификатов =="
install -d -m 755 /etc/pki/tls/certs
install -d -m 700 /etc/pki/tls/private
install -m 644 "$SSL_CRT" "$DEST_CRT"
install -m 600 "$SSL_KEY" "$DEST_KEY"
chown root:root "$DEST_KEY"

CHAIN_LINE_COMMENT="# SSLCertificateChainFile ${DEST_CHAIN}"
if [[ -n "$SSL_CHAIN" && -f "$SSL_CHAIN" ]]; then
  install -m 644 "$SSL_CHAIN" "$DEST_CHAIN"
  CHAIN_LINE_COMMENT="SSLCertificateChainFile ${DEST_CHAIN}"
  echo "chain → $DEST_CHAIN"
fi

if [[ -n "$CA_CERT" && -f "$CA_CERT" ]]; then
  echo "== CA в системный trust (этот хост) =="
  install -m 644 "$CA_CERT" /etc/pki/ca-trust/source/anchors/org-ca.crt
  update-ca-trust
  update-ca-trust extract
fi

if [[ "$SKIP_HTTPD_CONF" != "1" ]]; then
  echo "== Конфиг httpd SSL (FQDN=${REPO_FQDN}) =="
  SRC_SSL="${SCRIPT_DIR}/../../configs/local-repo/httpd-ssl-repo.conf"
  if [[ -f "$SRC_SSL" ]]; then
    install -m 644 "$SRC_SSL" /etc/httpd/conf.d/ssl-repo.conf
    sed -i "s/repo.example.ru/${REPO_FQDN}/g" /etc/httpd/conf.d/ssl-repo.conf
    sed -i "s|10.0.0.0/8|${REPO_NET}|g" /etc/httpd/conf.d/ssl-repo.conf
    if [[ -n "$SSL_CHAIN" && -f "$SSL_CHAIN" ]]; then
      sed -i "s|# SSLCertificateChainFile .*|SSLCertificateChainFile ${DEST_CHAIN}|" \
        /etc/httpd/conf.d/ssl-repo.conf
    fi
  else
    # минимальная правка штатного ssl.conf по доке РЕД ОС
    if [[ -f /etc/httpd/conf.d/ssl.conf ]]; then
      sed -i -E "s|^#?\s*ServerName\s+.*|ServerName ${REPO_FQDN}|" /etc/httpd/conf.d/ssl.conf || true
      sed -i -E "s|^SSLCertificateFile\s+.*|SSLCertificateFile ${DEST_CRT}|" /etc/httpd/conf.d/ssl.conf
      sed -i -E "s|^SSLCertificateKeyFile\s+.*|SSLCertificateKeyFile ${DEST_KEY}|" /etc/httpd/conf.d/ssl.conf
      if [[ -n "$SSL_CHAIN" && -f "$SSL_CHAIN" ]]; then
        if grep -qE '^\s*SSLCertificateChainFile' /etc/httpd/conf.d/ssl.conf; then
          sed -i -E "s|^#?\s*SSLCertificateChainFile\s+.*|SSLCertificateChainFile ${DEST_CHAIN}|" \
            /etc/httpd/conf.d/ssl.conf
        else
          echo "SSLCertificateChainFile ${DEST_CHAIN}" >> /etc/httpd/conf.d/ssl.conf
        fi
      fi
    fi
  fi

  # ServerName в главном конфиге (как в доке SSL для веб-серверов)
  if [[ -f /etc/httpd/conf/httpd.conf ]]; then
    if grep -qE '^\s*ServerName\s+' /etc/httpd/conf/httpd.conf; then
      sed -i -E "s|^\s*ServerName\s+.*|ServerName ${REPO_FQDN}|" /etc/httpd/conf/httpd.conf
    elif grep -qE '^#\s*ServerName\s+' /etc/httpd/conf/httpd.conf; then
      sed -i -E "s|^#\s*ServerName\s+.*|ServerName ${REPO_FQDN}|" /etc/httpd/conf/httpd.conf
    else
      echo "ServerName ${REPO_FQDN}" >> /etc/httpd/conf/httpd.conf
    fi
  fi

  # ограничение каталога репозитория
  SRC_DIR="${SCRIPT_DIR}/../../configs/local-repo/httpd-local-repo.conf"
  if [[ -f "$SRC_DIR" ]]; then
    install -m 644 "$SRC_DIR" /etc/httpd/conf.d/local-repo.conf
    sed -i "s|10.0.0.0/8|${REPO_NET}|g" /etc/httpd/conf.d/local-repo.conf
  fi

  apachectl configtest
  systemctl enable --now httpd
  systemctl restart httpd
fi

echo "== firewalld https (${REPO_NET}) =="
systemctl enable --now firewalld
firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"${REPO_NET}\" service name=\"https\" accept"
firewall-cmd --reload

echo
echo "Готово."
echo "  crt:  $DEST_CRT"
echo "  key:  $DEST_KEY"
echo "  FQDN: $REPO_FQDN"
echo "  ${CHAIN_LINE_COMMENT}"
echo
echo "Проверка: curl -Ik https://${REPO_FQDN}/"
echo "На клиентах установите CA_CERT в anchors и используйте https://${REPO_FQDN}/repos/..."
