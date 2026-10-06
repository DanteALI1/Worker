#!/bin/bash
# Полное удаление данных локального зеркала перед повторным деплоем.
# Сертификаты /home/svcsecadm/uibrep.* НЕ трогает.
#
#   bash wipe-local-repo.sh           # спросит YES
#   FORCE=1 bash wipe-local-repo.sh   # без вопроса
#
# Удаляет:
#   /opt/repos  (пакеты, ca, DEPLOY.txt, incoming)
#   /var/local-repo-ar*  (архив и отчёты)
#   /var/log/local-repo
#
# После этого:
#   bash deploy-uibrep-mirror.sh

set -euo pipefail

STORAGE_ROOT="${STORAGE_ROOT:-/opt/repos}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/var/local-repo-archive}"
ARCHIVE_GLOB="${ARCHIVE_GLOB:-/var/local-repo-ar*}"
LOG_DIR="${LOG_DIR:-/var/log/local-repo}"
FORCE="${FORCE:-0}"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 && "${ALLOW_NONROOT:-0}" != "1" ]]; then
  die "запустите от root"
fi

echo "================================================================"
echo " ПОЛНОЕ УДАЛЕНИЕ локального репозитория"
echo "================================================================"
echo " Будет удалено:"
echo "   ${STORAGE_ROOT}"
echo "   ${ARCHIVE_GLOB}"
echo "   ${LOG_DIR}"
echo " Не трогает: /home/svcsecadm/uibrep.crt uibrep.key, httpd, cron"
echo
df -h /opt /var 2>/dev/null || true
echo
du -sh "$STORAGE_ROOT" $ARCHIVE_GLOB "$LOG_DIR" 2>/dev/null || true
echo

if [[ "$FORCE" != "1" ]]; then
  read -r -p "Введите YES для удаления: " ans
  [[ "$ans" == "YES" ]] || die "отменено (нужно ровно YES или FORCE=1)"
fi

# пакеты и meta на /opt
if [[ -e "$STORAGE_ROOT" ]]; then
  echo "rm -rf ${STORAGE_ROOT}/*  ${STORAGE_ROOT}/.??*"
  # не удаляем сам каталог: на нём может висеть symlink /var/www/html/repos
  find "$STORAGE_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
rm -rf "${STORAGE_ROOT}.incoming" /opt/repos/redos8.incoming 2>/dev/null || true

# архив по маске
shopt -s nullglob
for p in $ARCHIVE_GLOB; do
  echo "rm -rf $p"
  rm -rf "$p"
done
shopt -u nullglob

# логи sync
rm -rf "$LOG_DIR"

# пустые каталоги для следующего deploy
mkdir -p "${STORAGE_ROOT}/redos8" "${STORAGE_ROOT}/ca" \
  "${ARCHIVE_ROOT}/redos8" "${ARCHIVE_ROOT}/reports"
chmod -R a+rX "$STORAGE_ROOT" "$ARCHIVE_ROOT" || true
if id apache &>/dev/null; then
  chown -R root:apache "$STORAGE_ROOT" "$ARCHIVE_ROOT" || true
fi
restorecon -Rv "$STORAGE_ROOT" "$ARCHIVE_ROOT" >/dev/null 2>&1 || true

echo
echo "================================================================"
echo " Удалено. Место:"
df -h /opt /var 2>/dev/null || true
du -sh "$STORAGE_ROOT" "$ARCHIVE_ROOT" 2>/dev/null || true
echo
echo " Дальше:"
echo "   cd каталог-с-скриптами"
echo "   bash deploy-uibrep-mirror.sh"
echo "================================================================"
