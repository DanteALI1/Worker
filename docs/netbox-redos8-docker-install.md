# NetBox в Docker на РЕД ОС 8 (от А до Я)

Полная установка на **пустом** сервере: обновления → Docker Engine → SELinux → проект `netbox-docker` в `/opt/netbox-docker` → PostgreSQL/Redis в контейнерах → HTTPS (nginx на хосте) → firewalld (доступ только с вашего IP).

| Параметр | Значение |
|---|---|
| ОС | РЕД ОС 8 |
| IP NetBox | `10.0.130.10` (по умолчанию) |
| HTTPS | только с IP, который вы укажете |
| Каталог проекта | `/opt/netbox-docker` |
| Образ | `netboxcommunity/netbox` (проект [netbox-docker](https://github.com/netbox-community/netbox-docker)) |
| Публикация приложения | `127.0.0.1:8080` → nginx `:443` |

Автоматизация: [`scripts/netbox/install-netbox-docker-redos8.sh`](scripts/netbox/install-netbox-docker-redos8.sh).

> Классическая установка без Docker: [`netbox-redos8-install.md`](netbox-redos8-install.md).

---

## Быстрый старт

На сервере (`10.0.130.10`), от **root**:

```bash
cd /path/to/docs/scripts/netbox
chmod +x install-netbox-docker-redos8.sh
bash install-netbox-docker-redos8.sh
```

Скрипт на каждом этапе запрашивает данные и сохраняет ответы в `/var/lib/netbox-docker-install/answers.env`.

---

## Архитектура

```
Клиент (ваш IP)
    │  HTTPS :443  (firewalld rich-rule + nginx allow)
    ▼
 nginx на хосте (TLS)
    │  proxy → 127.0.0.1:8080
    ▼
 Docker Compose (/opt/netbox-docker)
    ├── netbox
    ├── netbox-worker
    ├── postgres
    ├── redis (tasks)
    └── redis-cache
```

Контейнеры **не** слушают внешний интерфейс напрямую — наружу открыт только nginx.

---

## Этап A. Подготовка данных

| Данные | Пример |
|---|---|
| IP сервера NetBox | `10.0.130.10` |
| IP клиента для HTTPS | `10.0.130.50` |
| FQDN (или IP) | `netbox.example.local` |
| Ветка netbox-docker | `release` |
| Пароли БД / Redis / SECRET_KEY | генерируются скриптом |
| Админ NetBox | логин, e-mail, пароль |

Нужны: доступ к репозиториям РЕД ОС, Docker Hub (или зеркало), GitHub.

```bash
cat /etc/red-release
ip -br a
```

---

## Этап B. Обновление системы

```bash
dnf -y update

dnf -y install \
  curl wget git tar unzip openssl ca-certificates \
  policycoreutils policycoreutils-python-utils setools-console \
  firewalld chrony which yum-utils device-mapper-persistent-data lvm2

systemctl enable --now chronyd firewalld
```

---

## Этап C. Установка Docker Engine + Compose

На РЕД ОС 8 пакеты могут называться по-разному. Порядок попыток:

### Вариант 1 — пакеты РЕД ОС / совместимые

```bash
dnf -y install docker docker-compose
# или
dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

### Вариант 2 — Docker CE (если подключён репозиторий Docker)

```bash
dnf -y install dnf-plugins-core
# при наличии docker-ce.repo:
dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### Запуск

```bash
systemctl enable --now docker
docker version
docker compose version   # предпочтительно plugin
# либо: docker-compose version
```

Проверка:

```bash
docker run --rm hello-world
```

---

## Этап D. SELinux для Docker

Рекомендуется оставить **enforcing**.

```bash
getenforce

# Docker + nginx reverse-proxy к контейнеру на localhost
setsebool -P container_manage_cgroup 1 || true
setsebool -P httpd_can_network_connect 1

# Если используете docker с SELinux labels (по умолчанию)
# тома netbox-docker монтируются с флагом :z в compose — это нормально

sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
setenforce 1
getenforce
```

При AVC после `docker compose up`:

```bash
ausearch -m avc -ts recent
grep denied /var/log/audit/audit.log | audit2allow -M netbox_docker
semodule -i netbox_docker.pp
```

Черновик модуля для nginx→localhost: [`configs/netbox/netbox_local.te`](configs/netbox/netbox_local.te).

---

## Этап E. Клонирование netbox-docker в `/opt`

```bash
mkdir -p /opt
cd /opt
git clone -b release https://github.com/netbox-community/netbox-docker.git
cd /opt/netbox-docker
```

Структура важного:

| Путь | Назначение |
|---|---|
| `docker-compose.yml` | сервисы NetBox, Postgres, Redis |
| `docker-compose.override.yml` | порты, суперпользователь (создаёте вы) |
| `env/netbox.env` | SECRET_KEY, DB_*, REDIS_*, ALLOWED_HOSTS-логика через конфиг |
| `env/postgres.env` | пароль PostgreSQL |
| `env/redis.env`, `env/redis-cache.env` | пароли Redis |

---

## Этап F. Секреты и env

**Обязательно замените** демо-пароли из репозитория на свои.

```bash
# Пример генерации
openssl rand -base64 32
```

В `env/postgres.env`:

```env
POSTGRES_DB=netbox
POSTGRES_USER=netbox
POSTGRES_PASSWORD=<сильный_пароль>
```

В `env/redis.env` / `env/redis-cache.env` — `REDIS_PASSWORD=...` (могут отличаться).

В `env/netbox.env` синхронизируйте:

- `DB_PASSWORD` = пароль из postgres.env  
- `REDIS_PASSWORD` / `REDIS_CACHE_PASSWORD`  
- `SECRET_KEY` — длинная случайная строка  
- при необходимости `API_TOKEN_PEPPER_1`  

Шаблон-заготовка: [`configs/netbox/docker/`](configs/netbox/docker/).

---

## Этап G. `docker-compose.override.yml`

Слушаем **только localhost** (nginx снаружи):

```yaml
services:
  netbox:
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      SKIP_SUPERUSER: "false"
      SUPERUSER_NAME: "admin"
      SUPERUSER_EMAIL: "admin@example.local"
      SUPERUSER_PASSWORD: "<пароль_админа>"
```

Готовый шаблон: [`configs/netbox/docker/docker-compose.override.yml`](configs/netbox/docker/docker-compose.override.yml).

---

## Этап H. Запуск стека

```bash
cd /opt/netbox-docker
docker compose pull
docker compose up -d
docker compose ps
docker compose logs -f netbox
```

Дождитесь `healthy` у `netbox`. Проверка с хоста:

```bash
curl -sI http://127.0.0.1:8080/login/ | head
```

Создание админа вручную (если не задали SUPERUSER_*):

```bash
docker compose exec netbox /opt/netbox/netbox/manage.py createsuperuser
```

Автозапуск после перезагрузки — через systemd unit (скрипт ставит `netbox-docker.service`) либо:

```bash
# restart: always уже в образах/политике docker; unit гарантирует compose up после boot
systemctl enable --now netbox-docker.service
```

---

## Этап I. nginx HTTPS на хосте

```bash
dnf -y install nginx

openssl req -x509 -nodes -newkey rsa:4096 -days 825 \
  -keyout /etc/pki/tls/private/netbox.key \
  -out /etc/pki/tls/certs/netbox.crt \
  -subj "/CN=10.0.130.10" \
  -addext "subjectAltName=IP:10.0.130.10"
```

Конфиг: [`configs/netbox/docker/nginx-netbox-docker.conf`](configs/netbox/docker/nginx-netbox-docker.conf)  
(прокси на `127.0.0.1:8080`, `allow` только вашего IP).

```bash
cp nginx-netbox-docker.conf /etc/nginx/conf.d/netbox.conf
# замените ALLOWED_CLIENT_IP на ваш IP
nginx -t
systemctl enable --now nginx
```

---

## Этап J. firewalld

```bash
CLIENT=10.0.130.50   # ← ваш IP

firewall-cmd --permanent --remove-service=https || true
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${CLIENT} port port=443 protocol=tcp accept"
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${CLIENT} port port=80 protocol=tcp accept"
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload
```

Порты Docker (`8080`, `5432`, Redis) **не** открывать наружу.

---

## Этап K. Сеть (IP 10.0.130.10)

```bash
nmcli con show
nmcli con mod "ИМЯ" \
  ipv4.addresses 10.0.130.10/24 \
  ipv4.gateway 10.0.130.1 \
  ipv4.method manual
nmcli con up "ИМЯ"
```

---

## Этап L. Проверка «от А до Я»

```bash
docker compose -f /opt/netbox-docker/docker-compose.yml \
  -f /opt/netbox-docker/docker-compose.override.yml ps

systemctl status docker nginx netbox-docker
curl -kI https://10.0.130.10/
getenforce
firewall-cmd --list-all
```

С разрешённого клиента: браузер → `https://10.0.130.10/`.

---

## Обслуживание

```bash
cd /opt/netbox-docker

# логи
docker compose logs -f --tail=200

# обновление образов
docker compose pull
docker compose up -d

# бэкап БД
docker compose exec -T postgres pg_dump -U netbox netbox > netbox-$(date +%F).sql

# останов / старт
docker compose stop
docker compose start
```

---

## Файлы в репозитории

| Путь | Назначение |
|---|---|
| [`scripts/netbox/install-netbox-docker-redos8.sh`](scripts/netbox/install-netbox-docker-redos8.sh) | Интерактивный установщик Docker |
| [`configs/netbox/docker/docker-compose.override.yml`](configs/netbox/docker/docker-compose.override.yml) | Override (localhost + superuser) |
| [`configs/netbox/docker/nginx-netbox-docker.conf`](configs/netbox/docker/nginx-netbox-docker.conf) | nginx TLS → `:8080` |
| [`configs/netbox/docker/netbox-docker.service`](configs/netbox/docker/netbox-docker.service) | systemd unit |

Секреты: `/var/lib/netbox-docker-install/answers.env` (`chmod 600`).

---

## Типичные проблемы

| Симптом | Что проверить |
|---|---|
| `docker: command not found` | пакеты docker/docker-ce, `systemctl start docker` |
| pull timeout | доступ к Docker Hub / прокси `HTTP_PROXY` |
| netbox unhealthy | `docker compose logs netbox`, пароли в env согласованы |
| 502 от nginx | контейнер слушает `127.0.0.1:8080`, `httpd_can_network_connect` |
| Permission denied (SELinux) | `:z` на томах, AVC → audit2allow |
| Нет доступа с клиента | rich-rule firewalld + `allow` в nginx |
