#!/bin/bash
# Поиск и выдача пакетов из архива /var/local-repo-archive.
#
# Примеры:
#   bash repo-archive-tool.sh list
#   bash repo-archive-tool.sh search bash
#   bash repo-archive-tool.sh show bash-5
#   bash repo-archive-tool.sh url bash-5.1.8-1.el8.x86_64.rpm
#   bash repo-archive-tool.sh restore-all
#       → вернуть в /opt все RPM из архива, которых там нет (после ложной архивации)
#   MOVE=1 bash repo-archive-tool.sh restore-all
#       → то же, но перенести (не копировать), чтобы не дублировать место
#
# Переменные:
#   ARCHIVE_REPO=/var/local-repo-archive/redos8
#   DESTDIR=/opt/repos/redos8
#   REPO_FQDN=...  (для печати URL; иначе из /opt/repos/DEPLOY.txt)

set -euo pipefail

ARCHIVE_REPO="${ARCHIVE_REPO:-/var/local-repo-archive/redos8}"
DESTDIR="${DESTDIR:-/opt/repos/redos8}"
REPORT_DIR="${REPORT_DIR:-/var/local-repo-archive/reports}"
CMD="${1:-list}"
shift || true

fqdn() {
  if [[ -n "${REPO_FQDN:-}" ]]; then
    echo "$REPO_FQDN"
    return
  fi
  if [[ -f /opt/repos/DEPLOY.txt ]]; then
    awk -F= '/^REPO_FQDN=/{print $2; exit}' /opt/repos/DEPLOY.txt
    return
  fi
  hostname -f 2>/dev/null || hostname
}

usage() {
  cat <<EOF
Использование: $0 <команда> [аргументы]

  list                          — список всех RPM в архиве
  search <подстрока>            — поиск по имени файла
  reports                       — список отчётов синхронизации
  latest                        — последний отчёт
  url <file.rpm>                — HTTPS URL для скачивания
  restore <repoid> <file.rpm>   — вернуть пакет в актуальное зеркало + createrepo
  restore-all                   — вернуть в /opt все RPM, которых там нет
                                MOVE=1 — перенести из архива (не копировать)
  du                            — занятое место архивом

Архив:   $ARCHIVE_REPO
Зеркало: $DESTDIR
EOF
}

case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  list)
    find "$ARCHIVE_REPO" -type f -name '*.rpm' -printf '%P\n' 2>/dev/null | sort
    ;;
  search)
    q="${1:-}"
    [[ -n "$q" ]] || { echo "укажите подстроку"; exit 1; }
    find "$ARCHIVE_REPO" -type f -name "*.rpm" -printf '%P\n' 2>/dev/null | grep -i -- "$q" || true
    ;;
  reports)
    ls -1t "${REPORT_DIR}"/sync-*.txt 2>/dev/null || echo "(нет отчётов)"
    ;;
  latest)
    if [[ -f "${REPORT_DIR}/latest.txt" ]]; then
      cat "${REPORT_DIR}/latest.txt"
    else
      echo "нет ${REPORT_DIR}/latest.txt"
      exit 1
    fi
    ;;
  url)
    f="${1:-}"
    [[ -n "$f" ]] || { echo "укажите file.rpm"; exit 1; }
    path="$(find "$ARCHIVE_REPO" -type f -name "$f" -printf '%P\n' 2>/dev/null | head -n1)"
    [[ -n "$path" ]] || { echo "не найден: $f"; exit 1; }
    echo "https://$(fqdn)/archive/redos8/${path}"
    ;;
  restore)
    repoid="${1:-}"
    f="${2:-}"
    [[ -n "$repoid" && -n "$f" ]] || { echo "restore <repoid> <file.rpm>"; exit 1; }
    src="${ARCHIVE_REPO}/${repoid}/${f}"
    [[ -f "$src" ]] || src="$(find "$ARCHIVE_REPO" -type f -name "$f" | head -n1)"
    [[ -f "$src" ]] || { echo "нет в архиве: $f"; exit 1; }
    mkdir -p "${DESTDIR}/${repoid}"
    cp -a "$src" "${DESTDIR}/${repoid}/"
    if [[ -f "${DESTDIR}/${repoid}/comps.xml" ]]; then
      createrepo -v --compress-type=zstd --general-compress-type=zstd \
        "${DESTDIR}/${repoid}" -g comps.xml
    else
      createrepo -v --compress-type=zstd --general-compress-type=zstd \
        "${DESTDIR}/${repoid}"
    fi
    echo "Восстановлен: ${DESTDIR}/${repoid}/$(basename "$src")"
    echo "На клиенте: dnf clean all && dnf install $(basename "$src" .rpm | sed 's/\.[^.]*$//')  # или точное имя"
    ;;
  restore-all)
    moved=0
    skipped=0
    shopt -s nullglob
    for src in "$ARCHIVE_REPO"/*/*.rpm; do
      [[ -f "$src" ]] || continue
      repoid="$(basename "$(dirname "$src")")"
      base="$(basename "$src")"
      dest="${DESTDIR}/${repoid}/${base}"
      mkdir -p "${DESTDIR}/${repoid}"
      if [[ -f "$dest" ]]; then
        skipped=$((skipped + 1))
        continue
      fi
      if [[ "${MOVE:-0}" == "1" ]]; then
        mv -f "$src" "$dest"
      else
        cp -a "$src" "$dest"
      fi
      moved=$((moved + 1))
      echo "RESTORE ${repoid}/${base}"
    done
    shopt -u nullglob
    for d in "$DESTDIR"/*; do
      [[ -d "$d" ]] || continue
      if command -v createrepo >/dev/null 2>&1; then
        if [[ -f "$d/comps.xml" ]]; then
          createrepo -v --compress-type=zstd --general-compress-type=zstd "$d" -g comps.xml >/dev/null
        else
          createrepo -v --compress-type=zstd --general-compress-type=zstd "$d" >/dev/null
        fi
      else
        echo "ПРЕДУПРЕЖДЕНИЕ: createrepo не найден, пересоберите метаданные вручную для $d" >&2
      fi
    done
    echo "Готово: возвращено=${moved}, уже_были_в_opt=${skipped}  DESTDIR=$DESTDIR"
    [[ "${MOVE:-0}" == "1" ]] && echo "Файлы перенесены из архива (MOVE=1)."
    ;;
  du)
    du -sh "$ARCHIVE_REPO" 2>/dev/null || echo "0"
    du -sh "$ARCHIVE_REPO"/* 2>/dev/null || true
    df -h /var /opt 2>/dev/null || true
    ;;
  *)
    usage
    exit 1
    ;;
esac
