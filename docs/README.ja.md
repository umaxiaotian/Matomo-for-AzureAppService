# Matomo for Azure App Service  

このコンテナイメージは、**Azure App Service (Linux コンテナ)** 上で  
**Matomo 5.6.1 を完全に安定動作**させることを目的に最適化されています。

---

# 特徴

## 1️⃣ App Service の環境変数に完全対応

「アプリケーション設定」で次の変数を設定してください：

| 変数名 | 説明 |
|--------|-------|
| `MATOMO_DATABASE_HOST` | DB ホスト名 |
| `MATOMO_DATABASE_NAME` | DB 名 |
| `MATOMO_DATABASE_PASSWORD` | DB パスワード |
| `MATOMO_DATABASE_PORT` | DB ポート |
| `MATOMO_DATABASE_USER` | DB ユーザー |
| `WEBSITES_CONTAINER_START_TIME_LIMIT` | 起動待ち時間（任意） |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | **false 推奨**（独自マウント使用のため） |

エントリポイント側で自動的に取り込みます。

---

## 2️⃣ 推奨 Azure Files マウント構成

あなたが実際に設定しているように、次のように共有フォルダをマウントします：

| 共有名 | マウント先 | 用途 |
|-------|-------------|-------|
| config | `/var/www/html/config` | Matomo 設定永続化 |
| plugins | `/var/www/html/plugins` | プラグイン永続化 |
| tmp | `/var/www/html/tmp` | セッション・キャッシュ |
| htaccess | `/matomo_htaccess` | カスタム .htaccess |

---

## 3️⃣ .htaccess の永続化とオーバーライド

`/matomo_htaccess/.htaccess` を配置すると、  
コンテナ起動時に `/var/www/html/.htaccess` にコピーされます。

Matomo 全体を index.php 経由で守れるため、  
IP制限やセキュリティ強化に有効です。

### 例：指定した IP のみ index.php にアクセス許可

```apache
RewriteEngine On

SetEnvIf X-Forwarded-For ^203\.0\.113\.10(,|$) allow_ip
SetEnvIf X-Forwarded-For ^198\.51\.100\.20(,|$) allow_ip
SetEnvIf REMOTE_ADDR ^203\.0\.113\.10$ allow_ip
SetEnvIf REMOTE_ADDR ^198\.51\.100\.20$ allow_ip

RewriteRule !^index\.php$ - [L]

RewriteCond %{ENV:allow_ip} !^1$
RewriteRule ^ - [F]
```

---

## 4️⃣ Azure Files の UID/GID 自動調整に対応

Azure Files の多くは UID/GID が `1000:1000` です。  
これにより Matomo が以下のエラーを出します：

```
Session data file is not created by your uid
```

本コンテナは `/var/www/html/tmp` の UID/GID を読み取り、  
`www-data` を同じ UID/GID に変更することで完全に解決します。

---

## 5️⃣ SSH アクセス（ポート 2222）

Azure Portal → SSH でそのまま接続できます。

ローカルテスト：

```bash
ssh root@localhost -p 2222
Password: Docker!
```

