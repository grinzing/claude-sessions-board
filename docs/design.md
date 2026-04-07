# 設計ノート

`claude-sessions-board` の設計判断とその根拠をまとめたメモ。本体のREADMEに収まらない「なぜそうしたか」を残す場所。

## 解きたい問題

複数のClaude Codeセッションを同じプロジェクトディレクトリで並行起動するとき、お互いの存在・作業内容・触っているファイルが見えないため:

- 編集が衝突して片方の作業が消える
- 同じファイルを同時に直してしまう
- 「あの人は今何やってるんだっけ？」がわからない
- 「この作業終わるまで待ちたい」が伝えられない

`git worktree` で物理的に分けても、共有ファイル（package.json、CI設定、設定ファイル類）や、worktree内のサブディレクトリ分担、読み取り調査セッション同士の可視化までは解決しない。

## 設計原則

1. **依存ゼロ** — Python 3 標準ライブラリと shell とClaude Codeのhookだけで動く。デーモンもDBもqueueも要らない
2. **入れたら勝手に動く** — `install.sh` 一発、ユーザーの追加操作なし
3. **壊れても自然に回復する** — kill -9 されてもTTL+GCが片付ける
4. **対等** — 「親セッション」「マスター」のようなロールはない。全セッションが同列
5. **Claude自身に判断させる** — ロック衝突時は待たずにdenyしてClaudeに次手を考えさせる

## アーキテクチャ

### ストレージレイアウト

```
~/.claude/coordination/projects/<sha1(realpath(cwd))>/
├── _meta.json                       プロジェクト元cwd（人間用）
├── _last_gc                          最終GC時刻
├── sessions/<session_id>.json        セッションheartbeat
├── locks/<sha1(abs_path)>.json       ファイル単位lock
└── inbox/<session_id>/
    ├── new/<msg_id>.json              未読
    └── processed/<msg_id>.json        既読（renameで移動）
```

プロジェクトを `realpath(cwd)` のSHA-1で識別する。同じworktreeでも実体パスが同じなら同じboardを共有する。

### セッションheartbeat

```json
{
  "session_id": "abc123-...",
  "pid": 12345,
  "pid_start_token": "Sun Apr  7 14:30:00 2026",
  "cwd": "/Users/.../project",
  "branch": "feat/auth",
  "summary": "implementing auth middleware",
  "started_at": "2026-04-07T14:30:00+00:00",
  "expires_at": "2026-04-07T15:00:00+00:00"
}
```

- `expires_at` は TTL=30分。`UserPromptSubmit` hookで自動延長される
- `pid_start_token` は `ps -o lstart=` の生文字列。PID再利用検出に使う

### file lock

```json
{
  "session_id": "abc123-...",
  "path": "/abs/path/to/file.ts",
  "mode": "write",
  "acquired_at": "2026-04-07T14:35:00+00:00",
  "expires_at": "2026-04-07T14:45:00+00:00"
}
```

- TTL=10分（短め）
- `mode` は `read` / `write`（現バージョンでは情報的、強制はwrite単位）

## 設計判断と根拠

### Atomic write: tmpfile-in-same-dir + os.replace

POSIXでは `rename(2)` が同一ファイルシステム上で原子的。`os.replace()` を使い、tmpファイルは**必ず宛先と同じディレクトリ**に作る（別FSをまたぐとatomic性が崩れる）。

```python
tmp = path.parent / f".{path.name}.tmp.{pid}.{random}"
with open(tmp, "w") as f:
    json.dump(data, f); f.flush(); os.fsync(f.fileno())
os.replace(tmp, path)
```

### Stale 検出は3条件AND

1. `os.kill(pid, 0)` で PID が生きている
2. `ps -o lstart=` の文字列が記録時と一致（PID再利用検出）
3. `expires_at` が未来

PIDだけの判定は、OS が PID を別プロセスに再利用したときに「他人のプロセスを生存とみなす」事故を起こす。`pid_start_token` で防御する。

### Lazy GC

`heartbeat` コマンド実行時に `_last_gc` ファイルを見て、5分以上経っていたら GC を走らせる。

- メリット: cron や常駐デーモンが不要
- デメリット: 全セッションが死んでいる間は GC が走らない（が、その状態には誰も困らない）

### inboxは「rename方式」で既読管理

`new/<id>.json` を読んだら `processed/<id>.json` に `os.replace()` で移す。**フラグを上書きする方式は絶対に避ける**（並行read/writeの競合源）。

### Lockは「待たない」

`PreToolUse` hookは「他者がロック中ならdeny + reason」を返してすぐ抜ける。ブロックして待つ実装は:

- Claude Code のhookタイムアウトに引っかかる
- ユーザー体験を破壊する（応答が止まる）
- デッドロックの温床

代わりに reason に `sessions-board send <holder> "..."` の指示を入れて、Claude自身に交渉手を考えさせる。これは Claude Code の reason フィールドが LLM に読まれる仕様を活用している。

### SessionEnd は信用しない

`SessionEnd` hookは `kill -9` / OS shutdown / クラッシュ時には呼ばれない。Best-effortの掃除としてのみ使い、real cleanup は `expires_at` + lazy GC に任せる。

### session_id 解決の3段構え

1. `--session-id` 引数（最優先、hookから渡す）
2. `$CLAUDE_SESSION_ID` 環境変数（Claude Code が export していれば）
3. `_session_by_ppid_<PPID>` ポインタファイル（hook bash の PPID から逆引き）

3番目のおかげで、CLI を Claude が手動で叩くときも引数なしで自セッションを特定できる。

## アンチパターン（やらなかったこと）

- **flock(2)** ベースのロック — 異なるプロセスから同じファイルを atomic に管理するなら有効だが、TTL/可視性/メッセージング機能を持たせるとどのみち別ファイルが要る。シンプルさのため JSON ファイル一本に倒した
- **デーモン化** — ユーザー側の常駐プロセス管理は失敗の温床。lazy GC + TTL で代替
- **巨大JSON 1ファイルに状態集約** — write競合が多発する。1セッション=1ファイル、1ロック=1ファイルに分割
- **`--wait` オプション付きlock** — 待ち中のhookがUXを破壊する。denyしてClaudeに次手を考えさせる
- **session_idを自動生成** — Claude Codeのhookが提供する `session_id` を使うのが正解。独自IDは混乱のもと

## 既知の制約

- worktreeの物理パスが異なると別boardになる。共有settings.jsonをworktree間で調整したい場合はboardをまたぐ仕組みが必要（現バージョンは未対応）
- ロックは write 単位のみ強制。read/write の RW セマンティクスは情報的
- macOS と Linux 想定。Windowsは未テスト
- `ps -o lstart=` のフォーマットがOSで微妙に違うが、文字列一致で扱うので問題なし

## 参考にしたもの

- [Claude Code Hooks リファレンス](https://code.claude.com/docs/en/hooks)
- [Claude Code Agent Teams](https://github.com/FlorianBruniaux/claude-code-ultimate-guide/blob/main/guide/workflows/agent-teams.md) — 公式の `~/.claude/teams/{team}/inboxes/` 構造
- [The Stale pidfile Syndrome](https://perfec.to/posts/stale-pidfile/)
- [npm/write-file-atomic](https://github.com/npm/write-file-atomic)
- 関連issue: anthropics/claude-code#21277, anthropics/claude-code#24798
