# Скрипты локального репозитория РЕД ОС 8

Хранилище по умолчанию: **`/opt/repos`** (symlink `/var/www/html/repos` → `/opt/repos`).

| Скрипт | Где запускать | Назначение |
|--------|---------------|------------|
| `bootstrap-mirror-server.sh` | сервер-зеркало | пакеты, httpd, firewalld, `/opt/repos`, cron |
| `sync-redos8-repos.sh` | сервер-зеркало | `reposync` + `createrepo` → `/opt/repos/redos8` |
| `configure-client.sh` | каждый клиент | отключить официальные repo, подключить зеркало |

Подробный гайд: [`docs/redos8-local-repo.md`](../../redos8-local-repo.md).

## Примеры

```bash
# На зеркале (нужны рядом docs/scripts/local-repo и docs/configs/local-repo):
cd docs/scripts/local-repo
REPO_NET=10.0.0.0/8 bash bootstrap-mirror-server.sh

# Первая полная синхронизация (сотни ГБ, долго):
NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh

# Ежедневный режим (только newest) — уже в cron после bootstrap

# На клиенте:
REPO_HOST=10.0.0.10 bash configure-client.sh
REPO_HOST=10.0.0.10 WITH_EXTRAS=1 WITH_INTERNAL=1 bash configure-client.sh
```

## Переопределение каталога

```bash
STORAGE_ROOT=/data/repos bash bootstrap-mirror-server.sh
DESTDIR=/data/repos/redos8 /usr/local/sbin/sync-redos8-repos.sh
```
