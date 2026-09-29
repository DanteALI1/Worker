# Worker

Документация по инфраструктуре на РЕД ОС 8:

- **[Запуск у вас: uibrep.crt / uibrep.key](docs/redos8-uibrep-runbook.md)** — пошагово + один скрипт
- **[Архив старых пакетов на /var](docs/redos8-repo-archive.md)** — перед обновлением зеркала старые RPM сохраняются
- **[Полный гайд локального репозитория (HTTPS)](docs/redos8-local-repo.md)**
- Конфиги: [`docs/configs/local-repo/`](docs/configs/local-repo/)
- Скрипты: [`docs/scripts/local-repo/`](docs/scripts/local-repo/)

### Зеркало (ваши серты в `/home/svcsecadm`)

```bash
# на сервере-зеркале от root:
bash docs/scripts/local-repo/deploy-uibrep-mirror.sh
# серты по умолчанию: /home/svcsecadm/uibrep.crt и uibrep.key
# имя узла берётся из сертификата автоматически
```

### Клиент

```bash
scp root@ЗЕРКАЛО:/opt/repos/ca/uibrep-ca.crt /tmp/
scp root@ЗЕРКАЛО:/usr/local/sbin/configure-repo-client.sh /tmp/
REPO_IP=IP_ЗЕРКАЛА CA_FILE=/tmp/uibrep-ca.crt bash /tmp/configure-repo-client.sh
```