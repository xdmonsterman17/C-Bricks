#!/usr/bin/env sh
# Commits the repo's changes and pushes them to GitHub (origin).
# Right-click > Execute works too: it opens its own terminal window.
# Usage: ./push-github.sh "commit message" [-y]     (-y: don't ask before committing and pushing)
# What is committed follows .gitignore (the working notes, build/, .build/ and prebuilt/ stay local). Nothing is
# rewritten: a plain commit and a normal push (no force); if GitHub has newer commits, the push stops and says so.
YES=0
MSG=""
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    *) MSG="$a" ;;
  esac
done
cd "$(dirname "$0")"
# Run from a file manager (right-click > Execute: no terminal, so nothing would be seen): open one and run this
# script in it again; that window stays open at the end until Enter is pressed.
if [ ! -t 0 ] || [ ! -t 1 ]; then
  SELF="$(pwd)/$(basename "$0")"
  for T in x-terminal-emulator lxterminal xfce4-terminal gnome-terminal konsole xterm; do
    command -v "$T" >/dev/null 2>&1 || continue
    case "$T" in
      gnome-terminal) exec "$T" -- sh "$SELF" "$@" ;;
      *) exec "$T" -e sh "$SELF" "$@" ;;
    esac
  done
  echo "push-github.sh: no terminal program found: run it from a terminal"; exit 1
fi
trap 'echo; printf "Press Enter to close. "; read -r _' EXIT
if [ -z "$MSG" ]; then
  if [ -t 0 ]; then printf "Commit message: "; read -r MSG; fi
  if [ -z "$MSG" ]; then echo "push-github.sh: give a commit message: ./push-github.sh \"what changed\""; exit 1; fi
fi
git remote get-url origin >/dev/null 2>&1 || { echo "push-github.sh: no 'origin' remote"; exit 1; }
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git add -A
if git diff --cached --quiet; then
  echo "Nothing new to commit."
else
  git status --short
  if [ "$YES" -ne 1 ]; then
    printf "Commit these to '%s' and push to %s? [y/N] " "$BRANCH" "$(git remote get-url origin)"
    read -r ans
    case "$ans" in y|Y|yes) ;; *) git reset -q; echo "Cancelled (nothing committed)."; exit 1 ;; esac
  fi
  git commit -q -m "$MSG" || exit 1
fi
git push origin "$BRANCH" || { echo "push-github.sh: the push failed (newer commits on GitHub? run: git pull --rebase origin $BRANCH)"; exit 1; }
echo "Pushed $BRANCH to $(git remote get-url origin)."
