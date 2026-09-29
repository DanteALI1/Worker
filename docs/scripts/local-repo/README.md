# Скрипты локального репозитория РЕД ОС 8 (HTTPS + УЦ)

Хранилище: **`/opt/repos`**. Раздача: **HTTPS**.

| Скрипт | Назначение |
|--------|------------|
| **`deploy-uibrep-mirror.sh`** | **готово к запуску** под `/home/svcsecadm/uibrep.{crt,key}`, FQDN из серта |
| `bootstrap-mirror-server.sh` | общий bootstrap |
| `install-ssl-certs.sh` | только SSL |
| `sync-redos8-repos.sh` | `reposync` + `createrepo` |
| `configure-client.sh` | универсальный клиент |

Пошагово: [`docs/redos8-uibrep-runbook.md`](../../redos8-uibrep-runbook.md).

## Запуск на вашем зеркале

```bash
# от root, серты уже в /home/svcsecadm/
bash deploy-uibrep-mirror.sh

# только подготовка без скачивания пакетов:
SKIP_SYNC=1 bash deploy-uibrep-mirror.sh
```
