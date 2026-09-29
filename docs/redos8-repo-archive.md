# Архив старых пакетов на `/var`

При каждом обновлении локального зеркала **старые RPM не удаляются**, а переносятся на раздел **`/var`**, чтобы их можно было скачать или поставить через dnf.

## Схема

```text
Актуальное зеркало (newest)     Архив предыдущих версий
/opt/repos/redos8/          →    /var/local-repo-archive/redos8/
https://FQDN/repos/...           https://FQDN/archive/redos8/...
```

| Путь | Назначение |
|------|------------|
| `/opt/repos/redos8/` | текущие пакеты для `dnf update` |
| `/var/local-repo-archive/redos8/<repoid>/` | старые RPM |
| `/var/local-repo-archive/reports/` | отчёты: что обновилось / что ушло в архив |
| `/var/log/local-repo/` | лог sync |

У вас `/var` большой (~800+ ГБ) — архив как раз туда; `/opt` остаётся под актуальное зеркало.

## Как работает sync

Скрипт [`sync-redos8-repos.sh`](scripts/local-repo/sync-redos8-repos.sh) при `ARCHIVE=1` и `NEWEST=1` (так стоит в cron после deploy):

1. Скачивает **новое** зеркало во временный каталог (`*.incoming`), не трогая текущее.
2. Сравнивает списки RPM:
   - есть в старом, нет в новом → **перенос в `/var/local-repo-archive`**
   - новые файлы → остаются в актуальном зеркале
3. Пишет отчёт в `/var/local-repo-archive/reports/sync-ДАТА.txt` (symlink `latest.txt`).
4. Делает `createrepo` и для зеркала, и для архива.
5. Чистит архив старше `ARCHIVE_KEEP_DAYS` дней (по умолчанию **180**).

Первый полный прогон (`NEWEST=0`) архивацию superseded не делает — нечего сравнивать. Архив наполняется со **второй** синхронизации (ночной cron).

## Как скачать / поставить старый пакет

### С любого хоста в сети (HTTPS)

```bash
# список / поиск на зеркале
repo-archive-tool.sh list
repo-archive-tool.sh search bash
repo-archive-tool.sh url bash-5.1.8-1.x86_64.rpm
# → https://FQDN/archive/redos8/redos8_base_src/bash-....rpm

curl -O "https://FQDN/archive/redos8/redos8_base_src/имя.rpm"
```

### Через dnf на клиенте

Archive-репозитории ставятся с `enabled=0`. Включение разово:

```bash
dnf install имя-пакета \
  --enablerepo=RedOS8-Archive-Base-local,RedOS8-Archive-Updates-local
```

Или конкретная версия:

```bash
dnf install bash-5.1.8-1.el8 \
  --enablerepo=RedOS8-Archive-Base-local
```

### Вернуть пакет в актуальное зеркало (на сервере)

```bash
repo-archive-tool.sh restore redos8_base_src bash-5.1.8-1.el8.x86_64.rpm
# копирует в /opt/repos/redos8/... и пересобирает createrepo
```

## Отчёты

```bash
cat /var/local-repo-archive/reports/latest.txt
# строки:
#   NEW      redos8_updates_src/foo-2.0-1.rpm     — появился в зеркале
#   ARCHIVE  redos8_updates_src/foo-1.0-1.rpm     — ушёл в архив на /var
#   EXPIRE   ...                                   — удалён по retention
```

## Настройки

| Переменная | Default | Смысл |
|------------|---------|--------|
| `ARCHIVE` | `1` | включить архивацию |
| `ARCHIVE_ROOT` | `/var/local-repo-archive` | корень на `/var` |
| `ARCHIVE_KEEP_DAYS` | `180` | хранить N дней (`0` = не чистить) |
| `NEWEST` | `1` | в cron; для архивации нужен `1` |

Пример cron (ставит `deploy-uibrep-mirror.sh`):

```cron
30 2 * * * root ARCHIVE=1 NEWEST=1 /usr/local/sbin/sync-redos8-repos.sh
```

Дольше хранить / не чистить:

```bash
# в /etc/cron.d/redos8-local-repo:
30 2 * * * root ARCHIVE=1 NEWEST=1 ARCHIVE_KEEP_DAYS=365 /usr/local/sbin/sync-redos8-repos.sh
# или ARCHIVE_KEEP_DAYS=0
```

Место:

```bash
repo-archive-tool.sh du
df -h /var /opt
```

## Проверка после деплоя

```bash
ls /var/local-repo-archive/redos8/
curl -I https://ВАШ_FQDN/archive/
# после нескольких sync:
repo-archive-tool.sh latest
```
