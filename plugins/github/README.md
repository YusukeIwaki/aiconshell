# GitHub プラグイン

GitHub App として動作する in-process プラグイン。resource API の polling で
issue / comment / review / workflow 更新を取得し、コメント返信と issue 作成を行う。
Events API（timeline）一本には依存しない。

## 必要な環境変数

| 変数 | 必須 | 説明 |
| --- | --- | --- |
| `GITHUB_APP_ID` | 必須 | GitHub App ID（数値） |
| `GITHUB_INSTALLATION_ID` | 必須 | 対象 installation の ID（数値） |
| `GITHUB_PRIVATE_KEY` | どちらか必須 | App の PEM 秘密鍵（PEM 本文） |
| `GITHUB_PRIVATE_KEY_FILE` | どちらか必須 | PEM を格納した private ファイルのパス |
| `GITHUB_API_URL` | 任意 | API ベース URL。既定 `https://api.github.com`（GHES 用に変更可） |

秘密鍵は `GITHUB_PRIVATE_KEY` 直書きか `GITHUB_PRIVATE_KEY_FILE` のどちらかで渡す。
両方ある場合は直書きが優先される。秘密の値はログ・EventLog・catalog に出さない。

## 最小権限（App permissions）

poll のみの場合:

- Issues: Read-only
- Pull requests: Read-only
- Actions: Read-only（workflow runs 取得に使用）
- Metadata: Read-only（自動付与）

返信・issue 作成を行う場合、上記に加えて:

- Issues: Read and write
- Pull requests: Read and write（PR へのコメント返信に使用）

`contents` や `administration` は不要。installation token は最長 1 時間で、
アダプターが expiry の 60 秒前に破棄して再取得する。

## セットアップ

1. GitHub App を作成し、上記の最小権限だけを付与する。
2. 秘密鍵（PEM）を発行し、アプリ実行環境の ENV か private ファイルに配置する。
3. App を対象リポジトリに install し、installation ID を控える
   （`https://api.github.com/app/installations` を App JWT で GET すると一覧できる）。
4. `scope` は `owner/repo` 形式で指定する。

## 操作

- `latest_events`: issue（一覧 `since` 付き）→ issue ごとに comments、
  PR なら reviews と review comments、さらに Actions workflow runs を取得する。
  全ページ取得の途中で失敗したら例外を送出し、cursor は前進させない。
- `reply`: `resource_id` は `issue:owner/repo#123` / `pr:owner/repo#123`。
- `create_issue`: `scope` は `owner/repo`。

cursor は `{"since": "ISO8601"}` のみ（JSON serializable）。
`cursor.next` に前回中断 URL を渡すとそこから再開するが、host は API host のみ許可する。

## 制約

- 1 回の poll で展開する issue は最大 50 件、1 エンドポイントのページ追跡は最大 25。
- workflow runs は新しい順に最大 3 ページだけ取得し、更新時刻で絞り込む。
  古くに作成された run の完了検知は遅延・欠落し得る。
- installation token 取得・API 呼び出しの 429 / rate limit 残量 0 は
  `RateLimited`（`retry_after` 付き）として返す。呼び出し側で待機・再試行すること。
- `Link: rel="next"` の host が API host と異なる場合は要求を送らず `HostRejected`。

## 公式ドキュメント

- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/about-authentication-with-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt
- https://docs.github.com/en/rest/issues/issues
- https://docs.github.com/en/rest/issues/comments
- https://docs.github.com/en/rest/pulls/reviews
- https://docs.github.com/en/rest/actions/workflow-runs
- https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
