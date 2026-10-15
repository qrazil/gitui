# --- core.ignorecase ---------------------------------------------------------------------
# The work tree is case-sensitive here: `core.ignorecase=true` makes git (and
# 1git) fold names against the index as on a case-insensitive volume, and a
# hard link stands in for "the same file under another case" (same size,
# same mtime), which is what such a volume answers for the new name.

IC='git config core.ignorecase true'

if wanted stash; then
    case_ "icase: stash -u leaves a case variant of a tracked file" fx_rbase "$IC; echo v > B.TXT; echo n > new.txt; echo m >> a.txt" 'G stash push -u; G stash list; git show --stat --format= "stash@{0}^3" 2>&1; ls'
    case_ "icase: stash -u with an untracked variant directory" fx_rbase "$IC; mkdir -p SRC; echo n > SRC/new.txt; echo m >> a.txt" 'G stash push -u; git ls-tree -r --name-only "stash@{0}^3" 2>&1; ls'
    case_ "icase: stash pop over a case-only rename on the branch" fx_rbase "$IC; echo local >> a.txt; git stash -q; git mv a.txt A.txt; git commit -qm rename; ln A.txt a.txt" 'G stash pop; G stash list; git ls-files'
    case_ "icase: stash push after a case-only rename" fx_rbase "$IC; git mv a.txt A.txt; echo more >> A.txt" 'G stash push; G stash pop; git status -s; git ls-files'
fi

if wanted rebase; then
    case_ "icase: rebase over a case-only rename, the new name is there" fx_rbase "$IC; git checkout -q other; git mv a.txt A.txt; git commit -qm mv; git checkout -q main; echo more >> a.txt; git commit -qam edit; git checkout -q other; ln A.txt a.txt" 'G rebase main; git ls-files'
    case_ "icase: rebase a case-only rename onto an edit" fx_rbase "$IC; git checkout -q other; git mv a.txt A.txt; git commit -qm mv; git checkout -q main; echo more >> b.txt; git commit -qam edit; git checkout -q other" 'G rebase main; git ls-files'
fi

if wanted pick; then
    case_ "icase: revert a case-only rename" fx_rbase "$IC; git mv a.txt A.txt; git commit -qm rename" 'G revert --no-edit HEAD; git ls-files'
    case_ "icase: cherry-pick a commit adding a case variant of a tracked file" fx_rbase "$IC; git checkout -q other; echo v > K.txt; git add K.txt; git commit -qm variant; git checkout -q main" 'G cherry-pick other; git ls-files; ls'
fi

if wanted clean; then
    case_ "icase: clean keeps case variants of tracked files" fx_rbase "$IC; echo v > K.TXT; mkdir -p DOCS; echo n > DOCS/x.txt; echo z > zzz.txt" 'G clean -n -d; G clean -f -d; ls'
    case_ "icase: clean -x honors ignore patterns case-insensitively" fx_rbase "$IC; echo '*.log' > .gitignore; git add .gitignore; git commit -qm ign; echo v > X.LOG; echo z > zzz.txt" 'G clean -n -x; G clean -n'
fi
