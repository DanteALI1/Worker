#!/bin/bash
# Синхронизация локального зеркала РЕД ОС 8 с архивацией старых пакетов на /var.
#
# Схема:
#   /opt/repos/redos8/                 — актуальные пакеты
#   /var/local-repo-archive/redos8/    — архив старых версий → HTTPS /archive/redos8/
#   /var/local-repo-archive/reports/   — отчёты «что ушло в архив»
#
# Алгоритм (ARCHIVE=1, NEWEST=1):
#   1) Скачать свежий снимок в DESTDIR.incoming/ (текущее /opt не трогаем)
#   2) Сравнить списки RPM (только имена файлов):
#        — нет отличий → /opt остаётся как есть, архив не трогаем
#        — есть обновления/новые → старые RPM (есть в /opt, нет в incoming)
#          переносятся в /var/.../archive; новые копируются в /opt;
#          неизменённые RPM в /opt не перезаписываются
#   3) createrepo только если были изменения
#   4) Retention по ARCHIVE_KEEP_DAYS
#
#   install -m 750 sync-redos8-repos.sh /usr/local/sbin/sync-redos8-repos.sh
#
# Переменные:
#   DESTDIR=/opt/repos/redos8
#   ARCHIVE_ROOT=/var/local-repo-archive
#   ARCHIVE=1|0
#   ARCHIVE_KEEP_DAYS=180   (0 = не чистить)
#   REPOIDS="redos8_base_src redos8_updates_src redos8_extras_src ..."
#   NEWEST=1|0
#   LOG_DIR=/var/log/local-repo

set -euo pipefail

DESTDIR="${DESTDIR:-/opt/repos/redos8}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-/var/local-repo-archive}"
ARCHIVE_REPO="${ARCHIVE_REPO:-${ARCHIVE_ROOT}/redos8}"
ARCHIVE="${ARCHIVE:-1}"
ARCHIVE_KEEP_DAYS="${ARCHIVE_KEEP_DAYS:-180}"
# Все основные ветки РЕД ОС 8 (для установки доп. ПО нужны extras и 3rdparty)
REPOIDS="${REPOIDS:-redos8_base_src redos8_updates_src redos8_extras_src redos8_3rdparty_src redos8_debuginfo_src redos8_kernel_rt_src redos8_kernel_testing_src}"
NEWEST="${NEWEST:-1}"
LOG_DIR="${LOG_DIR:-/var/log/local-repo}"
INCOMING="${INCOMING:-${DESTDIR}.incoming}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG_DIR}/sync-$(date +%F).log"
REPORT_DIR="${ARCHIVE_ROOT}/reports"
REPORT="${REPORT_DIR}/sync-${STAMP}.txt"

mkdir -p "$LOG_DIR" "$DESTDIR" "$ARCHIVE_REPO" "$REPORT_DIR"
exec >>"$LOG" 2>&1

echo "=== $(date -Is) sync start ==="
echo "DESTDIR=$DESTDIR ARCHIVE=$ARCHIVE ARCHIVE_ROOT=$ARCHIVE_ROOT"
echo "REPOIDS=$REPOIDS NEWEST=$NEWEST ARCHIVE_KEEP_DAYS=$ARCHIVE_KEEP_DAYS"

dnf makecache || true

: >"$REPORT"
report() { echo "$*" | tee -a "$REPORT"; }

report "Отчёт синхронизации ${STAMP}"
report "Зеркало: $DESTDIR"
report "Архив:   $ARCHIVE_REPO"
report ""

rebuild_repo() {
  local path="$1"
  [[ -d "$path" ]] || mkdir -p "$path"
  if [[ -d "$path/.repodata" ]]; then
    rm -rf "$path/.repodata"
  fi
  # пустой каталог — всё равно создадим метаданные
  if [[ -f "$path/comps.xml" ]]; then
    createrepo -v --compress-type=zstd --general-compress-type=zstd \
      "$path" -g comps.xml >/dev/null
  else
    createrepo -v --compress-type=zstd --general-compress-type=zstd \
      "$path" >/dev/null
  fi
}

archive_rpm() {
  local src="$1" repoid="$2"
  local base dest
  base="$(basename "$src")"
  dest="${ARCHIVE_REPO}/${repoid}/${base}"
  mkdir -p "${ARCHIVE_REPO}/${repoid}"
  if [[ -f "$dest" ]]; then
    rm -f "$src"
    report "ARCHIVE_SKIP_EXISTS  ${repoid}/${base}"
    return 0
  fi
  mv -f "$src" "$dest"
  touch "$dest"
  report "ARCHIVE  ${repoid}/${base}"
}

sync_one_with_archive() {
  local repoid="$1"
  local old="${DESTDIR}/${repoid}"
  local new="${INCOMING}/${repoid}"
  local base archived=0 newpkgs=0 unchanged=0
  local old_list new_list only_new only_old

  echo "--- sync+archive $repoid ---"
  mkdir -p "$old"
  rm -rf "$new"

  old_list="$(mktemp)"
  new_list="$(mktemp)"
  only_new="$(mktemp)"
  only_old="$(mktemp)"
  find "$old" -maxdepth 1 -type f -name '*.rpm' -printf '%f\n' 2>/dev/null | sort >"$old_list"

  report "=== ${repoid} ==="
  report "Пакетов в /opt до sync: $(wc -l <"$old_list")"

  # снимок upstream → INCOMING (каталог /opt не меняем до сравнения)
  local sync_opts=(--downloadcomps --download-metadata -p "$INCOMING")
  if [[ "$NEWEST" == "1" ]]; then
    sync_opts+=(--newest-only --delete)
  fi
  reposync --repo "$repoid" "${sync_opts[@]}"

  [[ -d "$new" ]] || mkdir -p "$new"
  find "$new" -maxdepth 1 -type f -name '*.rpm' -printf '%f\n' 2>/dev/null | sort >"$new_list"
  report "Пакетов в upstream (incoming): $(wc -l <"$new_list")"

  comm -13 "$old_list" "$new_list" >"$only_new"
  comm -23 "$old_list" "$new_list" >"$only_old"
  newpkgs=$(wc -l <"$only_new")
  local to_archive
  to_archive=$(wc -l <"$only_old")
  unchanged=$(comm -12 "$old_list" "$new_list" | wc -l)
  # wc -l может дать ведущие пробелы
  newpkgs=$((10#${newpkgs// /}))
  to_archive=$((10#${to_archive// /}))
  unchanged=$((10#${unchanged// /}))

  # нет новых и нечего архивировать → /opt не трогаем
  if [[ "$newpkgs" -eq 0 && "$to_archive" -eq 0 ]]; then
    report "UNCHANGED  набор RPM совпадает с upstream — /opt/${repoid} не изменялся"
    report "Итого ${repoid}: актуальных=$(wc -l <"$old_list"), новых=0, в_архив=0, без_изменений=${unchanged}"
    rm -rf "$new"
    rm -f "$old_list" "$new_list" "$only_new" "$only_old"
    return 0
  fi

  report ""
  report "Новые / обновлённые файлы (появятся в /opt):"
  while read -r base; do
    [[ -n "$base" ]] || continue
    report "NEW      ${repoid}/${base}"
  done <"$only_new"

  report ""
  report "Уходят в /var (были в /opt, нет в upstream — superseded/удалены):"
  while read -r base; do
    [[ -n "$base" ]] || continue
    if [[ -f "${old}/${base}" ]]; then
      archive_rpm "${old}/${base}" "$repoid"
      archived=$((archived + 1))
    fi
  done <"$only_old"

  # только новые RPM → в /opt; совпадающие имена не перезаписываем
  while read -r base; do
    [[ -n "$base" ]] || continue
    if [[ -f "${new}/${base}" ]]; then
      mv -f "${new}/${base}" "${old}/${base}"
    fi
  done <"$only_new"

  # обновить вспомогательные файлы (comps и т.п.), не трогая rpm
  if [[ -f "${new}/comps.xml" ]]; then
    cp -f "${new}/comps.xml" "${old}/comps.xml"
  fi

  rm -rf "$new"
  rebuild_repo "$old"
  if [[ "$archived" -gt 0 ]]; then
    rebuild_repo "${ARCHIVE_REPO}/${repoid}"
  fi

  report ""
  report "Итого ${repoid}: актуальных=$(find "$old" -maxdepth 1 -type f -name '*.rpm' | wc -l), новых_файлов=${newpkgs}, в_архив=${archived}, без_изменений=${unchanged}"
  rm -f "$old_list" "$new_list" "$only_new" "$only_old"
}

sync_one_plain() {
  local repoid="$1"
  echo "--- sync (без архивации) $repoid ---"
  if [[ -d "$DESTDIR/$repoid/.repodata" ]]; then
    rm -rf "$DESTDIR/$repoid/.repodata"
  fi
  local opts=(--downloadcomps --download-metadata -p "$DESTDIR")
  if [[ "$NEWEST" == "1" ]]; then
    opts+=(--newest-only --delete)
  fi
  reposync --repo "$repoid" "${opts[@]}"
  rebuild_repo "$DESTDIR/$repoid"
}

rm -rf "$INCOMING"
mkdir -p "$INCOMING"

for REPOID in $REPOIDS; do
  if [[ "$ARCHIVE" == "1" && "$NEWEST" == "1" ]]; then
    sync_one_with_archive "$REPOID"
  else
    sync_one_plain "$REPOID"
    if [[ "$ARCHIVE" == "1" && "$NEWEST" != "1" ]]; then
      report "NEWEST=0: архивация superseded не используется (полная история в зеркале)."
    fi
  fi
done

rm -rf "$INCOMING"

if [[ "$ARCHIVE" == "1" && "${ARCHIVE_KEEP_DAYS}" =~ ^[0-9]+$ && "$ARCHIVE_KEEP_DAYS" -gt 0 ]]; then
  echo "--- retention ${ARCHIVE_KEEP_DAYS}d ---"
  report ""
  report "Retention: удаление из архива старше ${ARCHIVE_KEEP_DAYS} дн."
  while IFS= read -r -d '' f; do
    report "EXPIRE  ${f#${ARCHIVE_REPO}/}"
    rm -f "$f"
  done < <(find "$ARCHIVE_REPO" -type f -name '*.rpm' -mtime "+${ARCHIVE_KEEP_DAYS}" -print0 2>/dev/null)
  for REPOID in $REPOIDS; do
    [[ -d "${ARCHIVE_REPO}/${REPOID}" ]] && rebuild_repo "${ARCHIVE_REPO}/${REPOID}"
  done
fi

STORAGE_ROOT="$(dirname "$DESTDIR")"
if id apache &>/dev/null; then
  chown -R root:apache "$STORAGE_ROOT" "$ARCHIVE_ROOT" || true
fi
chmod -R a+rX "$STORAGE_ROOT" "$ARCHIVE_ROOT" || true
# SELinux на архиве
if command -v semanage >/dev/null 2>&1; then
  semanage fcontext -a -t httpd_sys_content_t "${ARCHIVE_ROOT}(/.*)?" 2>/dev/null \
    || semanage fcontext -m -t httpd_sys_content_t "${ARCHIVE_ROOT}(/.*)?" 2>/dev/null \
    || true
fi
restorecon -Rv "$STORAGE_ROOT" "$ARCHIVE_ROOT" >/dev/null 2>&1 || true

ln -sfn "$REPORT" "${REPORT_DIR}/latest.txt"
report ""
report "Готово: $(date -Is)"
report "Отчёт: $REPORT"
report "Скачать старый RPM: https://<FQDN>/archive/redos8/<repoid>/<file.rpm>"
report "dnf: --enablerepo=RedOS8-Archive-Base-local,RedOS8-Archive-Updates-local"
report "Утилита: repo-archive-tool.sh list|search|url|restore"

echo "=== $(date -Is) sync done === report=$REPORT ==="
