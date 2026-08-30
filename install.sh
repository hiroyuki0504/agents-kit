#!/bin/bash
# install.sh — agents-kit v1 導入スクリプト（SPEC §9/§10 準拠。冪等）
# https://github.com/hiroyuki0504/agents-kit (MIT License)
# 用法: install.sh <target-repo-path> [--no-push]（path 省略時 .）
# グローバル設定（~/.claude、git config --global、repo 外の hooksPath 先）には一切触れない。
set -u -o pipefail

command -v python3 >/dev/null 2>&1 || { echo "エラー: python3 が必要（README の動作環境を参照）" >&2; exit 1; }

KIT_DIR="$(cd "$(dirname "$0")" && pwd)/kit"
if [ ! -f "$KIT_DIR/agents" ] || [ ! -f "$KIT_DIR/PROTOCOL.md" ]; then
  echo "エラー: 同梱物が見つからない: $KIT_DIR/agents, $KIT_DIR/PROTOCOL.md" >&2
  exit 1
fi

T="."
NO_PUSH=0
for a in "$@"; do
  case "$a" in
    --no-push) NO_PUSH=1 ;;
    -*) echo "エラー: 未知のオプション: $a" >&2; exit 1 ;;
    *) T="$a" ;;
  esac
done
# 物理パスへ正規化（macOS の /var → /private/var 等。realpath 済みパスとの前綴比較を成立させる）
T="$(cd "$T" 2>/dev/null && pwd -P)" || { echo "エラー: ディレクトリが無い" >&2; exit 1; }

g() { LC_ALL=C LANG=C git -C "$T" "$@"; }

# push 失敗分類（kit/agents の定数 PUSH_CAS_PATTERNS と 1:1 対応の移植。§5.3。
# python 側: \[rejected\] / non-fast-forward / fetch first / \[remote rejected\] /
#            incorrect old value / failed to update ref / cannot lock ref
# 変更時は kit/agents の PUSH_CAS_PATTERNS も同時に更新すること）
AGENTS_KIT_CAS_PATTERNS='\[rejected\]|non-fast-forward|fetch first|\[remote rejected\]|incorrect old value|failed to update ref|cannot lock ref'
is_cas_err() { printf '%s' "$1" | grep -Eq "$AGENTS_KIT_CAS_PATTERNS"; }

realpath_py() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# ---------------------------------------------------------------------------
# 手順1: 検証と検出
# ---------------------------------------------------------------------------
if ! g rev-parse --git-dir >/dev/null 2>&1; then
  echo "エラー: $T は git リポジトリではない" >&2
  exit 1
fi
COMMON_GITDIR="$(g rev-parse --path-format=absolute --git-common-dir)"

CFG="$T/.agents/config.json"
REMOTE="origin"
CFG_MAIN=""
CFG_STATE=""
if [ -f "$CFG" ]; then
  REMOTE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("remote") or "origin")' "$CFG" 2>/dev/null || echo origin)"
  CFG_MAIN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("main_branch") or "")' "$CFG" 2>/dev/null || echo "")"
  CFG_STATE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("state_branch") or "")' "$CFG" 2>/dev/null || echo "")"
fi
if ! g remote get-url "$REMOTE" >/dev/null 2>&1; then
  cat >&2 <<EOF
エラー: remote '$REMOTE' が無い。共有 remote が必要。ローカル専用なら:
  git init --bare ../<repo>-coord.git && git -C <repo> remote add origin ../<repo>-coord.git
（push の FF 検査はローカル bare でも同一に働く）
EOF
  exit 1
fi

# default branch 検出（ls-remote --symref HEAD。検出不能なら main にフォールバックし警告）
DETECTED="$(g ls-remote --symref "$REMOTE" HEAD 2>/dev/null | awk '$1=="ref:" && $2 ~ /^refs\/heads\// {sub("refs/heads/","",$2); print $2; exit}')"
if [ -z "$DETECTED" ]; then
  DETECTED="main"
  echo "警告: default branch を検出できなかった。main とみなす（違う場合は .agents/config.json の main_branch を直し install.sh を再実行）"
fi
MAIN="${CFG_MAIN:-$DETECTED}"
STATE="${CFG_STATE:-agent-state}"

# ブランチ名の検証（§10 手順1）: フックと JSON に埋め込むため文字集合を限定する。
# 外れる名前を黙って埋め込むと防壁が無言で壊れる（シェル/sed メタ文字）ため赤字で拒否。
for bn in "$MAIN" "$STATE"; do
  case "$bn" in
    ""|*[!A-Za-z0-9._/-]*)
      printf '\033[31mエラー: ブランチ名 %s に使えない文字が含まれる（対応は [A-Za-z0-9._/-] のみ。フック/JSON への安全な埋め込みのための制限）。ブランチ名を変えるか config.json を直せ。\033[0m\n' "$bn" >&2
      exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# フック設置先の事前解決（手順2の dirty 記録対象に使うため、ファイル変更より前に決める）
# ---------------------------------------------------------------------------
HP="$(g config --get core.hooksPath || true)"
HOOK_MODE="common"     # common | inrepo | outside
HOOK_FILE="$COMMON_GITDIR/hooks/pre-push"
HOOK_REL=""            # T 相対（追跡ファイルとして push する場合のみ非空）
if [ -n "$HP" ]; then
  case "$HP" in
    /*) HP_ABS="$HP" ;;
    *)  HP_ABS="$T/$HP" ;;
  esac
  HP_ABS="$(realpath_py "$HP_ABS")"
  case "$HP_ABS/" in
    "$T"/*) HOOK_MODE="inrepo"; HOOK_FILE="$HP_ABS/pre-push" ;;
    *)      HOOK_MODE="outside"; HOOK_FILE="" ;;
  esac
fi
if [ "$HOOK_MODE" = "inrepo" ]; then
  rel="${HOOK_FILE#"$T"/}"
  if g ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    HOOK_REL="$rel"
  fi
fi

# ---------------------------------------------------------------------------
# 手順2: 事前 dirty 記録（これから触る kit 管理外ファイル。変更前に取る）
#   - symlink の実体（repo 内）も記録対象にするため、realpath 解決を dirty 記録より前に行う
#     （字面の AGENTS.md だけ見ると、実体＝追跡ファイルの未コミット変更が素通りして
#      ブートストラップ push でユーザーの未公開内容が main に載る）。
#   - 差分が kit 生成分のみのファイル（ポインタ/フックブロック・.gitignore 追記行を除くと
#     HEAD と一致）は dirty とみなさない（前回 run の生成物で回復動線が永遠に塞がるのを防ぐ）。
# ---------------------------------------------------------------------------
A_REAL="$(realpath_py "$T/AGENTS.md")"
C_REAL="$(realpath_py "$T/CLAUDE.md")"
GI_REAL="$(realpath_py "$T/.gitignore")"
rel_in_repo() { case "$1/" in "$T"/*) printf '%s' "${1#"$T"/}" ;; *) printf '' ;; esac; }
A_RELP="$(rel_in_repo "$A_REAL")"
C_RELP="$(rel_in_repo "$C_REAL")"
GI_RELP="$(rel_in_repo "$GI_REAL")"

kit_only_diff() {  # $1=T相対パス $2=ptr|gi|hook。kit 生成/追記分のみの差分なら 0
  python3 - "$T" "$1" "$2" <<'PYEOF'
import os, subprocess, sys
T, rel, mode = sys.argv[1], sys.argv[2], sys.argv[3]
path = os.path.realpath(os.path.join(T, rel))
try:
    work = open(path, encoding="utf-8", errors="surrogateescape").read()
except OSError:
    sys.exit(1)          # 読めない/消えている → dirty 扱い（安全側）
def strip_block(text, start, end):
    out, inblk = [], False
    for ln in text.split("\n"):
        if start in ln:
            inblk = True
            continue
        if end in ln:
            inblk = False
            continue
        if not inblk:
            out.append(ln)
    return "\n".join(out)
if mode == "ptr":
    s = strip_block(work, ">>> agents-kit >>>", "<<< agents-kit <<<")
elif mode == "hook":
    s = strip_block(work, ">>> agents-kit pre-push >>>", "<<< agents-kit pre-push <<<")
else:  # gi
    s = "\n".join(ln for ln in work.split("\n")
                  if ln not in ("/.worktrees/", "/.agents/config.json"))
r = subprocess.run(["git", "-C", T, "cat-file", "blob", "HEAD:%s" % rel],
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
head = r.stdout.decode("utf-8", "surrogateescape") if r.returncode == 0 else ""
sys.exit(0 if s.strip("\n") == head.strip("\n") else 1)  # 末尾改行差のみ許容
PYEOF
}

PRE_DIRTY=""
DIRTY_SEEN=" "
dirty_candidate() {  # $1=T相対パス（空可） $2=種別
  local rel="$1" mode="$2" st
  [ -n "$rel" ] || return 0
  case "$DIRTY_SEEN" in *" $rel "*) return 0 ;; esac
  DIRTY_SEEN="$DIRTY_SEEN$rel "
  st="$(g status --porcelain -- "$rel" 2>/dev/null)"
  [ -n "$st" ] || return 0
  if kit_only_diff "$rel" "$mode"; then return 0; fi
  PRE_DIRTY="$PRE_DIRTY$st
"
}
dirty_candidate "AGENTS.md" ptr
dirty_candidate "$A_RELP" ptr
dirty_candidate "CLAUDE.md" ptr
dirty_candidate "$C_RELP" ptr
dirty_candidate ".gitignore" gi
dirty_candidate "$GI_RELP" gi
dirty_candidate "$HOOK_REL" hook

# ---------------------------------------------------------------------------
# 手順3: kit 同梱物の配置（常に上書き）+ config.json（無ければ生成、既存なら触らない）
# ---------------------------------------------------------------------------
mkdir -p "$T/.agents/bin"
cp "$KIT_DIR/agents" "$T/.agents/bin/agents"
chmod +x "$T/.agents/bin/agents"
cp "$KIT_DIR/PROTOCOL.md" "$T/.agents/PROTOCOL.md"
CONFIG_CREATED=0
if [ ! -f "$CFG" ]; then
  printf '{\n "main_branch": "%s",\n "test_cmd": null\n}\n' "$MAIN" > "$CFG"
  CONFIG_CREATED=1
fi

# ---------------------------------------------------------------------------
# 手順4: AGENTS.md / CLAUDE.md ポインタブロック（symlink は実体側に追記し、リンクは保持）
# ---------------------------------------------------------------------------
PTR_START='<!-- >>> agents-kit >>> (install.sh が管理。手で編集しない) -->'
PTR_END='<!-- <<< agents-kit <<< -->'
ptr_block() {
  cat <<'EOF'
<!-- >>> agents-kit >>> (install.sh が管理。手で編集しない) -->
この repo は複数 AI セッション並行開発の協調プロトコルを使う。
作業を始める前に .agents/PROTOCOL.md を読み、従うこと。
調整 CLI: .agents/bin/agents（まず: .agents/bin/agents sync）
worktree 内で見つからない場合はリポジトリルートの .agents/bin/agents を絶対パスで実行。
<!-- <<< agents-kit <<< -->
EOF
}
install_ptr() {  # $1 = 実体ファイルの絶対パス（symlink 解決済み）
  local f="$1" tmp
  tmp="$COMMON_GITDIR/agents-tmp-ptr.$$"
  if [ -f "$f" ]; then
    # 既存ブロックを除去してから末尾に追記（= 置換）。tmp→mv でなく > で書き実体化を防ぐ
    awk -v s="$PTR_START" -v e="$PTR_END" '
      index($0, s) {inblk=1; next}
      index($0, e) {inblk=0; next}
      !inblk {print}' "$f" > "$tmp"
    { cat "$tmp"; ptr_block; } > "$f"
    rm -f "$tmp"
  else
    ptr_block > "$f"
  fi
}
install_ptr "$A_REAL"     # A_REAL/C_REAL は手順2の前に解決済み
if [ "$C_REAL" != "$A_REAL" ]; then
  install_ptr "$C_REAL"
fi

# ---------------------------------------------------------------------------
# 手順5: .gitignore（行単位の存在検査で冪等）
# ---------------------------------------------------------------------------
GI="$GI_REAL"             # 手順2の前に解決済み
touch "$GI"
for line in '/.worktrees/' '/.agents/config.json'; do
  if ! grep -qxF "$line" "$GI"; then
    { [ -s "$GI" ] && [ -n "$(tail -c1 "$GI")" ] && echo; printf '%s\n' "$line"; } >> "$GI"
  fi
done

# ---------------------------------------------------------------------------
# 手順6: pre-push フック設置（§9。実効フックパスへ。repo 外パスには書かない）
# ---------------------------------------------------------------------------
# ブロックは必ず「先頭（shebang 直後）」に前置する（§9）。末尾追記は禁止:
# 既存フックの早期 exit 0 / stdin 消費でブロックが到達不能な死にコードになり、
# 防壁が無言で失効する。stdin は一時ファイルへ退避して判定し、通過後に exec < で
# 既存フック本体へ再供給する（stdin を読む既存フックとも共存する）。
HOOK_BLOCK_TEMPLATE="$(cat <<'HBEOF'
# >>> agents-kit pre-push >>> (install.sh が管理。手で編集しない)
agents_kit_tmp="${GIT_DIR:-.git}/agents-kit-prepush.$$"
if ! cat > "$agents_kit_tmp"; then
  echo "agents-kit: push 一覧(stdin)を退避できないため push を拒否した。" >&2
  exit 1
fi
agents_kit_bad=""
while read -r _lr _ls agents_kit_ref _rs; do
  case "$agents_kit_ref" in
    ("refs/heads/<MAIN>")  if [ -z "${AGENTS_MERGE_TOKEN:-}" ]; then agents_kit_bad=x; fi ;;
    ("refs/heads/<STATE>") if [ -z "${AGENTS_STATE_TOKEN:-}" ]; then agents_kit_bad=x; fi ;;
  esac
done < "$agents_kit_tmp"
if [ -n "$agents_kit_bad" ]; then
  rm -f "$agents_kit_tmp"
  echo "agents-kit: 保護されたブランチへの直接 push を拒否した。これはあなたへの停止命令である。" >&2
  echo "  main に入れる唯一の方法: '.agents/bin/agents merge <slug>'（状態の変更は agents コマンドのみ）" >&2
  echo "  --no-verify や環境変数の手動設定による回避は禁止（重大な規律違反。操作は agent-state に記録され監査される）。" >&2
  exit 1
fi
exec < "$agents_kit_tmp"
rm -f "$agents_kit_tmp"
# <<< agents-kit pre-push <<<
HBEOF
)"

hook_block() {  # 埋め込み済みブロックを stdout へ（repo 外 hooksPath の手動前置用表示）
  HB_T="$HOOK_BLOCK_TEMPLATE" python3 -c \
    'import os,sys;sys.stdout.write(os.environ["HB_T"].replace("<MAIN>",sys.argv[1]).replace("<STATE>",sys.argv[2])+"\n")' \
    "$MAIN" "$STATE"
}

install_hook_block() {  # $1=フックファイル。新規=完全ファイル / 既存=旧ブロック除去+shebang直後に前置
  HB_T="$HOOK_BLOCK_TEMPLATE" python3 - "$1" "$MAIN" "$STATE" <<'PYEOF'
import os, sys
p, main, state = sys.argv[1], sys.argv[2], sys.argv[3]
block = os.environ["HB_T"].replace("<MAIN>", main).replace("<STATE>", state) + "\n"
if not os.path.exists(p):
    with open(p, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\n" + block + "exit 0\n")
    sys.exit(0)
text = open(p, encoding="utf-8", errors="surrogateescape").read()
start, end = ">>> agents-kit pre-push >>>", "<<< agents-kit pre-push <<<"
out, inblk = [], False
for ln in text.split("\n"):     # 旧ブロック（位置を問わず）を除去
    if start in ln:
        inblk = True
        continue
    if end in ln:
        inblk = False
        continue
    if not inblk:
        out.append(ln)
if out and out[0].startswith("#!"):
    head, rest = out[0] + "\n", out[1:]
else:
    head, rest = "", out
rest_text = "\n".join(rest)
if rest_text and not rest_text.endswith("\n"):
    rest_text += "\n"           # 改行なし終端の既存フックとの癒着防止
with open(p, "w", encoding="utf-8", errors="surrogateescape") as fh:
    fh.write(head + block + rest_text)   # 開いて書く（symlink を実体化させない）
PYEOF
}

if [ "$HOOK_MODE" = "outside" ]; then
  printf '\033[31m警告: core.hooksPath が repo 外（%s）を指しているため、main 直 push 防壁を設置できない。\n以下のブロックを %s/pre-push の先頭（shebang 直後）に手で前置せよ（前置するまで agents sync が毎回警告し続ける。末尾追記は既存フックの早期 exit で無効化されるため不可）:\033[0m\n' "$HP" "$HP" >&2
  hook_block >&2
else
  mkdir -p "$(dirname "$HOOK_FILE")"
  if [ ! -f "$HOOK_FILE" ]; then
    install_hook_block "$HOOK_FILE"
    chmod +x "$HOOK_FILE"
  else
    HAD_MARKER=0
    grep -qF '>>> agents-kit pre-push >>>' "$HOOK_FILE" && HAD_MARKER=1
    install_hook_block "$HOOK_FILE"
    chmod +x "$HOOK_FILE"
    if [ "$HAD_MARKER" = 1 ]; then
      echo "既存の agents-kit ブロックを更新し、先頭（shebang 直後）に配置し直した。"
    else
      echo "既存の pre-push フックの先頭（shebang 直後）に agents-kit ブロックを前置した（push 一覧の stdin はブロック通過後に既存処理へ再供給される）。"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 手順7: agent-state 初期化（orphan。plumbing で作成し push。失敗は §5.3 で分類）
# ---------------------------------------------------------------------------
if [ -z "$(g ls-remote "$REMOTE" "refs/heads/$STATE" 2>/dev/null)" ]; then
  B="$(printf '0\n' | g hash-object -w --stdin)"
  RD="$(printf 'agents-kit の調整用ブランチ（orphan）。\ndirectives/ = 指示台帳、claims/ = 担当宣言、log/ = 完了記録、counter = seq 採番。\n読み書きは .agents/bin/agents 経由のみ。手で編集・push しないこと。\n' | g hash-object -w --stdin)"
  TREE="$(printf '100644 blob %s\tREADME.md\n100644 blob %s\tcounter\n' "$RD" "$B" | g mktree)"
  C="$(g -c user.name=agents-kit -c user.email=agents-kit@local commit-tree "$TREE" -m 'agents-kit: state root')"
  PUSH_ERR="$(AGENTS_STATE_TOKEN=1 g push "$REMOTE" "$C:refs/heads/$STATE" 2>&1 >/dev/null)" || {
    if is_cas_err "$PUSH_ERR"; then
      echo "agent-state は他セッションが先に作成した（正常）"
    else
      echo "エラー: agent-state の push に失敗:" >&2
      printf '%s\n' "$PUSH_ERR" >&2
      exit 1
    fi
  }
fi
# 無限空振りループの根絶: 最後に存在を再確認してから成功を宣言する
if [ -z "$(g ls-remote "$REMOTE" "refs/heads/$STATE" 2>/dev/null)" ]; then
  echo "エラー: push は通ったように見えるが remote に refs/heads/$STATE が存在しない。remote 設定を確認せよ" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 手順8: ブートストラップ push（.agents 一式を main へ。導入デッドロックの解消）
# ---------------------------------------------------------------------------
SKIPPED_PUSH_REASON=""
push_files() {  # 一時 index で commit を構築して push。$1 = リトライ回数
  local attempt="$1" TIP TMPIDX TREE COMMIT PUSH_ERR parent_args rel real
  g fetch --quiet "$REMOTE" "+refs/heads/$MAIN:refs/remotes/$REMOTE/$MAIN" 2>/dev/null
  TIP="$(g rev-parse -q --verify "refs/remotes/$REMOTE/$MAIN" 2>/dev/null || true)"
  # 冪等スキップ: remote 版 .agents/bin/agents が今回配置した実体と同一 blob なら押さない
  if [ -n "$TIP" ]; then
    local remote_blob local_blob
    remote_blob="$(g rev-parse -q --verify "$TIP:.agents/bin/agents" 2>/dev/null || true)"
    local_blob="$(g hash-object "$T/.agents/bin/agents")"
    if [ -n "$remote_blob" ] && [ "$remote_blob" = "$local_blob" ]; then
      echo "ブートストラップ push: スキップ（main の .agents/bin/agents は既に同一）"
      return 0
    fi
  fi
  TMPIDX="$COMMON_GITDIR/agents-tmp/idx-install-$$-$attempt"
  mkdir -p "$COMMON_GITDIR/agents-tmp"
  if [ -n "$TIP" ]; then
    GIT_INDEX_FILE="$TMPIDX" g read-tree "$TIP^{tree}" || return 1
    parent_args=(-p "$TIP")
  else
    GIT_INDEX_FILE="$TMPIDX" g read-tree --empty || return 1
    parent_args=()
  fi
  add_one() {  # $1=T相対パス $2=mode
    local blob
    blob="$(g hash-object -w --stdin < "$T/$1")" || return 1
    GIT_INDEX_FILE="$TMPIDX" g update-index --add --cacheinfo "$2,$blob,$1" || return 1
  }
  add_one ".agents/bin/agents" 100755 || return 1
  add_one ".agents/PROTOCOL.md" 100644 || return 1
  # AGENTS.md / CLAUDE.md は symlink の実体側（repo 外実体は追加しない）。config.json は含めない（ignore 済み・クローンローカル）
  local seen_real=""
  for name in AGENTS.md CLAUDE.md; do
    real="$(realpath_py "$T/$name")"
    case "$real/" in
      "$T"/*)
        rel="${real#"$T"/}"
        case " $seen_real " in *" $rel "*) continue ;; esac
        seen_real="$seen_real $rel"
        add_one "$rel" 100644 || return 1 ;;
      *) echo "警告: ${name} の実体が repo 外（${real}）のため commit に含めない" >&2 ;;
    esac
  done
  rel="$(realpath_py "$T/.gitignore")"; rel="${rel#"$T"/}"
  add_one "$rel" 100644 || return 1
  if [ -n "$HOOK_REL" ]; then
    add_one "$HOOK_REL" 100755 || return 1
  fi
  TREE="$(GIT_INDEX_FILE="$TMPIDX" g write-tree)" || return 1
  COMMIT="$(g -c user.name=agents-kit -c user.email=agents-kit@local commit-tree "$TREE" ${parent_args[@]+"${parent_args[@]}"} -m 'agents-kit: install')" || return 1
  rm -f "$TMPIDX"
  PUSH_ERR="$(AGENTS_MERGE_TOKEN=1 g push "$REMOTE" "$COMMIT:refs/heads/$MAIN" 2>&1 >/dev/null)" && {
    echo "ブートストラップ push: 完了（$MAIN に .agents 一式を載せた）"
    return 0
  }
  if is_cas_err "$PUSH_ERR"; then
    return 42   # CAS 敗北 → fetch し直して再構築
  fi
  echo "エラー: ブートストラップ push に失敗:" >&2
  printf '%s\n' "$PUSH_ERR" >&2
  cat >&2 <<EOF
手動レシピ: ブランチを切って通常の PR/マージ手順で上記ファイル
（.agents/bin/agents, .agents/PROTOCOL.md, AGENTS.md, CLAUDE.md, .gitignore${HOOK_REL:+, $HOOK_REL}）
を $MAIN に入れ、その後 install.sh を再実行して検証せよ。
EOF
  return 1
}

reconcile_checkout() {  # 手順8.5（§10）: ブートストラップ commit が remote main に載った後、
  # 導入クローンの checkout を FF で追いつかせる。これをしないと直後の git pull が
  # 「未追跡の .agents 等に上書きされる」で拒否される（導入初日に必ず踏む紙傷）。
  # 条件を全て満たす時だけ動き、満たさなければ 1 行の案内のみ（ユーザーの状態を壊さない）。
  local TIP cur f blob removed=""
  g fetch --quiet "$REMOTE" "+refs/heads/$MAIN:refs/remotes/$REMOTE/$MAIN" 2>/dev/null
  TIP="$(g rev-parse -q --verify "refs/remotes/$REMOTE/$MAIN" 2>/dev/null || true)"
  [ -n "$TIP" ] || return 0
  cur="$(g symbolic-ref --quiet --short HEAD || true)"
  [ "$cur" = "$MAIN" ] || return 0
  [ "$(g rev-parse HEAD 2>/dev/null)" = "$TIP" ] && return 0
  if ! g merge-base --is-ancestor HEAD "$TIP" 2>/dev/null; then
    echo "注意: ローカル $MAIN が remote と分岐している。自動では進めない（git pull --rebase 等で手動解消）"
    return 0
  fi
  # dirty な追跡ファイルは、内容が TIP の blob と同一（= install が配った更新そのもの）なら
  # HEAD 版へ戻してから FF する（FF 後に TIP の内容へ戻るため無損失）。それ以外の dirty は中止。
  local reverted="" xy
  restore_all() {
    local r
    while IFS= read -r r; do
      [ -n "$r" ] && g cat-file blob "$TIP:$r" > "$T/$r"
    done <<< "$removed
$reverted"
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    xy="${line:0:2}"; f="${line:3}"
    blob="$(g rev-parse -q --verify "$TIP:$f" 2>/dev/null || true)"
    if [ "$xy" = " M" ] && [ -n "$blob" ] && [ "$(g hash-object "$T/$f")" = "$blob" ]; then
      g checkout --quiet -- "$f" || { restore_all; echo "注意: $f を戻せず checkout の自動前進を中止（git pull を手で行え）"; return 0; }
      reverted="$reverted$f
"
    else
      restore_all
      echo "注意: 追跡ファイルに未コミット変更（${line}）があるため checkout を自動で進めない。commit 後の git pull が .agents 等の未追跡ファイルに阻まれたら、それらを消してから pull せよ（内容は commit 済みで失われない）"
      return 0
    fi
  done <<< "$(g status --porcelain -uno)"
  restore_removed() { restore_all; }
  # FF を阻む未追跡ファイルのうち「remote 版と内容同一」のものだけを消す（FF 後に追跡状態で復活する）
  while IFS= read -r -d '' f; do
    if [ -e "$T/$f" ] && ! g ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      blob="$(g rev-parse -q --verify "$TIP:$f" 2>/dev/null || true)"
      if [ -n "$blob" ] && [ "$(g hash-object "$T/$f")" = "$blob" ]; then
        rm -f "$T/$f"
        removed="$removed$f
"
      else
        restore_removed
        echo "注意: 未追跡の $f が remote 版と内容が異なるため checkout の自動前進を中止（git pull を手で行え）"
        return 0
      fi
    fi
  done < <(g diff --name-only -z HEAD "$TIP")
  if g merge --ff-only "$TIP" >/dev/null 2>&1; then
    echo "ローカル checkout を $MAIN 最新へ前進させた（この後の git pull は不要）"
  else
    restore_removed
    echo "注意: checkout の自動前進に失敗した。git pull を手で行え（.agents 等の未追跡ファイルに阻まれたら消してよい。内容は commit 済み）"
  fi
  return 0
}

# 判定順は §10 手順8 のとおり a（冪等スキップ）→ b（事前 dirty）。逆にすると
# ブートストラップ済み repo で「commit して再実行せよ」という誤った行動指示を出す。
bootstrap_identical() {
  g fetch --quiet "$REMOTE" "+refs/heads/$MAIN:refs/remotes/$REMOTE/$MAIN" 2>/dev/null
  local TIP remote_blob local_blob
  TIP="$(g rev-parse -q --verify "refs/remotes/$REMOTE/$MAIN" 2>/dev/null || true)"
  [ -n "$TIP" ] || return 1
  remote_blob="$(g rev-parse -q --verify "$TIP:.agents/bin/agents" 2>/dev/null || true)"
  local_blob="$(g hash-object "$T/.agents/bin/agents")"
  [ -n "$remote_blob" ] && [ "$remote_blob" = "$local_blob" ]
}

if bootstrap_identical; then
  echo "ブートストラップ push: スキップ（$MAIN の .agents/bin/agents は既に同一）"
elif [ "$NO_PUSH" = "1" ]; then
  SKIPPED_PUSH_REASON="--no-push 指定。内容を確認したら install.sh を再実行せよ（install.sh が push する）"
elif [ -n "$PRE_DIRTY" ]; then
  SKIPPED_PUSH_REASON="以下に既存の未コミット変更があるため自動 push しない:
${PRE_DIRTY}内容を確認して commit した後、install.sh を再実行せよ（install.sh が push する）"
else
  ok=1
  for i in 1 2 3 4 5; do
    push_files "$i"; rc=$?
    if [ $rc -eq 0 ]; then ok=0; break; fi
    if [ $rc -eq 42 ]; then continue; fi
    exit 1
  done
  if [ $ok -ne 0 ]; then
    echo "エラー: ブートストラップ push が CAS 敗北を 5 回超えた。少し待って install.sh を再実行せよ" >&2
    exit 1
  fi
fi

# 手順8.5: ブートストラップ内容が remote main に載っている場合のみ、導入クローンの checkout を追いつかせる
if [ -z "$SKIPPED_PUSH_REASON" ]; then
  reconcile_checkout
fi

# ---------------------------------------------------------------------------
# 手順9: 出力（次にやることを明示）
# ---------------------------------------------------------------------------
echo ""
echo "==== agents-kit 導入完了: $T ===="
echo "健全性の確認: .agents/bin/agents doctor をいつでも実行できる（read-only の一括検査。--run-tests で main のテスト実走つき）"
if [ "$CONFIG_CREATED" = "1" ]; then
  echo "(a) .agents/config.json の test_cmd を設定せよ。例:"
else
  echo "(a) .agents/config.json の test_cmd を確認せよ。例:"
fi
cat <<EOF
      {"main_branch": "$MAIN", "test_cmd": "npm test"}   # pytest なら "pytest -q"、テスト無し repo は "true" と明示
    設定後、repo ルートで一度 sh -c '<test_cmd>' を実行し素で通ることを確認せよ
    （main の時点で通らない test_cmd は全セッションの done/merge を止める）。
    言語の生成物（__pycache__ 等）は repo の .gitignore に入れておくこと（残ると done が dirty で停止する）。
    merge_lock_ttl_min（既定 30 分）はフルテスト所要時間の 2 倍以上に設定すること
    （ハートビートがあるため下回っても安全性は壊れないが、警告が増える）。
    config.json はクローンローカル＝コミットされない。別クローンでは install.sh 再実行＋test_cmd 再設定。
(b) 各 AI セッションには「.agents/PROTOCOL.md を読め」とだけ言えばよい。
(c) 推奨（GitHub の場合）: branch protection は $MAIN と $STATE に対して
    「Allow force pushes をオフ」「Allow deletions をオフ」の 2 つだけ有効化。
    Require a pull request before merging 系は設定しない（agents merge の直接 push と非互換で
    ツールが自壊する。どうしても設定する場合はユーザー自身を bypass に入れる）。
EOF
if [ -n "$SKIPPED_PUSH_REASON" ]; then
  echo "(d) ブートストラップ push はスキップした:"
  printf '%s\n' "$SKIPPED_PUSH_REASON" | sed 's/^/    /'
fi
if [ "$HOOK_MODE" = "outside" ]; then
  echo "(!) main 直 push 防壁は未設置（core.hooksPath が repo 外）。上記の赤字警告に従え。"
fi
exit 0
