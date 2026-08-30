#!/bin/bash
# tests/smoke.sh — agents-kit のエンドツーエンド自動検証。
# mktemp -d 配下にローカル bare origin + クローンの sandbox を作り、8 項目を検証する。
# set -e は使わず PASS/FAIL を数え、全 PASS で exit 0。gh には依存しない
# （remote が github.com を含まないため PR 経路は自動スキップされる）。
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
echo "sandbox: $SB"
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS+1)); }
ng() { echo "FAIL: $1"; shift; while [ $# -gt 0 ]; do printf '      %s\n' "$1"; shift; done; FAIL=$((FAIL+1)); }
G() { LC_ALL=C git -C "$SB/repo" "$@"; }

# ---------------------------------------------------------------------------
# sandbox 準備: bare origin + クローン + seed コミット
# ---------------------------------------------------------------------------
git init --quiet --bare -b main "$SB/origin.git"
git clone --quiet "$SB/origin.git" "$SB/repo" 2>/dev/null
G config user.name "smoke-user"
G config user.email "smoke@local"
mkdir -p "$SB/repo/src"
echo "# smoke repo" > "$SB/repo/README.md"
printf 'def seed():\n    return 1\n' > "$SB/repo/src/app.py"
G add -A >/dev/null
G commit --quiet -m "seed"
G push --quiet origin main

# ---------------------------------------------------------------------------
# (1) install.sh → main に .agents 一式（ブートストラップ push）、config.json、.gitignore
# ---------------------------------------------------------------------------
INSTALL_OUT="$SB/install.out"
if "$KIT_ROOT/install.sh" "$SB/repo" > "$INSTALL_OUT" 2>&1; then
  ok "(1a) install.sh が exit 0"
else
  ng "(1a) install.sh が失敗 (rc=$?)" "$(tail -n 20 "$INSTALL_OUT")"
fi
G fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main"
MAIN_FILES="$(G ls-tree -r --name-only refs/remotes/origin/main)"
if printf '%s\n' "$MAIN_FILES" | grep -qx '.agents/bin/agents' \
   && printf '%s\n' "$MAIN_FILES" | grep -qx '.agents/PROTOCOL.md'; then
  ok "(1b) origin/main に .agents/bin/agents と PROTOCOL.md が載った（ブートストラップ push）"
else
  ng "(1b) origin/main に .agents が無い" "$MAIN_FILES"
fi
if [ -f "$SB/repo/.agents/config.json" ]; then
  ok "(1c) config.json が生成された"
else
  ng "(1c) config.json が無い"
fi
if grep -qxF '/.worktrees/' "$SB/repo/.gitignore" && grep -qxF '/.agents/config.json' "$SB/repo/.gitignore"; then
  ok "(1d) .gitignore に 2 行が追記された"
else
  ng "(1d) .gitignore 追記が無い" "$(cat "$SB/repo/.gitignore" 2>/dev/null)"
fi
if [ -z "$(G ls-remote origin refs/heads/agent-state)" ]; then
  ng "(1e) origin に agent-state が無い"
else
  ok "(1e) origin に agent-state が作成された"
fi

# 主 checkout を origin/main に揃え、test_cmd を設定
G reset --quiet --hard refs/remotes/origin/main
python3 - "$SB/repo/.agents/config.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["test_cmd"] = "true"
open(p, "w").write(json.dumps(cfg, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
EOF
AG="$SB/repo/.agents/bin/agents"

# ---------------------------------------------------------------------------
# (3) sandbox クローンからの git push origin main 直接 push がフックに拒否される
# ---------------------------------------------------------------------------
echo "tmp" >> "$SB/repo/README.md"
G add README.md >/dev/null
G commit --quiet -m "direct push attempt"
PUSH_ERR="$SB/push.err"
if G push origin main > /dev/null 2> "$PUSH_ERR"; then
  ng "(3) main への直接 push が通ってしまった"
else
  if grep -q "agents-kit" "$PUSH_ERR" && grep -q "停止命令" "$PUSH_ERR"; then
    ok "(3) 直接 push がフックに拒否された（停止命令の文言つき）"
  else
    ng "(3) push は失敗したがフックの文言が無い" "$(cat "$PUSH_ERR")"
  fi
fi
G reset --quiet --hard refs/remotes/origin/main

# ---------------------------------------------------------------------------
# (2)(4)(5) directive → start → 実装 → done → merge の一本道 + パス重複 + seen ゲート
# ---------------------------------------------------------------------------
cd "$SB/repo"
D1="$("$AG" directive "テスト指示1: src を触る" 2>/dev/null | head -n1)"
if [ "$D1" = "d00001" ]; then
  ok "(2a) directive が d00001 を返した"
else
  ng "(2a) directive の 1 行目が d00001 でない: '$D1'"
fi

START_OUT="$SB/start.out"
if "$AG" start feat-a --directive "$D1" --paths "src/**" --intent "feat-a 実装" > "$START_OUT" 2>&1; then
  ok "(2b) start feat-a が成功"
else
  ng "(2b) start feat-a が失敗 (rc=$?)" "$(tail -n 10 "$START_OUT")"
fi
WT="$(ls -d "$SB/repo/.worktrees"/feat-a-* 2>/dev/null | head -n1)"
if [ -n "$WT" ] && [ -d "$WT" ]; then
  ok "(2c) worktree が作成された: ${WT#$SB/repo/}"
else
  ng "(2c) worktree が無い" "$(ls "$SB/repo/.worktrees" 2>/dev/null)"
fi

# (4) 2つ目の start がパス重複で exit 4、相手 intent 表示
OV_OUT="$SB/overlap.out"
"$AG" start feat-b --directive "$D1" --paths "src/util/**" --intent "feat-b 実装" > "$OV_OUT" 2>&1
RC=$?
if [ $RC -eq 4 ]; then
  ok "(4a) パス重複の start が exit 4"
else
  ng "(4a) パス重複の start が exit 4 でない (rc=$RC)" "$(cat "$OV_OUT")"
fi
if grep -q "feat-a 実装" "$OV_OUT"; then
  ok "(4b) 相手 claim の intent が表示された"
else
  ng "(4b) 相手 intent が出力に無い" "$(cat "$OV_OUT")"
fi

# 実装コミット
printf 'def hello():\n    return "hi"\n' > "$WT/src/newfile.py"
git -C "$WT" add src/newfile.py >/dev/null
git -C "$WT" commit --quiet -m "feat-a: add newfile"

# (5) 新 directive 追加後の done が exit 3、--seen 復唱で通る
D2="$("$AG" directive "テスト指示2: 追加の指示" 2>/dev/null | head -n1)"
DONE1_OUT="$SB/done1.out"
(cd "$WT" && "$AG" done) > "$DONE1_OUT" 2>&1
RC=$?
if [ $RC -eq 3 ] && grep -q "テスト指示2" "$DONE1_OUT"; then
  ok "(5a) 未読 directive がある done が exit 3 で全文表示"
else
  ng "(5a) done が exit 3 + 全文表示にならない (rc=$RC)" "$(cat "$DONE1_OUT")"
fi
# (5a2) 復唱ゲートの表示順とストリーム: 拒否文（完成形 --seen 入り）は directive 全文の
#       「後」かつ stdout 側に出る（stderr 分離だとパイプ捕捉で順序が逆転するため。§8.5 手順4）
(cd "$WT" && "$AG" done) > "$SB/done1.stdout" 2> "$SB/done1.stderr"
L_TEXT="$(grep -n "テスト指示2" "$SB/done1.stdout" | head -n1 | cut -d: -f1)"
L_CMD="$(grep -n "復唱して再実行" "$SB/done1.stdout" | head -n1 | cut -d: -f1)"
if [ -n "$L_TEXT" ] && [ -n "$L_CMD" ] && [ "$L_TEXT" -lt "$L_CMD" ] \
   && ! grep -q "復唱して再実行" "$SB/done1.stderr"; then
  ok "(5a2) 復唱ゲート: 拒否文が directive 全文の後・stdout 側（パイプ捕捉でも順序不変）"
else
  ng "(5a2) 復唱ゲートの出力順/ストリームが不正" "text行=$L_TEXT cmd行=$L_CMD" \
     "stderr: $(cat "$SB/done1.stderr")"
fi
DONE2_OUT="$SB/done2.out"
(cd "$WT" && "$AG" done --seen "$D2") > "$DONE2_OUT" 2>&1
RC=$?
if [ $RC -eq 0 ]; then
  ok "(5b) done --seen $D2 の復唱で通った"
else
  ng "(5b) done --seen が失敗 (rc=$RC)" "$(tail -n 15 "$DONE2_OUT")"
fi

# (2) merge → main にマージが載る
MERGE_OUT="$SB/merge.out"
(cd "$WT" && "$AG" merge feat-a) > "$MERGE_OUT" 2>&1
RC=$?
if [ $RC -eq 0 ]; then
  ok "(2d) merge feat-a が成功"
else
  ng "(2d) merge feat-a が失敗 (rc=$RC)" "$(tail -n 20 "$MERGE_OUT")"
fi
G fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main"
if G ls-tree -r --name-only refs/remotes/origin/main | grep -qx 'src/newfile.py'; then
  ok "(2e) マージ結果が origin/main に載った"
else
  ng "(2e) origin/main に src/newfile.py が無い"
fi
if G log -1 --format=%s refs/remotes/origin/main | grep -q "merge feat-a"; then
  ok "(2f) main 先頭がマージコミット"
else
  ng "(2f) main 先頭がマージコミットでない: $(G log -1 --format=%s refs/remotes/origin/main)"
fi
if G ls-tree -r --name-only refs/remotes/origin/agent-state | grep -q 'claims/feat-a.json'; then
  ng "(2g) merge 後も claim が残っている"
else
  ok "(2g) merge 後に claim が解除された"
fi

# ---------------------------------------------------------------------------
# (6) evict --dry-run と status --json / sync --json のパース可能性
# ---------------------------------------------------------------------------
if "$AG" evict --dry-run > "$SB/evict.out" 2>&1; then
  ok "(6a) evict --dry-run が exit 0"
else
  ng "(6a) evict --dry-run が失敗 (rc=$?)" "$(cat "$SB/evict.out")"
fi
if "$AG" status --json 2>"$SB/status.err" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>"$SB/status.parse.err"; then
  ok "(6b) status --json がパース可能"
else
  ng "(6b) status --json がパース不能" "$(cat "$SB/status.parse.err" "$SB/status.err" 2>/dev/null)"
fi
if "$AG" sync --json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)'; then
  ok "(6c) sync --json がパース可能"
else
  ng "(6c) sync --json がパース不能"
fi

# ---------------------------------------------------------------------------
# (7) merge 手順9 成功直後の kill 相当（log を書く前に中断）→ 再 merge で回収経路(4b)
#     origin の pre-receive で「merge-log feat-c」の state push だけを拒否して中断を再現する
# ---------------------------------------------------------------------------
D3="$("$AG" directive "テスト指示3: lib を作る" 2>/dev/null | head -n1)"
"$AG" start feat-c --directive "$D3" --paths "lib/**" --intent "feat-c 実装" > "$SB/start-c.out" 2>&1
WT2="$(ls -d "$SB/repo/.worktrees"/feat-c-* 2>/dev/null | head -n1)"
if [ -z "$WT2" ]; then
  ng "(7a) feat-c の worktree が無い" "$(cat "$SB/start-c.out")"
else
  ok "(7a) feat-c を start"
fi
mkdir -p "$WT2/lib"
printf 'def lib_fn():\n    return 2\n' > "$WT2/lib/x.py"
git -C "$WT2" add lib/x.py >/dev/null
git -C "$WT2" commit --quiet -m "feat-c: add lib"
(cd "$WT2" && "$AG" done) > "$SB/done-c.out" 2>&1
RC=$?
if [ $RC -eq 0 ]; then
  ok "(7b) feat-c done が成功"
else
  ng "(7b) feat-c done が失敗 (rc=$RC)" "$(tail -n 15 "$SB/done-c.out")"
fi

# 中断シミュレーション: merge-log feat-c の push だけを origin 側で拒否
cat > "$SB/origin.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read old new ref; do
  if [ "$ref" = "refs/heads/agent-state" ]; then
    subj="$(git log -1 --format=%s "$new" 2>/dev/null)"
    if [ "$subj" = "merge-log feat-c" ]; then
    echo "smoke: simulated crash before merge-log" >&2
    exit 1
    fi
  fi
done
exit 0
EOF
chmod +x "$SB/origin.git/hooks/pre-receive"

CRASH_OUT="$SB/merge-crash.out"
(cd "$WT2" && "$AG" merge feat-c) > "$CRASH_OUT" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
  ok "(7c) log 書込前の中断を再現（merge が rc=$RC で停止）"
else
  ng "(7c) 中断シミュレーションが失敗（merge が成功してしまった）" "$(tail -n 10 "$CRASH_OUT")"
fi
G fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main"
if G ls-tree -r --name-only refs/remotes/origin/main | grep -qx 'lib/x.py'; then
  ok "(7d) 中断時点で main push（手順9）は成功済み"
else
  ng "(7d) main に lib/x.py が無い＝手順9まで到達していない" "$(tail -n 20 "$CRASH_OUT")"
fi
if G ls-tree -r --name-only refs/remotes/origin/agent-state | grep -q 'log/.*merge-feat-c'; then
  ng "(7e) 中断したのに merge-log が書かれている"
else
  ok "(7e) merge-log は未記録（kill 相当の状態）"
fi

rm -f "$SB/origin.git/hooks/pre-receive"
RECOV_OUT="$SB/merge-recovery.out"
(cd "$WT2" && "$AG" merge feat-c) > "$RECOV_OUT" 2>&1
RC=$?
if [ $RC -eq 0 ] && grep -q "既マージを検出し回収した" "$RECOV_OUT"; then
  ok "(7f) 再 merge で回収経路(4b)が動いた"
else
  ng "(7f) 回収経路が動かない (rc=$RC)" "$(tail -n 20 "$RECOV_OUT")"
fi
G fetch --quiet origin "+refs/heads/agent-state:refs/remotes/origin/agent-state"
LOGF="$(G ls-tree -r --name-only refs/remotes/origin/agent-state | grep 'merge-feat-c' | head -n1)"
if [ -n "$LOGF" ] && G cat-file blob "refs/remotes/origin/agent-state:$LOGF" \
   | python3 -c 'import json,sys; o=json.load(sys.stdin); sys.exit(0 if (o.get("recovery") is True and o.get("tests")=="skipped-recovery" and o.get("merge_commit")) else 1)'; then
  ok "(7g) recovery:true の merge log が残った（実マージコミット特定つき）"
else
  ng "(7g) recovery log が無い/不正" "LOGF=$LOGF" "$(G cat-file blob "refs/remotes/origin/agent-state:$LOGF" 2>/dev/null)"
fi
if G ls-tree -r --name-only refs/remotes/origin/agent-state | grep -q 'claims/feat-c.json'; then
  ng "(7h) 回収後も claim が残っている"
else
  ok "(7h) 回収で claim が解除された"
fi

# ---------------------------------------------------------------------------
# (8) doctor: read-only preflight
#     健全 repo で exit 0 / test_cmd 未設定で exit 3 + ✖ 行 / --run-tests の片付け /
#     実行前後で origin の main と agent-state の SHA が不変（read-only 性）
# ---------------------------------------------------------------------------
STATE_BEFORE="$(G ls-remote origin refs/heads/agent-state | awk '{print $1}')"
MAIN_BEFORE="$(G ls-remote origin refs/heads/main | awk '{print $1}')"

DOC1_OUT="$SB/doctor1.out"
"$AG" doctor > "$DOC1_OUT" 2>&1
RC=$?
if [ $RC -eq 0 ] && grep -q "doctor: 問題なし" "$DOC1_OUT"; then
  ok "(8a) 健全 repo で doctor が exit 0（問題なし）"
else
  ng "(8a) doctor が exit 0 + 問題なしにならない (rc=$RC)" "$(cat "$DOC1_OUT")"
fi

cp "$SB/repo/.agents/config.json" "$SB/config.bak"
python3 - "$SB/repo/.agents/config.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["test_cmd"] = None
open(p, "w").write(json.dumps(cfg, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
EOF
DOC2_OUT="$SB/doctor2.out"
"$AG" doctor > "$DOC2_OUT" 2>&1
RC=$?
if [ $RC -eq 3 ] && grep -q "✖ test_cmd 未設定" "$DOC2_OUT" && grep -q "doctor: 問題 1 件" "$DOC2_OUT"; then
  ok "(8b) test_cmd 未設定の doctor が exit 3（✖ 行と件数つき）"
else
  ng "(8b) test_cmd 未設定の doctor が exit 3 + ✖ 行にならない (rc=$RC)" "$(cat "$DOC2_OUT")"
fi
cp "$SB/config.bak" "$SB/repo/.agents/config.json"

DOC3_OUT="$SB/doctor3.out"
"$AG" doctor --run-tests > "$DOC3_OUT" 2>&1
RC=$?
DOC_LEFT="$(ls -d "$SB/repo/.worktrees"/doctor-* 2>/dev/null)"
if [ $RC -eq 0 ] && grep -q "テスト実走: 緑" "$DOC3_OUT" && [ -z "$DOC_LEFT" ]; then
  ok "(8c) doctor --run-tests が緑を報告し一時 worktree を片付けた"
else
  ng "(8c) doctor --run-tests が失敗/片付け漏れ (rc=$RC left=$DOC_LEFT)" "$(tail -n 15 "$DOC3_OUT")"
fi

STATE_AFTER="$(G ls-remote origin refs/heads/agent-state | awk '{print $1}')"
MAIN_AFTER="$(G ls-remote origin refs/heads/main | awk '{print $1}')"
if [ -n "$STATE_BEFORE" ] && [ -n "$MAIN_BEFORE" ] \
   && [ "$STATE_BEFORE" = "$STATE_AFTER" ] && [ "$MAIN_BEFORE" = "$MAIN_AFTER" ]; then
  ok "(8d) doctor 前後で origin の main / agent-state が不変（read-only）"
else
  ng "(8d) doctor が origin を変更した" "state: $STATE_BEFORE -> $STATE_AFTER" "main: $MAIN_BEFORE -> $MAIN_AFTER"
fi

# ---------------------------------------------------------------------------
# 結果
# ---------------------------------------------------------------------------
echo ""
echo "==== smoke 結果: PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -eq 0 ]; then
  rm -rf "$SB"
  exit 0
else
  echo "sandbox を残した（調査用）: $SB"
  exit 1
fi
