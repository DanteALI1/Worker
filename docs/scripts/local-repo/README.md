# Скрипты локального репозитория РЕД ОС 8 (HTTPS + УЦ)

Хранилище: **`/opt/repos`**. Раздача: **HTTPS** с вашими `.crt` / `.key` от УЦ.

| Скрипт | Где | Назначение |
|--------|-----|------------|
| `bootstrap-mirror-server.sh` | зеркало | пакеты, `/opt/repos`, firewalld https, опционально SSL |
| `install-ssl-certs.sh` | зеркало | установка `.crt`/`.key`/chain, httpd SSL, trust |
| `sync-redos8-repos.sh` | зеркало | `reposync` + `createrepo` → `/opt/repos/redos8` |
| `configure-client.sh` | клиент | CA в trust, HTTPS `.repo`, отключение официальных |

Гайд: [`docs/redos8-local-repo.md`](../../redos8-local-repo.md).

## Зеркало

```bash
cd docs/scripts/local-repo

REPO_NET=10.0.0.0/8 \
REPO_FQDN=repo.example.ru \
SSL_CRT=/path/to/server.crt \
SSL_KEY=/path/to/server.key \
SSL_CHAIN=/path/to/ca-chain.crt \
  bash bootstrap-mirror-server.sh

NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh
```

Только SSL (если зеркало уже есть):

```bash
SSL_CRT=/path/server.crt SSL_KEY=/path/server.key \
REPO_FQDN=repo.example.ru bash install-ssl-certs.sh
```

## Клиент

```bash
REPO_HOST=repo.example.ru \
REPO_IP=10.0.0.10 \
PROTO=https \
CA_CERT=/path/to/ca-root.crt \
  bash configure-client.sh
```
