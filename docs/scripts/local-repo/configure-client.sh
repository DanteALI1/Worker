#!/bin/bash
# Настройка клиента РЕД ОС 8 на локальное зеркало по HTTPS (УЦ).
#   REPO_HOST=fqdn REPO_IP=10.0.0.10 CA_CERT=/path/ca.crt bash configure-client.sh
#
# По умолчанию включает: Base, Updates, Extras, 3rdparty.
# Debuginfo / kernel-* — enabled=0 (включаются WITH_DEBUG=1 / WITH_KERNEL=1).

set -euo pipefail

REPO_HOST="${REPO_HOST:-repo.example.ru}"
REPO_IP="${REPO_IP:-}"
PROTO="${PROTO:-https}"
SSLVERIFY="${SSLVERIFY:-1}"
CA_CERT="${CA_CERT:-}"
WITH_ARCHIVE="${WITH_ARCHIVE:-1}"
WITH_DEBUG="${WITH_DEBUG:-0}"
WITH_KERNEL="${WITH_KERNEL:-0}"
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
fi

if [[ -n "$CA_CERT" && -f "$CA_CERT" ]]; then
  install -m 644 "$CA_CERT" /etc/pki/ca-trust/source/anchors/uibrep-ca.crt
  update-ca-trust && update-ca-trust extract
fi

for f in "${REPO_DIR}"/RedOS-Base.repo "${REPO_DIR}"/RedOS-Updates.repo \
         "${REPO_DIR}"/RedOS-Extras.repo "${REPO_DIR}"/RedOS-3rdparty.repo; do
  [[ -f "$f" ]] && sed -i 's/^enabled=1/enabled=0/' "$f"
done

write_repo() {
  local id="$1" name="$2" path="$3" enabled="${4:-1}"
  {
    echo "[${id}]"
    echo "name=${name}"
    echo "baseurl=${PROTO}://${REPO_HOST}${path}"
    echo "gpgcheck=1"
    echo "gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT"
    [[ "$PROTO" == "https" ]] && echo "sslverify=${SSLVERIFY}"
    echo "enabled=${enabled}"
  } >"${REPO_DIR}/${id}.repo"
  echo "wrote ${id}.repo enabled=${enabled}"
}

write_repo RedOS8-Base-local     "Local RED OS 8 Base"     "/repos/redos8/redos8_base_src/"     1
write_repo RedOS8-Updates-local  "Local RED OS 8 Updates"  "/repos/redos8/redos8_updates_src/"  1
write_repo RedOS8-Extras-local   "Local RED OS 8 Extras"   "/repos/redos8/redos8_extras_src/"   1
write_repo RedOS8-3rdparty-local "Local RED OS 8 3rdparty" "/repos/redos8/redos8_3rdparty_src/" 1
write_repo RedOS8-Debuginfo-local     "Local RED OS 8 Debuginfo"      "/repos/redos8/redos8_debuginfo_src/"      "$WITH_DEBUG"
write_repo RedOS8-KernelRT-local      "Local RED OS 8 kernel-rt"      "/repos/redos8/redos8_kernel_rt_src/"      "$WITH_KERNEL"
write_repo RedOS8-KernelTesting-local "Local RED OS 8 kernel-testing" "/repos/redos8/redos8_kernel_testing_src/" "$WITH_KERNEL"

if [[ "$WITH_ARCHIVE" == "1" ]]; then
  write_repo RedOS8-Archive-Base-local     "Base ARCHIVE"     "/archive/redos8/redos8_base_src/"     0
  write_repo RedOS8-Archive-Updates-local  "Updates ARCHIVE"  "/archive/redos8/redos8_updates_src/"  0
  write_repo RedOS8-Archive-Extras-local   "Extras ARCHIVE"   "/archive/redos8/redos8_extras_src/"   0
  write_repo RedOS8-Archive-3rdparty-local "3rdparty ARCHIVE" "/archive/redos8/redos8_3rdparty_src/" 0
fi

dnf clean all
dnf makecache
dnf repolist
echo "OK → ${PROTO}://${REPO_HOST} (Base+Updates+Extras+3rdparty)"
