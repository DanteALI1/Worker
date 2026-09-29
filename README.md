# Worker

Документация по инфраструктуре на РЕД ОС 8:

- **[Локальный репозиторий РЕД ОС 8 (HTTPS + УЦ)](docs/redos8-local-repo.md)** — зеркало на `/opt/repos`, раздача по HTTPS с вашими `.crt`/`.key`
- Конфиги: [`docs/configs/local-repo/`](docs/configs/local-repo/)
- Скрипты: [`docs/scripts/local-repo/`](docs/scripts/local-repo/)

### Зеркало

```bash
cd docs/scripts/local-repo
REPO_FQDN=repo.example.ru \
SSL_CRT=/path/server.crt SSL_KEY=/path/server.key \
REPO_NET=10.0.0.0/8 \
  bash bootstrap-mirror-server.sh
NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh
```

### Клиент

```bash
REPO_HOST=repo.example.ru REPO_IP=10.0.0.10 \
PROTO=https CA_CERT=/path/ca-root.crt \
  bash docs/scripts/local-repo/configure-client.sh
```
