# Клиентские .repo — подключение к локальному зеркалу

Перед копированием замените `10.0.0.10` на IP вашего сервера-зеркала.  
Официальные `RedOS-Base.repo` / `RedOS-Updates.repo` на клиенте должны иметь `enabled=0`.

Пути в `baseurl` (`/repos/redos8/...`) соответствуют symlink  
`/var/www/html/repos` → `/opt/repos` на зеркале.

## Установка

```bash
REPO_HOST=10.0.0.10
sed "s/10.0.0.10/${REPO_HOST}/g" RedOS8-Base-local.repo \
  > /etc/yum.repos.d/RedOS8-Base-local.repo
sed "s/10.0.0.10/${REPO_HOST}/g" RedOS8-Updates-local.repo \
  > /etc/yum.repos.d/RedOS8-Updates-local.repo
# опционально:
# sed "s/10.0.0.10/${REPO_HOST}/g" RedOS8-Extras-local.repo \
#   > /etc/yum.repos.d/RedOS8-Extras-local.repo
# sed "s/10.0.0.10/${REPO_HOST}/g" Internal-local.repo \
#   > /etc/yum.repos.d/Internal-local.repo

dnf clean all
dnf makecache
dnf repolist
```

Или скрипт: `docs/scripts/local-repo/configure-client.sh`.
