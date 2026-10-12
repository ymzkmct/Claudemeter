# Claudemeter

[English](README.md)

Claude Code（Pro / Max）の利用上限をリアルタイムに macOS のメニューバーに表示するアプリ。

ソースコードのみの公開で、署名済みバイナリは配布しない。下記の手順で自分でビルドする。

メニューバー: `Claude 5h 8% · 7d 41%`（5時間枠 / 週次枠の使用率。`Claude` は常に表示し、隣に置いた Codex 版と見分けが付くようにしている）
ドロップダウン: 各枠の使用率バー・リセットまでの時間、モデル別週次枠、追加利用額、最終更新、更新間隔、ログイン時起動、終了

## 仕組み

- Claude Code がログイン時に Keychain へ保存する `Claude Code-credentials` の OAuth トークンで `GET https://api.anthropic.com/api/oauth/usage` を呼ぶ（`/usage` と同じデータ）
- 取得タイミング
  - 定期: 30秒 / 1分 / 5分（既定 1分）
  - `~/.claude/projects/**/*.jsonl`（セッションログ）が更新された 3 秒後（= Claude Code が応答を受け取った直後）
  - スリープ復帰時、ドロップダウンを開いたとき、手動
  - 連続取得は 15 秒以上空ける。429 を受けたら `Retry-After` まで待つ
- アクセストークンが期限切れなら refresh token で更新し、**同じ Keychain 項目に書き戻す**（`claude` CLI 側の認証を壊さないため）
- 直近の取得結果は UserDefaults に保存し、起動直後や取得失敗時は「古いデータ」として表示

## 前提

- macOS 14 以降
- **Xcode 26 以降**（Command Line Tools 単体では SDK とコンパイラの版が食い違いビルドできない）

```bash
sudo xcode-select -s <Xcode.app のパス>
sudo xcodebuild -license accept
```

- Claude Code で `claude` を実行してログイン済みであること（Keychain に項目がある）

## ビルドと起動

```bash
scripts/build-app.sh --install
```

`build/Claudemeter.app` を作り `/Applications`（`INSTALL_DIR` で変更可）にコピーして起動する。`--install` なしならビルドのみ。

Keychain へのアクセスは `claude` CLI がこの項目に使っているのと同じ `/usr/bin/security` 経由で行うため、アプリ固有の許可は不要で、初回起動時やリビルド後に確認ダイアログは出ない。

「security がキーチェーンに含まれるキー "Claude Code-credentials" へアクセスしようとしています」というパスワード入力付きのダイアログが出る場合は、項目の ACL partition list から `apple-tool:` が落ちている状態（別アプリが Security.framework 経由で項目を書き換えると起きる。[anthropics/claude-code#62213](https://github.com/anthropics/claude-code/issues/62213) 参照）。ログインキーチェーンのパスワードを入れて「常に許可」を一度選べば、`claude` CLI も Claudemeter も以後は無言で動く（別の何かが項目を書き換えるまで）。Claudemeter 自身は `security` 経由でしか更新しないので `apple-tool:` を落とさない。

署名: `Apple Development` の証明書があればそれで署名し、なければ ad-hoc 署名になる。どちらでも Keychain 項目には `/usr/bin/security` からしか触れないため、署名の違いで許可を求められることはない。

Xcode 未導入で CLT の `swift build` が壊れている環境向けに `scripts/build-app-clt-fallback.sh` も置いてある（CLT 同梱の macOS 15 SDK を bare swiftc で使う回避策。恒久対応は Xcode 導入）。

開発中は `swift run` でも起動できる（Dock には出ない。「ログイン時に起動」は .app からの起動時のみ有効）。

## テスト

```bash
swift test
```

## ログ

```bash
log stream --predicate 'subsystem == "jp.ymzkmct.Claudemeter"' --level info
```

## セキュリティと扱うデータ

- 通信先は `api.anthropic.com`（利用状況）と `platform.claude.com`（トークン更新）の 2 つだけ。HTTPS、TLS 1.2 以上、リダイレクトは追わない（Bearer トークンを他ホストへ送らないため）。クッキーやディスクキャッシュは使わない
- 読むもの: Keychain の `Claude Code-credentials`（Claude Code がログイン時に作る項目）。他の Keychain 項目には触れない
- 書くもの: 同じ Keychain 項目のトークン部分（期限切れ時の更新結果）。他のキーはそのまま保持する。更新は読み取った項目（account 一致）だけに限定
- Keychain の読み書きはすべて `/usr/bin/security` を子プロセスとして実行して行う（`claude` CLI が同じ項目に使っているツール）。書き戻し時は認証情報 JSON をその短命なプロセスのコマンドライン引数で渡すため、実行中の数ミリ秒間は同一ユーザーの他プロセスから見える
- `~/.claude/projects` は FSEvents でパスの変更を見るだけで、セッションログの中身は読まない
- トークンはログ・UI・UserDefaults のどこにも出さない。UserDefaults に保存するのは使用率などの表示用スナップショットのみ
- OAuth の `client_id` はソースに含まれるが、これは Claude Code 自身が使う公開クライアント ID（PKCE 前提の public client）で秘密情報ではない
- サンドボックスは使っていない（他アプリの Keychain 項目と `~/.claude` の監視に必要なため）
- テレメトリや外部送信はない

## 制限事項

- 非公式 API のため、Anthropic 側の変更で動かなくなる可能性がある
- API キー / Bedrock / Vertex 利用時は対象外（Keychain に OAuth 項目がない）
- refresh token も期限切れの場合は `claude` で再ログインが必要（ドロップダウンに案内を表示）
- レスポンス形式のうち `limits[]`（モデル別週次枠）の扱いは CodexBar の実装を参考にしており、実レスポンスでの確認待ち

## ライセンス

MIT。[LICENSE](LICENSE) を参照。
