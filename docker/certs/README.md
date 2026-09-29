# TLS-сертификаты

Положите сюда перед запуском `install.sh`:

- `server.crt` — сертификат (лучше full chain: cert + intermediate)
- `server.key` — приватный ключ

Либо передайте пути через `CERT_FILE` и `KEY_FILE`.

Если файлов нет, `install.sh` создаст self-signed сертификат.
