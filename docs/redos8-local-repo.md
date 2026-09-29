# Локальный репозиторий РЕД ОС 8 — полный гайд

Пошаговая инструкция по развёртыванию **зеркала официальных репозиториев РЕД ОС 8** на сервере «Сервер минимальный» и раздаче пакетов/обновлений на все хосты в сети `10.0.0.0/8`.

Основано на официальной базе знаний РЕД ОС:

- [Создание локального репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo/)
- [Синхронизация локального репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-update-repo/)
- [Локальный репозиторий по HTTPS](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/)
- [Источники программ (репозитории)](https://redos.red-soft.ru/base/redos-8_0/8_0-base-consept/8_0-sys-dnf/8_0-gen-info-dnf/8_0-dnf-repo/)

Готовые файлы в этом репозитории:

| Путь | Назначение |
|------|------------|
| [`docs/configs/local-repo/`](configs/local-repo/) | `.repo` источников и клиентов, фрагмент `httpd` |
| [`docs/scripts/local-repo/`](scripts/local-repo/) | bootstrap / sync / настройка клиентов |

---

## 1. Целевая схема

```text
Интернет (repo1.red-soft.ru / mirror.yandex.ru)
        │
        │  reposync (только сервер-зеркало)
        ▼
┌────────────────────────────────────────────┐
│  Сервер-зеркало РЕД ОС 8                   │
│  IP: 10.0.0.10  (замените на свой)         │
│  Данные:  /opt/repos/redos8/               │
│  Web:     /var/www/html/repos → /opt/repos │
│  URL:     http://10.0.0.10/repos/…         │
└────────────────────────────────────────────┘
        │
        │  dnf install / dnf update (HTTP)
        ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Сервер A     │  │ Сервер B     │  │ …            │
│ 10.0.0.21    │  │ 10.0.0.22    │  │ 10.0.0.x     │
└──────────────┘  └──────────────┘  └──────────────┘
```

**Роли:**

1. **Сервер-зеркало** — желательно единственный хост с доступом в Интернет. Скачивает Base, Updates (и при необходимости extras), отдаёт по HTTP.
2. **Клиенты** — остальные серверы РЕД ОС 8 в `10.0.0.0/8`. Берут пакеты только с зеркала; официальные URL отключены.

**Параметры по умолчанию** (замените под себя):

| Параметр | Значение |
|----------|----------|
| IP зеркала | `10.0.0.10` |
| Сеть клиентов | `10.0.0.0/8` |
| Хранилище пакетов | `/opt/repos/` |
| Каталог зеркала | `/opt/repos/redos8/` |
| Каталог своих RPM | `/opt/repos/internal/` |
| Публикация httpd | `/var/www/html/repos` → symlink на `/opt/repos` |
| Редакция | **Стандартная** (`8.0`, не `8.0c`) |
| Архитектура | `x86_64` |
| Протокол | HTTP (HTTPS — раздел 10) |

> Если сеть не `/8`, а например `10.0.0.0/24`, подставьте свой префикс в firewalld и в `httpd-local-repo.conf`.

---

## 2. Требования и диск

| Требование | Рекомендация |
|------------|--------------|
| ОС | РЕД ОС 8, «Сервер минимальный», стандартная редакция |
| Диск | Реальный размер — через `dnf repoinfo` (все ветки часто **~300–400 ГБ**). Запас **+20–30%** |
| Сеть | Статический IP в `10.0.0.0/8`, Интернет для `reposync` |
| RAM | 2 ГБ+ |
| Права | команды от `root` (`su -` или `sudo su -`) |

### Оценка размера

```bash
df -hT / /var /opt /home

dnf repoinfo | grep -iE '^(идентификатор репозитория|Repo-id|размер.*репозитория|Repo-size)'

dnf repoinfo | grep -iE 'размер.*репозитория' | awk -F ':' '{
  size = $2; sub(/M$/, "", size);
  if (index($2, "M") > 0) total += size / 1024; else total += size
} END { printf "Общий размер подключённых репозиториев: %.2f G\n", total }'
```

Пример разметки (типичный сервер с отдельными `/var` и `/opt`):

| Точка монтирования | Свободно (примерно) | Для зеркала ~392 ГБ |
|--------------------|---------------------|---------------------|
| `/` | ~90 ГБ | **нет** |
| `/home` | ~93 ГБ | **нет** |
| `/var` | ~840 ГБ | да |
| `/opt` | ~878 ГБ | **да — сюда** |

**Всегда используйте `/opt/repos`**, если `/opt` — самый большой свободный раздел. `/var` оставьте под логи, journal и сервисы.

> ~392 ГБ — это **все** подключённые ветки. Для раздачи обновлений обычно достаточно **Base + Updates**. С `--newest-only` (скрипт sync) места нужно меньше, чем для полного исторического зеркала.

---

## 3. Подготовка сервера-зеркала

### Вариант A — скрипт (рекомендуется)

Скопируйте на сервер каталог `docs/scripts/local-repo` и `docs/configs/local-repo`, затем:

```bash
cd /path/to/Worker/docs/scripts/local-repo
REPO_NET=10.0.0.0/8 bash bootstrap-mirror-server.sh
```

Скрипт установит пакеты, поднимет httpd/firewalld, создаст `/opt/repos`, symlink, SELinux-контекст, source `.repo`, sync в cron.

### Вариант B — вручную

#### 3.1. Базовая настройка

```bash
su -

hostnamectl set-hostname repo.local
timedatectl set-timezone Europe/Moscow
ip -br a
```

#### 3.2. Пакеты

```bash
dnf install -y httpd createrepo_c dnf-utils policycoreutils-python-utils
```

| Пакет | Зачем |
|-------|--------|
| `httpd` | раздача по HTTP |
| `createrepo_c` | метаданные (`createrepo`) |
| `dnf-utils` | `reposync` |
| `policycoreutils-python-utils` | `semanage` для SELinux на `/opt/repos` |

#### 3.3. httpd и firewalld

```bash
systemctl enable --now httpd
systemctl enable --now firewalld

firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" service name="http" accept'
firewall-cmd --reload
firewall-cmd --list-all
```

Опционально ограничить каталог репозитория в httpd — скопируйте [`httpd-local-repo.conf`](configs/local-repo/httpd-local-repo.conf) в `/etc/httpd/conf.d/local-repo.conf` и выполните `apachectl configtest && systemctl reload httpd`.

#### 3.4. Каталог зеркала на `/opt`

```bash
mkdir -p /opt/repos/redos8 /opt/repos/internal/rpms /var/www/html /var/log/local-repo
ln -sfn /opt/repos /var/www/html/repos

semanage fcontext -a -t httpd_sys_content_t "/opt/repos(/.*)?" 2>/dev/null \
  || semanage fcontext -m -t httpd_sys_content_t "/opt/repos(/.*)?"
restorecon -Rv /opt/repos

chown -R root:apache /opt/repos
chmod -R 755 /opt/repos

ls -la /var/www/html/repos
# должен показать symlink → /opt/repos
```

Проверка httpd:

```bash
curl -I http://127.0.0.1/
# HTTP/1.1 200 OK
```

---

## 4. Какие ветки зеркалировать

| Ветка | URL (фрагмент) | Нужно ли |
|-------|----------------|----------|
| **os** (Base) | `…/redos/8.0/$basearch/os` | **Да** |
| **updates** | `…/redos/8.0/$basearch/updates` | **Да** |
| `extras` | `…/extras` | по необходимости |
| `3rdparty` | сторонние пакеты без бюллетеней | осознанно |
| `debuginfo` / `kernel-rt` | отладка / RT-ядро | редко |

Для «обновления и пакеты установки на все сервера» достаточно **Base + Updates**.

> Сертифицированная редакция: в URL путь `8.0c` вместо `8.0`. Не смешивайте редакции на одних клиентах.

---

## 5. Источники для reposync (на зеркале)

Отдельные `.repo` с `enabled=0` — только для `reposync`:

```bash
cat > /etc/yum.repos.d/redos8_base_src.repo << 'EOF'
[redos8_base_src]
name=RedOS 8 - Base (Mirror source)
baseurl=https://repo1.red-soft.ru/redos/8.0/$basearch/os,https://mirror.yandex.ru/redos/8.0/$basearch/os,http://repo.red-soft.ru/redos/8.0/$basearch/os
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT
enabled=0
EOF

cat > /etc/yum.repos.d/redos8_updates_src.repo << 'EOF'
[redos8_updates_src]
name=RedOS 8 - Updates (Mirror source)
baseurl=https://repo1.red-soft.ru/redos/8.0/$basearch/updates,https://mirror.yandex.ru/redos/8.0/$basearch/updates,http://repo.red-soft.ru/redos/8.0/$basearch/updates
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT
enabled=0
EOF
```

Опционально extras — файл [`redos8_extras_src.repo`](configs/local-repo/sources/redos8_extras_src.repo).

Готовые копии: [`docs/configs/local-repo/sources/`](configs/local-repo/sources/).

```bash
dnf repolist --all | grep -E 'redos8_(base|updates|extras)_src'
```

---

## 6. Первичное зеркалирование

Первая загрузка может занять **много часов** и сотни гигабайт.

```bash
mkdir -p /opt/repos/redos8
cd /opt/repos/redos8

# Полное зеркало Base
reposync --repoid=redos8_base_src \
  --download-metadata --downloadcomps \
  --download-path=/opt/repos/redos8

# Полное зеркало Updates
reposync --repoid=redos8_updates_src \
  --download-metadata --downloadcomps \
  --download-path=/opt/repos/redos8
```

Только новейшие версии (меньше места):

```bash
reposync --repoid=redos8_base_src \
  --download-metadata --downloadcomps --newest-only \
  --download-path=/opt/repos/redos8
```

Метаданные:

```bash
# Base — обязательно -g comps.xml
createrepo -v --compress-type=zstd --general-compress-type=zstd \
  /opt/repos/redos8/redos8_base_src/ -g comps.xml

# Updates
if [[ -f /opt/repos/redos8/redos8_updates_src/comps.xml ]]; then
  createrepo -v --compress-type=zstd --general-compress-type=zstd \
    /opt/repos/redos8/redos8_updates_src/ -g comps.xml
else
  createrepo -v --compress-type=zstd --general-compress-type=zstd \
    /opt/repos/redos8/redos8_updates_src/
fi
```

Права:

```bash
chown -R root:apache /opt/repos
chmod -R 755 /opt/repos
restorecon -Rv /opt/repos
```

Проверка (замените IP):

```bash
curl -I http://10.0.0.10/repos/redos8/redos8_base_src/repodata/repomd.xml
curl -I http://10.0.0.10/repos/redos8/redos8_updates_src/repodata/repomd.xml
# ожидается HTTP/1.1 200 OK

df -h /opt
du -sh /opt/repos/redos8/*
```

Либо одной командой через скрипт:

```bash
# полное зеркало
NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh

# или только newest (меньше места)
/usr/local/sbin/sync-redos8-repos.sh
```

---

## 7. Автоматическая синхронизация (cron)

Установите скрипт [`sync-redos8-repos.sh`](scripts/local-repo/sync-redos8-repos.sh):

```bash
install -m 750 /path/to/sync-redos8-repos.sh /usr/local/sbin/sync-redos8-repos.sh
mkdir -p /var/log/local-repo

cat > /etc/cron.d/redos8-local-repo << 'EOF'
30 2 * * * root /usr/local/sbin/sync-redos8-repos.sh
EOF
chmod 644 /etc/cron.d/redos8-local-repo
```

Скрипт по умолчанию пишет в **`/opt/repos/redos8`**, использует `--newest-only --delete`.

Переменные:

| Переменная | По умолчанию | Смысл |
|------------|--------------|--------|
| `DESTDIR` | `/opt/repos/redos8` | куда качать |
| `REPOIDS` | `redos8_base_src redos8_updates_src` | список веток |
| `NEWEST` | `1` | `0` = полное зеркало |

```bash
REPOIDS="redos8_base_src redos8_updates_src redos8_extras_src" \
  /usr/local/sbin/sync-redos8-repos.sh

tail -f /var/log/local-repo/sync-$(date +%F).log
```

---

## 8. Настройка клиентов

На **каждом** сервере РЕД ОС 8 в сети.

### 8.1. Отключить официальные репозитории

Не удаляйте файлы — отключите:

```bash
for f in /etc/yum.repos.d/RedOS-Base.repo /etc/yum.repos.d/RedOS-Updates.repo; do
  [ -f "$f" ] || continue
  sed -i 's/^enabled=1/enabled=0/' "$f"
done

dnf config-manager --set-disabled RedOS-Base RedOS-Updates 2>/dev/null || true
grep -nE '^\s*(enabled|baseurl|mirrorlist)=' /etc/yum.repos.d/*.repo
```

### 8.2. Подключить локальное зеркало

Замените `10.0.0.10` на IP зеркала:

```bash
cat > /etc/yum.repos.d/RedOS8-Base-local.repo << 'EOF'
[RedOS8-Base-local]
name=Local RED OS 8 Base repo
baseurl=http://10.0.0.10/repos/redos8/redos8_base_src/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT
enabled=1
EOF

cat > /etc/yum.repos.d/RedOS8-Updates-local.repo << 'EOF'
[RedOS8-Updates-local]
name=Local RED OS 8 Updates repo
baseurl=http://10.0.0.10/repos/redos8/redos8_updates_src/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT
enabled=1
EOF
```

Шаблоны: [`docs/configs/local-repo/clients/`](configs/local-repo/clients/).

Скрипт:

```bash
REPO_HOST=10.0.0.10 bash configure-client.sh
# с extras и internal:
REPO_HOST=10.0.0.10 WITH_EXTRAS=1 WITH_INTERNAL=1 bash configure-client.sh
```

### 8.3. Проверка

```bash
dnf clean all
dnf makecache
dnf repolist
dnf check-update || true
dnf install -y tree
dnf update -y
```

В `repolist` должны быть `RedOS8-Base-local` и `RedOS8-Updates-local`, официальные — disabled.

---

## 9. Свой репозиторий внутренних RPM

```bash
mkdir -p /opt/repos/internal/rpms
# cp /path/to/*.rpm /opt/repos/internal/rpms/

createrepo -v --compress-type=zstd --general-compress-type=zstd \
  /opt/repos/internal/
chown -R root:apache /opt/repos/internal
restorecon -Rv /opt/repos/internal
```

После добавления новых RPM снова запускайте `createrepo` для `/opt/repos/internal`.

На клиентах:

```bash
cat > /etc/yum.repos.d/Internal-local.repo << 'EOF'
[Internal-local]
name=Internal packages
baseurl=http://10.0.0.10/repos/internal/
gpgcheck=0
enabled=1
EOF

dnf makecache
dnf install -y имя-вашего-пакета
```

> В production лучше подписывать RPM и включить `gpgcheck=1`.

---

## 10. HTTPS (опционально)

В закрытой сети обычно хватает HTTP. HTTPS — по [официальной инструкции](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/):

```bash
dnf install -y mod_ssl
# сертификат → /etc/pki/tls/certs/web_repo.cer
# ключ       → /etc/pki/tls/private/web_repo.key
# ServerName и пути в /etc/httpd/conf.d/ssl.conf
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" service name="https" accept'
firewall-cmd --reload
systemctl restart httpd
```

На клиентах: `baseurl=https://…`, CA через `update-ca-trust`, либо временно `sslverify=0`.

---

## 11. Установка РЕД ОС с локального зеркала

1. Загрузка с ISO/USB РЕД ОС 8.
2. Источник установки: `http://10.0.0.10/repos/redos8/redos8_base_src/`
3. При необходимости Updates: `http://10.0.0.10/repos/redos8/redos8_updates_src/`
4. После установки сразу раздел **8** (клиентские `.repo`).

Справка: [Установка РЕД ОС из репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-install/8_0-alter-install/8_0-install-redos-from-repo/).

---

## 12. Эксплуатация

### Чеклист

- [ ] `sync-redos8-repos.sh` без ошибок в `/var/log/local-repo/`
- [ ] `curl -I http://10.0.0.10/repos/redos8/redos8_base_src/repodata/repomd.xml` → 200
- [ ] На клиентах `dnf makecache` и `dnf check-update` с `RedOS8-*-local`
- [ ] Место: `df -h /opt` и `du -sh /opt/repos/redos8/*`

### Типичные ошибки

| Симптом | Что проверить |
|---------|----------------|
| `repomd.xml` 404 | не выполнен `createrepo`; неверный `baseurl` |
| 403 / Permission denied | права `apache`, SELinux на `/opt/repos` |
| Timeout | firewalld rich-rule, маршрутизация |
| Клиент качает из Интернета | официальные `.repo` с `enabled=1` |
| После update снова официальные repo | `.rpmnew` / перезапись — снова `enabled=0` |
| GPG error | ключ `RPM-GPG-KEY-RED-SOFT` |
| Symlink не отдаётся | `Options FollowSymLinks` в httpd; `ls -la /var/www/html/repos` |

SELinux (если сбросился контекст):

```bash
semanage fcontext -a -t httpd_sys_content_t "/opt/repos(/.*)?" 2>/dev/null \
  || semanage fcontext -m -t httpd_sys_content_t "/opt/repos(/.*)?"
restorecon -Rv /opt/repos
```

---

## 13. Порядок работ «с нуля»

1. Сервер РЕД ОС 8 minimal, IP `10.0.0.10`, свободное место на **`/opt` ≥ размера репозиториев + 20–30%**, Интернет.
2. `bash bootstrap-mirror-server.sh` **или** вручную: пакеты, httpd, firewalld, `/opt/repos` + symlink.
3. Source `.repo`: `redos8_base_src`, `redos8_updates_src` (`enabled=0`).
4. `NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh` (или ручной `reposync` + `createrepo` в `/opt/repos/redos8`).
5. `curl` к `repomd.xml` → 200.
6. Cron на sync уже стоит после bootstrap.
7. На всех клиентах: `REPO_HOST=10.0.0.10 bash configure-client.sh`.
8. (Опционально) `/opt/repos/internal` для своих RPM.
9. (Опционально) установка новых ОС с URL зеркала.

---

## 14. Что подставить под свою сеть

1. Точный **IP зеркала** и префикс сети (`/8`, `/16`, `/24`).
2. Редакция: **стандартная** (`8.0`) или **сертифицированная** (`8.0c`).
3. Нужны ли **extras / 3rdparty**.
4. Клиенты без Интернета (зеркало — единственный источник)?
5. Нужен ли **HTTPS**.
6. Нужна ли **сетевая установка** (Anaconda) с зеркала.

---

## Ссылки

- [Создание локального репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo/)
- [Синхронизация](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-update-repo/)
- [HTTPS](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/)
- [Firewalld](https://redos.red-soft.ru/base/redos-8_0/8_0-network/8_0-sec-firewall/8_0-configuring-firewall/)
- [Список пакетов pkgs.red-soft.ru](https://pkgs.red-soft.ru/)
