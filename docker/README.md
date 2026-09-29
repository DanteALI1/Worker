# Docker: NetBox + MediaWiki (полная автоустановка)

Установка на **чистый** сервер (Red OS 8 / RHEL-подобные): скрипт сам ставит Docker, поднимает стек, генерирует пароли и в конце пишет всё в файл.

## Что получите

| Система   | URL                        |
|-----------|----------------------------|
| NetBox    | `https://ХОСТ:443`         |
| MediaWiki | `https://ХОСТ:8443`        |

Внутри Docker Compose:

- NetBox + PostgreSQL 15 + Redis + worker  
- MediaWiki + MariaDB  
- Nginx (TLS, ваши сертификаты или self-signed)

## Быстрый старт

На сервере от **root**:

```bash
# 1) скопируйте каталог docker/ на сервер (git clone / scp)
cd /path/to/Worker/docker

# 2) (опционально) положите свои сертификаты:
#    docker/certs/server.crt
#    docker/certs/server.key
#    или передайте пути через CERT_FILE / KEY_FILE

# 3) запуск
bash install.sh
```

В конце скрипт выведет креды и сохранит их в:

```text
/opt/netbox-wiki/CREDENTIALS.txt
```

Также создаётся `/opt/netbox-wiki/.env` (права `600`).

## Свои сертификаты

Вариант A — файлы в репозитории перед запуском:

```text
docker/certs/server.crt
docker/certs/server.key
```

Вариант B — переменные окружения:

```bash
CERT_FILE=/etc/ssl/certs/fullchain.pem \
KEY_FILE=/etc/ssl/private/privkey.pem \
bash install.sh
```

Если сертификаты не указаны, будет выпущен **self-signed** на имя хоста.

## Параметры запуска

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `INSTALL_DIR` | `/opt/netbox-wiki` | Куда положить compose/.env/креды |
| `INSTALL_HOST` | hostname сервера | Имя в URL и сертификате |
| `NETBOX_HTTPS_PORT` | `443` | Внешний порт NetBox |
| `MEDIAWIKI_HTTPS_PORT` | `8443` | Внешний порт MediaWiki |
| `NETBOX_IMAGE_TAG` | `v3.7.8` | Тег образа NetBox |
| `MEDIAWIKI_IMAGE_TAG` | `1.39.11` | Тег образа MediaWiki |
| `WIKI_NAME` | `CorpWiki` | Название wiki |
| `NETBOX_SUPERUSER_NAME` | `admin` | Логин NetBox |
| `WIKI_ADMIN_USER` | `WikiAdmin` | Логин MediaWiki |
| `SKIP_DOCKER_INSTALL` | `0` | `1` = не ставить Docker |
| `CERT_FILE` / `KEY_FILE` | — | Пути к вашим TLS-файлам |

Пример:

```bash
INSTALL_HOST=dc1.example.local \
NETBOX_HTTPS_PORT=443 \
MEDIAWIKI_HTTPS_PORT=8443 \
CERT_FILE=/root/tls/server.crt \
KEY_FILE=/root/tls/server.key \
bash install.sh
```

## Что делает `install.sh`

1. Проверяет root  
2. Ставит Docker + Compose (dnf/yum или Docker CE), если их нет  
3. Открывает порты в firewalld  
4. Копирует `docker-compose.yml` и nginx-конфиги в `INSTALL_DIR`  
5. Готовит TLS  
6. Генерирует все пароли и `SECRET_KEY`, пишет `.env`  
7. `docker compose pull && up -d`  
8. Ждёт NetBox, автоматически ставит MediaWiki (`install.php`)  
9. Прописывает `$wgServer` под HTTPS и порт  
10. Пишет `CREDENTIALS.txt` и печатает его в консоль  

Повторный запуск: если `LocalSettings.php` уже есть, MediaWiki повторно не ставится.  
`.env` при повторном запуске **перезаписывается** новыми паролями — не запускайте install.sh повторно на боевом стенде без бэкапа. Для перезапуска стека используйте `docker compose up -d` в `INSTALL_DIR`.

## Управление после установки

```bash
cd /opt/netbox-wiki
docker compose --env-file .env ps
docker compose --env-file .env logs -f netbox
docker compose --env-file .env restart nginx
docker compose --env-file .env down
docker compose --env-file .env up -d
```

## Структура

```text
docker/
  install.sh                 # главный установщик
  certs/                     # ваши server.crt / server.key (опционально)
  templates/
    docker-compose.yml
    env.example
    nginx/netbox.conf
    nginx/mediawiki.conf
  README.md
```

## Требования к серверу

- Red OS 8 / RHEL 8+ / Rocky / Alma (минимальная установка ок)  
- доступ в интернет для образов Docker (или свой registry)  
- рекомендуемо: ≥ 2 vCPU, ≥ 4 GB RAM, ≥ 20 GB диска  

## Устранение проблем

```bash
cd /opt/netbox-wiki
docker compose --env-file .env ps
docker compose --env-file .env logs --tail=200 netbox
docker compose --env-file .env logs --tail=200 mediawiki
docker compose --env-file .env logs --tail=100 nginx
cat install.log
cat CREDENTIALS.txt
```

- **502 на :443** — NetBox ещё мигрирует БД; подождите 1–2 минуты, смотрите `logs netbox`  
- **SSL ошибка** — проверьте chain в `certs/server.crt`, CN/SAN  
- **Wiki с http-ссылками** — проверьте блок `Added by netbox-wiki` в `LocalSettings.php`  
- **Нет доступа извне** — `firewall-cmd --list-ports`, security groups  
