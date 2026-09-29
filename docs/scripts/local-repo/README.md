# Скрипты локального репозитория РЕД ОС 8

| Скрипт | Где запускать | Назначение |
|--------|---------------|------------|
| `bootstrap-mirror-server.sh` | сервер-зеркало | пакеты, httpd, firewalld, каталоги, cron |
| `sync-redos8-repos.sh` | сервер-зеркало | `reposync` + `createrepo` (ручной / cron) |
| `configure-client.sh` | каждый клиент | отключить официальные repo, подключить зеркало |

Подробный гайд: [`docs/redos8-local-repo.md`](../../redos8-local-repo.md).

## Примеры

```bash
# На зеркале (с машины, куда скопированы файлы репозитория Worker):
cd docs/scripts/local-repo
REPO_NET=10.0.0.0/8 bash bootstrap-mirror-server.sh
NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh   # первая полная синхронизация

# На клиенте:
REPO_HOST=10.0.0.10 bash configure-client.sh
REPO_HOST=10.0.0.10 WITH_EXTRAS=1 WITH_INTERNAL=1 bash configure-client.sh
```
