#!/usr/bin/env bash
# =============================================================================
# populate-remote.sh  —  push the standalone I-SPI deployment repo to GitHub
#
# Run this from inside your local repo directory, e.g. (Git Bash in RStudio):
#   cd /c/Users/d78039e/Documents/R-git/deploy_ispi
#   bash push-to-github.sh
#
# It is safe to re-run: every step is idempotent.
#
# It assumes the remote https://github.com/immunoplex/i-spi-deployment was
# created on GitHub WITH an AGPL license (so it already has a LICENSE commit).
# The merge step below keeps that LICENSE and prefers YOUR files on any overlap.
# =============================================================================
set -euo pipefail

REMOTE_URL="https://github.com/immunoplex/i-spi-deployment.git"
# If you use SSH instead of HTTPS, comment the line above and use:
# REMOTE_URL="git@github.com:immunoplex/i-spi-deployment.git"
BRANCH="main"

echo "==> Working directory: $(pwd)"
read -r -p "    Is this your deploy repo directory? [y/N] " ok
[ "${ok:-}" = "y" ] || [ "${ok:-}" = "Y" ] || { echo "Aborting — cd into the repo first."; exit 1; }

# --- 0. Git identity must be set (commits fail otherwise) ---------------------
if ! git config user.email >/dev/null 2>&1; then
  echo "!! No git identity set. Configure it once, then re-run:"
  echo '     git config --global user.name  "Your Name"'
  echo '     git config --global user.email "you@example.com"'
  exit 1
fi

# --- 1. Initialise the repo (default branch = main) ---------------------------
if [ ! -d .git ]; then
  git init -b "$BRANCH" 2>/dev/null || { git init; git branch -M "$BRANCH"; }
else
  git branch -M "$BRANCH"
fi

# --- 2. Point 'origin' at the remote (idempotent) -----------------------------
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi
echo "==> origin = $(git remote get-url origin)"

# --- 3. Drop in .gitignore and .gitattributes if missing ----------------------
# .gitattributes forces LF endings. This matters: postgresql.yml embeds an
# init.sh (a #!/bin/bash script) inside a ConfigMap; if it carries Windows CRLF
# it can fail when the postgres container runs it on Linux. Normalising to LF
# here fixes that at commit time.
if [ ! -f .gitattributes ]; then
  cat > .gitattributes <<'EOF'
# Normalise all text to LF so manifests/scripts run correctly on Linux.
* text=auto eol=lf
*.sql text eol=lf
*.yml text eol=lf
*.md  text eol=lf
*.sh  text eol=lf
EOF
  echo "==> wrote .gitattributes"
fi

if [ ! -f .gitignore ]; then
  cat > .gitignore <<'EOF'
# --- RStudio / R cruft (this is an RStudio project dir) ---
.Rproj.user/
.Rhistory
.RData
.Ruserdata

# --- Secrets: never commit sed-substituted copies ---
# The tracked manifests keep the IMMUNOPLEX_* placeholders and are safe.
# If you make locally-substituted copies (real passwords/keys), keep them out:
*.local.yml
*-substituted.yml
*-secrets.yml
immunoplex-root-ca.crt

# --- this helper script ---
push-to-github.sh
populate-remote.sh

# --- OS ---
.DS_Store
Thumbs.db
EOF
  echo "==> wrote .gitignore"
fi

# --- 4. Stage everything, normalising line endings ----------------------------
git add -A
git add --renormalize . >/dev/null 2>&1 || true

# Show what will be committed, and warn if any file still has real secrets in it
echo "==> Files staged:"
git status --short
echo
echo "==> Placeholder check (these SHOULD still say IMMUNOPLEX_* — i.e. NOT yet"
echo "    substituted with real secrets):"
grep -rl "IMMUNOPLEX_OAUTH_SECRET\|IMMUNOPLEX_POSTGRES_PASSWORD" . \
  --include='*.yml' 2>/dev/null | sed 's/^/      placeholder present: /' || true
echo "    If any manifest shows a real password/hex string instead of a"
echo "    placeholder, Ctrl-C now and remove it before committing."
echo
read -r -p "==> Proceed to commit + push? [y/N] " go
[ "${go:-}" = "y" ] || [ "${go:-}" = "Y" ] || { echo "Stopped before commit."; exit 0; }

# --- 5. Commit (skip cleanly if nothing changed) ------------------------------
if git diff --cached --quiet; then
  echo "==> Nothing new to commit."
else
  git commit -m "Standalone I-SPI deployment: immunoplex rename, offline-images guide, local test runbook"
fi

# --- 6. Reconcile with the GitHub-created history (the AGPL LICENSE) ----------
git fetch origin || true
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  echo "==> Remote already has commits (e.g. the AGPL LICENSE). Merging them in,"
  echo "    keeping YOUR files on any overlap (LICENSE is brought in either way)."
  git merge -X ours --allow-unrelated-histories \
    -m "Merge GitHub-initialised repo (LICENSE) with local deployment files" \
    "origin/$BRANCH"
fi

# --- 7. Push ------------------------------------------------------------------
echo "==> Pushing to $REMOTE_URL ($BRANCH)"
echo "    (HTTPS will prompt for GitHub credentials — use a Personal Access"
echo "     Token as the password, or have Git Credential Manager handle it.)"
git push -u origin "$BRANCH"

echo
echo "==> Done. Recent history:"
git log --oneline -n 5
echo "==> View it at: https://github.com/immunoplex/i-spi-deployment"
