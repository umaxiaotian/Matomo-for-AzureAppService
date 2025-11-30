# Matomo for Azure App Service Rebuild
这个容器镜像专为在 **Azure App Service（Linux 容器）** 上运行 **Matomo** 而设计，并完全兼容以下功能：

- ✔ 支持 Azure Files 持久化存储（config、plugins、tmp）
- ✔ 自动同步 Azure Files 的 UID/GID（修复 PHP 会话权限问题）
- ✔ 从专用挂载路径 (`/matomo_htaccess`) 加载自定义 `.htaccess`
- ✔ 提供 SSH 访问（端口 **2222**），兼容 Azure Portal 的 SSH 控制台
- ✔ 支持基于 X-Forwarded-For 的 IP 访问限制
- ✔ 完全兼容 App Service 环境变量
- ✔ Matomo 核心无需任何修改
- ✔ **强化安全性 — 所有镜像均通过 Trivy 扫描**
- ✔ **所有标签（tags）每日自动进行漏洞扫描**（GitHub Actions）

---

# 🔐 安全与漏洞管理（Trivy）

本项目集成了 **Trivy（Aqua Security）**，确保镜像在构建和发布过程中保持安全。

- 每次构建都会自动执行 **Trivy 扫描**，检测系统与库的漏洞。
- 如果发现任何 *High* 或 *Critical* 等级的漏洞，CI 流程会 **直接失败**。
- 通过 GitHub Actions 定时任务执行：
  - **每日扫描所有已发布标签**
  - 自动报告或提醒新发现的漏洞
- 这确保了即使 Matomo 或基础镜像更新后，安全性仍可持续保持。

CI 中使用的示例扫描命令：

```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 ghcr.io/OWNER/matomo-appservice-rebuild:latest
````

---

# 功能特性

## 1️⃣ Azure App Service 环境变量

Matomo 的数据库配置应在 “App Settings” 中设置：

| 环境变量名称                                | 作用                               |
| ------------------------------------- | -------------------------------- |
| `MATOMO_DATABASE_HOST`                | 数据库主机                            |
| `MATOMO_DATABASE_NAME`                | 数据库名称                            |
| `MATOMO_DATABASE_PASSWORD`            | 数据库密码                            |
| `MATOMO_DATABASE_PORT`                | 数据库端口                            |
| `MATOMO_DATABASE_USER`                | 数据库用户名                           |
| `WEBSITES_CONTAINER_START_TIME_LIMIT` | （可选）容器启动超时时间延长                   |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | 使用自定义 Azure Files 时必须为 **false** |

容器启动时会自动读取这些变量。

---

## 2️⃣ Azure Files 挂载点（推荐配置）

App Service 建议按如下方式挂载 Azure Files：

| 共享名称         | 挂载路径                    | 作用                |
| ------------ | ----------------------- | ----------------- |
| **config**   | `/var/www/html/config`  | 持久化 Matomo 配置文件   |
| **plugins**  | `/var/www/html/plugins` | 自定义插件及其持久化        |
| **tmp**      | `/var/www/html/tmp`     | 会话、缓存、日志          |
| **htaccess** | `/matomo_htaccess`      | 覆写根目录 `.htaccess` |

容器会检测 `/var/www/html/tmp`（Azure Files）的 UID/GID，
并自动调整运行时 `www-data` 用户的权限。

可避免 Matomo 常见错误：

```
Session data file is not created by your uid
```

---

## 3️⃣ 自定义 .htaccess（通过 /matomo_htaccess）

若要覆写 Matomo 根目录的 `.htaccess`，只需上传：

```text
/matomo_htaccess/.htaccess
```

启动时会自动复制到：

```text
/var/www/html/.htaccess
```

可用于：

* IP 允许 / 拒绝 列表
* 基于 X-Forwarded-For 的访问过滤
* 反向代理 rewrite 规则
* 安全加固规则

### 示例：限制 index.php 仅允许指定 IP

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

## 4️⃣ SSH 访问（端口 2222）

容器内置 OpenSSH，并在 **2222 端口**运行，兼容 Azure Portal 的 SSH 控制台。

本地测试：

```bash
ssh root@localhost -p 2222
Password: Docker!
```

---

## 5️⃣ 使用 Azure Database for MySQL（SSL / require_secure_transport）

使用 **Azure Database for MySQL** 时，可能出现如下错误：

```text
Connections using insecure transport are prohibited while --require_secure_transport=ON.
```

本镜像默认使用 **非 SSL 连接**。如需非 SSL 方式连接，请：

1. 打开 Azure Database for MySQL 的 **Server parameters**
2. 将 `require_secure_transport` 设置为 **OFF**
3. 保存并应用更改
などもできます！
```
