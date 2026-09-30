# Скрипты локального репозитория РЕД ОС 8

Инструкция: [`docs/redos8-local-repo.md`](../../redos8-local-repo.md)

| Скрипт | Назначение |
|--------|------------|
| `deploy-uibrep-mirror.sh` | деплой: HTTPS, `/opt/repos`, архив на `/var`, cron |
| `sync-redos8-repos.sh` | sync + перенос старых RPM в `/var/local-repo-archive` |
| `repo-archive-tool.sh` | list / search / url / restore / du |
| `clean-local-repo.sh` | полная очистка `/opt/repos` и `/var/local-repo-ar*` |
| `configure-client.sh` | настройка клиента (альтернатива helper с зеркала) |

```bash
# на зеркале от root (нужны все .sh из этого каталога):
bash deploy-uibrep-mirror.sh
SKIP_SYNC=1 bash deploy-uibrep-mirror.sh   # без первого reposync

# полная очистка пакетов и архива (спросит YES):
bash clean-local-repo.sh
FORCE=1 bash clean-local-repo.sh                 # без вопроса
TARGET=archive FORCE=1 bash clean-local-repo.sh  # только /var/local-repo-ar*
TARGET=opt FORCE=1 bash clean-local-repo.sh      # только пакеты в /opt/repos
```

По умолчанию sync зеркалирует все ветки: base, updates, **extras**, **3rdparty**, debuginfo, kernel-rt, kernel-testing (часто 300–400+ ГБ на `/opt`).

Серты по умолчанию: `/home/svcsecadm/uibrep.crt`, `uibrep.key`. FQDN — из сертификата.
