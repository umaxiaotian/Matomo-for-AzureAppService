![abe15ab0-a704-47c7-b61d-a07a5c28c5da](https://github.com/user-attachments/assets/e179ddd9-9343-4dca-8f9b-bdc784964f8e)
# Matomo for Azure App Service Rebuild

This container image is designed specifically to run **Matomo** on **Azure App Service (Linux Containers)** with full compatibility for:

* ✔ Azure Files persistent storage (config, plugins, tmp, matomo.js)
* ✔ Automatic UID/GID sync for Azure Files (fixes PHP session issues)
* ✔ Custom `.htaccess` loading from a dedicated mount (`/matomo_htaccess`)
* ✔ SSH access (port **2222**) for Azure portal SSH console
* ✔ X-Forwarded-For–aware IP restriction
* ✔ Works with App Service environment variables
* ✔ Zero modification required on Matomo core
* ✔ **Security hardened — all images are scanned with Trivy**
* ✔ **Daily vulnerability scanning across *all tags*** (GitHub Actions)

---

# 📚 README for each language

* [日本語](docs/README.ja.md)
* [简体中文](docs/README.zh-CN.md)

---

# 🔐 Security & Vulnerability Control (Trivy)

This project integrates **Trivy (Aqua Security)** to ensure the image remains secure.

* Every build includes an automated **Trivy scan**
* CI fails if any *High* or *Critical* vulnerabilities are detected
* A scheduled GitHub Actions workflow performs:

  * **Daily scan** of all published tags
  * Auto-reporting of vulnerabilities

Example scan command used in CI:

```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 ghcr.io/OWNER/matomo-appservice-rebuild:latest
```

---

# ✨ Features

## 1️⃣ Azure App Service Environment Variables

Configure Matomo database settings through **App Settings**:

| Environment Variable                  | Purpose                                                |
| ------------------------------------- | ------------------------------------------------------ |
| `MATOMO_DATABASE_HOST`                | Database host                                          |
| `MATOMO_DATABASE_NAME`                | Database name                                          |
| `MATOMO_DATABASE_PASSWORD`            | Database password                                      |
| `MATOMO_DATABASE_PORT`                | Database port                                          |
| `MATOMO_DATABASE_USER`                | Database user                                          |
| `WEBSITES_CONTAINER_START_TIME_LIMIT` | (optional) Increased startup timeout                   |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | Must be **false** when using custom Azure Files mounts |

The entrypoint automatically consumes these values.

---

# 2️⃣ Azure Files Mount Points (Recommended Setup)

Mount Azure Files shares like this:

| Share Name    | Mount Path                | Purpose                                   |
| ------------- | ------------------------- | ----------------------------------------- |
| **config**    | `/var/www/html/config`    | Matomo config.ini.php persistence         |
| **plugins**   | `/var/www/html/plugins`   | Custom plugins                            |
| **tmp**       | `/var/www/html/tmp`       | Cache, sessions, logs, asset generation   |
| **matomo-js** | `/var/www/html/matomo-js` | Persistent JavaScript tracker (matomo.js) |
| **htaccess**  | `/matomo_htaccess`        | Custom .htaccess override                 |

The container then adjusts UID/GID of `www-data` to match the Azure Files mount, preventing errors like:

```
Session data file is not created by your uid
```

---

# 3️⃣ Persistent matomo.js Support

Matomo rewrites:

* `/usr/src/matomo/matomo.js`
* `/var/www/html/matomo.js`

Because the application code is read-only inside the image, these files must be offloaded to a writable location.

### ✔ Solution: dedicated mount `/var/www/html/matomo-js`

The entrypoint performs:

| Path                                | Behavior                                     |
| ----------------------------------- | -------------------------------------------- |
| `/var/www/html/matomo-js/matomo.js` | Real, writable persistent file (Azure Files) |
| `/usr/src/matomo/matomo.js`         | Symlink → persistent file                    |
| `/var/www/html/matomo.js`           | Symlink → persistent file                    |

If no `matomo.js` exists anywhere, an **empty file is created**, ensuring Matomo does not crash.

---

# 4️⃣ Custom `.htaccess` Support

To override Matomo's default `.htaccess`, upload a file to:

```
/matomo_htaccess/.htaccess
```

The entrypoint will copy it to:

```
/var/www/html/.htaccess
```

Example usage:

* Restrict access
* Add reverse proxy rules
* Apply IP allowlists
* Insert security hardening rules

### Example `.htaccess`

```apache
RewriteEngine On

# Allowed IPs
SetEnvIf X-Forwarded-For ^203\.0\.113\.10 allow_ip
SetEnvIf X-Forwarded-For ^198\.51\.100\.20 allow_ip
SetEnvIf REMOTE_ADDR ^203\.0\.113\.10$ allow_ip
SetEnvIf REMOTE_ADDR ^198\.51\.100\.20$ allow_ip

# Only protect index.php
RewriteRule !^index\.php$ - [L]

# Deny otherwise
RewriteCond %{ENV:allow_ip} !^1$
RewriteRule ^ - [F]
```

---

# 5️⃣ SSH Access (Port 2222)

Compatible with Azure’s built-in SSH console.

Local testing:

```bash
ssh root@localhost -p 2222
Password: Docker!
```

---

# 6️⃣ Using Azure Database for MySQL (require_secure_transport)

Azure Database for MySQL may require SSL:

```
Connections using insecure transport are prohibited while --require_secure_transport=ON.
```

This container uses **non-SSL** by default.

To allow connections:

1. Open **Server parameters** in Azure MySQL
2. Set `require_secure_transport = OFF`

---

# 7️⃣ Immutability of Matomo Core

Matomo core files remain inside the image at:

```
/usr/src/matomo
```

Only these paths are writable:

* `/var/www/html/config`
* `/var/www/html/plugins`
* `/var/www/html/tmp`
* `/var/www/html/matomo-js`

Everything else is symlinked to the immutable source, ensuring:

* safer upgrades
* consistent deployments
* no accidental core modifications

---

# 8️⃣ Daily Vulnerability Scans (All Tags)

GitHub Actions workflow scans every published tag daily:

* Scans for **HIGH / CRITICAL** vulnerabilities
* Creates GitHub Issues automatically when something is detected
* Helps maintain long-term container security