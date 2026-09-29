# Клиентские `.repo`

Замените `repo.example.ru` на FQDN из сертификата (или используйте `configure-repo-client.sh` / `configure-client.sh`).

| Файл | Назначение | enabled |
|------|------------|---------|
| `RedOS8-Base-local.repo` | os (база) | 1 |
| `RedOS8-Updates-local.repo` | updates | 1 |
| `RedOS8-Extras-local.repo` | extras — доп. ПО | 1 |
| `RedOS8-3rdparty-local.repo` | 3rdparty — сторонние пакеты | 1 |
| `RedOS8-Debuginfo-local.repo` | debuginfo | 0 |
| `RedOS8-KernelRT-local.repo` | kernel-rt | 0 |
| `RedOS8-KernelTesting-local.repo` | kernel-testing | 0 |
| `RedOS8-Archive-*-local.repo` | старые пакеты (`/archive/...`) | 0 |
| `Internal-local.repo` | свои RPM | 1 |

```bash
# доп. ПО (extras/3rdparty уже включены после configure-*)
dnf install ПАКЕТ

# старая версия из архива
dnf install PKG --enablerepo=RedOS8-Archive-Base-local,RedOS8-Archive-Updates-local,RedOS8-Archive-Extras-local,RedOS8-Archive-3rdparty-local
```
