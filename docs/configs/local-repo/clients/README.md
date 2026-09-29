# Клиентские .repo — HTTPS к локальному зеркалу

Замените `repo.example.ru` на FQDN из сертификата УЦ.  
На клиенте сначала установите корневой CA УЦ в trust store (см. гайд).

Официальные `RedOS-Base.repo` / `RedOS-Updates.repo` → `enabled=0`.

## Установка

```bash
# 1) DNS или hosts
echo '10.0.0.10 repo.example.ru' >> /etc/hosts

# 2) CA УЦ
install -m 644 /path/to/ca-root.crt /etc/pki/ca-trust/source/anchors/org-ca.crt
update-ca-trust && update-ca-trust extract

# 3) repo-файлы
REPO_HOST=repo.example.ru
for f in RedOS8-Base-local.repo RedOS8-Updates-local.repo; do
  sed "s/repo.example.ru/${REPO_HOST}/g" "$f" > "/etc/yum.repos.d/$f"
done

dnf clean all && dnf makecache && dnf repolist
```

Или: `REPO_HOST=repo.example.ru PROTO=https CA_CERT=/path/ca-root.crt bash configure-client.sh`.
