# Клиентские `.repo`

Замените `repo.example.ru` на FQDN из сертификата (или используйте `configure-repo-client.sh` / `configure-client.sh`).

| Файл | Назначение | enabled |
|------|------------|---------|
| `RedOS8-Base-local.repo` | актуальное Base | 1 |
| `RedOS8-Updates-local.repo` | актуальное Updates | 1 |
| `RedOS8-Archive-*-local.repo` | старые пакеты (`/archive/...`) | 0 |
| `RedOS8-Extras-local.repo` | extras (если зеркалируете) | 1 |
| `Internal-local.repo` | свои RPM | 1 |

```bash
dnf install PKG --enablerepo=RedOS8-Archive-Base-local,RedOS8-Archive-Updates-local
```
