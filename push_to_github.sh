#!/usr/bin/env bash
set -euo pipefail

cd /Users/giteshkukreja/Downloads/DropShelf

echo "==> Initializing git repo..."
git init

echo "==> Staging all files..."
git add -A

echo "==> Committing..."
git commit -m "first commit"

echo "==> Setting main branch..."
git branch -M main

echo "==> Adding remote..."
git remote remove origin 2>/dev/null || true
git remote add origin https://github.com/giteshkukreja19/DropShelf.git

echo "==> Pushing to GitHub..."
git push -u origin main

echo "Done!"
