# Источники для reposync на сервере-зеркале
# Скопировать в /etc/yum.repos.d/ на зеркале. enabled=0 — только для зеркалирования.

## Файлы

| Файл | Repoid | Ветка |
|------|--------|-------|
| `redos8_base_src.repo` | `redos8_base_src` | os (Base) |
| `redos8_updates_src.repo` | `redos8_updates_src` | updates |
| `redos8_extras_src.repo` | `redos8_extras_src` | extras (опционально) |

Для сертифицированной редакции замените в `baseurl` путь `8.0` на `8.0c`.
