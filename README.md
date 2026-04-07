# claude-sessions-board

> A coordination board for parallel Claude Code sessions.
> When multiple Claude Code instances run in the same project directory,
> they can see each other, declare what they're doing, lock files, and
> exchange short messages — all through a tiny filesystem-based protocol.
> Zero dependencies. Auto-cleanup. Drop-in install.

複数の Claude Code セッションを同じプロジェクトで並行起動するときに、お互いの存在・作業内容・触っているファイルを可視化して衝突を防ぐ「伝言板」ツール。

---

## なぜこれが必要か

Claude Code を日常的に使っていると、こんなシーンが増えます。

- 1つは実装、もう1つは調査、もう1つはレビュー — 同じリポジトリで複数セッション
- 朝立ち上げたセッションを閉じ忘れたまま、別ターミナルで新しいセッションを始める
- worktree で分けたつもりが、共有設定ファイル（package.json、CI、Tailwind 設定等）は結局同じ実体

このとき:

- 同じファイルを同時に編集してどちらかの作業が消える
- お互いの存在を知らないので「触っちゃダメなファイル」がわからない
- 「あのセッション今何やってるんだっけ？」が見えない

`git worktree` で物理的に分けるのは強力だが、それだけでは:
- 共有ファイルの編集衝突
- 読み取り調査セッション同士の可視化
- 「あの作業終わるまで待ちたい」みたいな依存関係の伝達

までは解決しない。**claude-sessions-board** はこの隙間を埋めるために作りました。

---

## できること

セッションが起動すると自動的にboardに登録され、他のセッションから見えるようになります。

```
[Sessions Board] registered as session_id=abc123def456

== Active sessions in /Users/me/work/myapp ==
- abc123def456 (you)  branch=feat/auth  pid=12345
- 789xyzabcdef        branch=main       pid=67890
    summary: investigating slow queries

== sessions-board usage ==
- Declare what you're doing: sessions-board summary "<one-line>"
- See other sessions:        sessions-board list
- Lock a file:               sessions-board lock <path>
- Send a message:            sessions-board send <session_id> "<text>"
- Read your inbox:           sessions-board inbox
```

ロック中のファイルを別セッションが編集しようとすると、PreToolUse hookが自動でブロック:

```
This file is locked by another Claude Code session
(session_id=abc123def456, mode=write, expires_at=2026-04-07T15:00:00+00:00).
Coordinate with the lock holder before editing:
`sessions-board send abc123def456 "<your message>"`.
```

伝言を送ると、相手の次のプロンプト送信時に自動表示されます:

```
[Sessions Board: new messages]
== Inbox (1 new) ==
[2026-04-07T14:50:00+00:00] from 789xyzabcdef: please release auth.ts when you're done
```

---

## インストール

### 必要なもの
- macOS or Linux
- Python 3.8+
- Claude Code がインストール済み（`~/.claude/` が存在）

### 手順

```bash
git clone https://github.com/grinzing/claude-sessions-board.git
cd claude-sessions-board
./install.sh --dry-run    # 何が変わるか確認
./install.sh              # 実行
```

`install.sh` がやること:

1. `bin/sessions-board` を `~/.claude/bin/` にコピー
2. `hooks/*.sh` を `~/.claude/hooks/` にコピー
3. `~/.claude/settings.json` の `hooks` セクションに4つのhookエントリを追記（自動バックアップ付き、idempotent）

オプション:
- `--dry-run`: 何も変更せず、行う操作だけ表示
- `--force`: 確認なしで上書き

インストール後、Claude Code を再起動すれば次のセッションから自動で動きます。

### アンインストール

```bash
./uninstall.sh                  # CLI/hook/settings.jsonエントリを削除
./uninstall.sh --purge-state    # ~/.claude/coordination/ も含めて完全削除
./uninstall.sh --dry-run        # 削除内容の確認のみ
```

---

## 使い方

### 1. 作業内容を宣言する（必須）

セッションを開始してユーザーから作業内容を聞いたら、すぐに宣言する:

```bash
sessions-board summary "認証ミドルウェアを実装中"
```

これで他セッションから「あなたが何をしているか」が見えるようになります。

### 2. 他セッションを確認する

```bash
sessions-board list
```

```
== Active sessions in /Users/me/work/myapp ==
- abc123def456 (you)  branch=feat/auth  pid=12345
    summary: 認証ミドルウェアを実装中
- 789xyzabcdef        branch=main       pid=67890
    summary: APIドキュメント更新
```

### 3. ファイルをロックする

長時間触る予定のファイルは明示的にロック:

```bash
sessions-board lock src/lib/auth.ts
sessions-board unlock src/lib/auth.ts
```

ロックは10分でタイムアウトします。長時間触り続けたい場合は再度実行してください。

### 4. 伝言を送る

```bash
sessions-board send 789xyzabcdef "auth.tsを編集したい、終わったら教えて"
```

相手のセッションでは次のプロンプト送信時に自動で表示されます。

### 5. 受信箱を見る

```bash
sessions-board inbox          # 既読にして表示
sessions-board inbox --peek   # 既読にせず覗く
```

---

## 仕組み

### ストレージ

```
~/.claude/coordination/projects/<sha1(realpath(cwd))>/
├── _meta.json
├── sessions/<session_id>.json    # heartbeat（30分TTL）
├── locks/<sha1(file_path)>.json  # ファイル単位lock（10分TTL）
└── inbox/<session_id>/
    ├── new/                       # 未読メッセージ
    └── processed/                 # 既読メッセージ
```

プロジェクトの識別は `realpath(cwd)` のSHA-1。同じworktreeでも実体パスが同じなら同じboardを共有します。

### hooks

| Hook | 役割 |
|---|---|
| **SessionStart** | 自分を登録、他セッション一覧と未読伝言を表示 |
| **UserPromptSubmit** | heartbeat更新（TTL延長）、新着伝言通知、lazy GC |
| **PreToolUse(Edit/Write/MultiEdit/NotebookEdit)** | 他者ロック中のファイルへの編集をdeny + reason |
| **SessionEnd** | best-effort cleanup（kill -9では呼ばれない前提） |

### 設計のポイント

- **lazy GC**: 5分以上GCしてなければ heartbeat 時に自動掃除（cron不要）
- **stale検出は3条件AND**: pid生存 + `pid_start_token`（ps lstart）一致 + expires_at未来
- **atomic write**: 同一ディレクトリにtmp → `os.replace()`
- **inboxはrename方式**: `new/` → `processed/` でアトミック既読管理（フラグは競合のもと）
- **lockは「待たない」**: PreToolUseでdeny+reason返してClaude自身に次手を考えさせる
- **SessionEndに依存しない**: TTL+GCが本命

詳細は [docs/design.md](docs/design.md) を参照。

---

## worktree / Agent Teams との関係

| 仕組み | 役割 | 守備範囲 |
|---|---|---|
| **git worktree** | 物理隔離 | ファイル衝突の根絶、ブランチ並行 |
| **Claude Code Agent Teams**（公式） | 明示的なチーム分担 | 計画されたマルチエージェント協調 |
| **claude-sessions-board** | 論理的な可視化と調整 | 偶発的な複数セッションの気付きと調整 |

これらは**置き換えではなく補完**の関係です。

- worktree は「物理的に作業ディレクトリを分けるルール」
- Agent Teams は「明示的に複数エージェントでチームを組む公式機能」
- sessions-board は「日常的に偶然複数セッションが立ち上がるときに、自動で気付ける仕組み」

筆者は worktree 運用ルール + sessions-board の二段構えで使っています。

---

## トラブルシューティング

### `sessions-board list` で何も出ない

- `~/.claude/coordination/projects/` 配下にプロジェクトディレクトリがあるか確認
- セッションが正しく登録されているか: `cat ~/.claude/coordination/projects/*/sessions/*.json`
- hookが動いているか: Claude Code を再起動して `[Sessions Board] registered as ...` のメッセージが出るか

### Edit/Write が常にdenyされる

- 古いセッションのロックが残っている可能性: `sessions-board gc` で手動掃除
- ロックTTLは10分なので、それ以上経てば自動的に解放される

### 別プロジェクトのセッションも見えてしまう

- `realpath(cwd)` が同じだとそうなります。symlink経由で同じディレクトリを2つの名前で開いていないか確認

### settings.json を壊したくない

- `install.sh --dry-run` でまず確認
- 実行時に `~/.claude/settings.json.backup.<timestamp>` に自動バックアップが作られます

---

## テスト

```bash
./test/smoke.sh
```

end-to-end smoke test を一時HOME上で実行します。実際の `~/.claude/coordination/` には触りません。

---

## 制約事項

- macOS / Linux 想定。Windows未テスト
- worktreeの物理パスが異なると別boardになる
- ロックはwrite単位のみ強制（read/write のRWセマンティクスは情報的）
- セッション数が数百規模になると `list` が遅くなる可能性あり（実用範囲は10〜20セッション程度を想定）

---

## ライセンス

[MIT](LICENSE)

---

## 関連リンク

- [Claude Code Hooks 公式リファレンス](https://code.claude.com/docs/en/hooks)
- [Claude Code Agent Teams](https://github.com/FlorianBruniaux/claude-code-ultimate-guide/blob/main/guide/workflows/agent-teams.md)
- 関連issue: [anthropics/claude-code#21277](https://github.com/anthropics/claude-code/issues/21277), [#24798](https://github.com/anthropics/claude-code/issues/24798)
- 設計の経緯と背景: 〈note記事リンク（公開後追記）〉

---

## Contributing

issue/PR 歓迎です。特に以下のフィードバックが嬉しいです:

- Linux/Windows での動作報告
- 別のhookタイプ（PostToolUse など）での活用アイデア
- worktreeをまたぐboard共有のアイデア
- ロック粒度やRWセマンティクスの強化案
