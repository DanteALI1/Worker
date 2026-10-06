#!/bin/bash
# ============================================================================
# Готовый деплой локального зеркала РЕД ОС 8 (HTTPS)
# Сертификаты по умолчанию:
#   /home/svcsecadm/uibrep.crt
#   /home/svcsecadm/uibrep.key
#
# Запуск на сервере-зеркале от root:
#   bash deploy-uibrep-mirror.sh
#
# Опции:
#   SKIP_SYNC=1     — не запускать reposync (только подготовка)
#   NEWEST=0        — полное зеркало (по умолчанию NEWEST=0 при первом запуске)
#   REPO_NET=...    — сеть клиентов (по умолчанию 10.0.0.0/8)
#   REPO_FQDN=...   — принудительно задать имя (иначе из сертификата / hostname)
#   SSL_CRT=... SSL_KEY=... — другие пути к сертификатам
# ============================================================================

set -euo pipefail

SSL_CRT="${SSL_CRT:-/home/svcsecadm/uibrep.crt}"
SSL_KEY="${SSL_KEY:-/home/svcsecadm/uibrep.key}"
REPO_NET="${REPO_NET:-10.0.0.0/8}"
STORAGE_ROOT="${STORAGE_ROOT:-/opt/repos}"
WEB_REPOS="${WEB_REPOS:-/var/www/html/repos}"
DESTDIR="${DESTDIR:-${STORAGE_ROOT}/redos8}"
INTERNAL="${INTERNAL:-${STORAGE_ROOT}/internal}"
DEST_CRT="${DEST_CRT:-/etc/pki/tls/certs/repo.crt}"
DEST_KEY="${DEST_KEY:-/etc/pki/tls/private/repo.key}"
DEST_CHAIN="${DEST_CHAIN:-/etc/pki/tls/certs/repo-chain.crt}"
SKIP_SYNC="${SKIP_SYNC:-0}"
NEWEST="${NEWEST:-0}"
LOG_DIR="${LOG_DIR:-/var/log/local-repo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "== $* =="; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  die "Запустите от root: sudo bash $0   или   su - -c \"bash $0\""
fi

[[ -f "$SSL_CRT" ]] || die "Нет сертификата: $SSL_CRT"
[[ -f "$SSL_KEY" ]] || die "Нет ключа: $SSL_KEY"

# --- определить FQDN: SAN → CN → hostname -f → hostname ---
detect_fqdn() {
  local crt="$1" san cn hostf hostn
  san="$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*DNS:\s*\([^ ]*\).*/\1/p' | head -n1 | tr -d '[:space:]')"
  if [[ -n "$san" ]]; then
    echo "$san"
    return
  fi
  cn="$(openssl x509 -in "$crt" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/.*[,/]CN=\([^,/]*\).*/\1/p' | head -n1 | tr -d '[:space:]')"
  # иногда subject = CN=... без запятой впереди
  if [[ -z "$cn" ]]; then
    cn="$(openssl x509 -in "$crt" -noout -subject 2>/dev/null \
      | sed -n 's/.*CN\s*=\s*\([^,/]*\).*/\1/p' | head -n1 | tr -d '[:space:]')"
  fi
  if [[ -n "$cn" ]]; then
    echo "$cn"
    return
  fi
  hostf="$(hostname -f 2>/dev/null || true)"
  if [[ -n "$hostf" && "$hostf" != "localhost" && "$hostf" != *"(none)"* ]]; then
    echo "$hostf"
    return
  fi
  hostn="$(hostname 2>/dev/null || true)"
  [[ -n "$hostn" ]] || die "Не удалось определить имя узла"
  echo "$hostn"
}

REPO_FQDN="${REPO_FQDN:-$(detect_fqdn "$SSL_CRT")}"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$HOST_IP" ]] || HOST_IP="$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"

log "Параметры"
echo "  SSL_CRT   = $SSL_CRT"
echo "  SSL_KEY   = $SSL_KEY"
echo "  REPO_FQDN = $REPO_FQDN   (из сертификата/системы)"
echo "  HOST_IP   = ${HOST_IP:-не определён}"
echo "  REPO_NET  = $REPO_NET"
echo "  STORAGE   = $STORAGE_ROOT"
echo "  NEWEST    = $NEWEST  SKIP_SYNC=$SKIP_SYNC"
echo

# --- проверка пары crt/key (берём первый сертификат из PEM) ---
log "Проверка сертификата и ключа"
TMP_LEAF="$(mktemp)"
awk 'BEGIN{p=0} /BEGIN CERTIFICATE/{p++; if(p>1) exit} {print}' "$SSL_CRT" >"$TMP_LEAF"
mod_crt="$(openssl x509 -noout -modulus -in "$TMP_LEAF" | openssl md5)"
mod_key="$(openssl rsa  -noout -modulus -in "$SSL_KEY" 2>/dev/null | openssl md5 || true)"
[[ -n "$mod_key" && "$mod_crt" == "$mod_key" ]] || {
  rm -f "$TMP_LEAF"
  die "uibrep.crt и uibrep.key не образуют пару (или ключ не PEM RSA)"
}
openssl x509 -in "$TMP_LEAF" -noout -subject -issuer -dates
openssl x509 -in "$TMP_LEAF" -noout -ext subjectAltName 2>/dev/null || true
rm -f "$TMP_LEAF"

# --- пакеты ---
log "Установка пакетов"
dnf install -y httpd mod_ssl createrepo_c dnf-utils policycoreutils-python-utils openssl

# --- каталоги ---
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/var/local-repo-archive}"
log "Каталоги зеркала на ${STORAGE_ROOT}, архив на ${ARCHIVE_ROOT}"
mkdir -p "$DESTDIR" "$INTERNAL/rpms" "$LOG_DIR" /var/www/html \
  "${STORAGE_ROOT}/ca" /etc/pki/tls/certs /etc/pki/tls/private \
  "${ARCHIVE_ROOT}/redos8" "${ARCHIVE_ROOT}/reports"

if [[ -e "$WEB_REPOS" && ! -L "$WEB_REPOS" ]]; then
  die "${WEB_REPOS} уже существует и это не symlink. Перенесите: mv ${WEB_REPOS} ${WEB_REPOS}.bak"
fi
ln -sfn "$STORAGE_ROOT" "$WEB_REPOS"

semanage fcontext -a -t httpd_sys_content_t "${STORAGE_ROOT}(/.*)?" 2>/dev/null \
  || semanage fcontext -m -t httpd_sys_content_t "${STORAGE_ROOT}(/.*)?" 2>/dev/null \
  || true
semanage fcontext -a -t httpd_sys_content_t "${ARCHIVE_ROOT}(/.*)?" 2>/dev/null \
  || semanage fcontext -m -t httpd_sys_content_t "${ARCHIVE_ROOT}(/.*)?" 2>/dev/null \
  || true
restorecon -Rv "$STORAGE_ROOT" "$ARCHIVE_ROOT" >/dev/null || true
chown -R root:apache "$STORAGE_ROOT" "$ARCHIVE_ROOT"
chmod -R 755 "$STORAGE_ROOT" "$ARCHIVE_ROOT"

# --- hosts ---
if [[ -n "${HOST_IP:-}" ]]; then
  if grep -qE "[[:space:]]${REPO_FQDN}([[:space:]]|\$)" /etc/hosts; then
    sed -i -E "s|^[0-9.]+[[:space:]]+${REPO_FQDN}([[:space:]].*)?$|${HOST_IP} ${REPO_FQDN}|" /etc/hosts
  else
    echo "${HOST_IP} ${REPO_FQDN}" >> /etc/hosts
  fi
  log "/etc/hosts → ${HOST_IP} ${REPO_FQDN}"
fi

# hostname системы (не ломаем, если уже задан)
if [[ "$(hostname -f 2>/dev/null || true)" != "$REPO_FQDN" ]]; then
  hostnamectl set-hostname "$REPO_FQDN" 2>/dev/null || true
fi

# --- сертификаты ---
log "Установка uibrep.crt / uibrep.key"
# лист + возможная цепочка из того же PEM
CERT_COUNT="$(grep -c 'BEGIN CERTIFICATE' "$SSL_CRT" || true)"
if [[ "${CERT_COUNT:-0}" -gt 1 ]]; then
  awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n==1{print}' "$SSL_CRT" >"$DEST_CRT"
  awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n>=2{print}' "$SSL_CRT" >"$DEST_CHAIN"
  HAVE_CHAIN=1
  log "В uibrep.crt несколько сертификатов: лист + цепочка (${CERT_COUNT})"
else
  install -m 644 "$SSL_CRT" "$DEST_CRT"
  HAVE_CHAIN=0
  # если рядом лежит CA — подхватим
  for cand in \
    /home/svcsecadm/uibrep-ca.crt \
    /home/svcsecadm/ca.crt \
    /home/svcsecadm/rootCA.crt \
    /home/svcsecadm/ca-root.crt
  do
    if [[ -f "$cand" ]]; then
      install -m 644 "$cand" "$DEST_CHAIN"
      HAVE_CHAIN=1
      log "Цепочка/CA из $cand"
      break
    fi
  done
fi
install -m 600 "$SSL_KEY" "$DEST_KEY"
chown root:root "$DEST_KEY"

# копия CA/цепочки для клиентов
if [[ "$HAVE_CHAIN" == "1" && -s "$DEST_CHAIN" ]]; then
  install -m 644 "$DEST_CHAIN" "${STORAGE_ROOT}/ca/uibrep-ca-chain.crt"
  install -m 644 "$DEST_CHAIN" "${STORAGE_ROOT}/ca/uibrep-ca.crt"
  install -m 644 "$DEST_CHAIN" /etc/pki/ca-trust/source/anchors/uibrep-ca.crt
  update-ca-trust
  update-ca-trust extract
  log "CA/цепочка для клиентов: ${STORAGE_ROOT}/ca/uibrep-ca.crt"
else
  log "Внимание: отдельный CA не найден — положите корневой УЦ в /home/svcsecadm/uibrep-ca.crt"
  echo "         Без этого клиенты не пройдут проверку HTTPS (sslverify=1)."
fi

# --- httpd SSL vhost ---
log "Настройка httpd (HTTPS, ServerName=${REPO_FQDN})"
systemctl enable --now httpd

# ServerName в главном конфиге
if [[ -f /etc/httpd/conf/httpd.conf ]]; then
  if grep -qE '^\s*ServerName\s+' /etc/httpd/conf/httpd.conf; then
    sed -i -E "s|^\s*ServerName\s+.*|ServerName ${REPO_FQDN}|" /etc/httpd/conf/httpd.conf
  elif grep -qE '^#\s*ServerName\s+' /etc/httpd/conf/httpd.conf; then
    sed -i -E "s|^#\s*ServerName\s+.*|ServerName ${REPO_FQDN}|" /etc/httpd/conf/httpd.conf
  else
    echo "ServerName ${REPO_FQDN}" >> /etc/httpd/conf/httpd.conf
  fi
fi

CHAIN_DIRECTIVE="# SSLCertificateChainFile ${DEST_CHAIN}"
if [[ "$HAVE_CHAIN" == "1" && -s "$DEST_CHAIN" ]]; then
  CHAIN_DIRECTIVE="SSLCertificateChainFile ${DEST_CHAIN}"
fi

cat > /etc/httpd/conf.d/ssl-repo.conf << EOF
# Сгенерировано deploy-uibrep-mirror.sh — не править вручную без нужды
# Listen 443 задаёт mod_ssl (ssl.conf)

<VirtualHost _default_:443>
    ServerName ${REPO_FQDN}
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile ${DEST_CRT}
    SSLCertificateKeyFile ${DEST_KEY}
    ${CHAIN_DIRECTIVE}

    ErrorLog logs/ssl-repo-error_log
    CustomLog logs/ssl-repo-access_log combined

    <Directory "/var/www/html">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    <Directory "/var/www/html/repos">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require ip ${REPO_NET}
    </Directory>

    <Directory "${STORAGE_ROOT}">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require ip ${REPO_NET}
    </Directory>

    # Архив старых RPM (раздел /var)
    Alias /archive ${ARCHIVE_ROOT}
    <Directory "${ARCHIVE_ROOT}">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require ip ${REPO_NET}
    </Directory>
</VirtualHost>
EOF

# Отключить конфликтующий default SSL vhost из ssl.conf (оставляем Listen и модули)
if [[ -f /etc/httpd/conf.d/ssl.conf ]]; then
  if ! grep -q 'UIBREP_SSL_VHOST_DISABLED' /etc/httpd/conf.d/ssl.conf; then
    cp -a /etc/httpd/conf.d/ssl.conf "/etc/httpd/conf.d/ssl.conf.bak.$(date +%Y%m%d%H%M%S)"
    # комментируем блок VirtualHost _default_:443
    awk '
      BEGIN {skip=0}
      /<VirtualHost[^\n]*_default_:443>/ {skip=1; print "# UIBREP_SSL_VHOST_DISABLED"; print "# "$0; next}
      skip && /<\/VirtualHost>/ {print "# "$0; skip=0; next}
      skip {print "# "$0; next}
      {print}
    ' /etc/httpd/conf.d/ssl.conf > /etc/httpd/conf.d/ssl.conf.tmp
    mv /etc/httpd/conf.d/ssl.conf.tmp /etc/httpd/conf.d/ssl.conf
  fi
fi

apachectl configtest
systemctl restart httpd

# --- firewalld ---
log "firewalld: https для ${REPO_NET}"
systemctl enable --now firewalld
firewall-cmd --permanent --remove-service=http 2>/dev/null || true
firewall-cmd --permanent --remove-service=https 2>/dev/null || true
firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"${REPO_NET}\" service name=\"https\" accept"
firewall-cmd --reload

# --- source .repo для reposync (все ветки РЕД ОС 8) ---
log "Source-репозитории для reposync (base/updates/extras/3rdparty/debuginfo/kernel-*)"
write_src_repo() {
  local id="$1" name="$2" path="$3"
  cat > "/etc/yum.repos.d/${id}.repo" << EOF
[${id}]
name=${name}
baseurl=https://repo1.red-soft.ru/redos/8.0/\$basearch/${path},https://mirror.yandex.ru/redos/8.0/\$basearch/${path},http://repo.red-soft.ru/redos/8.0/\$basearch/${path}
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT
enabled=0
EOF
}
write_src_repo redos8_base_src           "RedOS 8 - Base (Mirror source)"           os
write_src_repo redos8_updates_src        "RedOS 8 - Updates (Mirror source)"        updates
write_src_repo redos8_extras_src         "RedOS 8 - Extras (Mirror source)"         extras
write_src_repo redos8_3rdparty_src       "RedOS 8 - 3rdparty (Mirror source)"       3rdparty
write_src_repo redos8_debuginfo_src      "RedOS 8 - Debuginfo (Mirror source)"      debuginfo
write_src_repo redos8_kernel_rt_src      "RedOS 8 - kernel-rt (Mirror source)"      kernel-rt
write_src_repo redos8_kernel_testing_src "RedOS 8 - kernel-testing (Mirror source)" kernel-testing

# список для sync/cron (можно сузить через REPOIDS=...)
REPOIDS_DEFAULT="redos8_base_src redos8_updates_src redos8_extras_src redos8_3rdparty_src redos8_debuginfo_src redos8_kernel_rt_src redos8_kernel_testing_src"
REPOIDS="${REPOIDS:-$REPOIDS_DEFAULT}"

# --- sync-скрипт (с архивацией на /var) + cron ---
log "Установка sync-скрипта (ARCHIVE=1 → /var/local-repo-archive) и cron"
SYNC_SRC="${SCRIPT_DIR}/sync-redos8-repos.sh"
[[ -f "$SYNC_SRC" ]] || die "Нет $SYNC_SRC — скопируйте весь каталог docs/scripts/local-repo/"
install -m 750 "$SYNC_SRC" /usr/local/sbin/sync-redos8-repos.sh
if [[ -f "${SCRIPT_DIR}/repo-archive-tool.sh" ]]; then
  install -m 755 "${SCRIPT_DIR}/repo-archive-tool.sh" /usr/local/sbin/repo-archive-tool.sh
fi
if [[ -f "${SCRIPT_DIR}/clean-local-repo.sh" ]]; then
  install -m 750 "${SCRIPT_DIR}/clean-local-repo.sh" /usr/local/sbin/clean-local-repo.sh
fi
if [[ -f "${SCRIPT_DIR}/wipe-local-repo.sh" ]]; then
  install -m 750 "${SCRIPT_DIR}/wipe-local-repo.sh" /usr/local/sbin/wipe-local-repo.sh
fi

# nightly sync: newest + archive old RPMs to /var (все ветки)
cat > /etc/cron.d/redos8-local-repo << EOF
30 2 * * * root ARCHIVE=1 NEWEST=1 REPOIDS="${REPOIDS}" /usr/local/sbin/sync-redos8-repos.sh
EOF
chmod 644 /etc/cron.d/redos8-local-repo

# --- клиентский helper на зеркале ---
cat > /usr/local/sbin/configure-repo-client.sh << EOF
#!/bin/bash
# Настройка клиента РЕД ОС 8 на зеркало https://${REPO_FQDN}/
# Скопируйте на клиент вместе с CA:
#   scp root@ЗЕРКАЛО:/opt/repos/ca/uibrep-ca.crt /tmp/
#   scp root@ЗЕРКАЛО:/usr/local/sbin/configure-repo-client.sh /tmp/
#   REPO_IP=${HOST_IP:-IP_ЗЕРКАЛА} CA_FILE=/tmp/uibrep-ca.crt bash /tmp/configure-repo-client.sh
set -euo pipefail
REPO_HOST="${REPO_FQDN}"
REPO_IP="\${REPO_IP:-${HOST_IP:-}}"
CA_FILE="\${CA_FILE:-}"
[[ "\$(id -u)" -eq 0 ]] || { echo "нужен root"; exit 1; }

if [[ -n "\$REPO_IP" ]]; then
  if grep -qE "[[:space:]]\${REPO_HOST}([[:space:]]|\$)" /etc/hosts; then
    sed -i -E "s|^[0-9.]+[[:space:]]+\${REPO_HOST}([[:space:]].*)?\$|\${REPO_IP} \${REPO_HOST}|" /etc/hosts
  else
    echo "\${REPO_IP} \${REPO_HOST}" >> /etc/hosts
  fi
  echo "hosts: \${REPO_IP} \${REPO_HOST}"
fi

# CA: явный путь, либо типичные места после scp
if [[ -z "\$CA_FILE" ]]; then
  for cand in /tmp/uibrep-ca.crt /tmp/uibrep-ca-chain.crt \\
              /opt/repos/ca/uibrep-ca.crt /opt/repos/ca/uibrep-ca-chain.crt; do
    [[ -f "\$cand" ]] && CA_FILE="\$cand" && break
  done
fi
if [[ -n "\$CA_FILE" && -f "\$CA_FILE" ]]; then
  install -m 644 "\$CA_FILE" /etc/pki/ca-trust/source/anchors/uibrep-ca.crt
  update-ca-trust
  update-ca-trust extract
  echo "CA установлен: \$CA_FILE"
else
  echo "ПРЕДУПРЕЖДЕНИЕ: CA не найден. Положите файл в /tmp/uibrep-ca.crt или задайте CA_FILE=..." >&2
  echo "Без CA dnf makecache по HTTPS может упасть на проверке сертификата." >&2
fi

for f in /etc/yum.repos.d/RedOS-Base.repo /etc/yum.repos.d/RedOS-Updates.repo \
         /etc/yum.repos.d/RedOS-Extras.repo /etc/yum.repos.d/RedOS-3rdparty.repo; do
  [[ -f "\$f" ]] && sed -i 's/^enabled=1/enabled=0/' "\$f"
done

write_local_repo() {
  local file="\$1" id="\$2" name="\$3" path="\$4" enabled="\$5"
  cat > "/etc/yum.repos.d/\${file}" << REPO
[\${id}]
name=\${name}
baseurl=https://${REPO_FQDN}\${path}
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT
sslverify=1
enabled=\${enabled}
REPO
}

# Актуальные (для установки доп. ПО — extras и 3rdparty включены)
write_local_repo RedOS8-Base-local.repo           RedOS8-Base-local           "Local RED OS 8 Base"           "/repos/redos8/redos8_base_src/"           1
write_local_repo RedOS8-Updates-local.repo        RedOS8-Updates-local        "Local RED OS 8 Updates"        "/repos/redos8/redos8_updates_src/"        1
write_local_repo RedOS8-Extras-local.repo         RedOS8-Extras-local         "Local RED OS 8 Extras"         "/repos/redos8/redos8_extras_src/"         1
write_local_repo RedOS8-3rdparty-local.repo       RedOS8-3rdparty-local       "Local RED OS 8 3rdparty"       "/repos/redos8/redos8_3rdparty_src/"       1
# Спец. ветки — по умолчанию выключены, включайте при необходимости
write_local_repo RedOS8-Debuginfo-local.repo      RedOS8-Debuginfo-local      "Local RED OS 8 Debuginfo"      "/repos/redos8/redos8_debuginfo_src/"      0
write_local_repo RedOS8-KernelRT-local.repo       RedOS8-KernelRT-local       "Local RED OS 8 kernel-rt"      "/repos/redos8/redos8_kernel_rt_src/"      0
write_local_repo RedOS8-KernelTesting-local.repo  RedOS8-KernelTesting-local  "Local RED OS 8 kernel-testing" "/repos/redos8/redos8_kernel_testing_src/" 0
# Архив старых версий
write_local_repo RedOS8-Archive-Base-local.repo     RedOS8-Archive-Base-local     "Local RED OS 8 Base ARCHIVE"     "/archive/redos8/redos8_base_src/"     0
write_local_repo RedOS8-Archive-Updates-local.repo  RedOS8-Archive-Updates-local  "Local RED OS 8 Updates ARCHIVE"  "/archive/redos8/redos8_updates_src/"  0
write_local_repo RedOS8-Archive-Extras-local.repo   RedOS8-Archive-Extras-local   "Local RED OS 8 Extras ARCHIVE"   "/archive/redos8/redos8_extras_src/"   0
write_local_repo RedOS8-Archive-3rdparty-local.repo RedOS8-Archive-3rdparty-local "Local RED OS 8 3rdparty ARCHIVE" "/archive/redos8/redos8_3rdparty_src/" 0

curl -fsSI "https://\${REPO_HOST}/repos/redos8/redos8_base_src/repodata/repomd.xml" | head -n1 \\
  || echo "Предупреждение: repomd.xml пока недоступен (зеркало ещё качается?)" >&2

dnf clean all
dnf makecache
dnf repolist
echo "OK → https://${REPO_FQDN}/"
echo "Включены: Base, Updates, Extras, 3rdparty"
echo "Старые пакеты: dnf install PKG --enablerepo=RedOS8-Archive-*-local"
EOF
chmod 755 /usr/local/sbin/configure-repo-client.sh

# сохранить факты деплоя
cat > /opt/repos/DEPLOY.txt << EOF
REPO_FQDN=${REPO_FQDN}
HOST_IP=${HOST_IP:-}
REPO_NET=${REPO_NET}
SSL_CRT_SRC=${SSL_CRT}
URL=https://${REPO_FQDN}/repos/redos8/
ARCHIVE_URL=https://${REPO_FQDN}/archive/redos8/
ARCHIVE_ROOT=${ARCHIVE_ROOT}
REPOIDS=${REPOIDS}
CA_FOR_CLIENTS=${STORAGE_ROOT}/ca/
SYNC=/usr/local/sbin/sync-redos8-repos.sh
ARCHIVE_TOOL=/usr/local/sbin/repo-archive-tool.sh
CLIENT_HELPER=/usr/local/sbin/configure-repo-client.sh
EOF

# --- первичная синхронизация ---
# Первый прогон: полное зеркало (NEWEST=0) без архивации superseded.
# Дальше cron: NEWEST=1 ARCHIVE=1 — старые RPM уходят на /var.
# Внимание: все ветки занимают много места (часто 300–400+ ГБ).
if [[ "$SKIP_SYNC" != "1" ]]; then
  log "Первичное зеркалирование всех веток (NEWEST=${NEWEST}, REPOIDS=${REPOIDS})"
  echo "Это ДОЛГО и требует много места на /opt. Лог: ${LOG_DIR}/sync-$(date +%F).log"
  if [[ "$NEWEST" == "1" ]]; then
    ARCHIVE=1 NEWEST=1 DESTDIR="$DESTDIR" ARCHIVE_ROOT="$ARCHIVE_ROOT" REPOIDS="$REPOIDS" \
      /usr/local/sbin/sync-redos8-repos.sh
  else
    ARCHIVE=0 NEWEST=0 DESTDIR="$DESTDIR" REPOIDS="$REPOIDS" \
      /usr/local/sbin/sync-redos8-repos.sh
  fi
else
  log "SKIP_SYNC=1 — зеркалирование пропущено"
  echo "Запустите позже: NEWEST=0 ARCHIVE=0 REPOIDS='${REPOIDS}' /usr/local/sbin/sync-redos8-repos.sh"
fi

# --- проверка ---
log "Проверка HTTPS"
set +e
curl -Ik "https://${REPO_FQDN}/" 2>&1 | head -n 5
curl -Ik "https://${REPO_FQDN}/repos/redos8/" 2>&1 | head -n 5
curl -Ik "https://${REPO_FQDN}/archive/" 2>&1 | head -n 5
set -e

echo
echo "================================================================"
echo " ГОТОВО"
echo "================================================================"
echo " Имя узла (из серта/системы): ${REPO_FQDN}"
echo " IP:                          ${HOST_IP:-?}"
echo " Актуальные пакеты:           https://${REPO_FQDN}/repos/redos8/"
echo " Архив старых (на /var):      https://${REPO_FQDN}/archive/redos8/"
echo " Каталог архива:              ${ARCHIVE_ROOT}"
echo " Отчёты sync:                 ${ARCHIVE_ROOT}/reports/latest.txt"
echo " Утилита архива:              /usr/local/sbin/repo-archive-tool.sh"
echo " CA для клиентов:             ${STORAGE_ROOT}/ca/"
echo " Клиентский скрипт:           /usr/local/sbin/configure-repo-client.sh"
echo
echo " На КЛИЕНТЕ:"
echo "   scp root@${HOST_IP:-ЗЕРКАЛО}:/opt/repos/ca/uibrep-ca.crt /tmp/"
echo "   scp root@${HOST_IP:-ЗЕРКАЛО}:/usr/local/sbin/configure-repo-client.sh /tmp/"
echo "   REPO_IP=${HOST_IP:-IP_ЗЕРКАЛА} CA_FILE=/tmp/uibrep-ca.crt bash /tmp/configure-repo-client.sh"
echo
echo " Старый пакет на клиенте:"
echo "   dnf install PKG --enablerepo=RedOS8-Archive-Base-local,RedOS8-Archive-Updates-local"
echo " Или скачать: https://${REPO_FQDN}/archive/redos8/<repoid>/<file.rpm>"
echo "================================================================"
