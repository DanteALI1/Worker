# Локальный репозиторий РЕД ОС 8 — полный гайд

Пошаговая инструкция по развёртыванию **зеркала официальных репозиториев РЕД ОС 8** на сервере «Сервер минимальный» и раздаче пакетов/обновлений на все хосты в сети `10.0.0.0/8`.

Основано на официальной базе знаний РЕД ОС:

- [Создание локального репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo/)
- [Синхронизация локального репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-update-repo/)
- [Локальный репозиторий по HTTPS](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/)
- [Источники программ (репозитории)](https://redos.red-soft.ru/base/redos-8_0/8_0-base-consept/8_0-sys-dnf/8_0-gen-info-dnf/8_0-dnf-repo/)

В репозитории рядом лежат готовые файлы:

| Путь | Назначение |
|------|------------|
| [`docs/configs/local-repo/`](configs/local-repo/) | `.repo`-файлы источников и клиентов, пример `httpd` |
| [`docs/scripts/local-repo/`](scripts/local-repo/) | скрипт зеркалирования и установка на клиентах |

---

## 1. Целевая схема

```text
Интернет (repo1.red-soft.ru / mirror.yandex.ru)
        │
        │  reposync (только сервер-зеркало)
        ▼
┌───────────────────────────────────────┐
│  Сервер-зеркало РЕД ОС 8              │
│  IP: 10.0.0.10  (замените на свой)    │
│  httpd → http://10.0.0.10/repos/…     │
│  /var/www/html/repos/redos8/          │
└───────────────────────────────────────┘
        │
        │  dnf install / dnf update (HTTP)
        ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Сервер A     │  │ Сервер B     │  │ …            │
│ 10.0.0.21    │  │ 10.0.0.22    │  │ 10.0.0.x     │
└──────────────┘  └──────────────┘  └──────────────┘
```

**Роли:**

1. **Сервер-зеркало** — единственный хост с доступом в Интернет (желательно). Скачивает Base, Updates и доп. ветки, публикует их по HTTP.
2. **Клиенты** — остальные серверы РЕД ОС 8 в `10.0.0.0/8`. Берут пакеты только с зеркала, официальные URL отключены.

**Параметры по умолчанию в гайде** (замените под себя):

| Параметр | Значение |
|----------|----------|
| IP зеркала | `10.0.0.10` |
| Сеть клиентов | `10.0.0.0/8` |
| Каталог пакетов | `/opt/repos/redos8/` → symlink `/var/www/html/repos` (или сразу `/var/www/html/repos`) |
| Редакция | **Стандартная** (`8.0`, не `8.0c`) |
| Архитектура | `x86_64` |
| Протокол | HTTP (для закрытой сети достаточно; HTTPS — раздел 10) |

> Если у вас не `/8`, а например `10.0.0.0/24`, везде подставьте свой префикс в правилах firewalld.

---

## 2. Требования к серверу-зеркалу

| Требование | Рекомендация |
|------------|--------------|
| ОС | РЕД ОС 8, «Сервер минимальный», стандартная редакция |
| Диск | Смотрите реальный размер через `dnf repoinfo` (часто **~300–400 ГБ** на все подключённые ветки; Base+Updates обычно основная масса). Нужен запас **+20–30%** под рост updates |
| Сеть | Статический IP в `10.0.0.0/8`, доступ в Интернет для `reposync` |
| RAM | 2 ГБ+ (минимальный сервер обычно хватает) |
| Права | все команды от `root` (`su -` или `sudo su -`) |

### Куда класть пакеты (выбор раздела)

Сначала оцените размер и свободное место:

```bash
df -hT /
df -hT /var /opt /home 2>/dev/null

# По каждому репозиторию
dnf repoinfo | grep -iE '^(идентификатор репозитория|Repo-id|размер.*репозитория|Repo-size)'

# Сумма всех подключённых (если вывод в G/M на русском)
dnf repoinfo | grep -iE 'размер.*репозитория' | awk -F ':' '{
  size = $2; sub(/M$/, "", size);
  if (index($2, "M") > 0) total += size / 1024; else total += size
} END { printf "Общий размер подключённых репозиториев: %.2f G\n", total }'
```

Пример разметки сервера (ваши цифры могут совпадать):

| Точка монтирования | Свободно (примерно) | Для зеркала ~392 ГБ |
|--------------------|---------------------|---------------------|
| `/` (`/dev/sda4`) | ~90 ГБ | **нет** |
| `/home` | ~93 ГБ | **нет** |
| `/var` | ~840 ГБ | да |
| `/opt` | ~878 ГБ | **да, предпочтительно** |

**Рекомендация:** хранить пакеты на **`/opt/repos`**, а для `httpd` сделать симлинк в `/var/www/html/repos`. Так `/var` остаётся свободным под логи, journal, БД и кэш, а самое большое пустое место (`/opt`) используется под зеркало.

```bash
mkdir -p /opt/repos/redos8 /opt/repos/internal/rpms
mkdir -p /var/www/html
ln -sfn /opt/repos /var/www/html/repos

# SELinux: httpd должен читать /opt/repos
dnf install -y policycoreutils-python-utils
semanage fcontext -a -t httpd_sys_content_t "/opt/repos(/.*)?"
restorecon -Rv /opt/repos
chown -R root:apache /opt/repos
chmod -R 755 /opt/repos
```

URL для клиентов не меняется: `http://10.0.0.10/repos/redos8/...` (симлинк прозрачен для httpd).

Альтернатива — писать сразу в `/var/www/html/repos` на разделе `/var`, если `/opt` занят другими сервисами. **Не** кладите зеркало на `/` или `/home` при размере ~400 ГБ.

> `392 G` — это **все** подключённые репозитории. Для раздачи обновлений обычно достаточно **Base + Updates**. Посмотрите размеры по ID:
>
> ```bash
> dnf repoinfo base updates 2>/dev/null | grep -iE '^(идентификатор|Repo-id|размер|Repo-size)'
> # или реальные ID из: dnf repolist --all
> ```
>
> С `--newest-only` (как в скрипте sync) диск занимает меньше, чем полное историческое зеркало.

---

## 3. Подготовка сервера-зеркала

### 3.1. Базовая настройка

```bash
su -

hostnamectl set-hostname repo.local
timedatectl set-timezone Europe/Moscow

# Статический IP — через nmcli / ваши настройки сети.
# Пример: 10.0.0.10/8, шлюз 10.0.0.1
ip -br a
```

### 3.2. Пакеты для зеркала

```bash
dnf install -y httpd createrepo_c dnf-utils policycoreutils-python-utils
```

| Пакет | Зачем |
|-------|--------|
| `httpd` | раздача каталога репозитория по HTTP |
| `createrepo_c` | метаданные (`createrepo`) |
| `dnf-utils` | `reposync` |
| `policycoreutils-python-utils` | `semanage` для SELinux (если каталог не стандартный) |

### 3.3. Запуск httpd и firewalld

```bash
systemctl enable --now httpd
systemctl enable --now firewalld

# Доступ к HTTP только из внутренней сети
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" service name="http" accept'
firewall-cmd --reload
firewall-cmd --list-all
```

Если rich-rule неудобен, можно открыть HTTP глобально (хуже для периметра):

```bash
firewall-cmd --permanent --add-service=http
firewall-cmd --reload
```

### 3.4. Каталог зеркала

```bash
mkdir -p /var/www/html/repos/redos8
chown -R root:apache /var/www/html/repos
chmod -R 755 /var/www/html/repos
restorecon -Rv /var/www/html/repos
```

Проверка с самого сервера:

```bash
curl -I http://127.0.0.1/
# HTTP/1.1 200 OK
```

---

## 4. Какие ветки зеркалировать

По умолчанию в РЕД ОС подключены:

| Ветка | URL (фрагмент) | Нужно ли |
|-------|----------------|----------|
| **os** (Base) | `…/redos/8.0/$basearch/os` | **Да** — установка пакетов |
| **updates** | `…/redos/8.0/$basearch/updates` | **Да** — обновления безопасности |

Дополнительно (по желанию):

| Ветка | Назначение |
|-------|------------|
| `extras` | пакеты сверх базового набора |
| `3rdparty` | сторонние бинарники «как есть», без бюллетеней безопасности |
| `debuginfo` | отладочные пакеты |
| `kernel-rt` | realtime-ядро |

Для «распространять обновления и пакеты установки на все сервера» достаточно **Base + Updates**. Ниже зеркалируются они; `extras` добавлен как опциональный шаг.

> **Сертифицированная** редакция: пути `8.0c` вместо `8.0` (см. официальную статью). Не смешивайте стандартную и сертифицированную на одних клиентах.

---

## 5. Источники для reposync (на зеркале)

Создайте **отдельные** `.repo` с `enabled=0` — они нужны только `reposync`, не для установки пакетов на самом зеркале из Интернета в обычном режиме.

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

Опционально — extras:

```bash
cat > /etc/yum.repos.d/redos8_extras_src.repo << 'EOF'
[redos8_extras_src]
name=RedOS 8 - Extras (Mirror source)
baseurl=https://repo1.red-soft.ru/redos/8.0/$basearch/extras,https://mirror.yandex.ru/redos/8.0/$basearch/extras,http://repo.red-soft.ru/redos/8.0/$basearch/extras
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT
enabled=0
EOF
```

Готовые копии: [`docs/configs/local-repo/sources/`](configs/local-repo/sources/).

Проверка ID:

```bash
dnf repolist --all | grep -E 'redos8_(base|updates|extras)_src'
```

---

## 6. Первичное зеркалирование

Перейдите в каталог и запустите синхронизацию. Первая загрузка может занять **много часов** и съесть десятки гигабайт.

```bash
cd /var/www/html/repos/redos8

# Base (с comps для групп пакетов)
reposync --repoid=redos8_base_src \
  --download-metadata --downloadcomps \
  --download-path=/var/www/html/repos/redos8

# Updates
reposync --repoid=redos8_updates_src \
  --download-metadata --downloadcomps \
  --download-path=/var/www/html/repos/redos8
```

Только новейшие версии пакетов (меньше места, хуже история версий):

```bash
reposync --repoid=redos8_base_src \
  --download-metadata --downloadcomps --newest-only \
  --download-path=/var/www/html/repos/redos8
```

Метаданные после синхронизации:

```bash
# Base — обязательно -g comps.xml
createrepo -v --compress-type=zstd --general-compress-type=zstd \
  /var/www/html/repos/redos8/redos8_base_src/ -g comps.xml

# Updates
createrepo -v --compress-type=zstd --general-compress-type=zstd \
  /var/www/html/repos/redos8/redos8_updates_src/
```

Если для Updates есть `comps.xml`:

```bash
createrepo -v --compress-type=zstd --general-compress-type=zstd \
  /var/www/html/repos/redos8/redos8_updates_src/ -g comps.xml
```

Права и SELinux:

```bash
chown -R root:apache /var/www/html/repos
chmod -R 755 /var/www/html/repos
restorecon -Rv /var/www/html/repos
```

Проверка URL с зеркала или с клиента:

```bash
curl -I http://10.0.0.10/repos/redos8/redos8_base_src/repodata/repomd.xml
curl -I http://10.0.0.10/repos/redos8/redos8_updates_src/repodata/repomd.xml
```

Ожидается `HTTP/1.1 200 OK`.

---

## 7. Автоматическая синхронизация (cron)

Скопируйте скрипт [`docs/scripts/local-repo/sync-redos8-repos.sh`](scripts/local-repo/sync-redos8-repos.sh) на сервер:

```bash
install -m 750 /path/to/sync-redos8-repos.sh /usr/local/sbin/sync-redos8-repos.sh
mkdir -p /var/log/local-repo
```

Или создайте вручную:

```bash
cat > /usr/local/sbin/sync-redos8-repos.sh << 'EOF'
#!/bin/bash
set -euo pipefail

DESTDIR=/var/www/html/repos/redos8
# Добавьте redos8_extras_src при необходимости
REPOIDS="redos8_base_src redos8_updates_src"
LOG=/var/log/local-repo/sync-$(date +%F).log

mkdir -p "$(dirname "$LOG")" "$DESTDIR"
exec >>"$LOG" 2>&1

echo "=== $(date -Is) sync start ==="
dnf makecache || true

for REPOID in $REPOIDS; do
  echo "--- sync $REPOID ---"
  if [[ -d "$DESTDIR/$REPOID/.repodata" ]]; then
    rm -rf "$DESTDIR/$REPOID/.repodata"
  fi
  # --newest-only --delete: только актуальные пакеты, удаление устаревших
  reposync --repo "$REPOID" --newest-only --delete \
    --downloadcomps --download-metadata -p "$DESTDIR"

  if [[ -f "$DESTDIR/$REPOID/comps.xml" ]]; then
    createrepo -v --compress-type=zstd --general-compress-type=zstd \
      "$DESTDIR/$REPOID" -g comps.xml
  else
    createrepo -v --compress-type=zstd --general-compress-type=zstd \
      "$DESTDIR/$REPOID"
  fi
done

chown -R root:apache "$DESTDIR"
restorecon -Rv "$DESTDIR" >/dev/null || true
echo "=== $(date -Is) sync done ==="
EOF

chmod 750 /usr/local/sbin/sync-redos8-repos.sh
```

Cron — каждую ночь в 02:30:

```bash
cat > /etc/cron.d/redos8-local-repo << 'EOF'
30 2 * * * root /usr/local/sbin/sync-redos8-repos.sh
EOF
chmod 644 /etc/cron.d/redos8-local-repo
```

Первый прогон вручную:

```bash
/usr/local/sbin/sync-redos8-repos.sh
tail -f /var/log/local-repo/sync-$(date +%F).log
```

---

## 8. Настройка клиентов (все серверы в 10.0.0.0)

На **каждом** сервере РЕД ОС 8, который должен брать пакеты с зеркала.

### 8.1. Отключить официальные репозитории

Не удаляйте файлы — при обновлении пакетов они могут появиться снова. Отключите:

```bash
# Типичные имена на РЕД ОС 8
for f in /etc/yum.repos.d/RedOS-Base.repo /etc/yum.repos.d/RedOS-Updates.repo; do
  [ -f "$f" ] || continue
  sed -i 's/^enabled=1/enabled=0/' "$f"
done

# На всякий случай — всё, что ещё смотрит в Интернет (кроме локальных)
dnf config-manager --set-disabled RedOS-Base RedOS-Updates 2>/dev/null || true
```

Проверьте `enabled=` во всех файлах:

```bash
grep -nE '^\s*(enabled|baseurl|mirrorlist)=' /etc/yum.repos.d/*.repo
```

### 8.2. Подключить локальные репозитории

Замените `10.0.0.10` на IP вашего зеркала:

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

Скрипт массовой настройки: [`docs/scripts/local-repo/configure-client.sh`](scripts/local-repo/configure-client.sh).

```bash
# На клиенте:
REPO_HOST=10.0.0.10 bash configure-client.sh
```

### 8.3. Проверка на клиенте

```bash
dnf clean all
dnf makecache
dnf repolist
dnf check-update || true

# Установка тестового пакета (пример)
dnf install -y tree
```

`dnf makecache` должен завершиться **без ошибок**. В `repolist` должны быть `RedOS8-Base-local` и `RedOS8-Updates-local`, а официальные — disabled.

Обновление системы с зеркала:

```bash
dnf update -y
```

---

## 9. Свой репозиторий внутренних RPM (установка «своих» пакетов)

Помимо зеркала официальных пакетов, удобно держать каталог с вашими `.rpm` (агенты, внутренние сборки, offline-пакеты).

На зеркале:

```bash
mkdir -p /var/www/html/repos/internal/rpms
# Скопируйте RPM:
# cp /path/to/*.rpm /var/www/html/repos/internal/rpms/

createrepo -v --compress-type=zstd --general-compress-type=zstd \
  /var/www/html/repos/internal/
chown -R root:apache /var/www/html/repos/internal
restorecon -Rv /var/www/html/repos/internal
```

После добавления новых RPM снова запускайте `createrepo` по каталогу `internal`.

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

> Для production лучше подписывать свои RPM и включить `gpgcheck=1` с вашим ключом.

---

## 10. HTTPS (опционально)

В закрытой сети `10.0.0.0` обычно хватает HTTP. Если нужен HTTPS — по [официальной инструкции](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/):

```bash
dnf install -y mod_ssl
# Сертификат + ключ → /etc/pki/tls/certs/web_repo.cer
#                    → /etc/pki/tls/private/web_repo.key
# Настроить ServerName и пути в /etc/httpd/conf.d/ssl.conf
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" service name="https" accept'
firewall-cmd --reload
systemctl restart httpd
```

На клиентах: `baseurl=https://…`, доверенный CA через `update-ca-trust`, либо временно `sslverify=0` для самоподписанного сертификата.

---

## 11. Установка РЕД ОС с локального зеркала (новые серверы)

Anaconda умеет ставить ОС из сетевого репозитория. После того как зеркало готово:

1. Загрузитесь с ISO/USB РЕД ОС 8.
2. В разделе источников установки добавьте репозиторий:
   - URL: `http://10.0.0.10/repos/redos8/redos8_base_src/`
3. При необходимости добавьте Updates:  
   `http://10.0.0.10/repos/redos8/redos8_updates_src/`
4. После установки сразу примените раздел **8** (клиентские `.repo`), чтобы дальнейшие `dnf update` шли только с зеркала.

Подробнее: [Установка РЕД ОС из репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-install/8_0-alter-install/8_0-install-redos-from-repo/) — там указаны официальные URL; у вас вместо них — IP зеркала.

---

## 12. Эксплуатация и чеклист

### Ежедневно / по cron

- [ ] Скрипт `sync-redos8-repos.sh` отрабатывает без ошибок в `/var/log/local-repo/`
- [ ] На клиентах `dnf check-update` видит пакеты с `RedOS8-*-local`

### После крупных обновлений зеркала

- [ ] `curl -I http://10.0.0.10/repos/redos8/redos8_base_src/repodata/repomd.xml`
- [ ] На тестовом клиенте `dnf makecache && dnf update`

### Диск

```bash
df -h /var/www/html/repos
du -sh /var/www/html/repos/redos8/*
```

### Типичные ошибки

| Симптом | Что проверить |
|---------|----------------|
| `repomd.xml` 404 | не выполнен `createrepo`; неверный путь в `baseurl` |
| Permission denied / 403 | права `apache`, SELinux `httpd_sys_content_t` |
| Timeout с клиента | firewalld rich-rule / маршрутизация `10.0.0.0` |
| Клиент всё ещё качает из Интернета | не отключён `RedOS-Base.repo` / `enabled=1` |
| После `dnf update` снова официальные repo | появились `.rpmnew` или перезаписались файлы — снова `enabled=0`, локальные оставить |
| GPG error | ключ `RPM-GPG-KEY-RED-SOFT` на месте; `gpgcheck=1` |

SELinux для нестандартного каталога:

```bash
semanage fcontext -a -t httpd_sys_content_t "/mnt/repodisk(/.*)?"
restorecon -Rv /mnt/repodisk
```

---

## 13. Порядок работ «с нуля» (краткий чеклист)

1. Выделить сервер РЕД ОС 8 minimal, IP `10.0.0.10`, диск ≥ 80–150 ГБ, Интернет.
2. Установить `httpd createrepo_c dnf-utils`, включить httpd + firewalld (HTTP из `10.0.0.0/8`).
3. Создать `/var/www/html/repos/redos8/`.
4. Добавить `redos8_base_src.repo` и `redos8_updates_src.repo` (`enabled=0`).
5. Выполнить `reposync` + `createrepo` для Base и Updates.
6. Проверить `curl` к `repomd.xml`.
7. Поставить `/usr/local/sbin/sync-redos8-repos.sh` в cron.
8. На всех клиентах: отключить официальные repo, добавить локальные, `dnf makecache`.
9. (Опционально) каталог `internal` для своих RPM.
10. (Опционально) установка новых ОС с URL зеркала.

---

## 14. Что уточнить под вашу сеть

Если что-то из этого отличается — подставьте свои значения в конфиги и скрипты:

1. **Точный IP зеркала** и префикс сети (`/8`, `/16`, `/24`).
2. **Стандартная или сертифицированная** редакция (`8.0` vs `8.0c`).
3. Нужны ли ветки **extras / 3rdparty** в полном объёме.
4. Должно ли зеркало быть **единственным** выходом в Интернет, а клиенты — без внешнего доступа.
5. Нужен ли **HTTPS** и свой CA.
6. Нужна ли **сетевая установка** новых серверов с зеркала (Anaconda).

---

## Ссылки

- [Создание локального репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo/)
- [Синхронизация](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-update-repo/)
- [HTTPS](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/)
- [Firewalld](https://redos.red-soft.ru/base/redos-8_0/8_0-network/8_0-sec-firewall/8_0-configuring-firewall/)
- [Список пакетов pkgs.red-soft.ru](https://pkgs.red-soft.ru/)
