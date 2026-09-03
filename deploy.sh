#!/usr/bin/env bash
#
# deploy.sh
# ------------------------------------------------------------
# Commits and pushes the current state of your HTML report
# folder to GitHub. Run this by hand whenever you're ready to
# publish this month's updates — Netlify (connected to the
# same GitHub repo) will auto-build/deploy on push.
#
# One-time setup required before this works:
#   - HTML_DIR must already be a git repo with an 'origin'
#     remote pointing at your GitHub repo (see setup steps).
#   - SSH key added to your GitHub account so 'git push' does
#     not prompt for a username/password.
#
# Usage:
#   ./deploy.sh [path-to-folder-containing-the-html-files] ["optional commit message"]
#
# If no folder is given, the current directory is used.
# If no message is given, a timestamped default is used.
# ------------------------------------------------------------

set -euo pipefail

HTML_DIR="${1:-.}"
MSG="${2:-Update reports $(date +'%Y-%m-%d %H:%M')}"

if [[ ! -d "$HTML_DIR" ]]; then
  echo "ERROR: folder not found: $HTML_DIR" >&2
  exit 1
fi

cd "$HTML_DIR"

if [[ ! -d .git ]]; then
  echo "ERROR: $(pwd) is not a git repository yet." >&2
  echo "Run the one-time setup (git init + remote add origin + first push) first." >&2
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "ERROR: no 'origin' remote configured for this repo." >&2
  echo "Run: git remote add origin git@github.com:yourname/your-repo.git" >&2
  exit 1
fi

branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"

echo "Repo   : $(pwd)"
echo "Remote : $(git remote get-url origin)"
echo "Branch : $branch"
echo

git add -A

if git diff --cached --quiet; then
  echo "Nothing changed — nothing to deploy."
  exit 0
fi

echo "Changes to be pushed:"
git diff --cached --stat
echo

git commit -m "$MSG"
git push origin "$branch"

echo
echo "Pushed to GitHub ($branch). Netlify should redeploy automatically within a minute or so."
