# Worker

Документация и скрипты для РЕД ОС 8.

## NetBox

Развёртывание на пустом сервере РЕД ОС 8 (IP `10.0.130.10`, HTTPS, SELinux).

| Способ | Инструкция | Скрипт |
|---|---|---|
| Классика (`/opt/netbox`) | [`docs/netbox-redos8-install.md`](docs/netbox-redos8-install.md) | `install-netbox-redos8.sh` |
| Docker (`/opt/netbox-docker`) | [`docs/netbox-redos8-docker-install.md`](docs/netbox-redos8-docker-install.md) | `install-netbox-docker-redos8.sh` |

```bash
# скопируйте docs/scripts/netbox/ на сервер, затем от root:
bash install-netbox-redos8.sh           # без Docker
bash install-netbox-docker-redos8.sh    # в Docker
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
