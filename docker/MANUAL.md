# Ручная установка NetBox + MediaWiki в Docker

Пошаговая установка **без** `install.sh`: вы сами создаёте каталоги, копируете файлы, пишете `.env`, поднимаете Compose и настраиваете MediaWiki.

Автоустановка скриптом: [`README.md`](README.md).  
Установка без Docker (пакеты ОС): [`../docs/redos8-netbox-mediawiki.md`](../docs/redos8-netbox-mediawiki.md).

---

## 1. Целевая схема

| Система   | Внешний URL              | Куда проксирует Nginx | Контейнер / порт внутри сети Compose |
|-----------|--------------------------|------------------------|--------------------------------------|
| NetBox    | `https://ХОСТ:443`       | `:443`                 | `netbox:8080`                        |
| MediaWiki | `https://ХОСТ:8443`      | `:8443`                | `mediawiki:80`                       |

### Контейнеры стека

| Сервис          | Образ                              | Назначение                          | Данные (Docker volume)      |
|-----------------|------------------------------------|-------------------------------------|-----------------------------|
| `postgres`      | `postgres:15-alpine`               | БД NetBox                           | `netbox-postgres`           |
| `redis`         | `redis:7-alpine`                   | Очереди и кэш NetBox                | `netbox-redis`              |
| `netbox`        | `netboxcommunity/netbox:v3.7.8`    | Веб NetBox (Gunicorn)               | media / reports / scripts   |
| `netbox-worker` | тот же образ NetBox                | RQ-worker                           | —                           |
| `mediawiki-db`  | `mariadb:10.11`                    | БД MediaWiki                        | `mediawiki-mysql`           |
| `mediawiki`     | `mediawiki:1.39.11`                | PHP + файлы wiki                    | `mediawiki-html`            |
| `nginx`         | `nginx:1.25-alpine`                | TLS и разделение портов             | файлы с хоста (certs, conf) |

Вне сети Docker с хоста доступны **только** порты Nginx (`443` и `8443`). Остальные сервисы слушают внутри bridge-сети Compose.

---

## 2. Карта каталогов на хосте

Всё рабочее дерево стека живёт в одном каталоге установки. Рекомендуемый путь:

```text
/opt/netbox-wiki/                    ← INSTALL_DIR (рабочий каталог Compose)
├── docker-compose.yml               ← описание сервисов
├── .env                             ← секреты и порты (права 600!)
├── CREDENTIALS.txt                  ← ваш список паролей/URL (создаёте сами)
├── certs/
│   ├── server.crt                   ← TLS-сертификат (лучше full chain)
│   └── server.key                   ← приватный ключ (права 600)
├── nginx/
│   ├── netbox.conf                  ← virtual host :443 → netbox:8080
│   └── mediawiki.conf               ← virtual host :8443 → mediawiki:80
└── scripts/                         ← опционально: сниппеты, заметки
    └── mediawiki-proxy-snippet.php
```

### Откуда брать файлы в репозитории

```text
Worker/docker/
├── templates/
│   ├── docker-compose.yml     → копировать в /opt/netbox-wiki/docker-compose.yml
│   ├── env.example            → основа для /opt/netbox-wiki/.env
│   └── nginx/
│       ├── netbox.conf        → /opt/netbox-wiki/nginx/netbox.conf
│       └── mediawiki.conf     → /opt/netbox-wiki/nginx/mediawiki.conf
└── certs/                     → ваши crt/key можно положить сюда до копирования
    ├── server.crt             (опционально)
    └── server.key             (опционально)
```

### Что монтируется в контейнеры

| Путь на хосте                         | Путь в контейнере `nginx`      | Режим |
|---------------------------------------|--------------------------------|-------|
| `/opt/netbox-wiki/nginx/netbox.conf`  | `/etc/nginx/conf.d/netbox.conf`| ro    |
| `/opt/netbox-wiki/nginx/mediawiki.conf` | `/etc/nginx/conf.d/mediawiki.conf` | ro |
| `/opt/netbox-wiki/certs/`             | `/etc/nginx/certs/`            | ro    |

Данные БД и приложений **не** лежат как обычные папки в `/opt/netbox-wiki` — они в именованных Docker volumes (см. раздел 10).

---

## 3. Требования

- ОС: Red OS 8 / RHEL 8+ / Rocky / Alma (или любой Linux с Docker)
- root (или пользователь в группе `docker` + sudo для firewalld)
- Интернет для pull образов (или свой registry)
- Рекомендуемо: ≥ 2 vCPU, ≥ 4 GB RAM, ≥ 20 GB диска
- Свободные порты хоста: `443`, `8443` (или свои — тогда меняете в `.env`)

Подставьте свои значения:

| Плейсхолдер     | Пример                |
|-----------------|------------------------|
| `ХОСТ`          | `dc1.example.local`    |
| `INSTALL_DIR`   | `/opt/netbox-wiki`     |

---

## 4. Установка Docker и Compose вручную

### 4.1. Пакеты из репозиториев ОС (предпочтительно на Red OS)

```bash
dnf install -y curl wget ca-certificates openssl

# вариант A — пакеты ОС
dnf install -y docker docker-compose || dnf install -y moby-engine docker-compose

systemctl enable --now docker
docker --version
docker compose version || docker-compose --version
```

### 4.2. Если пакетов нет — Docker CE

```bash
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
```

### 4.3. Standalone Compose (если плагина нет)

```bash
arch="$(uname -m)"
# x86_64 или aarch64
curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-${arch}" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
docker-compose version
```

Проверка:

```bash
docker info
```

Дальше в примерах используется `docker compose` (v2). Если у вас только v1 — замените на `docker-compose`.

---

## 5. Firewall

```bash
systemctl enable --now firewalld
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=8443/tcp
firewall-cmd --reload
firewall-cmd --list-ports
```

Если порты другие — открывайте те, что укажете в `.env` (`NETBOX_HTTPS_PORT`, `MEDIAWIKI_HTTPS_PORT`).

---

## 6. Создание дерева каталогов

```bash
INSTALL_DIR=/opt/netbox-wiki
mkdir -p "${INSTALL_DIR}/nginx" \
         "${INSTALL_DIR}/certs" \
         "${INSTALL_DIR}/scripts"

# права на каталог установки
chmod 750 "${INSTALL_DIR}"
```

Скопируйте шаблоны из репозитория (путь к клону замените на свой):

```bash
REPO=/path/to/Worker   # куда сделали git clone / scp

cp -f "${REPO}/docker/templates/docker-compose.yml" \
      "${INSTALL_DIR}/docker-compose.yml"

cp -f "${REPO}/docker/templates/nginx/netbox.conf" \
      "${INSTALL_DIR}/nginx/netbox.conf"

cp -f "${REPO}/docker/templates/nginx/mediawiki.conf" \
      "${INSTALL_DIR}/nginx/mediawiki.conf"

cp -f "${REPO}/docker/templates/env.example" \
      "${INSTALL_DIR}/.env"
```

Итог:

```bash
find "${INSTALL_DIR}" -type f | sort
# ожидается:
# /opt/netbox-wiki/.env
# /opt/netbox-wiki/docker-compose.yml
# /opt/netbox-wiki/nginx/mediawiki.conf
# /opt/netbox-wiki/nginx/netbox.conf
```

---

## 7. TLS-сертификаты → `/opt/netbox-wiki/certs/`

Nginx внутри контейнера ждёт **ровно** эти имена:

```text
/opt/netbox-wiki/certs/server.crt
/opt/netbox-wiki/certs/server.key
```

Они прописаны в `nginx/*.conf` как `/etc/nginx/certs/server.crt` и `server.key`.

### Вариант A — свои сертификаты

```bash
# full chain предпочтительнее (server + intermediate)
cp /etc/ssl/certs/server-fullchain.crt /opt/netbox-wiki/certs/server.crt
cp /etc/ssl/private/server.key         /opt/netbox-wiki/certs/server.key

chmod 644 /opt/netbox-wiki/certs/server.crt
chmod 600 /opt/netbox-wiki/certs/server.key
```

CN/SAN сертификата должны совпадать с именем, по которому открываете URL.

### Вариант B — self-signed (лаборатория)

```bash
HOST=dc1.example.local   # ваш хост

openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
  -keyout /opt/netbox-wiki/certs/server.key \
  -out    /opt/netbox-wiki/certs/server.crt \
  -subj "/CN=${HOST}/O=NetBox-Wiki/C=RU" \
  -addext "subjectAltName=DNS:${HOST},DNS:localhost,IP:127.0.0.1"

chmod 600 /opt/netbox-wiki/certs/server.key
chmod 644 /opt/netbox-wiki/certs/server.crt
```

---

## 8. Файл `.env` — что писать и зачем

Файл: **`/opt/netbox-wiki/.env`** (Compose читает его рядом с `docker-compose.yml`).

Сгенерируйте пароли:

```bash
# пароль ~28 символов
openssl rand -base64 48 | tr -d '\n' | tr '+/' 'Aa' | cut -c1-28

# SECRET_KEY NetBox ~64 символа
openssl rand -base64 64 | tr -d '\n' | tr '+/' 'Xx' | cut -c1-64
```

Откройте `.env` и заполните (пример):

```bash
# --- хост и порты ---
INSTALL_HOST=dc1.example.local
ALLOWED_HOSTS=*
NETBOX_HTTPS_PORT=443
MEDIAWIKI_HTTPS_PORT=8443

# --- версии образов ---
NETBOX_IMAGE_TAG=v3.7.8
MEDIAWIKI_IMAGE_TAG=1.39.11

# --- PostgreSQL (контейнер postgres) ---
NETBOX_DB_NAME=netbox
NETBOX_DB_USER=netbox
NETBOX_DB_PASSWORD=СЛОЖНЫЙ_ПАРОЛЬ_PG

# --- NetBox ---
NETBOX_SECRET_KEY=ДЛИННЫЙ_SECRET_KEY
NETBOX_SUPERUSER_NAME=admin
NETBOX_SUPERUSER_EMAIL=admin@dc1.example.local
NETBOX_SUPERUSER_PASSWORD=СЛОЖНЫЙ_ПАРОЛЬ_NETBOX_ADMIN

# --- MariaDB (контейнер mediawiki-db) ---
WIKI_NAME=CorpWiki
WIKI_DB_NAME=mediawiki
WIKI_DB_USER=wiki
WIKI_DB_PASSWORD=СЛОЖНЫЙ_ПАРОЛЬ_WIKI_DB
WIKI_DB_ROOT_PASSWORD=СЛОЖНЫЙ_ПАРОЛЬ_MARIADB_ROOT

# --- учётная запись админа MediaWiki (для install.php) ---
WIKI_ADMIN_USER=WikiAdmin
WIKI_ADMIN_PASSWORD=СЛОЖНЫЙ_ПАРОЛЬ_WIKI_ADMIN
```

```bash
chmod 600 /opt/netbox-wiki/.env
```

### Смысл переменных

| Переменная | Куда попадает | Зачем |
|------------|---------------|--------|
| `NETBOX_HTTPS_PORT` / `MEDIAWIKI_HTTPS_PORT` | publish портов Nginx | внешние HTTPS-порты на хосте |
| `NETBOX_*` DB | env контейнера `postgres` и `netbox` | создание БД и подключение |
| `NETBOX_SECRET_KEY` | env `netbox` / `netbox-worker` | криптоподпись Django |
| `NETBOX_SUPERUSER_*` | env `netbox` | первый админ создаётся при старте образа |
| `ALLOWED_HOSTS` | env NetBox | список Host; `*` — удобно для стенда |
| `WIKI_DB_*` | env `mediawiki-db` | создание БД wiki |
| `WIKI_ADMIN_*` / `WIKI_NAME` | вы вручную в `install.php` | не читаются Compose автоматически |

`INSTALL_HOST` в Compose не подставляется сам — он нужен вам для URL и `$wgServer`.

---

## 9. Запуск стека

```bash
cd /opt/netbox-wiki

docker compose --env-file .env pull
docker compose --env-file .env up -d
docker compose --env-file .env ps
```

Ожидаемые сервисы в статусе `running` / healthy:

- `postgres`, `redis`, `netbox`, `netbox-worker`
- `mediawiki-db`, `mediawiki`
- `nginx`

NetBox при первом старте мигрирует схему БД — это может занять 1–2 минуты.

```bash
# логи, пока поднимается
docker compose --env-file .env logs -f netbox

# проверка с хоста
curl -kI https://127.0.0.1:443/login/
curl -kI https://127.0.0.1:8443/
```

Когда `/login/` отвечает `200`/`302` — NetBox готов.  
Страница wiki до шага 11 может показывать мастер установки MediaWiki — это нормально.

---

## 10. Где лежат данные (Docker volumes)

Имена volumes задаёт Compose (префикс проекта = имя каталога, обычно `netbox-wiki_...`):

| Volume (логический)   | Внутри контейнера                         | Что хранит |
|-----------------------|-------------------------------------------|------------|
| `netbox-postgres`     | `/var/lib/postgresql/data`                | БД NetBox |
| `netbox-redis`        | `/data`                                   | AOF Redis |
| `netbox-media`        | `/opt/netbox/netbox/media`                | вложения NetBox |
| `netbox-reports`      | `/opt/netbox/netbox/reports`              | отчёты |
| `netbox-scripts`      | `/opt/netbox/netbox/scripts`              | кастомные скрипты |
| `mediawiki-mysql`     | `/var/lib/mysql`                          | БД MediaWiki |
| `mediawiki-html`      | `/var/www/html`                           | код wiki + `LocalSettings.php` + `images/` |

Посмотреть на хосте:

```bash
docker volume ls | grep -E 'netbox|mediawiki'
docker volume inspect netbox-wiki_netbox-postgres
# Mountpoint обычно: /var/lib/docker/volumes/<имя>/_data
```

**Важно:** `docker compose down` **без** `-v` контейнеры удаляет, volumes оставляет.  
`docker compose down -v` или `uninstall.sh` — **сотрёт БД и wiki**.

---

## 11. Ручная установка MediaWiki

### 11.1. Права на uploads

```bash
cd /opt/netbox-wiki
docker compose --env-file .env exec -T mediawiki \
  bash -lc 'chown -R www-data:www-data /var/www/html/images || true'
```

### 11.2. Через браузер (проще)

1. Откройте `https://ХОСТ:8443`
2. Мастер установки MediaWiki:
   - **Database type:** MySQL/MariaDB  
   - **Database host:** `mediawiki-db` ← имя сервиса Compose, не localhost  
   - **Database name:** значение `WIKI_DB_NAME` (обычно `mediawiki`)  
   - **Database user / password:** `WIKI_DB_USER` / `WIKI_DB_PASSWORD`  
   - имя wiki, язык `ru`, учётная запись админа  
3. Скачайте `LocalSettings.php`

Положить файл в контейнер:

```bash
# LocalSettings.php лежит у вас, например, в /root/LocalSettings.php
docker compose --env-file .env cp /root/LocalSettings.php mediawiki:/var/www/html/LocalSettings.php
docker compose --env-file .env exec -T mediawiki \
  bash -lc 'chown www-data:www-data /var/www/html/LocalSettings.php; chmod 640 /var/www/html/LocalSettings.php'
```

### 11.3. Через CLI (`maintenance/install.php`)

Подставьте пароли из своего `.env`:

```bash
cd /opt/netbox-wiki
set -a; source .env; set +a

docker compose --env-file .env exec -T mediawiki php maintenance/install.php \
  --server="https://${INSTALL_HOST}:${MEDIAWIKI_HTTPS_PORT}" \
  --scriptpath="" \
  --lang=ru \
  --dbtype=mysql \
  --dbserver=mediawiki-db \
  --dbname="${WIKI_DB_NAME}" \
  --dbuser="${WIKI_DB_USER}" \
  --dbpass="${WIKI_DB_PASSWORD}" \
  --pass="${WIKI_ADMIN_PASSWORD}" \
  "${WIKI_NAME}" "${WIKI_ADMIN_USER}"
```

### 11.4. HTTPS и порт `:8443` в LocalSettings.php

За reverse proxy MediaWiki должна знать внешний URL:

```bash
cd /opt/netbox-wiki
set -a; source .env; set +a

cat > /opt/netbox-wiki/scripts/mediawiki-proxy-snippet.php <<EOF

# Added by netbox-wiki manual install
\$wgServer = "https://${INSTALL_HOST}:${MEDIAWIKI_HTTPS_PORT}";
\$wgCanonicalServer = "https://${INSTALL_HOST}:${MEDIAWIKI_HTTPS_PORT}";
\$wgForceHTTPS = true;
\$wgSecureLogin = true;
if (isset(\$_SERVER["HTTP_X_FORWARDED_PROTO"]) && \$_SERVER["HTTP_X_FORWARDED_PROTO"] === "https") {
  \$_SERVER["HTTPS"] = "on";
}
EOF

docker compose --env-file .env cp \
  /opt/netbox-wiki/scripts/mediawiki-proxy-snippet.php \
  mediawiki:/tmp/mediawiki-proxy-snippet.php

docker compose --env-file .env exec -T mediawiki bash -lc '
LS=/var/www/html/LocalSettings.php
test -f "$LS" || exit 1
if ! grep -q "Added by netbox-wiki" "$LS"; then
  cat /tmp/mediawiki-proxy-snippet.php >> "$LS"
fi
chown www-data:www-data "$LS" 2>/dev/null || true
'

docker compose --env-file .env restart nginx
```

Проверка: `https://ХОСТ:8443` — главная wiki без редиректов на `http://`.

---

## 12. NetBox: вход и проверка

1. Откройте `https://ХОСТ:443` (или `:NETBOX_HTTPS_PORT`)
2. Логин / пароль — `NETBOX_SUPERUSER_NAME` / `NETBOX_SUPERUSER_PASSWORD` из `.env`
3. Суперпользователь создаётся образом NetBox при первом запуске (переменные `SUPERUSER_*`)

Дополнительный суперпользователь (по желанию):

```bash
docker compose --env-file .env exec -it netbox \
  /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py createsuperuser
```

---

## 13. Сохраните креды

Создайте файл вручную (не коммитьте в git):

```bash
cat > /opt/netbox-wiki/CREDENTIALS.txt <<EOF
NetBox:     https://ХОСТ:443
  user/pass: ...
MediaWiki:  https://ХОСТ:8443
  user/pass: ...
DB пароли: см. /opt/netbox-wiki/.env
EOF
chmod 600 /opt/netbox-wiki/CREDENTIALS.txt
```

---

## 14. Управление

Все команды — из `/opt/netbox-wiki`:

```bash
cd /opt/netbox-wiki

docker compose --env-file .env ps
docker compose --env-file .env logs -f netbox
docker compose --env-file .env logs -f mediawiki
docker compose --env-file .env logs -f nginx

docker compose --env-file .env restart nginx
docker compose --env-file .env stop
docker compose --env-file .env start
docker compose --env-file .env down          # остановить, volumes сохранить
docker compose --env-file .env up -d
```

Полное удаление (контейнеры + volumes + каталог): см. [`uninstall.sh`](uninstall.sh) и [`README.md`](README.md).

---

## 15. Сетевая схема (кратко)

```text
Клиент
  │
  ├─ https://ХОСТ:443  ──►  nginx:443   ──proxy──►  netbox:8080
  │                                              ├─ postgres:5432
  │                                              └─ redis:6379
  │
  └─ https://ХОСТ:8443 ──►  nginx:8443  ──proxy──►  mediawiki:80
                                                     └─ mediawiki-db:3306
```

Имена хостов БД внутри Compose: `postgres`, `redis`, `mediawiki-db` — **не** `127.0.0.1` с точки зрения контейнеров приложений.

---

## 16. Чеклист после установки

- [ ] `docker compose ps` — все сервисы Up  
- [ ] `curl -kI https://127.0.0.1:443/login/` — ответ NetBox  
- [ ] `curl -kI https://127.0.0.1:8443/` — ответ MediaWiki  
- [ ] вход в NetBox под суперпользователем  
- [ ] wiki открывается по HTTPS, ссылки не уводят на `http://`  
- [ ] `/opt/netbox-wiki/.env` права `600`  
- [ ] `server.key` права `600`  
- [ ] firewalld открыл нужные порты  
- [ ] креды сохранены вне git  

---

## 17. Типичные проблемы

| Симптом | Что проверить |
|---------|----------------|
| `Cannot connect to Docker daemon` | `systemctl status docker`, группа `docker` |
| Порт занят | `ss -tlnp \| egrep '443\|8443'`, смените порты в `.env` |
| 502 на `:443` | `logs netbox` — идёт миграция; healthcheck postgres/redis |
| Nginx не стартует | нет `certs/server.crt` или `server.key`; `logs nginx` |
| MediaWiki не видит БД | host = `mediawiki-db`, пароль = `WIKI_DB_PASSWORD` |
| Wiki с http-ссылками | блок `$wgServer` в `LocalSettings.php` (шаг 11.4) |
| NetBox `DisallowedHost` | `ALLOWED_HOSTS` в `.env`, затем `compose up -d` |
| Нет доступа извне | firewalld, security groups облака |
| Потеряли данные после `down -v` | volumes удалены — только из бэкапа |

Диагностика:

```bash
cd /opt/netbox-wiki
docker compose --env-file .env ps
docker compose --env-file .env logs --tail=200 netbox
docker compose --env-file .env logs --tail=200 mediawiki
docker compose --env-file .env logs --tail=100 nginx
docker compose --env-file .env exec nginx nginx -t
ls -la certs/ nginx/ .env
```

---

## 18. Связь с автоустановкой

| Действие | Вручную (этот документ) | Автоматически |
|----------|-------------------------|---------------|
| Docker | раздел 4 | `install.sh` |
| Каталоги / копирование | разделы 6–7 | `install.sh` |
| `.env` и пароли | раздел 8 | генерирует `install.sh` |
| Compose up | раздел 9 | `install.sh` |
| MediaWiki | раздел 11 | `install.php` в `install.sh` |
| Удаление | `compose down -v` + `rm -rf` | `uninstall.sh` |

Шаблоны одни и те же: `docker/templates/*`. Ручная установка использует их напрямую в `/opt/netbox-wiki`.
