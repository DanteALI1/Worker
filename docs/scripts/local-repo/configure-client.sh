#!/bin/bash
# Настройка клиента РЕД ОС 8 на локальное зеркало.
# Запуск от root на каждом сервере-клиенте:
#   REPO_HOST=10.0.0.10 bash configure-client.sh
#
# Опции:
#   REPO_HOST     — IP или DNS зеркала (обязательно логически, по умолчанию 10.0.0.10)
#   WITH_EXTRAS   — 1 = подключить extras
#   WITH_INTERNAL — 1 = подключить internal (свои RPM)
#   PROTO         — http (по умолчанию) или https
#   SSLVERIFY     — 0 только для самоподписанного HTTPS

set -euo pipefail

REPO_HOST="${REPO_HOST:-10.0.0.10}"
WITH_EXTRAS="${WITH_EXTRAS:-0}"
WITH_INTERNAL="${WITH_INTERNAL:-0}"
PROTO="${PROTO:-http}"
SSLVERIFY="${SSLVERIFY:-1}"
REPO_DIR="/etc/yum.repos.d"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите от root" >&2
  exit 1
fi

disable_official() {
  local f
  for f in \
    "${REPO_DIR}/RedOS-Base.repo" \
    "${REPO_DIR}/RedOS-Updates.repo" \
    "${REPO_DIR}/RedOS-Extras.repo"
  do
    if [[ -f "$f" ]]; then
      sed -i 's/^enabled=1/enabled=0/' "$f"
      echo "disabled: $f"
    fi
  done
  dnf config-manager --set-disabled RedOS-Base RedOS-Updates 2>/dev/null || true
}

write_repo() {
  local id="$1" name="$2" path="$3" gpg="$4"
  local file="${REPO_DIR}/${id}.repo"
  {
    echo "[${id}]"
    echo "name=${name}"
    echo "baseurl=${PROTO}://${REPO_HOST}${path}"
    echo "gpgcheck=${gpg}"
    if [[ "$gpg" == "1" ]]; then
      echo "gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT"
    fi
    if [[ "$PROTO" == "https" && "$SSLVERIFY" == "0" ]]; then
      echo "sslverify=0"
    fi
    echo "enabled=1"
  } >"$file"
  echo "wrote: $file"
}

disable_official

write_repo "RedOS8-Base-local" \
  "Local RED OS 8 Base repo" \
  "/repos/redos8/redos8_base_src/" \
  "1"

write_repo "RedOS8-Updates-local" \
  "Local RED OS 8 Updates repo" \
  "/repos/redos8/redos8_updates_src/" \
  "1"

if [[ "$WITH_EXTRAS" == "1" ]]; then
  write_repo "RedOS8-Extras-local" \
    "Local RED OS 8 Extras repo" \
    "/repos/redos8/redos8_extras_src/" \
    "1"
fi

if [[ "$WITH_INTERNAL" == "1" ]]; then
  write_repo "Internal-local" \
    "Internal packages (local mirror)" \
    "/repos/internal/" \
    "0"
fi

dnf clean all
dnf makecache
dnf repolist

echo "OK: клиент смотрит на ${PROTO}://${REPO_HOST}"
