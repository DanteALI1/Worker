# Установка NetBox на РЕД ОС 8

Поэтапное развёртывание NetBox на **пустом** сервере РЕД ОС 8: пакеты и обновления → PostgreSQL/Redis → приложение в `/opt/netbox` → Gunicorn/systemd → nginx HTTPS → firewalld → SELinux.

| Параметр | Значение |
|---|---|
| ОС | РЕД ОС 8 |
| IP NetBox | `10.0.130.10` (по умолчанию) |
| HTTPS | только с IP, который вы укажете |
| Каталог | `/opt/netbox` |
| Стек | PostgreSQL, Redis, Python 3.10+, Gunicorn, nginx |

Автоматизация: [`scripts/netbox/install-netbox-redos8.sh`](scripts/netbox/install-netbox-redos8.sh) — полный интерактивный скрипт (на каждом этапе спрашивает данные).

---

## Быстрый старт

На сервере NetBox (`10.0.130.10`), от **root**:

```bash
# скопируйте каталог docs/scripts/netbox/ на сервер, затем:
cd /path/to/netbox
chmod +x install-netbox-redos8.sh
bash install-netbox-redos8.sh
```

Скрипт последовательно пройдёт этапы 0–10 ниже и сохранит ответы в `/var/lib/netbox-install/answers.env`.

---

## Архитектура

```
Клиент (ваш IP)
    │  HTTPS :443 (firewalld rich-rule + nginx allow)
    ▼
 nginx (TLS)  ──►  gunicorn 127.0.0.1:8001  ──►  NetBox (/opt/netbox)
                      │
                      ├── PostgreSQL (localhost)
                      └── Redis (localhost, DB 0 tasks / DB 1 cache)
```

---

## Этап 0. Подготовка и данные, которые понадобятся

Заранее определите:

| Данные | Пример | Где используется |
|---|---|---|
| IP сервера NetBox | `10.0.130.10` | сеть, сертификат, ALLOWED_HOSTS |
| IP клиента для HTTPS | `10.0.130.50` | firewalld + nginx `allow` |
| FQDN (или тот же IP) | `netbox.example.local` | сертификат, Host |
| Версия NetBox | `v4.2.9` | GitHub release |
| Пароль БД / админа | — | PostgreSQL, Django |

Доступ в интернет (GitHub, репозитории РЕД ОС) или зеркало пакетов обязателен.

Проверка ОС:

```bash
cat /etc/red-release
uname -a
ip -br a
```

---

## Этап 1. Обновления и базовые пакеты

```bash
dnf -y update

dnf -y install \
  curl wget git tar unzip openssl ca-certificates \
  policycoreutils policycoreutils-python-utils setools-console \
  firewalld chrony which \
  gcc gcc-c++ make \
  libffi-devel openssl-devel bzip2-devel readline-devel \
  sqlite-devel zlib-devel libjpeg-turbo-devel \
  libxml2-devel libxslt-devel openldap-devel redhat-rpm-config

systemctl enable --now chronyd firewalld
```

---

## Этап 2. Python (≥ 3.10)

NetBox 4.2.x работает с Python 3.10/3.11; свежие ветки 4.5+ требуют 3.12+.

```bash
dnf -y install python3 python3-pip python3-devel
dnf -y install python3.11 python3.11-devel python3.11-pip   # если есть в репо
# либо python3.12*, если доступен

python3.11 -V   # или python3.12 / python3
```

Запомните путь интерпретатора — он передаётся в `upgrade.sh` как `PYTHON=...`.

---

## Этап 3. PostgreSQL

```bash
# предпочтительно 14/15/16, если есть в репозитории РЕД ОС
dnf -y install postgresql15-server postgresql15
# иначе: dnf -y install postgresql-server postgresql

postgresql-15-setup initdb    # либо postgresql-setup --initdb
systemctl enable --now postgresql-15
```

Создание БД (подставьте свои значения):

```bash
sudo -u postgres psql <<'SQL'
CREATE ROLE netbox WITH LOGIN PASSWORD 'ВАШ_ПАРОЛЬ_БД';
CREATE DATABASE netbox OWNER netbox;
GRANT ALL PRIVILEGES ON DATABASE netbox TO netbox;
\c netbox
GRANT ALL ON SCHEMA public TO netbox;
ALTER SCHEMA public OWNER TO netbox;
SQL
```

---

## Этап 4. Redis

```bash
dnf -y install redis
# bind 127.0.0.1 в /etc/redis.conf или /etc/redis/redis.conf
systemctl enable --now redis
redis-cli ping   # PONG
```

NetBox использует **две** логические БД Redis: `0` (tasks) и `1` (caching).

---

## Этап 5. Пользователь и код в `/opt/netbox`

```bash
groupadd --system netbox
useradd --system --gid netbox --home-dir /opt/netbox \
  --shell /sbin/nologin netbox

VER=v4.2.9
curl -fL -o /tmp/netbox.tgz \
  "https://github.com/netbox-community/netbox/archive/refs/tags/${VER}.tar.gz"
mkdir -p /opt/netbox
tar -xzf /tmp/netbox.tgz -C /tmp
mv /tmp/netbox-*/* /opt/netbox/
chown -R netbox:netbox /opt/netbox
```

---

## Этап 6. `configuration.py`, venv, миграции

```bash
cp /opt/netbox/netbox/netbox/configuration_example.py \
   /opt/netbox/netbox/netbox/configuration.py
```

Минимум в `configuration.py`:

- `ALLOWED_HOSTS` — IP/FQDN сервера  
- `DATABASE` / `DATABASES` — PostgreSQL  
- `REDIS` — tasks + caching  
- `SECRET_KEY` — случайная строка ≥ 50 символов  
- за прокси: `SECURE_PROXY_SSL_HEADER`, `USE_X_FORWARDED_*`

```bash
cd /opt/netbox
PYTHON=/usr/bin/python3.11 ./upgrade.sh

# суперпользователь
sudo -u netbox /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py createsuperuser
```

Скопируйте `contrib/gunicorn.py` → `/opt/netbox/gunicorn.py`, bind: `127.0.0.1:8001`.

---

## Этап 7. systemd

```bash
cp /opt/netbox/contrib/netbox.service /etc/systemd/system/
cp /opt/netbox/contrib/netbox-rq.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now netbox netbox-rq
systemctl status netbox
# при ошибке: journalctl -eu netbox
```

---

## Этап 8. nginx + HTTPS

```bash
dnf -y install nginx

# самоподписанный сертификат (лаборатория)
openssl req -x509 -nodes -newkey rsa:4096 -days 825 \
  -keyout /etc/pki/tls/private/netbox.key \
  -out /etc/pki/tls/certs/netbox.crt \
  -subj "/CN=10.0.130.10" \
  -addext "subjectAltName=IP:10.0.130.10"
```

Конфиг: [`configs/netbox/nginx-netbox.conf`](configs/netbox/nginx-netbox.conf)  
(подставьте свой `ALLOWED_CLIENT_IP`).

```bash
cp nginx-netbox.conf /etc/nginx/conf.d/netbox.conf
nginx -t
systemctl enable --now nginx
```

HTTP :80 → редирект на HTTPS. Статика: `/opt/netbox/netbox/static/`.

---

## Этап 9. firewalld

Доступ **только** с вашего клиентского IP:

```bash
CLIENT=10.0.130.50   # ← ваш IP

firewall-cmd --permanent --remove-service=https || true
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${CLIENT} port port=443 protocol=tcp accept"
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${CLIENT} port port=80 protocol=tcp accept"
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload
firewall-cmd --list-all
```

---

## Этап 10. SELinux

Рекомендуется оставить **enforcing**.

```bash
setsebool -P httpd_can_network_connect 1

semanage fcontext -a -t httpd_sys_content_t '/opt/netbox/netbox/static(/.*)?'
restorecon -Rv /opt/netbox/netbox/static

# локальный модуль (nginx → gunicorn на high port) — см. скрипт
# /var/lib/netbox-install/selinux/netbox_local.te

# режим
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
setenforce 1
getenforce
```

При отказах AVC:

```bash
ausearch -m avc -ts recent
# или
grep denied /var/log/audit/audit.log | audit2allow -M netbox_fix
semodule -i netbox_fix.pp
```

Черновик модуля: [`configs/netbox/netbox_local.te`](configs/netbox/netbox_local.te).

---

## Сеть (IP 10.0.130.10)

Если адрес ещё не назначен (NetworkManager):

```bash
nmcli con show
nmcli con mod "ИМЯ_СОЕДИНЕНИЯ" \
  ipv4.addresses 10.0.130.10/24 \
  ipv4.gateway 10.0.130.1 \
  ipv4.method manual
nmcli con up "ИМЯ_СОЕДИНЕНИЯ"
```

Скрипт может сделать это интерактивно в финале.

---

## Проверка

С разрешённого клиента:

```bash
curl -kI https://10.0.130.10/
# браузер: https://10.0.130.10/  (принять self-signed при необходимости)
```

На сервере:

```bash
systemctl status netbox netbox-rq nginx redis
ss -lntp | egrep '443|8001|5432|6379'
getenforce
```

---

## Файлы в репозитории

| Путь | Назначение |
|---|---|
| [`scripts/netbox/install-netbox-redos8.sh`](scripts/netbox/install-netbox-redos8.sh) | Полный интерактивный установщик |
| [`scripts/netbox/README.md`](scripts/netbox/README.md) | Краткая шпаргалка по скрипту |
| [`configs/netbox/nginx-netbox.conf`](configs/netbox/nginx-netbox.conf) | Шаблон nginx HTTPS |
| [`configs/netbox/netbox_local.te`](configs/netbox/netbox_local.te) | SELinux policy module |

Секреты после установки: `/var/lib/netbox-install/answers.env` (`chmod 600`).

---

## Типичные проблемы

| Симптом | Что проверить |
|---|---|
| `netbox.service` failed | `journalctl -eu netbox`, пароль БД, Redis, Python-версия |
| 502 Bad Gateway | gunicorn слушает `127.0.0.1:8001`, `httpd_can_network_connect`, SELinux AVC |
| Timeout / нет доступа | rich-rule firewalld, `allow` в nginx, маршрут до `10.0.130.10` |
| Статика 403/404 | `restorecon` на `/opt/netbox/netbox/static`, alias в nginx |
| `upgrade.sh` падает на pip | devel-пакеты, доступ к PyPI / зеркало |
