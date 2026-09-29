# Локальный репозиторий РЕД ОС 8 — полный гайд (HTTPS + УЦ)

Пошаговая инструкция: зеркало официальных репозиториев РЕД ОС 8 на «Сервер минимальный», раздача пакетов/обновлений в сети `10.0.0.0/8` по **HTTPS** с вашими сертификатами УЦ (`.crt` + `.key`).

Основано на базе знаний РЕД ОС:

- [Создание локального репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo/)
- [Локальный репозиторий по HTTPS](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/)
- [Настройка SSL для веб-серверов](https://redos.red-soft.ru/base/redos-8_0/8_0-security/8_0-ssl/8_0-ssl-for-webserv/)
- [Синхронизация локального репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-update-repo/)
- [Источники программ (репозитории)](https://redos.red-soft.ru/base/redos-8_0/8_0-base-consept/8_0-sys-dnf/8_0-gen-info-dnf/8_0-dnf-repo/)

| Путь | Назначение |
|------|------------|
| [`docs/configs/local-repo/`](configs/local-repo/) | `.repo`, httpd HTTP/HTTPS |
| [`docs/scripts/local-repo/`](scripts/local-repo/) | bootstrap / SSL / sync / клиент |
| [`redos8-repo-archive.md`](redos8-repo-archive.md) | архив старых RPM на `/var` при обновлении зеркала |
| [`redos8-uibrep-runbook.md`](redos8-uibrep-runbook.md) | готовый запуск с `uibrep.crt` / `uibrep.key` |

---

## 1. Целевая схема

```text
Интернет (repo1.red-soft.ru / mirror.yandex.ru)
        │
        │  reposync (только сервер-зеркало)
        ▼
┌─────────────────────────────────────────────────┐
│  Сервер-зеркало РЕД ОС 8                        │
│  IP:   10.0.0.10                                │
│  FQDN: repo.example.ru  (как в сертификате УЦ)  │
│  Данные: /opt/repos/redos8/                     │
│  Web:    /var/www/html/repos → /opt/repos       │
│  URL:    https://repo.example.ru/repos/…        │
│  TLS:    .crt + .key от вашего УЦ               │
└─────────────────────────────────────────────────┘
        │
        │  dnf (HTTPS, доверенный CA в trust store)
        ▼
   Серверы 10.0.0.x
```

| Параметр | Значение по умолчанию в гайде |
|----------|-------------------------------|
| IP зеркала | `10.0.0.10` |
| FQDN зеркала | `repo.example.ru` ← **замените на имя из вашего сертификата** |
| Сеть | `10.0.0.0/8` |
| Хранилище | `/opt/repos/` → web symlink `/var/www/html/repos` |
| Сертификат сервера | `/etc/pki/tls/certs/repo.crt` |
| Ключ сервера | `/etc/pki/tls/private/repo.key` |
| Цепочка (если есть) | `/etc/pki/tls/certs/repo-chain.crt` |
| Корневой/промежуточный CA на клиентах | `/etc/pki/ca-trust/source/anchors/` |
| Протокол | **HTTPS** |
| Редакция | Стандартная `8.0` |

> По [документации РЕД ОС](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/): доступ к зеркалу по HTTPS должен идти по **DNS-имени**, совпадающему с `CN` / `SAN` сертификата. На клиентах — запись DNS или строка в `/etc/hosts`.

---

## 2. Что нужно от вашего УЦ

Подготовьте файлы **до** настройки httpd:

| Файл | Формат | Куда на зеркале |
|------|--------|-----------------|
| Сертификат сервера | PEM `.crt` (или `.cer`) | `/etc/pki/tls/certs/repo.crt` |
| Закрытый ключ | PEM `.key` **без пароля** (или с passphrase — тогда нужен `SSLPassPhraseDialog`) | `/etc/pki/tls/private/repo.key` |
| Промежуточная цепочка (если УЦ выдал) | PEM `.crt` | `/etc/pki/tls/certs/repo-chain.crt` |
| Корневой CA (и промежуточный, если клиенты его не знают) | PEM `.crt` | на **каждом клиенте** → `anchors/` |

Проверка сертификата и соответствия ключу:

```bash
# CN / SAN — этим именем клиенты будут ходить на зеркало
openssl x509 -in /path/to/server.crt -noout -subject -dates -ext subjectAltName

# ключ и сертификат должны совпадать (одинаковый modulus)
openssl x509 -noout -modulus -in /path/to/server.crt | openssl md5
openssl rsa  -noout -modulus -in /path/to/server.key | openssl md5
```

Если УЦ отдал PKCS#12 (`.pfx` / `.p12`):

```bash
openssl pkcs12 -in server.pfx -clcerts -nokeys -out server.crt
openssl pkcs12 -in server.pfx -nocerts -nodes -out server.key
openssl pkcs12 -in server.pfx -cacerts -nokeys -out ca-chain.crt
chmod 600 server.key
```

---

## 3. Диск и каталог зеркала

Размещение пакетов — на **`/opt/repos`** (см. ваш `df`: `/opt` обычно самый большой раздел).

```bash
df -hT / /var /opt /home
dnf repoinfo | grep -iE 'размер.*репозитория'
```

```bash
mkdir -p /opt/repos/redos8 /opt/repos/internal/rpms /var/www/html /var/log/local-repo
ln -sfn /opt/repos /var/www/html/repos

dnf install -y policycoreutils-python-utils
semanage fcontext -a -t httpd_sys_content_t "/opt/repos(/.*)?" 2>/dev/null \
  || semanage fcontext -m -t httpd_sys_content_t "/opt/repos(/.*)?"
restorecon -Rv /opt/repos
chown -R root:apache /opt/repos
chmod -R 755 /opt/repos
```

---

## 4. Подготовка сервера-зеркала

### 4.1. Имя хоста и DNS

`ServerName` в httpd и `baseurl` на клиентах должны совпадать с именем в сертификате.

```bash
su -
hostnamectl set-hostname repo.example.ru
timedatectl set-timezone Europe/Moscow

# на зеркале
echo '10.0.0.10 repo.example.ru' >> /etc/hosts
```

На **каждом клиенте** (если нет внутреннего DNS):

```bash
echo '10.0.0.10 repo.example.ru' >> /etc/hosts
```

### 4.2. Пакеты

```bash
dnf install -y httpd mod_ssl createrepo_c dnf-utils policycoreutils-python-utils
systemctl enable --now httpd
systemctl enable --now firewalld
```

| Пакет | Зачем |
|-------|--------|
| `httpd` | раздача репозитория |
| `mod_ssl` | HTTPS ([док РЕД ОС](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/)) |
| `createrepo_c` / `dnf-utils` | метаданные / `reposync` |

### 4.3. Firewalld — HTTPS из внутренней сети

```bash
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" service name="https" accept'
# HTTP можно не открывать, если раздаёте только HTTPS
firewall-cmd --reload
firewall-cmd --list-all
```

---

## 5. Установка сертификатов УЦ на зеркале

По [инструкции РЕД ОС (локальный repo HTTPS)](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/) и [SSL для веб-серверов](https://redos.red-soft.ru/base/redos-8_0/8_0-security/8_0-ssl/8_0-ssl-for-webserv/).

### 5.1. Размещение файлов

Замените пути-источники на ваши:

```bash
install -d -m 755 /etc/pki/tls/certs
install -d -m 700 /etc/pki/tls/private

# сертификат сервера от УЦ
install -m 644 /path/to/your-server.crt /etc/pki/tls/certs/repo.crt

# закрытый ключ
install -m 600 /path/to/your-server.key /etc/pki/tls/private/repo.key
chown root:root /etc/pki/tls/private/repo.key

# промежуточная цепочка УЦ (если выдана отдельно)
# install -m 644 /path/to/ca-chain.crt /etc/pki/tls/certs/repo-chain.crt
```

Либо скрипт:

```bash
SSL_CRT=/path/to/server.crt \
SSL_KEY=/path/to/server.key \
SSL_CHAIN=/path/to/ca-chain.crt \   # опционально
REPO_FQDN=repo.example.ru \
  bash docs/scripts/local-repo/install-ssl-certs.sh
```

### 5.2. Настройка httpd (ssl.conf)

Согласно документации РЕД ОС — в `/etc/httpd/conf.d/ssl.conf` в VirtualHost `:443`:

```apache
ServerName repo.example.ru
SSLEngine on
SSLCertificateFile /etc/pki/tls/certs/repo.crt
SSLCertificateKeyFile /etc/pki/tls/private/repo.key
# если есть цепочка от УЦ:
# SSLCertificateChainFile /etc/pki/tls/certs/repo-chain.crt
```

Также укажите `ServerName` в `/etc/httpd/conf/httpd.conf` (раскомментируйте/задайте имя).

Готовый фрагмент: [`docs/configs/local-repo/httpd-ssl-repo.conf`](configs/local-repo/httpd-ssl-repo.conf) — можно поставить как отдельный vhost:

```bash
cp docs/configs/local-repo/httpd-ssl-repo.conf /etc/httpd/conf.d/ssl-repo.conf
# подставьте FQDN:
sed -i 's/repo.example.ru/ВАШ_FQDN/g' /etc/httpd/conf.d/ssl-repo.conf

# ограничение каталога репозитория сетью
cp docs/configs/local-repo/httpd-local-repo.conf /etc/httpd/conf.d/local-repo.conf

apachectl configtest
systemctl restart httpd
systemctl status httpd --no-pager
```

### 5.3. Проверка TLS

```bash
openssl s_client -connect repo.example.ru:443 -servername repo.example.ru </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

curl -I https://repo.example.ru/
# после добавления CA в trust на этой же машине — без -k
```

На самом зеркале для проверки до установки CA временно:

```bash
curl -Ik https://repo.example.ru/repos/redos8/
```

---

## 6. Источники reposync и зеркалирование

### 6.1. Source `.repo` (`enabled=0`)

Скопируйте из [`docs/configs/local-repo/sources/`](configs/local-repo/sources/) или создайте как в гайде (Base + Updates). Файлы не меняются от HTTPS — зеркало качает из Интернета по URL Red Soft.

```bash
install -m 644 docs/configs/local-repo/sources/redos8_*.repo /etc/yum.repos.d/
dnf repolist --all | grep redos8_
```

### 6.2. Первичная синхронизация

```bash
# скриптом (полное зеркало):
NEWEST=0 /usr/local/sbin/sync-redos8-repos.sh

# или вручную в /opt/repos/redos8 — см. раздел ниже / скрипт sync
```

Вручную:

```bash
reposync --repoid=redos8_base_src --download-metadata --downloadcomps \
  --download-path=/opt/repos/redos8
reposync --repoid=redos8_updates_src --download-metadata --downloadcomps \
  --download-path=/opt/repos/redos8

createrepo -v --compress-type=zstd --general-compress-type=zstd \
  /opt/repos/redos8/redos8_base_src/ -g comps.xml
createrepo -v --compress-type=zstd --general-compress-type=zstd \
  /opt/repos/redos8/redos8_updates_src/

chown -R root:apache /opt/repos
restorecon -Rv /opt/repos
```

Проверка раздачи по HTTPS:

```bash
curl -I https://repo.example.ru/repos/redos8/redos8_base_src/repodata/repomd.xml
```

### 6.3. Cron

```bash
install -m 750 docs/scripts/local-repo/sync-redos8-repos.sh /usr/local/sbin/sync-redos8-repos.sh
cat > /etc/cron.d/redos8-local-repo << 'EOF'
30 2 * * * root /usr/local/sbin/sync-redos8-repos.sh
EOF
```

`DESTDIR` по умолчанию: `/opt/repos/redos8`.

---

## 7. Bootstrap одной командой

Если файлы Worker уже на сервере:

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

Скрипт ставит пакеты (включая `mod_ssl`), каталоги на `/opt`, firewalld **https**, устанавливает сертификаты и конфиг httpd.

---

## 8. Настройка клиентов (HTTPS + доверие к УЦ)

По [документации РЕД ОС](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/):

1. Клиенты ходят на зеркало по **DNS-имени**.
2. Корневой (и при необходимости промежуточный) сертификат УЦ кладётся в trust store.
3. В `.repo` — `https://…`, **`sslverify=1`** (по умолчанию). `sslverify=0` — только для самоподписанных, **не для УЦ**.

### 8.1. DNS / hosts

```bash
echo '10.0.0.10 repo.example.ru' >> /etc/hosts
ping -c1 repo.example.ru
```

### 8.2. Доверие к вашему УЦ

Скопируйте **корневой CA** (и промежуточный, если нужно) с зеркала или носителя:

```bash
# пример: ca-root.crt от вашего УЦ
install -m 644 /path/to/ca-root.crt /etc/pki/ca-trust/source/anchors/org-ca.crt
# при отдельном промежуточном:
# install -m 644 /path/to/ca-intermediate.crt /etc/pki/ca-trust/source/anchors/org-ca-int.crt

update-ca-trust
update-ca-trust extract
```

Проверка:

```bash
curl -I https://repo.example.ru/repos/redos8/redos8_base_src/repodata/repomd.xml
# без -k, без ошибок сертификата
```

### 8.3. Отключить официальные репозитории

```bash
for f in /etc/yum.repos.d/RedOS-Base.repo /etc/yum.repos.d/RedOS-Updates.repo; do
  [ -f "$f" ] || continue
  sed -i 's/^enabled=1/enabled=0/' "$f"
done
```

### 8.4. Локальные `.repo` (HTTPS)

```bash
cat > /etc/yum.repos.d/RedOS8-Base-local.repo << 'EOF'
[RedOS8-Base-local]
name=Local RED OS 8 Base repo
baseurl=https://repo.example.ru/repos/redos8/redos8_base_src/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT
sslverify=1
enabled=1
EOF

cat > /etc/yum.repos.d/RedOS8-Updates-local.repo << 'EOF'
[RedOS8-Updates-local]
name=Local RED OS 8 Updates repo
baseurl=https://repo.example.ru/repos/redos8/redos8_updates_src/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-RED-SOFT
sslverify=1
enabled=1
EOF
```

Шаблоны: [`docs/configs/local-repo/clients/`](configs/local-repo/clients/).

Скрипт:

```bash
REPO_HOST=repo.example.ru \
PROTO=https \
CA_CERT=/path/to/ca-root.crt \
  bash docs/scripts/local-repo/configure-client.sh
```

### 8.5. Проверка на клиенте

```bash
dnf clean all
dnf makecache
dnf repolist
dnf check-update || true
dnf install -y tree
```

`dnf makecache` должен завершиться **без** SSL-ошибок.

---

## 9. Свой репозиторий внутренних RPM

```bash
mkdir -p /opt/repos/internal/rpms
# cp *.rpm /opt/repos/internal/rpms/
createrepo -v --compress-type=zstd --general-compress-type=zstd /opt/repos/internal/
chown -R root:apache /opt/repos/internal
restorecon -Rv /opt/repos/internal
```

Клиент:

```bash
# baseurl=https://repo.example.ru/repos/internal/
```

---

## 10. Установка РЕД ОС с зеркала

В Anaconda укажите:

- `https://repo.example.ru/repos/redos8/redos8_base_src/`
- при необходимости Updates: `https://repo.example.ru/repos/redos8/redos8_updates_src/`

На этапе установки клиент должен доверять вашему УЦ (или временно использовать HTTP только для инсталлятора — лучше заранее положить CA в образ/kickstart). После установки выполните раздел **8**.

---

## 11. Эксплуатация и типичные ошибки

| Симптом | Причина / действие |
|---------|---------------------|
| `SSL certificate problem: unable to get local issuer` | на клиенте нет CA в `anchors/` → `update-ca-trust extract` |
| `certificate verify failed: hostname mismatch` | `baseurl` не совпадает с CN/SAN; нужен FQDN, не IP (если IP нет в SAN) |
| httpd не стартует, ошибка key | неверный путь/права на `.key` (`600`, root); ключ не от этого `.crt` |
| `AH02565: Certificate and private key do not match` | перепутаны файлы crt/key |
| Цепочка неполная | добавьте `SSLCertificateChainFile` с intermediate от УЦ |
| 404 на `repomd.xml` | не выполнен `createrepo`; неверный путь |
| Клиент качает из Интернета | официальные `.repo` с `enabled=1` |

Проверки на зеркале:

```bash
apachectl configtest
systemctl status httpd --no-pager
df -h /opt
du -sh /opt/repos/redos8/*
curl -I https://repo.example.ru/repos/redos8/redos8_base_src/repodata/repomd.xml
```

---

## 12. Порядок работ «с нуля»

1. Получить от УЦ: `server.crt`, `server.key`, при необходимости `ca-chain.crt` и корневой `ca-root.crt` для клиентов.
2. Выбрать FQDN = имя в сертификате; DNS или `/etc/hosts` → `10.0.0.10`.
3. Место на `/opt` ≥ размера репозиториев (+20–30%).
4. `bootstrap-mirror-server.sh` с `SSL_CRT` / `SSL_KEY` / `REPO_FQDN` **или** вручную разделы 3–5.
5. Source `.repo` + `NEWEST=0 sync-redos8-repos.sh`.
6. На клиентах: hosts, CA в `anchors`, `configure-client.sh` с `PROTO=https`.
7. Cron sync уже на зеркале.

---

## 13. Что подставить под себя

1. **FQDN** из сертификата УЦ и IP зеркала.
2. Пути к вашим `.crt` / `.key` / CA.
3. Префикс сети (`10.0.0.0/8` или `/24`).
4. Редакция `8.0` или `8.0c`.
5. Нужны ли extras / internal RPM.

---

## Ссылки

- [Создание локального репозитория](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo/)
- [Локальный репозиторий HTTPS](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-create-repo-https/)
- [SSL для веб-серверов](https://redos.red-soft.ru/base/redos-8_0/8_0-security/8_0-ssl/8_0-ssl-for-webserv/)
- [Синхронизация](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-repo/8_0-update-repo/)
- [Firewalld](https://redos.red-soft.ru/base/redos-8_0/8_0-network/8_0-sec-firewall/8_0-configuring-firewall/)
