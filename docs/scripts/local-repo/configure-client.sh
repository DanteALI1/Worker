#!/bin/bash
# Настройка клиента РЕД ОС 8 на локальное зеркало по HTTPS (УЦ).
# Запуск от root:
#   REPO_HOST=repo.example.ru PROTO=https CA_CERT=/path/ca-root.crt \
#     bash configure-client.sh
#
# Опции:
#   REPO_HOST     — FQDN зеркала (должен совпадать с CN/SAN сертификата)
#   PROTO         — https (по умолчанию) или http
#   CA_CERT       — корневой/промежуточный CA (.crt) → trust store
#   SSLVERIFY     — 1 по умолчанию; 0 только если нет CA (не рекомендуется)
#   WITH_EXTRAS   — 1
#   WITH_INTERNAL — 1
#   REPO_IP       — если задан, добавит /etc/hosts: REPO_IP REPO_HOST

set -euo pipefail

REPO_HOST="${REPO_HOST:-repo.example.ru}"
REPO_IP="${REPO_IP:-}"
WITH_EXTRAS="${WITH_EXTRAS:-0}"
WITH_INTERNAL="${WITH_INTERNAL:-0}"
PROTO="${PROTO:-https}"
SSLVERIFY="${SSLVERIFY:-1}"
CA_CERT="${CA_CERT:-}"
REPO_DIR="/etc/yum.repos.d"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Запустите от root" >&2
  exit 1
fi

if [[ -n "$REPO_IP" ]]; then
  if grep -qE "[[:space:]]${REPO_HOST}([[:space:]]|\$)" /etc/hosts; then
    sed -i -E "s|^[0-9.]+[[:space:]]+${REPO_HOST}([[:space:]].*)?$|${REPO_IP} ${REPO_HOST}|" /etc/hosts
  else
    echo "${REPO_IP} ${REPO_HOST}" >> /etc/hosts
  fi
  echo "hosts: ${REPO_IP} ${REPO_HOST}"
fi

if [[ -n "$CA_CERT" ]]; then
  if [[ ! -f "$CA_CERT" ]]; then
    echo "Нет файла CA: $CA_CERT" >&2
    exit 1
  fi
  echo "== Установка CA в trust store =="
  install -m 644 "$CA_CERT" /etc/pki/ca-trust/source/anchors/org-ca.crt
  update-ca-trust
  update-ca-trust extract
fi

disable_official() {
  local f
  shopt -s nullglob
  for f in \
    "${REPO_DIR}/RedOS-Base.repo" \
    "${REPO_DIR}/RedOS-Updates.repo" \
    "${REPO_DIR}/RedOS-Extras.repo" \
    "${REPO_DIR}"/RedOS*.repo
  do
    case "$(basename "$f")" in
      *-local.repo|RedOS8-*-local.repo|Internal-local.repo) continue ;;
    esac
    if [[ -f "$f" ]] && grep -qE '^enabled=1' "$f"; then
      if grep -qE 'red-soft\.ru|mirror\.yandex\.ru' "$f"; then
        sed -i 's/^enabled=1/enabled=0/' "$f"
        echo "disabled: $f"
      fi
    fi
  done
  shopt -u nullglob
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
    if [[ "$PROTO" == "https" ]]; then
      echo "sslverify=${SSLVERIFY}"
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

echo "== Проверка HTTPS =="
if [[ "$PROTO" == "https" ]]; then
  curl -fsSI "https://${REPO_HOST}/repos/redos8/redos8_base_src/repodata/repomd.xml" | head -n1 \
    || echo "Предупреждение: curl не получил repomd.xml — проверьте CA, DNS и зеркало" >&2
fi

dnf clean all
dnf makecache
dnf repolist

echo "OK: клиент → ${PROTO}://${REPO_HOST}"
