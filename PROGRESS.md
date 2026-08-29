# PROGRESS — agents-kit

## 2026-08-30 v1 完成（設計→実装→実GitHub実証まで完了）

### これは何か
1つのGitHub repoに対し、別々のターミナルの複数AI（Claude Code / Codex混在・モデル/effort混在）が、ユーザーの随時指示を受けながらコンフリクトなく並行実装するための汎用調整キット。Claude固有機能に非依存（git + python3標準ライブラリ + 任意でgh）。

### 中核設計（SPEC.md が正）
- 調整媒体 = origin上のorphanブランチ `agent-state`。push のfast-forward検査をCASとして使う（push拒否=正常な調整イベント）。
- **後勝ち**: agent-stateのコミット順=全順序。seq最大のdirectiveが正。done/merge前の`--seen`復唱ゲートで未読のまま進めない。
- 担当宣言（claim）はアトミック、実装は各自worktree（origin/main SHA固定）、マージは`agents merge`のみ（ロック直列化+クリーンworktreeでシミュレーション+シンボル消失チェック+1マージごと全テスト+FF検査）。
- main / agent-state への直接pushはpre-pushフックが拒否（core.hooksPath対応、既存フックの先頭に前置）。

### 検証状態
- tests/smoke.sh 29検査 + tests/breaker.sh 14検査 全PASS（ローカルbare origin。同時claim×10、merge途中kill回収、ゾンビexit 8、stale lock奪取、master既定repo、敵対的既存フック等）。
- 実GitHub実証: private repo `hiroyuki0504/agents-kit-sandbox` で3並列AIセッション（fable/high・sonnet/medium・fable/low）が生シミュレーション。**9基準全PASS・プロトコル違反ゼロ**（後勝ち実行・seen-gate・衝突拒否・直列マージ鎖・テスト緑・コード消失なし・PR自動merged化・台帳整合・バイパス痕跡なし）。判定はstate全27コミット走査+GitHub activity APIの物証ベース。

### 使い方（新しいrepoへ）
```
~/agents-kit/install.sh /path/to/repo   # 冪等。再実行でkit更新配布
# .agents/config.json の test_cmd を設定（必須）
# 各AIセッションには「.agents/PROTOCOL.md を読んで従って」とだけ言う
```

### 未了・既知の限界
- ~/agents-kit 自体はローカルrepoのみ（GitHub未push。pushはユーザー判断待ち）。
- §7シンボル消失チェックはdoneのrebase解決ミスで消えたmainシンボルを原理的に捕捉できない（rebase後はremoved_by_brと区別不能）。そこはテストが唯一の番人（設計上の限界としてSPECに記載）。
- タスクキューからの完全自律pickupは非目標（directive台帳は将来拡張に耐える構造）。
- sandbox repoは実証の証跡として残置（不要なら GitHub上で削除: Settings→Delete this repository）。
