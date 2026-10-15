# --- renames (merge group) ----------------------------------------------------------------

# O: commands on `other`, M: commands on main, then `merge other`
rn() { printf 'git checkout -q other; %s; git add -A; git commit -qm other; git checkout -q main; %s; git add -A; git commit -qm mainline' "$1" "$2"; }

if wanted merge; then
    case_ "rename: renamed on theirs, edited on ours" fx_rbase "$(rn 'git mv a.txt moved.txt' 'sed -i.bak s/line\ 3/LINE\ 3/ a.txt; rm a.txt.bak')" 'G merge other'
    case_ "rename: renamed on ours, edited on theirs" fx_rbase "$(rn 'sed -i.bak s/line\ 3/LINE\ 3/ a.txt; rm a.txt.bak' 'git mv a.txt moved.txt')" 'G merge other'
    case_ "rename: renamed on theirs, nothing on ours" fx_rbase "$(rn 'git mv a.txt moved.txt' 'echo more > k.txt')" 'G merge other'
    case_ "rename: renamed and edited on theirs, edited elsewhere on ours" fx_rbase "$(rn 'git mv a.txt moved.txt; echo tail >> moved.txt' 'echo edit >> a.txt')" 'G merge other'
    case_ "rename: both sides rename the same way" fx_rbase "$(rn 'git mv a.txt moved.txt' 'git mv a.txt moved.txt; echo tail >> moved.txt')" 'G merge other'
    case_ "rename: both sides rename differently (1to2)" fx_rbase "$(rn 'git mv a.txt A1.txt' 'git mv a.txt A2.txt')" 'G merge other'
    case_ "rename: rename/delete" fx_rbase "$(rn 'git mv a.txt moved.txt' 'git rm -q a.txt')" 'G merge other'
    case_ "rename: delete/rename" fx_rbase "$(rn 'git rm -q a.txt' 'git mv a.txt moved.txt')" 'G merge other'
    case_ "rename: rename onto a file the other side added (rename/add)" fx_rbase "$(rn 'git mv a.txt c.txt' 'echo new > c.txt')" 'G merge other'
    case_ "rename: rename into a subdirectory" fx_rbase "$(rn 'git mv b.txt src/b.txt' 'echo x >> b.txt')" 'G merge other'
    case_ "rename: two files swap names" fx_rbase "$(rn 'git mv a.txt t.txt; git mv b.txt a.txt; git mv t.txt b.txt' 'echo x >> k.txt')" 'G merge other'
    case_ "rename: renamed and edited on both with a conflict" fx_rbase "$(rn 'git mv a.txt moved.txt; sed -i.bak s/line\ 5/THEIRS\ 5/ moved.txt; rm moved.txt.bak' 'sed -i.bak s/line\ 5/OURS\ 5/ a.txt; rm a.txt.bak')" 'G merge other'
    case_ "rename: inexact rename" fx_rbase "$(rn 'git mv a.txt moved.txt; echo extra >> moved.txt; sed -i.bak s/line\ 2/two/ moved.txt; rm moved.txt.bak' 'echo m >> k.txt')" 'G merge other'
    case_ "rename: below the similarity threshold is a delete and an add" fx_rbase "$(rn 'git rm -q b.txt; printf "x\ny\nz\n" > B.txt' 'echo edit >> b.txt')" 'G merge other'
    case_ "rename: a copy is not a rename" fx_rbase "$(rn 'cp a.txt a2.txt' 'echo edit >> a.txt')" 'G merge other'
    case_ "rename: directory rename with an edit inside" fx_rbase "$(rn 'git mv docs documentation' 'echo more >> docs/d.txt')" 'G merge other'
    case_ "rename: directory rename with a file added on the other side" fx_rbase "$(rn 'git mv docs documentation' 'echo new > docs/n.txt')" 'G merge other'
    case_ "rename: directory renamed on ours, file added on theirs" fx_rbase "$(rn 'echo new > docs/n.txt' 'git mv docs documentation')" 'G merge other'
    case_ "rename: directory renamed to a nested path" fx_rbase "$(rn 'mkdir -p deep/er; git mv docs deep/er/docs' 'echo x >> docs/d.txt')" 'G merge other'
    case_ "rename: a directory with two files renamed, one edited" fx_rbase "$(rn 'echo more >> src/s2.txt; echo s2 > src/s2.txt; git add src/s2.txt; git commit -qm s2; git mv src source' 'echo edit >> src/s.txt')" 'G merge other'
    case_ "rename: renamed file also changes mode" fx_rbase "$(rn 'git mv a.txt moved.txt; chmod +x moved.txt' 'echo edit >> a.txt')" 'G merge other'
    case_ "rename: renamed on both sides to nested names" fx_rbase "$(rn 'git mv a.txt src/a.txt' 'git mv a.txt docs/a.txt')" 'G merge other'
    case_ "rename: file replaced by a rename of another" fx_rbase "$(rn 'git rm -q a.txt; git mv b.txt a.txt' 'echo edit >> b.txt')" 'G merge other'
    case_ "rename: cherry-pick over a rename" fx_rbase "$(rn 'echo tail >> a.txt' 'git mv a.txt moved.txt')" 'G cherry-pick other'
    case_ "rename: revert over a rename" fx_rbase 'git checkout -q other; echo tail >> a.txt; git commit -qam edit; git mv a.txt moved.txt; git commit -qm rename; git checkout -q main; git merge -q other' 'G revert --no-edit HEAD~1'
    case_ "rename: stash pop over a rename" fx_rbase 'echo local >> a.txt; git stash -q; git mv a.txt moved.txt; git commit -qm rename' 'G stash pop'
    case_ "rename: diff3 style with a renamed file" fx_rbase "$(rn 'git mv a.txt moved.txt; sed -i.bak s/line\ 5/THEIRS\ 5/ moved.txt; rm moved.txt.bak' 'sed -i.bak s/line\ 5/OURS\ 5/ a.txt; rm a.txt.bak; git config merge.conflictStyle diff3')" 'G merge other'
fi

# --- conflict styles ----------------------------------------------------------------------

if wanted merge; then
    zd() { printf 'git checkout -q other; printf "%s" > a.txt; git commit -qam o; git checkout -q main; printf "%s" > a.txt; git commit -qam m; git config merge.conflictStyle %s' "$2" "$1" "$3"; }
    BASE='a\nb\nc\nd\ne\nf\ng\n'
    case_ "style: merge, common lines inside" fx_rbase "$(zd 'a\nb\nX\nd\nY\nf\ng\n' 'a\nb\nZ\nd\nW\nf\ng\n' merge)" 'G merge other'
    case_ "style: diff3, common lines inside" fx_rbase "$(zd 'a\nb\nX\nd\nY\nf\ng\n' 'a\nb\nZ\nd\nW\nf\ng\n' diff3)" 'G merge other'
    case_ "style: zdiff3, common lines inside" fx_rbase "$(zd 'a\nb\nX\nd\nY\nf\ng\n' 'a\nb\nZ\nd\nW\nf\ng\n' zdiff3)" 'G merge other'
    case_ "style: zdiff3, common edges" fx_rbase "$(zd 'a\nb\nc\nS\nd\nQ\nT\ne\nf\ng\n' 'a\nb\nc\nS\nU\nQ\nT\ne\nf\ng\n' zdiff3)" 'G merge other'
    case_ "style: diff3, common edges" fx_rbase "$(zd 'a\nb\nc\nS\nd\nQ\nT\ne\nf\ng\n' 'a\nb\nc\nS\nU\nQ\nT\ne\nf\ng\n' diff3)" 'G merge other'
    case_ "style: zdiff3 with an added block" fx_rbase "$(zd 'a\nb\nc\nn1\nn2\nd\ne\nf\ng\n' 'a\nb\nc\nn1\nm2\nd\ne\nf\ng\n' zdiff3)" 'G merge other'
    case_ "style: zdiff3 add/add" fx_rbase 'git checkout -q other; printf "p\nq\nr\n" > n.txt; git add n.txt; git commit -qm o; git checkout -q main; printf "p\nQ\nr\n" > n.txt; git add n.txt; git commit -qm m; git config merge.conflictStyle zdiff3' 'G merge other'
    case_ "style: cherry-pick zdiff3" fx_rbase "$(zd 'a\nb\nX\nd\nY\nf\ng\n' 'a\nb\nZ\nd\nW\nf\ng\n' zdiff3)" 'G cherry-pick other'
fi
