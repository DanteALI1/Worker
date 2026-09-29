# Source `.repo` для reposync на зеркале

Копируются в `/etc/yum.repos.d/` с `enabled=0` (только для `reposync`).  
Пакеты пишутся в `/opt/repos/redos8/<repoid>/`.

| Файл | Ветка |
|------|-------|
| `redos8_base_src.repo` | os (Base) |
| `redos8_updates_src.repo` | updates |
| `redos8_extras_src.repo` | extras (опционально) |

Для сертифицированной редакции замените в `baseurl` путь `8.0` → `8.0c`.
