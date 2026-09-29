#!/bin/bash
# Синхронизация локального зеркала РЕД ОС 8.
# Основано на: https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-update-repo/
#
# Установка на сервере-зеркале:
#   install -m 750 sync-redos8-repos.sh /usr/local/sbin/sync-redos8-repos.sh
#   echo '30 2 * * * root /usr/local/sbin/sync-redos8-repos.sh' > /etc/cron.d/redos8-local-repo
#
# Переменные окружения (опционально):
#   DESTDIR   — каталог зеркала (по умолчанию /var/www/html/repos/redos8)
#   REPOIDS   — список repoid через пробел
#   NEWEST    — 1 (по умолчанию) = --newest-only --delete; 0 = полное зеркало

set -euo pipefail

DESTDIR="${DESTDIR:-/var/www/html/repos/redos8}"
REPOIDS="${REPOIDS:-redos8_base_src redos8_updates_src}"
NEWEST="${NEWEST:-1}"
LOG_DIR="${LOG_DIR:-/var/log/local-repo}"
LOG="${LOG_DIR}/sync-$(date +%F).log"

mkdir -p "$LOG_DIR" "$DESTDIR"
exec >>"$LOG" 2>&1

echo "=== $(date -Is) sync start ==="
echo "DESTDIR=$DESTDIR REPOIDS=$REPOIDS NEWEST=$NEWEST"

dnf makecache || true

SYNC_OPTS=(--downloadcomps --download-metadata -p "$DESTDIR")
if [[ "$NEWEST" == "1" ]]; then
  SYNC_OPTS+=(--newest-only --delete)
fi

for REPOID in $REPOIDS; do
  echo "--- sync $REPOID ---"
  if [[ -d "$DESTDIR/$REPOID/.repodata" ]]; then
    rm -rf "$DESTDIR/$REPOID/.repodata"
  fi

  reposync --repo "$REPOID" "${SYNC_OPTS[@]}"

  if [[ -f "$DESTDIR/$REPOID/comps.xml" ]]; then
    createrepo -v --compress-type=zstd --general-compress-type=zstd \
      "$DESTDIR/$REPOID" -g comps.xml
  else
    createrepo -v --compress-type=zstd --general-compress-type=zstd \
      "$DESTDIR/$REPOID"
  fi
done

if id apache &>/dev/null; then
  chown -R root:apache "$DESTDIR" || true
fi
chmod -R a+rX "$DESTDIR" || true
restorecon -Rv "$DESTDIR" >/dev/null 2>&1 || true

echo "=== $(date -Is) sync done ==="
