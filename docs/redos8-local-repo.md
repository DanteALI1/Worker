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
2. Место на **`/opt`** — часто **300–400+ ГБ** под все ветки (os/updates/extras/3rdparty/debuginfo/kernel-*) + запас.
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
| Первый sync | полное зеркало всех веток (`NEWEST=0`), **долго** |

По умолчанию зеркалируются **все** ветки РЕД ОС 8:

| Ветка | repoid | Клиент (enabled) |
|-------|--------|------------------|
| os | `redos8_base_src` | 1 |
| updates | `redos8_updates_src` | 1 |
| extras | `redos8_extras_src` | 1 — доп. ПО |
| 3rdparty | `redos8_3rdparty_src` | 1 — сторонние пакеты |
| debuginfo | `redos8_debuginfo_src` | 0 |
| kernel-rt | `redos8_kernel_rt_src` | 0 |
| kernel-testing | `redos8_kernel_testing_src` | 0 |

Опции:

```bash
SKIP_SYNC=1 bash deploy-uibrep-mirror.sh          # только подготовка
REPO_NET=10.0.0.0/24 bash deploy-uibrep-mirror.sh # другая маска
REPO_FQDN=имя.local bash deploy-uibrep-mirror.sh  # принудительно имя
# сузить список (не рекомендуется, если нужно доп. ПО):
REPOIDS="redos8_base_src redos8_updates_src redos8_extras_src redos8_3rdparty_src" \
  bash deploy-uibrep-mirror.sh
```

---

## 3. Проверка зеркала

```bash
cat /opt/repos/DEPLOY.txt
FQDN=$(awk -F= '/^REPO_FQDN=/{print $2}' /opt/repos/DEPLOY.txt)

curl -Ik "https://${FQDN}/"
curl -I  "https://${FQDN}/repos/redos8/redos8_base_src/repodata/repomd.xml"     # после sync → 200
curl -I  "https://${FQDN}/repos/redos8/redos8_extras_src/repodata/repomd.xml"
curl -I  "https://${FQDN}/repos/redos8/redos8_3rdparty_src/repodata/repomd.xml"
curl -Ik "https://${FQDN}/archive/"

df -h /opt /var
du -sh /opt/repos/redos8/*
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

# доп. ПО из extras / 3rdparty (уже enabled=1 после helper)
dnf search ИМЯ
dnf install ПАКЕТ
```

Скрипт на клиенте: `/etc/hosts`, trust CA, отключение официальных repo, локальные HTTPS `.repo` (Base+Updates+Extras+3rdparty включены; debuginfo/kernel/archive — `enabled=0`).

Вручную debuginfo/kernel:

```bash
dnf install ПАКЕТ --enablerepo=RedOS8-Debuginfo-local
# или при настройке: WITH_DEBUG=1 WITH_KERNEL=1 bash configure-client.sh
```

---

## 5. Архив старых пакетов (`/var`)

Ночной sync (`ARCHIVE=1 NEWEST=1`) сравнивает `/opt` с upstream:

| Ситуация | Что происходит |
|----------|----------------|
| Обновление пакета | старый RPM → `/var/local-repo-archive`, новый → `/opt` |
| Новый пакет | появляется в `/opt` |
| Нет изменений | **`/opt` не трогается**, архив не меняется |
| Нет сети / пустой reposync | **`/opt` не трогается** (`ABORT` в отчёте) |

Неизменённые RPM в `/opt` не перезаписываются. Если incoming меньше **80%** пакетов от `/opt` (`MIN_INCOMING_PCT`), архивация не выполняется.

```text
/opt/repos/redos8/                      — актуальные
/var/local-repo-archive/redos8/         — старые (только superseded)
/var/local-repo-archive/reports/        — отчёты NEW / ARCHIVE / UNCHANGED
```

Первый полный sync (`NEWEST=0`) архив почти не наполняет. Архив растёт, когда upstream отдаёт новые версии (cron).

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

# если без интернета всё ошибочно ушло в архив:
MOVE=1 repo-archive-tool.sh restore-all
```

Хранение: **180 дней** (`ARCHIVE_KEEP_DAYS`). Не чистить: в cron добавьте `ARCHIVE_KEEP_DAYS=0`.

---

## 6. Эксплуатация

| Задача | Команда |
|--------|---------|
| Ночной sync + архив | уже в cron `02:30` |
| Ручной sync (все ветки) | `ARCHIVE=1 NEWEST=1 /usr/local/sbin/sync-redos8-repos.sh` |
| Sync только части | `REPOIDS="redos8_extras_src redos8_3rdparty_src" ARCHIVE=1 NEWEST=1 /usr/local/sbin/sync-redos8-repos.sh` |
| Полная очистка `/opt` + `/var/local-repo-ar*` | `FORCE=1 /usr/local/sbin/clean-local-repo.sh` (или `bash clean-local-repo.sh` → `YES`) |
| Только архив / только пакеты | `TARGET=archive\|opt FORCE=1 clean-local-repo.sh` |
| Параметры | `cat /opt/repos/DEPLOY.txt` |
| Лог | `/var/log/local-repo/sync-ДАТА.log` |
| Отчёт архива | `cat /var/local-repo-archive/reports/latest.txt` |

После очистки зеркало пустое — заново: `NEWEST=0 ARCHIVE=0 /usr/local/sbin/sync-redos8-repos.sh`.  
По умолчанию `KEEP_META=1` сохраняет `/opt/repos/ca` и `DEPLOY.txt`. Полный снос meta: `KEEP_META=0`.

---

## 7. Типичные ошибки

| Проблема | Действие |
|----------|----------|
| crt и key не пара | `openssl x509/rsa -noout -modulus … \| openssl md5` |
| httpd не стартует | `apachectl configtest`, `journalctl -u httpd -xe` |
| SSL на клиенте | нет CA → скопировать `/opt/repos/ca/uibrep-ca.crt` |
| hostname mismatch | FQDN в `.repo` ≠ SAN — смотрите `DEPLOY.txt` |
| Мало места | `df -h /opt /var` — все ветки часто 300–400+ ГБ на `/opt` |
| 404 repomd | sync ещё идёт; проверьте нужную ветку (`extras` / `3rdparty`) |
| `/opt` опустел без обновлений | ложная архивация при сбое сети — `MOVE=1 repo-archive-tool.sh restore-all` |

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
| `scripts/local-repo/clean-local-repo.sh` | полная очистка `/opt/repos` и архива |
| `scripts/local-repo/repo-archive-tool.sh` | list/search/url/restore |
| `scripts/local-repo/configure-client.sh` | альтернативная настройка клиента |
| `configs/local-repo/sources/` | source `.repo` для reposync |
| `configs/local-repo/clients/` | шаблоны клиентских `.repo` |
| `configs/local-repo/httpd-*.conf` | фрагменты httpd (deploy пишет сам) |

Основано на [базе знаний РЕД ОС](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo/) (локальный repo, HTTPS, sync).
