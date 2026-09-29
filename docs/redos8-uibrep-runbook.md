# Локальное зеркало РЕД ОС 8 — запуск у вас (uibrep.crt / uibrep.key)

Сертификаты уже лежат на сервере:

```text
/home/svcsecadm/uibrep.crt
/home/svcsecadm/uibrep.key
```

Скрипт **сам** читает имя из сертификата (SAN → CN), иначе берёт `hostname -f`, подставляет его в httpd/`/etc/hosts`/клиентские URL.

Полный гайд: [`redos8-local-repo.md`](redos8-local-repo.md).  
Скрипт: [`scripts/local-repo/deploy-uibrep-mirror.sh`](scripts/local-repo/deploy-uibrep-mirror.sh).

---

## Шаг 0. Перед запуском

1. Сервер: РЕД ОС 8 minimal, доступ в Интернет (для `reposync`).
2. Свободное место на **`/opt`** — сотни ГБ (у вас раньше оценка репозиториев ~392 ГБ).
3. Файлы сертификата на месте:

```bash
ls -l /home/svcsecadm/uibrep.crt /home/svcsecadm/uibrep.key
openssl x509 -in /home/svcsecadm/uibrep.crt -noout -subject -ext subjectAltName
```

4. (Желательно) корневой CA УЦ рядом, если его нет внутри `uibrep.crt` как цепочка:

```text
/home/svcsecadm/uibrep-ca.crt
# или ca.crt / rootCA.crt / ca-root.crt — скрипт подхватит
```

Без CA клиенты не смогут проверить HTTPS (`sslverify=1`).

---

## Шаг 1. Скопировать скрипт на зеркало

С машины, где есть репозиторий Worker, **или** скачайте файл с GitHub:

```bash
# на сервере-зеркале, от пользователя с sudo / root
mkdir -p /root/local-repo
# скопируйте сюда deploy-uibrep-mirror.sh
# (и по желанию sync-redos8-repos.sh из того же каталога)
```

Минимум нужен один файл:

```text
/root/local-repo/deploy-uibrep-mirror.sh
```

---

## Шаг 2. Запустить деплой (одна команда)

```bash
su -
cd /root/local-repo
chmod +x deploy-uibrep-mirror.sh
bash deploy-uibrep-mirror.sh
```

Что сделает скрипт:

| Действие | Результат |
|----------|-----------|
| Определеит FQDN | из `uibrep.crt` (SAN/CN) или hostname |
| Поставит пакеты | `httpd`, `mod_ssl`, `createrepo_c`, `dnf-utils`… |
| Каталог пакетов | `/opt/repos` + symlink `/var/www/html/repos` |
| SSL | `/etc/pki/tls/certs/repo.crt`, `.../private/repo.key` |
| httpd | VirtualHost 443, `ServerName=<из серта>` |
| firewalld | HTTPS только из `10.0.0.0/8` |
| reposync sources | Base + Updates |
| cron | sync каждую ночь в 02:30 |
| зеркалирование | сразу полное (`NEWEST=0`), **долго** |

### Если сейчас зеркалить не нужно (только подготовить сервер)

```bash
SKIP_SYNC=1 bash deploy-uibrep-mirror.sh
# потом:
NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh
```

### Если сеть не /8

```bash
REPO_NET=10.0.0.0/24 bash deploy-uibrep-mirror.sh
```

### Если нужно принудительно задать имя

```bash
REPO_FQDN=repo.company.local bash deploy-uibrep-mirror.sh
```

---

## Шаг 3. Проверить зеркало

Скрипт в конце выведет FQDN и IP. Также:

```bash
cat /opt/repos/DEPLOY.txt

curl -Ik "https://$(awk -F= '/^REPO_FQDN=/{print $2}' /opt/repos/DEPLOY.txt)/"

# после окончания sync:
curl -I "https://$(awk -F= '/^REPO_FQDN=/{print $2}' /opt/repos/DEPLOY.txt)/repos/redos8/redos8_base_src/repodata/repomd.xml"

df -h /opt
du -sh /opt/repos/redos8/*
tail -f /var/log/local-repo/sync-$(date +%F).log
```

Ожидается `HTTP/1.1 200` на `repomd.xml`.

---

## Шаг 4. Подключить клиентские серверы

На **зеркале** уже лежит helper: `/usr/local/sbin/configure-repo-client.sh`  
и CA (если был в цепочке): `/opt/repos/ca/uibrep-ca.crt`

На **каждом клиенте**:

```bash
# подставьте IP зеркала
MIRROR_IP=10.0.0.10   # ваш IP зеркала

scp root@${MIRROR_IP}:/opt/repos/ca/uibrep-ca.crt /tmp/
scp root@${MIRROR_IP}:/usr/local/sbin/configure-repo-client.sh /tmp/

su -
REPO_IP=${MIRROR_IP} CA_FILE=/tmp/uibrep-ca.crt bash /tmp/configure-repo-client.sh
```

Скрипт на клиенте:

- пропишет `/etc/hosts` → FQDN зеркала;
- установит CA в trust (`update-ca-trust`);
- отключит официальные RedOS repo;
- создаст локальные `.repo` на `https://<FQDN>/repos/...`;
- выполнит `dnf makecache`.

Проверка на клиенте:

```bash
dnf repolist
dnf check-update || true
dnf install -y tree
```

---

## Шаг 5. Архив старых пакетов на `/var`

При ночных обновлениях (`NEWEST=1`) пакеты, которые исчезают из актуального зеркала, **не удаляются**, а переносятся в:

```text
/var/local-repo-archive/redos8/
URL: https://<FQDN>/archive/redos8/
```

Подробно: [`redos8-repo-archive.md`](redos8-repo-archive.md).

```bash
# что ушло в архив при последнем sync
cat /var/local-repo-archive/reports/latest.txt

# поиск / URL
repo-archive-tool.sh search openssl
repo-archive-tool.sh url имя-пакета.rpm

# на клиенте поставить старую версию
dnf install PKG --enablerepo=RedOS8-Archive-Base-local,RedOS8-Archive-Updates-local
```

Хранение по умолчанию: **180 дней** (`ARCHIVE_KEEP_DAYS`).

## Шаг 6. Дальнейшая эксплуатация

| Задача | Команда |
|--------|---------|
| Ночной sync + архив | cron `02:30` → `ARCHIVE=1 NEWEST=1 sync-redos8-repos.sh` |
| Ручной sync | `ARCHIVE=1 NEWEST=1 /usr/local/sbin/sync-redos8-repos.sh` |
| Параметры деплоя | `cat /opt/repos/DEPLOY.txt` |
| Лог sync | `/var/log/local-repo/sync-ДАТА.log` |
| Отчёт архива | `cat /var/local-repo-archive/reports/latest.txt` |
| Место архива | `repo-archive-tool.sh du` |

---

## Если что-то пошло не так

| Проблема | Что сделать |
|----------|-------------|
| «crt и key не пара» | проверьте файлы: `openssl x509/rsa -noout -modulus … \| openssl md5` |
| httpd не стартует | `journalctl -u httpd -xe`, `apachectl configtest` |
| Клиент: SSL error | нет CA на клиенте — скопируйте `/opt/repos/ca/uibrep-ca.crt` |
| hostname mismatch | FQDN в `.repo` ≠ SAN сертификата — смотрите `DEPLOY.txt` |
| Мало места | зеркало на `/opt`; `df -h /opt` |
| 404 repomd | sync ещё не закончился |

---

## Краткий чеклист

- [ ] `ls /home/svcsecadm/uibrep.crt /home/svcsecadm/uibrep.key`
- [ ] `bash deploy-uibrep-mirror.sh` от root
- [ ] Дождаться окончания sync (или `SKIP_SYNC=1` + sync позже)
- [ ] `curl` → 200 на `repomd.xml`
- [ ] На клиентах: scp CA + `configure-repo-client.sh`
- [ ] На клиентах: `dnf makecache` без ошибок
