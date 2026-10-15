# `GIT_icase.m31` -- the case-folding name sets and the NFC conversion that
# `core.ignorecase` and `core.precomposeunicode` rest on, driven through
# `t_icase` and checked against known answers (ASCII-only fold, the index
# keeps its own spelling) and, for NFC, Python's `unicodedata`.
# The commands that use them are compared with git in
# scripts/compare_write.sh and scripts/compare_merge*.sh (group `icase`).
# Shares `test.sh`'s shell, `$WORK`, `$LANGC`, `build`, `note`/`bad`.

build t_icase

icase_check() { # <label> <want> <args...>
    local label=$1 want=$2
    shift 2
    local got
    got=$("$WORK/t_icase" "$@" 2>&1)
    if [ "$got" = "$want" ]; then
        note "icase: $label"
    else
        bad "icase: $label" "want '$want', got '$got'"
    fi
}

icase_check "fold lowers ASCII" "a.txt" fold "A.TXT"
icase_check "fold leaves non-ASCII alone" "stra$(printf '\xc3\x9f')e-$(printf '\xc3\x89')" fold "STRA$(printf '\xc3\x9f')E-$(printf '\xc3\x89')"
icase_check "file lookup finds the index spelling" "Docs/Readme.md" file "docs/README.MD" "Docs/Readme.md" "a.txt"
icase_check "file lookup misses" "-" file "docs/other.md" "Docs/Readme.md"
icase_check "the first spelling wins" "A.txt" file "a.TXT" "A.txt" "a.txt"
icase_check "a directory folds" "yes" dir "DOCS" "Docs/Readme.md"
icase_check "a nested directory folds" "yes" dir "docs/SUB" "Docs/Sub/f.txt"
icase_check "a file is not a directory" "no" dir "a.txt" "a.txt"
icase_check "adjust takes the index directories" "Docs/Sub/new.txt" adjust "DOCS/sub/new.txt" "Docs/Sub/f.txt"
icase_check "adjust leaves the file name" "Docs/NEW.MD" adjust "docs/NEW.MD" "Docs/Readme.md"
icase_check "adjust of an unknown directory" "Other/x" adjust "Other/x" "Docs/Readme.md"
icase_check "adjust of a top level name" "X.txt" adjust "X.txt" "x.txt"
icase_check "ignorecase from config" "true" config ignorecase "[core]
	ignorecase = true
" 
icase_check "ignorecase unset" "false" config ignorecase "[core]
	bare = false
"

# NFC against Python's unicodedata, for composed, decomposed and mixed names
for sample in "a" "caf$(printf '\xc3\xa9')" "cafe$(printf '\xcc\x81')" "$(printf 'A\xcc\x88rger')" "$(printf '\xe1\x84\x80\xe1\x85\xa1')" "$(printf 'o\xcc\x82\xcc\xa3')" "$(printf '\xe6\x97\xa5\xe6\x9c\xac')"; do
    want=$(python3 -c 'import sys,unicodedata; sys.stdout.write(unicodedata.normalize("NFC", sys.argv[1]))' "$sample")
    got=$("$WORK/t_icase" nfc "$sample")
    if [ "$got" = "$want" ]; then
        note "icase: nfc of $(printf '%s' "$sample" | od -An -c | tr -s ' ' | head -c 40)"
    else
        bad "icase: nfc" "want '$want', got '$got'"
    fi
done
