# Локальный репозиторий РЕД ОС 8

Один документ для вашего сервера: зеркало на `/opt`, архив старых пакетов на `/var`, HTTPS с сертификатами УЦ.

```text
Сертификаты (уже на сервере):
  /home/svcsecadm/uibrep.crt
  /home/svcsecadm/uibrep.key
  /home/svcsecadm/uibrep-ca.crt   # желательно, если CA не внутри .crt

Актуальное зеркало:  /opt/repos/redos8/     → https://FQDN/repos/redos8/
Архив старых RPM:    /var/local-repo-archive/redos8/ → https://FQDN/archive/redos8/
```

Скрипт деплоя сам берёт FQDN из сертификата (SAN → CN → hostname).

Файлы: [`docs/scripts/local-repo/`](scripts/local-repo/), [`docs/configs/local-repo/`](configs/local-repo/).

---

## 1. Перед запуском

1. РЕД ОС 8 minimal, доступ в Интернет (для `reposync`).
2. Место на **`/opt`** — сотни ГБ под актуальное зеркало (~размер репозиториев + запас).
3. Место на **`/var`** — под архив старых пакетов.
4. Сертификаты:

```bash
ls -l /home/svcsecadm/uibrep.crt /home/svcsecadm/uibrep.key
openssl x509 -in /home/svcsecadm/uibrep.crt -noout -subject -ext subjectAltName
```

Без корневого CA на клиентах HTTPS с `sslverify=1` не заработает. Положите CA как `/home/svcsecadm/uibrep-ca.crt` (или `ca.crt` / `rootCA.crt`) — скрипт подхватит. Если в `uibrep.crt` уже цепочка (несколько `BEGIN CERTIFICATE`) — отдельный файл не обязателен.

---

## 2. Деплой зеркала (одна команда)

Скопируйте на сервер **весь** каталог `docs/scripts/local-repo/` (нужны `deploy-uibrep-mirror.sh`, `sync-redos8-repos.sh`, `repo-archive-tool.sh`):

```bash
su -
mkdir -p /root/local-repo
# скопируйте сюда содержимое docs/scripts/local-repo/
cd /root/local-repo
chmod +x *.sh
bash deploy-uibrep-mirror.sh
```

| Что сделает | Куда |
|-------------|------|
| FQDN из серта | httpd, `/etc/hosts`, клиентские URL |
| Пакеты | `httpd`, `mod_ssl`, `createrepo_c`, `dnf-utils` |
| Зеркало | `/opt/repos` → symlink `/var/www/html/repos` |
| Архив | `/var/local-repo-archive` |
| SSL | `/etc/pki/tls/certs/repo.crt`, `.../private/repo.key` |
| firewalld | HTTPS из `10.0.0.0/8` |
| cron 02:30 | `ARCHIVE=1 NEWEST=1` sync |
| Первый sync | полное зеркало (`NEWEST=0`), **долго** |

Опции:

```bash
SKIP_SYNC=1 bash deploy-uibrep-mirror.sh          # только подготовка
REPO_NET=10.0.0.0/24 bash deploy-uibrep-mirror.sh # другая маска
REPO_FQDN=имя.local bash deploy-uibrep-mirror.sh  # принудительно имя
```

---

## 3. Проверка зеркала

```bash
cat /opt/repos/DEPLOY.txt
FQDN=$(awk -F= '/^REPO_FQDN=/{print $2}' /opt/repos/DEPLOY.txt)

curl -Ik "https://${FQDN}/"
curl -I  "https://${FQDN}/repos/redos8/redos8_base_src/repodata/repomd.xml"   # после sync → 200
curl -Ik "https://${FQDN}/archive/"

df -h /opt /var
tail -f /var/log/local-repo/sync-$(date +%F).log
```

---

## 4. Клиенты

На зеркале уже есть `/usr/local/sbin/configure-repo-client.sh` и CA в `/opt/repos/ca/` (если был).

```bash
MIRROR_IP=IP_вашего_зеркала

scp root@${MIRROR_IP}:/opt/repos/ca/uibrep-ca.crt /tmp/
scp root@${MIRROR_IP}:/usr/local/sbin/configure-repo-client.sh /tmp/

su -
REPO_IP=${MIRROR_IP} CA_FILE=/tmp/uibrep-ca.crt bash /tmp/configure-repo-client.sh

dnf repolist
dnf makecache
dnf check-update || true
```

Скрипт на клиенте: `/etc/hosts`, trust CA, отключение официальных repo, локальные HTTPS `.repo` (+ archive с `enabled=0`).

---

## 5. Архив старых пакетов (`/var`)

При ночном sync (`NEWEST=1`) RPM, которых больше нет в новом зеркале, **переносятся** в `/var/local-repo-archive` (не удаляются сразу).

```text
/opt/repos/redos8/                      — актуальные
/var/local-repo-archive/redos8/         — старые
/var/local-repo-archive/reports/        — отчёты NEW / ARCHIVE
```

Первый полный sync архив почти не наполняет. Архив растёт со **второй** синхронизации (cron).

```bash
# отчёт
cat /var/local-repo-archive/reports/latest.txt

# поиск и URL
repo-archive-tool.sh search openssl
repo-archive-tool.sh url имя.rpm
repo-archive-tool.sh du

# скачать
curl -O "https://${FQDN}/archive/redos8/redos8_base_src/имя.rpm"

# поставить на клиенте старую версию
dnf install PKG --enablerepo=RedOS8-Archive-Base-local,RedOS8-Archive-Updates-local

# вернуть в актуальное зеркало (на сервере)
repo-archive-tool.sh restore redos8_base_src имя.rpm
```

Хранение: **180 дней** (`ARCHIVE_KEEP_DAYS`). Не чистить: в cron добавьте `ARCHIVE_KEEP_DAYS=0`.

---

## 6. Эксплуатация

| Задача | Команда |
|--------|---------|
| Ночной sync + архив | уже в cron `02:30` |
| Ручной sync | `ARCHIVE=1 NEWEST=1 /usr/local/sbin/sync-redos8-repos.sh` |
| Параметры | `cat /opt/repos/DEPLOY.txt` |
| Лог | `/var/log/local-repo/sync-ДАТА.log` |
| Отчёт архива | `cat /var/local-repo-archive/reports/latest.txt` |

---

## 7. Типичные ошибки

| Проблема | Действие |
|----------|----------|
| crt и key не пара | `openssl x509/rsa -noout -modulus … \| openssl md5` |
| httpd не стартует | `apachectl configtest`, `journalctl -u httpd -xe` |
| SSL на клиенте | нет CA → скопировать `/opt/repos/ca/uibrep-ca.crt` |
| hostname mismatch | FQDN в `.repo` ≠ SAN — смотрите `DEPLOY.txt` |
| Мало места | `df -h /opt /var` |
| 404 repomd | sync ещё идёт |

---

## 8. Чеклист

- [ ] `ls /home/svcsecadm/uibrep.crt /home/svcsecadm/uibrep.key`
- [ ] Скопирован каталог `docs/scripts/local-repo/`
- [ ] `bash deploy-uibrep-mirror.sh` от root
- [ ] Sync завершён, `curl` → 200 на `repomd.xml`
- [ ] Клиенты: CA + `configure-repo-client.sh`, `dnf makecache` без ошибок

---

## Состав репозитория

| Путь | Назначение |
|------|------------|
| `scripts/local-repo/deploy-uibrep-mirror.sh` | деплой зеркала |
| `scripts/local-repo/sync-redos8-repos.sh` | sync + архив на `/var` |
| `scripts/local-repo/repo-archive-tool.sh` | list/search/url/restore |
| `scripts/local-repo/configure-client.sh` | альтернативная настройка клиента |
| `configs/local-repo/sources/` | source `.repo` для reposync |
| `configs/local-repo/clients/` | шаблоны клиентских `.repo` |
| `configs/local-repo/httpd-*.conf` | фрагменты httpd (deploy пишет сам) |

Основано на [базе знаний РЕД ОС](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo/) (локальный repo, HTTPS, sync).
