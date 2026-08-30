#!/bin/bash
# tests/uninstall.sh — uninstall.sh のエンドツーエンド自動検証。
# mktemp -d 配下に「ローカル bare origin + クローン」の sandbox をシナリオごとに作り、
# 撤去の契約 (a)〜(f) と claim 生存ゲート (g) を検証する。
# set -e は使わず PASS/FAIL を数え、全 PASS で exit 0。gh には依存しない。
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$KIT_ROOT/install.sh"
UNINSTALL="$KIT_ROOT/uninstall.sh"
SB_ROOT="$(mktemp -d)"
echo "uninstall sandbox root: $SB_ROOT"
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS+1)); }
ng() { echo "FAIL: $1"; shift; while [ $# -gt 0 ]; do printf '      %s\n' "$1"; shift; done; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# sandbox ビルダー（breaker.sh の mkrepo 踏襲。install はシナリオ側で明示的に行う）
#   mkrepo <name> → echo で repo パスを返す。グローバル副作用なし。
# ---------------------------------------------------------------------------
mkrepo() {
  local name="$1" SB="$SB_ROOT/$1"
  mkdir -p "$SB"
  git init --quiet --bare -b main "$SB/origin.git"
  git clone --quiet "$SB/origin.git" "$SB/repo" 2>/dev/null
  git -C "$SB/repo" config user.name un-test
  git -C "$SB/repo" config user.email un-test@local
  mkdir -p "$SB/repo/src"
  echo "# $name" > "$SB/repo/README.md"
  printf 'def seed():\n    return 1\n' > "$SB/repo/src/app.py"
  git -C "$SB/repo" add -A >/dev/null
  git -C "$SB/repo" commit --quiet -m seed
  git -C "$SB/repo" push --quiet origin main 2>/dev/null
  echo "$SB/repo"
}
main_tree() {  # $1=repo → origin/main のファイル一覧
  git -C "$1" fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" 2>/dev/null
  git -C "$1" ls-tree -r --name-only refs/remotes/origin/main
}

# ---------------------------------------------------------------------------
# (a) install → uninstall で、ローカルと origin/main の両方から kit の痕跡が消える
# ---------------------------------------------------------------------------
RPA="$(mkrepo a)"
"$INSTALL" "$RPA" > "$SB_ROOT/a-install.out" 2>&1 \
  || ng "(a0) 前提の install.sh が失敗 (rc=$?)" "$(tail -n 20 "$SB_ROOT/a-install.out")"
UN_A="$SB_ROOT/a-uninstall.out"
if "$UNINSTALL" "$RPA" > "$UN_A" 2>&1; then
  ok "(a1) uninstall.sh が exit 0"
else
  ng "(a1) uninstall.sh が失敗 (rc=$?)" "$(tail -n 30 "$UN_A")"
fi
if [ ! -e "$RPA/.agents" ]; then
  ok "(a2) .agents/ が働くツリーから消えた"
else
  ng "(a2) .agents/ が残っている"
fi
if [ ! -f "$RPA/.git/hooks/pre-push" ]; then
  ok "(a3) pre-push フック（kit 生成のみ）がファイルごと消えた"
else
  if grep -qF '>>> agents-kit pre-push >>>' "$RPA/.git/hooks/pre-push"; then
    ng "(a3) pre-push フックに agents-kit ブロックが残っている" "$(cat "$RPA/.git/hooks/pre-push")"
  else
    ng "(a3) kit 生成のみの pre-push フックがファイルごと消えていない" "$(cat "$RPA/.git/hooks/pre-push")"
  fi
fi
if [ ! -e "$RPA/AGENTS.md" ] && [ ! -e "$RPA/CLAUDE.md" ]; then
  ok "(a4) ブロックのみの AGENTS.md / CLAUDE.md がファイルごと消えた"
else
  ng "(a4) AGENTS.md / CLAUDE.md が残っている" "$(ls "$RPA" 2>/dev/null)"
fi
if ! grep -qxF '/.worktrees/' "$RPA/.gitignore" 2>/dev/null \
   && ! grep -qxF '/.agents/config.json' "$RPA/.gitignore" 2>/dev/null; then
  ok "(a5) .gitignore から kit 追記行が消えた"
else
  ng "(a5) .gitignore に kit 追記行が残っている" "$(cat "$RPA/.gitignore" 2>/dev/null)"
fi
TREE_A="$(main_tree "$RPA")"
if printf '%s\n' "$TREE_A" | grep -q '^\.agents/'; then
  ng "(a6) origin/main に .agents が残っている" "$TREE_A"
else
  ok "(a6) origin/main から .agents 一式が消えた（除去コミット push 済み）"
fi
if [ -z "$(git -C "$RPA" status --porcelain 2>/dev/null)" ]; then
  ok "(a7) ローカル checkout は除去コミットへ前進しクリーン（reconcile）"
else
  ng "(a7) uninstall 後の checkout がクリーンでない" "$(git -C "$RPA" status --porcelain)"
fi

# ---------------------------------------------------------------------------
# (b) 2 回目の uninstall は冪等（撤去済みの旨を出して exit 0、何も変更しない）
# ---------------------------------------------------------------------------
UN_B="$SB_ROOT/b-uninstall.out"
"$UNINSTALL" "$RPA" > "$UN_B" 2>&1
RC=$?
if [ $RC -eq 0 ] && grep -q "撤去済み" "$UN_B"; then
  ok "(b1) 2 回目の uninstall が冪等（撤去済み表示で exit 0）"
else
  ng "(b1) 2 回目の uninstall が冪等でない (rc=$RC)" "$(cat "$UN_B")"
fi

# ---------------------------------------------------------------------------
# (c) origin の agent-state: 無指定では残り、--purge-remote で消える
# ---------------------------------------------------------------------------
RPC="$(mkrepo c)"
"$INSTALL" "$RPC" > "$SB_ROOT/c-install.out" 2>&1 \
  || ng "(c0) 前提の install.sh が失敗 (rc=$?)" "$(tail -n 20 "$SB_ROOT/c-install.out")"
UN_C1="$SB_ROOT/c-uninstall1.out"
"$UNINSTALL" "$RPC" > "$UN_C1" 2>&1
RC=$?
if [ $RC -eq 0 ] && [ -n "$(git -C "$RPC" ls-remote origin refs/heads/agent-state)" ] \
   && grep -q "監査台帳" "$UN_C1"; then
  ok "(c1) 無指定の uninstall で origin の agent-state が残る（監査台帳の旨を出力）"
else
  ng "(c1) agent-state の既定保持が働いていない (rc=$RC)" "$(cat "$UN_C1")"
fi
UN_C2="$SB_ROOT/c-uninstall2.out"
"$UNINSTALL" "$RPC" --purge-remote > "$UN_C2" 2>&1
RC=$?
if [ $RC -eq 0 ]; then
  ok "(c2) uninstall --purge-remote が exit 0"
else
  ng "(c2) uninstall --purge-remote が失敗 (rc=$RC)" "$(cat "$UN_C2")"
fi
if [ -z "$(git -C "$RPC" ls-remote origin refs/heads/agent-state)" ]; then
  ok "(c3) --purge-remote で origin の agent-state が消えた"
else
  ng "(c3) --purge-remote 後も agent-state が残っている" "$(cat "$UN_C2")"
fi

# ---------------------------------------------------------------------------
# (d) 未コミット作業入り worktree があると拒否し、--force で通る
# ---------------------------------------------------------------------------
RPD="$(mkrepo d)"
"$INSTALL" "$RPD" > "$SB_ROOT/d-install.out" 2>&1 \
  || ng "(d0) 前提の install.sh が失敗 (rc=$?)" "$(tail -n 20 "$SB_ROOT/d-install.out")"
git -C "$RPD" worktree add -b tmp-manual "$RPD/.worktrees/manual-x" > /dev/null 2>&1
echo "wip: 未退避の作業" > "$RPD/.worktrees/manual-x/wip.txt"
UN_D1="$SB_ROOT/d-uninstall1.out"
"$UNINSTALL" "$RPD" > "$UN_D1" 2>&1
RC=$?
if [ $RC -ne 0 ] && grep -q "manual-x" "$UN_D1"; then
  ok "(d1) 未コミット作業入り worktree で拒否（対象を列挙して exit 非 0）"
else
  ng "(d1) 未コミット作業入り worktree で拒否されない (rc=$RC)" "$(cat "$UN_D1")"
fi
if [ -d "$RPD/.worktrees/manual-x" ] && [ -f "$RPD/.worktrees/manual-x/wip.txt" ]; then
  ok "(d2) 拒否時は worktree と作業ファイルが無傷"
else
  ng "(d2) 拒否時に worktree が消えている"
fi
UN_D2="$SB_ROOT/d-uninstall2.out"
"$UNINSTALL" "$RPD" --force > "$UN_D2" 2>&1
RC=$?
if [ $RC -eq 0 ] && [ ! -d "$RPD/.worktrees" ] && [ ! -e "$RPD/.agents" ]; then
  ok "(d3) --force で worktree ごと撤去が通る"
else
  ng "(d3) --force の撤去が失敗 (rc=$RC)" "$(cat "$UN_D2")"
fi

# ---------------------------------------------------------------------------
# (e) ユーザー既存内容入り AGENTS.md / pre-push フックはブロックだけ除去され内容無傷
# ---------------------------------------------------------------------------
RPE="$(mkrepo e)"
printf '# My project rules\n\nkeep me intact.\n' > "$RPE/AGENTS.md"
cp "$RPE/AGENTS.md" "$SB_ROOT/e-orig-agents.md"
git -C "$RPE" add AGENTS.md >/dev/null
git -C "$RPE" commit --quiet -m "user AGENTS.md"
git -C "$RPE" push --quiet origin main 2>/dev/null
printf '#!/bin/sh\necho user-hook >&2\nexit 0\n' > "$RPE/.git/hooks/pre-push"
chmod +x "$RPE/.git/hooks/pre-push"
cp "$RPE/.git/hooks/pre-push" "$SB_ROOT/e-orig-hook"
"$INSTALL" "$RPE" > "$SB_ROOT/e-install.out" 2>&1 \
  || ng "(e0) 前提の install.sh が失敗 (rc=$?)" "$(tail -n 20 "$SB_ROOT/e-install.out")"
UN_E="$SB_ROOT/e-uninstall.out"
"$UNINSTALL" "$RPE" > "$UN_E" 2>&1
RC=$?
if [ $RC -eq 0 ]; then
  ok "(e1) uninstall.sh が exit 0"
else
  ng "(e1) uninstall.sh が失敗 (rc=$RC)" "$(tail -n 30 "$UN_E")"
fi
if cmp -s "$RPE/AGENTS.md" "$SB_ROOT/e-orig-agents.md"; then
  ok "(e2) AGENTS.md はブロックだけ除去され、既存内容がバイト単位で無傷"
else
  ng "(e2) AGENTS.md の既存内容が変わった" "$(diff "$SB_ROOT/e-orig-agents.md" "$RPE/AGENTS.md" 2>&1 | head -n 10)"
fi
if [ ! -e "$RPE/CLAUDE.md" ]; then
  ok "(e3) ブロックのみの CLAUDE.md はファイルごと消えた"
else
  ng "(e3) CLAUDE.md が残っている" "$(cat "$RPE/CLAUDE.md")"
fi
if cmp -s "$RPE/.git/hooks/pre-push" "$SB_ROOT/e-orig-hook"; then
  ok "(e4) ユーザー既存の pre-push フックはブロックだけ除去され無傷"
else
  ng "(e4) pre-push フックの既存内容が変わった" "$(cat "$RPE/.git/hooks/pre-push" 2>/dev/null)"
fi
git -C "$RPE" fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" 2>/dev/null
git -C "$RPE" cat-file blob refs/remotes/origin/main:AGENTS.md > "$SB_ROOT/e-main-agents.md" 2>/dev/null
if cmp -s "$SB_ROOT/e-main-agents.md" "$SB_ROOT/e-orig-agents.md"; then
  ok "(e5) origin/main の AGENTS.md も元の内容へ戻った（除去コミット側の変換一致）"
else
  ng "(e5) origin/main の AGENTS.md が元に戻っていない" "$(cat "$SB_ROOT/e-main-agents.md" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# (f) uninstall 後に install.sh を再実行すると再導入できる（repo a を再利用）
# ---------------------------------------------------------------------------
RE_F="$SB_ROOT/f-reinstall.out"
if "$INSTALL" "$RPA" > "$RE_F" 2>&1; then
  ok "(f1) uninstall 後の install.sh 再実行が exit 0"
else
  ng "(f1) install.sh 再実行が失敗 (rc=$?)" "$(tail -n 20 "$RE_F")"
fi
if [ -x "$RPA/.agents/bin/agents" ] && [ -f "$RPA/.agents/PROTOCOL.md" ]; then
  ok "(f2) .agents 一式が再配置された"
else
  ng "(f2) .agents 一式が無い" "$(ls "$RPA/.agents" 2>/dev/null)"
fi
if main_tree "$RPA" | grep -qx '.agents/bin/agents'; then
  ok "(f3) origin/main に .agents が再ブートストラップされた"
else
  ng "(f3) origin/main に .agents が載っていない" "$(main_tree "$RPA")"
fi
if grep -qF '>>> agents-kit pre-push >>>' "$RPA/.git/hooks/pre-push" 2>/dev/null; then
  ok "(f4) pre-push フックの防壁が再設置された"
else
  ng "(f4) pre-push フックが再設置されていない" "$(cat "$RPA/.git/hooks/pre-push" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# (g) 生きた claim があると停止し、--force で続行できる
# ---------------------------------------------------------------------------
RPG="$(mkrepo g)"
"$INSTALL" "$RPG" > "$SB_ROOT/g-install.out" 2>&1 \
  || ng "(g0) 前提の install.sh が失敗 (rc=$?)" "$(tail -n 20 "$SB_ROOT/g-install.out")"
AGG="$RPG/.agents/bin/agents"
D1="$( (cd "$RPG" && "$AGG" directive "撤去ゲート検証用の指示") 2>/dev/null | head -n1 )"
(cd "$RPG" && "$AGG" start ufeat --directive "$D1" --paths "src/**" --intent "claim 生存ゲートの検証") \
  > "$SB_ROOT/g-start.out" 2>&1 \
  || ng "(g0b) 前提の agents start が失敗 (rc=$?)" "$(tail -n 10 "$SB_ROOT/g-start.out")"
UN_G1="$SB_ROOT/g-uninstall1.out"
"$UNINSTALL" "$RPG" > "$UN_G1" 2>&1
RC=$?
if [ $RC -ne 0 ] && grep -q "ufeat" "$UN_G1" && grep -q "生きた claim" "$UN_G1"; then
  ok "(g1) 生きた claim を列挙して停止（exit 非 0）"
else
  ng "(g1) 生きた claim で停止しない (rc=$RC)" "$(cat "$UN_G1")"
fi
UN_G2="$SB_ROOT/g-uninstall2.out"
"$UNINSTALL" "$RPG" --force > "$UN_G2" 2>&1
RC=$?
if [ $RC -eq 0 ] && [ ! -e "$RPG/.agents" ]; then
  ok "(g2) --force で claim を無視して撤去が通る"
else
  ng "(g2) --force の撤去が失敗 (rc=$RC)" "$(tail -n 30 "$UN_G2")"
fi

# ---------------------------------------------------------------------------
# (h) repo 内 core.hooksPath のフックも掃除される（hooksPath 設定自体は触らない）
# ---------------------------------------------------------------------------
RPH="$(mkrepo h)"
mkdir -p "$RPH/.githooks"
git -C "$RPH" config core.hooksPath .githooks
"$INSTALL" "$RPH" > "$SB_ROOT/h-install.out" 2>&1 \
  || ng "(h0) 前提の install.sh が失敗 (rc=$?)" "$(tail -n 20 "$SB_ROOT/h-install.out")"
UN_H="$SB_ROOT/h-uninstall.out"
"$UNINSTALL" "$RPH" > "$UN_H" 2>&1
RC=$?
if [ $RC -eq 0 ] && [ ! -f "$RPH/.githooks/pre-push" ] \
   && [ "$(git -C "$RPH" config --get core.hooksPath)" = ".githooks" ]; then
  ok "(h1) repo 内 hooksPath のフックを掃除し、core.hooksPath 設定は温存"
else
  ng "(h1) repo 内 hooksPath の掃除が不正 (rc=$RC)" "$(ls "$RPH/.githooks" 2>/dev/null)" "$(cat "$UN_H")"
fi

# ---------------------------------------------------------------------------
# (i) --no-push は remote への書き込みを保留し、再実行で完遂できる
# ---------------------------------------------------------------------------
RPI="$(mkrepo i)"
"$INSTALL" "$RPI" > "$SB_ROOT/i-install.out" 2>&1 \
  || ng "(i0) 前提の install.sh が失敗 (rc=$?)" "$(tail -n 20 "$SB_ROOT/i-install.out")"
UN_I1="$SB_ROOT/i-uninstall1.out"
"$UNINSTALL" "$RPI" --no-push > "$UN_I1" 2>&1
RC=$?
if [ $RC -eq 0 ] && [ ! -e "$RPI/.agents" ] && grep -q "保留" "$UN_I1" \
   && main_tree "$RPI" | grep -q '^\.agents/'; then
  ok "(i1) --no-push でローカルは撤去、origin/main への除去 push は保留"
else
  ng "(i1) --no-push の保留が不正 (rc=$RC)" "$(cat "$UN_I1")"
fi
UN_I2="$SB_ROOT/i-uninstall2.out"
"$UNINSTALL" "$RPI" > "$UN_I2" 2>&1
RC=$?
if [ $RC -eq 0 ] && ! main_tree "$RPI" | grep -q '^\.agents/'; then
  ok "(i2) 再実行（--no-push なし）で origin/main からも除去が完遂"
else
  ng "(i2) 再実行で除去が完遂しない (rc=$RC)" "$(cat "$UN_I2")"
fi

# ---------------------------------------------------------------------------
# (j) remote 到達不能でもローカル撤去は進む（push 系は案内にフォールバックし exit 0）
# ---------------------------------------------------------------------------
RPJ="$(mkrepo j)"
"$INSTALL" "$RPJ" > "$SB_ROOT/j-install.out" 2>&1 \
  || ng "(j0) 前提の install.sh が失敗 (rc=$?)" "$(tail -n 20 "$SB_ROOT/j-install.out")"
git -C "$RPJ" remote set-url origin "$SB_ROOT/no-such-remote.git"
UN_J="$SB_ROOT/j-uninstall.out"
"$UNINSTALL" "$RPJ" > "$UN_J" 2>&1
RC=$?
if [ $RC -eq 0 ] && [ ! -e "$RPJ/.agents" ] && grep -q "到達できない" "$UN_J"; then
  ok "(j1) remote 到達不能でもローカル撤去が進み、push 系は案内で exit 0"
else
  ng "(j1) remote 到達不能時の挙動が不正 (rc=$RC)" "$(cat "$UN_J")"
fi

# ---------------------------------------------------------------------------
# (k) repo 外 core.hooksPath は触らず、手動除去の案内のみ出す
# ---------------------------------------------------------------------------
RPK="$(mkrepo k)"
mkdir -p "$SB_ROOT/k-outside-hooks"
printf '#!/bin/sh\n# >>> agents-kit pre-push >>> (install.sh が管理。手で編集しない)\n# <<< agents-kit pre-push <<<\necho user >&2\nexit 0\n' \
  > "$SB_ROOT/k-outside-hooks/pre-push"
chmod +x "$SB_ROOT/k-outside-hooks/pre-push"
cp "$SB_ROOT/k-outside-hooks/pre-push" "$SB_ROOT/k-orig-outside-hook"
"$INSTALL" "$RPK" > "$SB_ROOT/k-install.out" 2>&1   # hooksPath 未設定のまま導入
git -C "$RPK" config core.hooksPath "$SB_ROOT/k-outside-hooks"
UN_K="$SB_ROOT/k-uninstall.out"
"$UNINSTALL" "$RPK" > "$UN_K" 2>&1
RC=$?
if [ $RC -eq 0 ] && cmp -s "$SB_ROOT/k-outside-hooks/pre-push" "$SB_ROOT/k-orig-outside-hook" \
   && grep -q "手で除去せよ" "$UN_K"; then
  ok "(k1) repo 外 hooksPath は無変更のまま、手動除去の案内を出す"
else
  ng "(k1) repo 外 hooksPath の扱いが不正 (rc=$RC)" "$(cat "$UN_K")"
fi

# ---------------------------------------------------------------------------
# (l) 除去コミットの push が恒久拒否されたら回復手順を出して exit 非 0、コミットは残る。
#     拒否を解消して再実行すれば完遂する。
# ---------------------------------------------------------------------------
RPL="$(mkrepo l)"
"$INSTALL" "$RPL" > "$SB_ROOT/l-install.out" 2>&1 \
  || ng "(l0) 前提の install.sh が失敗 (rc=$?)" "$(tail -n 20 "$SB_ROOT/l-install.out")"
cat > "$SB_ROOT/l/origin.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read old new ref; do
  if [ "$ref" = "refs/heads/main" ]; then
    echo "policy: main locked" >&2
    exit 1
  fi
done
exit 0
EOF
chmod +x "$SB_ROOT/l/origin.git/hooks/pre-receive"
UN_L1="$SB_ROOT/l-uninstall1.out"
"$UNINSTALL" "$RPL" > "$UN_L1" 2>&1
RC=$?
SHA_L="$(grep -o '除去コミット [0-9a-f]\{40\}' "$UN_L1" | head -n1 | awk '{print $2}')"
if [ $RC -ne 0 ] && grep -q "回復手順" "$UN_L1" \
   && [ -n "$SHA_L" ] && git -C "$RPL" cat-file -e "$SHA_L" 2>/dev/null; then
  ok "(l1) push 恒久拒否で回復手順を表示して exit 非 0（除去コミットはローカルに残る）"
else
  ng "(l1) push 拒否時の回復動線が不正 (rc=$RC sha=$SHA_L)" "$(cat "$UN_L1")"
fi
rm -f "$SB_ROOT/l/origin.git/hooks/pre-receive"
UN_L2="$SB_ROOT/l-uninstall2.out"
"$UNINSTALL" "$RPL" > "$UN_L2" 2>&1
RC=$?
if [ $RC -eq 0 ] && ! main_tree "$RPL" | grep -q '^\.agents/'; then
  ok "(l2) 拒否解消後の再実行で origin/main からも除去が完遂"
else
  ng "(l2) 再実行で完遂しない (rc=$RC)" "$(cat "$UN_L2")"
fi

# ---------------------------------------------------------------------------
# 結果
# ---------------------------------------------------------------------------
echo ""
echo "==== uninstall 結果: PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -eq 0 ]; then
  rm -rf "$SB_ROOT"
  exit 0
else
  echo "sandbox を残した（調査用）: $SB_ROOT"
  exit 1
fi
