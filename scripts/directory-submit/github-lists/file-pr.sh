#!/bin/zsh
# file-pr.sh <dir>: file ONE reviewed change. <dir> holds change.patch and pr.json, or issue.json.
# Needs: gh logged in with repo scope, git. Commits under your GitHub noreply address.
# Run it only after you have read the patch and the PR text.
set -e
d=${1:?usage: file-pr.sh <absolute dir>}
case $d in /*) ;; *) echo "use an absolute path"; exit 2 ;; esac
if [ -f $d/issue.json ]; then
  up=$(python3 -I -c "import json;print(json.load(open('$d/issue.json'))['upstream'])")
  t=$(python3 -I -c "import json;print(json.load(open('$d/issue.json'))['title'])")
  python3 -I -c "import json;open('$d/issue-body.md','w').write(json.load(open('$d/issue.json'))['body'])"
  echo "FILED $(gh issue create -R $up -t "$t" -F $d/issue-body.md)"
  exit 0
fi
j() { python3 -I -c "import json;print(json.load(open('$d/pr.json'))['$1'])"; }
up=$(j upstream); base=$(j base); sha=$(j base_sha); br=$(j branch); title=$(j title)
python3 -I -c "import json;open('$d/pr-body.md','w').write(json.load(open('$d/pr.json'))['body'])"
me=$(gh api user -q .login); id=$(gh api user -q .id); name=$(gh api user -q '.name // .login')
w=$(mktemp -d)
# the fork API returns the existing fork when you already have one, so the name is never guessed
fork=$(gh api -X POST repos/$up/forks -f name="${up%/*}-${up#*/}" -F default_branch_only=true -q .full_name)
for i in 1 2 3 4 5 6 7 8 9 10; do git ls-remote -q https://github.com/$fork >/dev/null 2>&1 && break; sleep 6; done
git clone -q --depth 50 https://github.com/$up $w/repo
cd $w/repo
git checkout -q -b $br origin/$base
# the upstream may have moved since the patch was made: fall back to the recorded base commit
if ! git apply --check $d/change.patch 2>/dev/null; then
  git fetch -q --depth 1 origin $sha && git checkout -q -B $br $sha
fi
git apply --check $d/change.patch
git apply $d/change.patch
git add -A
git -c user.name="$name" -c user.email="$id+$me@users.noreply.github.com" commit -q -m "$title"
git remote add fork https://github.com/$fork
git push -q -f fork $br
echo "FILED $(gh pr create -R $up --base $base --head ${fork%/*}:$br --title "$title" --body-file $d/pr-body.md)"
