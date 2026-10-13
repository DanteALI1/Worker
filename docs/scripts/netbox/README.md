# Скрипт установки NetBox (РЕД ОС 8)

## Файл

`install-netbox-redos8.sh` — интерактивная установка «с нуля» до работающего HTTPS.

## Запуск

```bash
# от root на сервере NetBox
chmod +x install-netbox-redos8.sh
bash install-netbox-redos8.sh
```

## Что спрашивает

На этапах запрашиваются:

1. IP NetBox (по умолчанию `10.0.130.10`)
2. IP клиента для HTTPS
3. FQDN / имя для сертификата
4. Версия NetBox (тег GitHub)
5. Параметры PostgreSQL и Redis
6. Логин/пароль администратора NetBox
7. Режим TLS (`self-signed` или свои файлы)
8. Режим SELinux (`enforcing` / `permissive`)
9. Опционально — назначение IP на интерфейс

## Куда ставит

| Компонент | Путь / служба |
|---|---|
| NetBox | `/opt/netbox` |
| Gunicorn | `127.0.0.1:8001`, `netbox.service` |
| RQ worker | `netbox-rq.service` |
| nginx | `/etc/nginx/conf.d/netbox.conf`, `:443` |
| Секреты установки | `/var/lib/netbox-install/answers.env` |
| Лог | `/var/lib/netbox-install/install.log` |

Полное описание этапов: [`../../netbox-redos8-install.md`](../../netbox-redos8-install.md).
