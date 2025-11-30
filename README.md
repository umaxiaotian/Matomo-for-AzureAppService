# Matomo for Azure App Service  

This container image is designed specifically to run **Matomo 5.6.1** on **Azure App Service (Linux Containers)** with full compatibility for:

- ✔ Azure Files persistent storage (config, plugins, tmp)
- ✔ Automatic UID/GID sync for Azure Files (fixes PHP session issues)
- ✔ Custom `.htaccess` loading from a dedicated mount (`/matomo_htaccess`)
- ✔ SSH access (port **2222**) for Azure portal SSH console
- ✔ X-Forwarded-For–aware IP restriction
- ✔ Works with App Service environment variables
- ✔ Zero modification required on Matomo core

---

# Features

## 1️⃣ Azure App Service Environment Variables

Matomo database settings should be configured in “App Settings”:

| Environment Variable | Purpose |
|----------------------|----------|
| `MATOMO_DATABASE_HOST` | Database host |
| `MATOMO_DATABASE_NAME` | Database name |
| `MATOMO_DATABASE_PASSWORD` | Database password |
| `MATOMO_DATABASE_PORT` | Database port |
| `MATOMO_DATABASE_USER` | Database user |
| `WEBSITES_CONTAINER_START_TIME_LIMIT` | (optional) Increased startup timeout |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | Must be **false** when using custom Azure Files mounts |

The container automatically consumes these variables through the entrypoint.

---

## 2️⃣ Azure Files Mount Points (Recommended Setup)

Your App Service should mount Azure Files like this:

| Share Name | Mount Path | Purpose |
|------------|------------|---------|
| **config** | `/var/www/html/config` | Matomo config.ini.php persistence |
| **plugins** | `/var/www/html/plugins` | Custom plugins, plugin persistence |
| **tmp** | `/var/www/html/tmp` | Sessions, cache, logs |
| **htaccess** | `/matomo_htaccess` | Custom .htaccess override |

The container detects the UID/GID of `/var/www/html/tmp` (Azure Files)  
and automatically updates the runtime `www-data` user to match.

This prevents the common Matomo error:

```text
Session data file is not created by your uid
````

---

## 3️⃣ Custom .htaccess Support (via /matomo_htaccess)

To override Matomo’s root `.htaccess`, simply upload:

```text
/matomo_htaccess/.htaccess
```

On startup, the container will copy it to:

```text
/var/www/html/.htaccess
```

This allows:

* IP allowlists / denylists
* X-Forwarded-For based client filtering
* Reverse proxy rewrite rules
* Hardening rules

### Example .htaccess (restrict index.php to allowed IPs)

```apache
RewriteEngine On

# Allowed IP addresses
SetEnvIf X-Forwarded-For ^203\.0\.113\.10(,|$) allow_ip
SetEnvIf X-Forwarded-For ^198\.51\.100\.20(,|$) allow_ip
SetEnvIf REMOTE_ADDR ^203\.0\.113\.10$ allow_ip
SetEnvIf REMOTE_ADDR ^198\.51\.100\.20$ allow_ip

# Only protect index.php
RewriteRule !^index\.php$ - [L]

# Deny everything else
RewriteCond %{ENV:allow_ip} !^1$
RewriteRule ^ - [F]
```

---

## 4️⃣ SSH Access (Port 2222)

The container runs OpenSSH on port **2222**, fully compatible with Azure portal’s SSH console.

Local testing:

```bash
ssh root@localhost -p 2222
Password: Docker!
```

---

## 5️⃣ Using Azure Database for MySQL (SSL / require_secure_transport)

When using **Azure Database for MySQL** as the Matomo database backend, you may hit an error like:

```text
Connections using insecure transport are prohibited while --require_secure_transport=ON.
```

This image is configured for a **non-SSL** connection by default.
If you want to connect without SSL, you must:

1. Open the **Server parameters** for your Azure Database for MySQL instance
2. Set the `require_secure_transport` parameter to **OFF**
3. Save / apply the change