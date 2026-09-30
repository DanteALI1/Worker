#!/bin/bash
# Полная очистка локального зеркала /opt/repos и архива /var/local-repo-archive*.
#
#   bash clean-local-repo.sh              # спросит подтверждение YES
#   FORCE=1 bash clean-local-repo.sh      # без вопроса
#   TARGET=archive bash clean-local-repo.sh   # только /var/local-repo-ar*
#   TARGET=opt     bash clean-local-repo.sh   # только /opt/repos (пакеты)
#   TARGET=all     bash clean-local-repo.sh   # оба (по умолчанию)
#   KEEP_META=1    ...                    # не трогать /opt/repos/ca и DEPLOY.txt
#
# После очистки зеркало пустое — заново:
#   NEWEST=0 ARCHIVE=0 /usr/local/sbin/sync-redos8-repos.sh
#
# Переменные:
#   STORAGE_ROOT=/opt/repos
#   ARCHIVE_GLOB=/var/local-repo-ar*

set -euo pipefail

STORAGE_ROOT="${STORAGE_ROOT:-/opt/repos}"
DESTDIR="${DESTDIR:-${STORAGE_ROOT}/redos8}"
INCOMING="${INCOMING:-${DESTDIR}.incoming}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/var/local-repo-archive}"
ARCHIVE_GLOB="${ARCHIVE_GLOB:-/var/local-repo-ar*}"
TARGET="${TARGET:-all}"   # all | opt | archive
FORCE="${FORCE:-0}"
KEEP_META="${KEEP_META:-1}"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 && "${ALLOW_NONROOT:-0}" != "1" ]]; then
  die "запустите от root"
fi

case "$TARGET" in
  all|opt|archive) ;;
  *) die "TARGET=all|opt|archive (сейчас: $TARGET)" ;;
esac

echo "================================================================"
echo " Очистка локального репозитория РЕД ОС 8"
echo "================================================================"
echo " TARGET=$TARGET  KEEP_META=$KEEP_META"
df -h /opt /var 2>/dev/null || true
echo

show_du() {
  local p
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    du -sh "$p" 2>/dev/null || true
  done
}

echo "Будет удалено:"
if [[ "$TARGET" == "all" || "$TARGET" == "opt" ]]; then
  show_du "$DESTDIR" "$INCOMING"
  if [[ "$KEEP_META" != "1" ]]; then
    show_du "${STORAGE_ROOT}/ca" "${STORAGE_ROOT}/DEPLOY.txt"
    echo "  (полное: всё содержимое ${STORAGE_ROOT}, кроме самой директории)"
  else
    echo "  пакеты: ${DESTDIR}/  и  ${INCOMING}/"
    echo "  сохранить: ${STORAGE_ROOT}/ca  ${STORAGE_ROOT}/DEPLOY.txt"
  fi
fi
if [[ "$TARGET" == "all" || "$TARGET" == "archive" ]]; then
  # shellcheck disable=SC2086
  for p in $ARCHIVE_GLOB; do
    [[ -e "$p" ]] || continue
    show_du "$p"
  done
  # если glob ничего не нашёл — покажем канонический путь
  # shellcheck disable=SC2086
  if ! compgen -G "$ARCHIVE_GLOB" >/dev/null 2>&1; then
    echo "  (нет совпадений: $ARCHIVE_GLOB)"
  fi
fi
echo

if [[ "$FORCE" != "1" ]]; then
  read -r -p "Введите YES для полной очистки: " ans
  [[ "$ans" == "YES" ]] || die "отменено (нужно ровно YES, или FORCE=1)"
fi

clean_opt() {
  echo "--- очистка ${STORAGE_ROOT} ---"
  mkdir -p "$STORAGE_ROOT"

  if [[ "$KEEP_META" == "1" ]]; then
    rm -rf "$DESTDIR" "$INCOMING"
    # на всякий случай другие *.incoming рядом
    shopt -s nullglob
    local extras=( "${STORAGE_ROOT}/"*.incoming )
    shopt -u nullglob
    ((${#extras[@]})) && rm -rf "${extras[@]}"
    mkdir -p "$DESTDIR"
  else
    # полная зачистка содержимого /opt/repos (symlink /var/www/html/repos сохраняем)
    find "$STORAGE_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    mkdir -p "$DESTDIR" "${STORAGE_ROOT}/ca"
  fi

  if id apache &>/dev/null; then
    chown -R root:apache "$STORAGE_ROOT" || true
  fi
  chmod -R a+rX "$STORAGE_ROOT" || true
  restorecon -Rv "$STORAGE_ROOT" >/dev/null 2>&1 || true
  echo "OK: ${STORAGE_ROOT} (пакеты удалены, каталог ${DESTDIR} пустой)"
}

clean_archive() {
  echo "--- очистка архива (${ARCHIVE_GLOB}) ---"
  local p found=0
  # shellcheck disable=SC2086
  for p in $ARCHIVE_GLOB; do
    [[ -e "$p" ]] || continue
    found=1
    echo "rm -rf $p"
    rm -rf "$p"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "(нечего удалять по маске $ARCHIVE_GLOB)"
  fi
  # канонические пути заново — sync/httpd ожидают их
  mkdir -p "${ARCHIVE_ROOT}/redos8" "${ARCHIVE_ROOT}/reports"
  if id apache &>/dev/null; then
    chown -R root:apache "$ARCHIVE_ROOT" || true
  fi
  chmod -R a+rX "$ARCHIVE_ROOT" || true
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t httpd_sys_content_t "${ARCHIVE_ROOT}(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t httpd_sys_content_t "${ARCHIVE_ROOT}(/.*)?" 2>/dev/null \
      || true
  fi
  restorecon -Rv "$ARCHIVE_ROOT" >/dev/null 2>&1 || true
  echo "OK: архив очищен, создан пустой ${ARCHIVE_ROOT}/"
}

case "$TARGET" in
  all)
    clean_opt
    clean_archive
    ;;
  opt) clean_opt ;;
  archive) clean_archive ;;
esac

echo
echo "================================================================"
echo " Готово. Место после очистки:"
df -h /opt /var 2>/dev/null || true
[[ "$TARGET" == "all" || "$TARGET" == "opt" ]] && du -sh "$STORAGE_ROOT" 2>/dev/null || true
[[ "$TARGET" == "all" || "$TARGET" == "archive" ]] && du -sh "$ARCHIVE_ROOT" 2>/dev/null || true
echo
echo " Заполнить зеркало заново:"
echo "   NEWEST=0 ARCHIVE=0 /usr/local/sbin/sync-redos8-repos.sh"
echo " Дальше cron снова будет архивировать superseded (ARCHIVE=1 NEWEST=1)."
if [[ "$KEEP_META" != "1" && ( "$TARGET" == "all" || "$TARGET" == "opt" ) ]]; then
  echo " CA/DEPLOY удалены — при необходимости: SKIP_SYNC=1 bash deploy-uibrep-mirror.sh"
fi
echo "================================================================"
