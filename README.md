# Worker

Документация по инфраструктуре на РЕД ОС 8:

- **[Локальный репозиторий РЕД ОС 8](docs/redos8-local-repo.md)** — зеркало Base/Updates на `/opt/repos`, раздача обновлений в сети `10.0.0.0`
- Конфиги `.repo` и httpd: [`docs/configs/local-repo/`](docs/configs/local-repo/)
- Скрипты bootstrap / sync / клиент: [`docs/scripts/local-repo/`](docs/scripts/local-repo/)

### Быстрый старт зеркала

```bash
cd docs/scripts/local-repo
REPO_NET=10.0.0.0/8 bash bootstrap-mirror-server.sh
NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh
```

### Быстрый старт клиента

```bash
REPO_HOST=10.0.0.10 bash docs/scripts/local-repo/configure-client.sh
```
