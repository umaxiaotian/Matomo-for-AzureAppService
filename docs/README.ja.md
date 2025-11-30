![abe15ab0-a704-47c7-b61d-a07a5c28c5da](https://github.com/user-attachments/assets/e179ddd9-9343-4dca-8f9b-bdc784964f8e)

# Matomo for Azure App Service Rebuild

このコンテナイメージは、**Matomo** を **Azure App Service（Linux コンテナ）** 上で動作させるために特別に設計されており、以下に完全対応しています：

* ✔ Azure Files による永続ストレージ（config, plugins, tmp）
* ✔ Azure Files の UID/GID を自動同期（PHP セッション問題を修正）
* ✔ 専用マウント（`/matomo_htaccess`）から `.htaccess` を読み込み
* ✔ Azure ポータルの SSH コンソール用の SSH アクセス（ポート **2222**）
* ✔ X-Forwarded-For を考慮した IP 制限
* ✔ App Service の環境変数に対応
* ✔ Matomo コアの修正は一切不要
* ✔ **セキュリティ強化 — Trivy による全イメージ脆弱性スキャン**
* ✔ **全タグを対象とした毎日の脆弱性スキャン**（GitHub Actions）

---

# 🔐 セキュリティ & 脆弱性管理（Trivy）

このプロジェクトでは、イメージの安全性を確保するため **Trivy（Aqua Security）** を組み込んでいます。

* すべてのビルドは OS とライブラリの脆弱性を検出する **Trivy 自動スキャン**を実行します。
* *High* または *Critical* の脆弱性が検出された場合、CI パイプラインは **失敗** します。
* GitHub Actions のスケジュール実行により：

  * **全公開タグを対象に毎日 Trivy スキャンを実施**
  * 新しい脆弱性が見つかった場合は自動報告／通知
* これにより、Matomo やベースイメージが更新された後でも安全性が継続します。

CI 内で使用されているスキャン例：

```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 ghcr.io/OWNER/matomo-appservice-rebuild:latest
```

---

# 機能一覧

## 1️⃣ Azure App Service の環境変数

Matomo のデータベース設定は「App Settings」で構成します：

| 環境変数名                                 | 目的                                |
| ------------------------------------- | --------------------------------- |
| `MATOMO_DATABASE_HOST`                | データベースホスト                         |
| `MATOMO_DATABASE_NAME`                | データベース名                           |
| `MATOMO_DATABASE_PASSWORD`            | データベースパスワード                       |
| `MATOMO_DATABASE_PORT`                | データベースポート                         |
| `MATOMO_DATABASE_USER`                | データベースユーザー                        |
| `WEBSITES_CONTAINER_START_TIME_LIMIT` | （任意）起動タイムアウトの延長                   |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | カスタム Azure Files を使う場合は **false** |

これらの変数はエントリポイントで自動的に取り込まれます。

---

## 2️⃣ Azure Files のマウントポイント（推奨構成）

App Service では次のように Azure Files をマウントする必要があります：

| 共有名          | マウントパス                  | 用途                         |
| ------------ | ----------------------- | -------------------------- |
| **config**   | `/var/www/html/config`  | Matomo config.ini.php の永続化 |
| **plugins**  | `/var/www/html/plugins` | カスタムプラグイン、プラグインの永続化        |
| **tmp**      | `/var/www/html/tmp`     | セッション、キャッシュ、ログ             |
| **htaccess** | `/matomo_htaccess`      | ルート .htaccess の上書き         |

コンテナは `/var/www/html/tmp`（Azure Files）の UID/GID を検出し、
実行時の `www-data` ユーザーを自動的に調整します。

これにより、Matomo のよくあるエラー：

```
Session data file is not created by your uid
```

を防げます。

---

## 3️⃣ カスタム .htaccess（/matomo_htaccess 経由）

Matomo のルート `.htaccess` を上書きするには、以下のファイルをアップロードします：

```text
/matomo_htaccess/.htaccess
```

起動時に以下へコピーされます：

```text
/var/www/html/.htaccess
```

これにより：

* IP アロウリスト / デナイリスト
* X-Forwarded-For でのクライアント制御
* リバースプロキシの rewrite ルール
* ハードニング設定

などが可能になります。

### .htaccess の例（index.php を特定 IP のみに制限）

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

## 4️⃣ SSH アクセス（ポート 2222）

コンテナは OpenSSH を **2222 番ポート**で実行しており、Azure ポータルの SSH コンソールと完全互換です。

ローカルテスト例：

```bash
ssh root@localhost -p 2222
Password: Docker!
```

---

## 5️⃣ Azure Database for MySQL の利用（SSL / require_secure_transport）

Matomo のデータベースとして **Azure Database for MySQL** を使用した場合、以下のようなエラーが出ることがあります：

```text
Connections using insecure transport are prohibited while --require_secure_transport=ON.
```

このイメージはデフォルトで **非 SSL 接続** になっています。
SSL なしで接続したい場合は：

1. Azure Database for MySQL の **Server parameters** を開く
2. `require_secure_transport` を **OFF** に設定
3. 変更を保存・適用
