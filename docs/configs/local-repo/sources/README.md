# Source `.repo` для reposync (на зеркале, `enabled=0`)

Пакеты → `/opt/repos/redos8/<repoid>/`.

| Файл | Ветка | Для чего |
|------|-------|----------|
| `redos8_base_src.repo` | os | базовая установка |
| `redos8_updates_src.repo` | updates | обновления |
| `redos8_extras_src.repo` | extras | дополнительное ПО |
| `redos8_3rdparty_src.repo` | 3rdparty | сторонние пакеты («как есть») |
| `redos8_debuginfo_src.repo` | debuginfo | отладка |
| `redos8_kernel_rt_src.repo` | kernel-rt | realtime-ядро |
| `redos8_kernel_testing_src.repo` | kernel-testing | предрелизные ядра |

По умолчанию sync зеркалирует **все** эти ветки.  
Сертифицированная редакция: в `baseurl` замените `8.0` → `8.0c`.
