# Скрипты установки NetBox (РЕД ОС 8)

## Классическая установка

`install-netbox-redos8.sh` — PostgreSQL/Redis/Python/Gunicorn на хосте, каталог `/opt/netbox`.

```bash
bash install-netbox-redos8.sh
```

Инструкция: [`../../netbox-redos8-install.md`](../../netbox-redos8-install.md).

## Docker-установка

`install-netbox-docker-redos8.sh` — официальный [netbox-docker](https://github.com/netbox-community/netbox-docker) в `/opt/netbox-docker`, HTTPS через nginx на хосте.

```bash
bash install-netbox-docker-redos8.sh
```

Инструкция (от А до Я): [`../../netbox-redos8-docker-install.md`](../../netbox-redos8-docker-install.md).

## Общие параметры

Оба скрипта интерактивны и на этапах запрашивают:

1. IP NetBox (по умолчанию `10.0.130.10`)
2. IP клиента для HTTPS
3. FQDN / имя для сертификата
4. Пароли / секреты (или генерируют сами)
5. Учётку администратора
6. Режим TLS (`self-signed` / свои файлы)
7. Режим SELinux (`enforcing` / `permissive`)

| | Классика | Docker |
|---|---|---|
| Каталог | `/opt/netbox` | `/opt/netbox-docker` |
| Приложение | gunicorn `:8001` | контейнер `:8080` (localhost) |
| БД / Redis | на хосте | в compose |
| HTTPS | nginx на хосте | nginx на хосте |
| Секреты | `/var/lib/netbox-install/answers.env` | `/var/lib/netbox-docker-install/answers.env` |
