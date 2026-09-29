# Установка NetBox и MediaWiki на Red OS 8

Подробная пошаговая инструкция для сервера **Red OS 8** (минимальная конфигурация, без полного обновления системы).  
Оба сервиса ставятся на **один** хост и разделяются по **портам** через Nginx + ваши SSL-сертификаты.

## Целевая схема

| Система   | URL                         | Внутри сервера                          |
|-----------|-----------------------------|-----------------------------------------|
| NetBox    | `https://ВАШ_ХОСТ:443`      | Gunicorn `127.0.0.1:8001`               |
| MediaWiki | `https://ВАШ_ХОСТ:8443`     | PHP-FPM + файлы в `/var/www/mediawiki`  |

Порты можно заменить (например `8443` / `8444`) — главное открыть их в firewalld и прописать в Nginx.

### Расположение сертификатов (пример)

```text
/etc/ssl/private/server.key
/etc/ssl/certs/server.crt
/etc/ssl/certs/ca-chain.crt   # если есть цепочка
```

Права:

```bash
chmod 600 /etc/ssl/private/server.key
chown root:root /etc/ssl/private/server.key /etc/ssl/certs/server.crt
```

---

## 0. Подготовка

```bash
# hostname и время
hostnamectl set-hostname netbox-wiki.example.local
timedatectl set-timezone Europe/Moscow

# базовые пакеты (без полного dnf update)
dnf install -y epel-release || true
dnf install -y git wget curl tar gzip gcc make openssl openssl-devel \
  libffi-devel zlib-devel bzip2-devel readline-devel sqlite-devel \
  libxml2-devel libxslt-devel libpq-devel redhat-rpm-config \
  policycoreutils-python-utils

# SELinux: веб-серверу разрешаем ходить в сеть/к БД
setsebool -P httpd_can_network_connect 1
setsebool -P httpd_can_network_connect_db 1

# firewall
systemctl enable --now firewalld
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=8443/tcp
firewall-cmd --reload
```

Проверьте доступные модули:

```bash
python3 --version
dnf module list python* postgresql* php redis nginx mariadb 2>/dev/null | head -80
```

### Важно для Red OS 8 / «без обновлений»

- Свежий NetBox 4.5+ требует **Python 3.12+** и **PostgreSQL 15+**.
- В базовых репозиториях RHEL 8 / Red OS 8 часто есть Python 3.9 и PostgreSQL 12/13.

Практичный путь для такого сервера:

- **NetBox 3.7.x** + Python 3.9 + PostgreSQL 13 — стабильно ставится из модулей.
- Либо Python 3.12 из исходников и PostgreSQL 15 (PGDG) — см. раздел «NetBox 4.x» в конце.

Ниже основная инструкция под **NetBox 3.7.8**.

---

## 1. PostgreSQL (для NetBox)

```bash
dnf module reset postgresql -y
dnf module enable postgresql:13 -y   # если 13 нет — попробуйте 12
dnf install -y postgresql-server postgresql

postgresql-setup --initdb
systemctl enable --now postgresql
```

Создайте БД и пользователя:

```bash
sudo -u postgres psql <<'SQL'
CREATE DATABASE netbox;
CREATE USER netbox WITH PASSWORD 'СЛОЖНЫЙ_ПАРОЛЬ_NETBOX';
ALTER DATABASE netbox OWNER TO netbox;
GRANT ALL PRIVILEGES ON DATABASE netbox TO netbox;
\c netbox
GRANT CREATE ON SCHEMA public TO netbox;
SQL
```

Проверка аутентификации (часто нужно `md5` или `scram-sha-256` для localhost в `pg_hba.conf`):

```bash
# отредактируйте /var/lib/pgsql/data/pg_hba.conf при необходимости
systemctl restart postgresql
psql -U netbox -h 127.0.0.1 -d netbox -W
```

---

## 2. Redis (для NetBox)

```bash
dnf install -y redis
systemctl enable --now redis
redis-cli ping   # ожидается PONG
```

---

## 3. Установка NetBox

```bash
dnf module enable python39 -y 2>/dev/null || true
dnf install -y python39 python39-devel python39-pip

useradd --system --shell /sbin/nologin --home-dir /opt/netbox netbox

cd /opt
wget https://github.com/netbox-community/netbox/archive/refs/tags/v3.7.8.tar.gz
tar -xzf v3.7.8.tar.gz
ln -s netbox-3.7.8 netbox
chown -R netbox:netbox /opt/netbox /opt/netbox-3.7.8
```

Конфиг:

```bash
cp /opt/netbox/netbox/netbox/configuration_example.py \
   /opt/netbox/netbox/netbox/configuration.py
```

Отредактируйте `/opt/netbox/netbox/netbox/configuration.py`:

```python
ALLOWED_HOSTS = ['ВАШ_ХОСТ', 'IP_СЕРВЕРА', 'localhost']

DATABASE = {
    'NAME': 'netbox',
    'USER': 'netbox',
    'PASSWORD': 'СЛОЖНЫЙ_ПАРОЛЬ_NETBOX',
    'HOST': '127.0.0.1',
    'PORT': '',
    'CONN_MAX_AGE': 300,
}

REDIS = {
    'tasks': {
        'HOST': '127.0.0.1',
        'PORT': 6379,
        'PASSWORD': '',
        'DATABASE': 0,
        'SSL': False,
    },
    'caching': {
        'HOST': '127.0.0.1',
        'PORT': 6379,
        'PASSWORD': '',
        'DATABASE': 1,
        'SSL': False,
    }
}
```

SECRET_KEY:

```bash
cd /opt/netbox/netbox
python3.9 ../netbox/generate_secret_key.py
# вставьте результат в configuration.py → SECRET_KEY = '...'
```

Установка зависимостей:

```bash
cd /opt/netbox
PYTHON=/usr/bin/python3.9 ./upgrade.sh
```

Gunicorn:

```bash
cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py
# bind обычно 127.0.0.1:8001 — проверьте
```

Systemd:

```bash
cp /opt/netbox/contrib/netbox.service /etc/systemd/system/
cp /opt/netbox/contrib/netbox-rq.service /etc/systemd/system/
# если в unit указан неверный python — поправьте ExecStart на venv:
# /opt/netbox/venv/bin/gunicorn ...

systemctl daemon-reload
systemctl enable --now netbox netbox-rq
systemctl status netbox netbox-rq
```

Суперпользователь:

```bash
source /opt/netbox/venv/bin/activate
cd /opt/netbox/netbox
python3 manage.py createsuperuser
```

---

## 4. MariaDB + PHP + MediaWiki

```bash
dnf install -y mariadb-server
systemctl enable --now mariadb
mysql_secure_installation
```

БД wiki:

```bash
mysql -u root -p <<'SQL'
CREATE DATABASE mediawiki CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wiki'@'localhost' IDENTIFIED BY 'СЛОЖНЫЙ_ПАРОЛЬ_WIKI';
GRANT ALL PRIVILEGES ON mediawiki.* TO 'wiki'@'localhost';
FLUSH PRIVILEGES;
SQL
```

PHP (для MediaWiki 1.39 LTS удобен PHP 7.4):

```bash
dnf module reset php -y
dnf module enable php:7.4 -y
dnf install -y php php-fpm php-mysqlnd php-gd php-xml php-mbstring \
  php-json php-intl php-apcu php-opcache
systemctl enable --now php-fpm
```

MediaWiki:

```bash
cd /tmp
wget https://releases.wikimedia.org/mediawiki/1.39/mediawiki-1.39.11.tar.gz
# при необходимости возьмите актуальный 1.39.x с releases.wikimedia.org
tar -xzf mediawiki-1.39.11.tar.gz
mkdir -p /var/www
mv mediawiki-1.39.11 /var/www/mediawiki
chown -R nginx:nginx /var/www/mediawiki
```

Проверьте `/etc/php-fpm.d/www.conf`:

```ini
user = nginx
group = nginx
listen = /run/php-fpm/www.sock
listen.owner = nginx
listen.group = nginx
```

```bash
systemctl restart php-fpm
```

---

## 5. Nginx: два порта → две системы

```bash
dnf install -y nginx
```

### `/etc/nginx/conf.d/netbox.conf`

```nginx
server {
    listen 443 ssl http2;
    server_name ВАШ_ХОСТ;

    ssl_certificate     /etc/ssl/certs/server.crt;
    ssl_certificate_key /etc/ssl/private/server.key;
    # если есть цепочка — объедините crt+chain в один файл (см. ниже)

    client_max_body_size 25m;

    location /static/ {
        alias /opt/netbox/netbox/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
    }
}
```

### `/etc/nginx/conf.d/mediawiki.conf`

```nginx
server {
    listen 8443 ssl http2;
    server_name ВАШ_ХОСТ;

    ssl_certificate     /etc/ssl/certs/server.crt;
    ssl_certificate_key /etc/ssl/private/server.key;

    root /var/www/mediawiki;
    index index.php;

    client_max_body_size 32m;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        try_files $uri =404;
        expires 7d;
    }

    location ~ ^/(cache|includes|maintenance|languages|vendor)/ {
        deny all;
    }
}
```

Полная цепочка сертификата (если нужно):

```bash
cat /etc/ssl/certs/server.crt /etc/ssl/certs/ca-chain.crt \
  > /etc/ssl/certs/server-fullchain.crt
# укажите server-fullchain.crt в ssl_certificate
```

SELinux для порта и путей:

```bash
semanage port -a -t http_port_t -p tcp 8443 2>/dev/null || \
semanage port -m -t http_port_t -p tcp 8443

semanage fcontext -a -t httpd_sys_content_t "/var/www/mediawiki(/.*)?"
semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/mediawiki/images(/.*)?"
restorecon -Rv /var/www/mediawiki

semanage fcontext -a -t httpd_sys_content_t "/opt/netbox/netbox/static(/.*)?"
restorecon -Rv /opt/netbox/netbox/static
setsebool -P httpd_can_network_connect 1
```

Запуск Nginx:

```bash
nginx -t
systemctl enable --now nginx
systemctl restart nginx
```

Проверка:

```bash
curl -kI https://127.0.0.1:443
curl -kI https://127.0.0.1:8443
ss -tlnp | egrep '443|8443|8001|9000|5432|6379'
```

---

## 6. Доводка MediaWiki через браузер

1. Откройте `https://ВАШ_ХОСТ:8443`.
2. Мастер установки:
   - БД: MariaDB, host `localhost`, DB `mediawiki`, user `wiki`, ваш пароль;
   - имя wiki, учётная запись администратора.
3. Скачайте `LocalSettings.php` и положите на сервер:

```bash
cp LocalSettings.php /var/www/mediawiki/
chown nginx:nginx /var/www/mediawiki/LocalSettings.php
chmod 640 /var/www/mediawiki/LocalSettings.php
```

В `LocalSettings.php` для HTTPS на нестандартном порту:

```php
$wgServer = "https://ВАШ_ХОСТ:8443";
$wgCanonicalServer = "https://ВАШ_ХОСТ:8443";
```

---

## 7. Доводка NetBox за reverse proxy

В `configuration.py` должен быть корректный `ALLOWED_HOSTS`.  
Для HTTPS-ссылок обычно достаточно заголовков Nginx `X-Forwarded-Proto` и `Host`.

Проверка: `https://ВАШ_ХОСТ:443` → вход суперпользователя NetBox.

---

## 8. Автозапуск и чеклист

```bash
systemctl enable --now postgresql redis mariadb php-fpm nginx netbox netbox-rq
systemctl --failed
journalctl -u netbox -u nginx -u php-fpm -xe --no-pager | tail -100
```

Итоговые URL:

- NetBox → `https://сервер:443`
- MediaWiki → `https://сервер:8443`

---

## Если нужен NetBox 4.x на Red OS 8

1. Соберите Python 3.12 из исходников в `/usr/local`.
2. Поставьте PostgreSQL 15+ (PGDG или пакеты Red OS, если есть).
3. Установите свежий release с GitHub и выполните  
   `PYTHON=/usr/local/bin/python3.12 ./upgrade.sh`.
4. Gunicorn, systemd и Nginx на `:443` — как выше.

Без обновлений и без внешних репозиториев этот путь обычно сложнее, чем NetBox 3.7.

---

## Типичные проблемы

| Симптом | Что проверить |
|---------|----------------|
| 502 на `:443` | `systemctl status netbox`, порт `8001`, SELinux `httpd_can_network_connect` |
| 502/404 PHP на `:8443` | socket php-fpm, `user`/`group` nginx, права на `/var/www/mediawiki` |
| SSL ошибка у клиента | полный chain в `ssl_certificate`, совпадение CN/SAN с URL |
| NetBox `DisallowedHost` | `ALLOWED_HOSTS` |
| Wiki с кривыми ссылками | `$wgServer` с портом `:8443` |
| firewall режет доступ | `firewall-cmd --list-ports` |

---

## Готовые фрагменты конфигов

В каталоге [`docs/configs/`](configs/) лежат шаблоны Nginx для копирования на сервер:

- `netbox.conf` — порт 443 → NetBox
- `mediawiki.conf` — порт 8443 → MediaWiki

Перед использованием замените `ВАШ_ХОСТ` и пути к сертификатам.

---

## Альтернатива: Docker

Автоустановка на чистый сервер (скрипт ставит Docker, генерирует пароли, пишет `CREDENTIALS.txt`):

→ [`docker/README.md`](../docker/README.md)
