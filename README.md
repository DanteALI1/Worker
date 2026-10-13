# Worker

Документация и скрипты для РЕД ОС 8.

## NetBox

Развёртывание NetBox на пустом сервере (IP `10.0.130.10`, HTTPS, SELinux, `/opt/netbox`):

**Инструкция:** [`docs/netbox-redos8-install.md`](docs/netbox-redos8-install.md)

```bash
# скопируйте docs/scripts/netbox/ на сервер, затем от root:
bash install-netbox-redos8.sh
```

## Локальный репозиторий

Зеркало + архив старых пакетов + HTTPS.

**Инструкция:** [`docs/redos8-local-repo.md`](docs/redos8-local-repo.md)

### Зеркало

```bash
# серты: /home/svcsecadm/uibrep.crt и uibrep.key
# скопируйте docs/scripts/local-repo/ на сервер, затем от root:
bash deploy-uibrep-mirror.sh
```

### Клиент

```bash
scp root@ЗЕРКАЛО:/opt/repos/ca/uibrep-ca.crt /tmp/
scp root@ЗЕРКАЛО:/usr/local/sbin/configure-repo-client.sh /tmp/
REPO_IP=IP_ЗЕРКАЛА CA_FILE=/tmp/uibrep-ca.crt bash /tmp/configure-repo-client.sh
```
