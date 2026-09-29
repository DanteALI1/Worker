# Скрипты локального репозитория РЕД ОС 8 (HTTPS + УЦ)

Хранилище: **`/opt/repos`**. Раздача: **HTTPS**.

| Скрипт | Назначение |
|--------|------------|
| **`deploy-uibrep-mirror.sh`** | **готово к запуску** под `/home/svcsecadm/uibrep.{crt,key}`, FQDN из серта |
| **`sync-redos8-repos.sh`** | sync + **архив старых RPM на `/var`** + отчёт |
| **`repo-archive-tool.sh`** | list/search/url/restore из архива |
| `bootstrap-mirror-server.sh` | общий bootstrap |
| `install-ssl-certs.sh` | только SSL |
| `configure-client.sh` | клиент (+ archive `.repo` с `enabled=0`) |

Пошагово: [`docs/redos8-uibrep-runbook.md`](../../redos8-uibrep-runbook.md).  
Архив: [`docs/redos8-repo-archive.md`](../../redos8-repo-archive.md).

## Запуск на вашем зеркале

```bash
# от root, серты уже в /home/svcsecadm/
bash deploy-uibrep-mirror.sh

# только подготовка без скачивания пакетов:
SKIP_SYNC=1 bash deploy-uibrep-mirror.sh
```
