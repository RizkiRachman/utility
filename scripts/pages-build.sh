#!/bin/sh
# Canonical repomix pack for the Pages digest.
#
# Single source of truth for the repomix invocation. The Cloudflare Pages
# dashboard "Build command" predates deploy-digest.yml and still passes the
# removed --exclude flag, which fails every PR preview build. Point the
# dashboard at this script (or let deploy-digest.yml PATCH it back on main
# pushes); PR preview builds recover on their next run.
#
# repomix is PINNED: @latest renamed flags once already (--exclude ->
# --ignore) and a moving target cannot be kept working across dashboard
# config and CI. Bump deliberately in both this script and the docs.
set -eu
mkdir -p public
npx -y repomix@1.19.0 \
  --include "workspace/agents/opencode/**" \
  --ignore "**/node_modules/**,**/skills/**/data/**,**/skills/**/scripts/tests/**,**/*.csv,**/*.html,**/library/**,**/references/**,**/fixtures/**,**/fonts/**,**/pre-install/**,**/rag/test/corpus/**,**/.cocoindex_code/**,**/target/**,**/__pycache__/**,**/*.whl,**/*.deb,**/*.tgz,**/*.bin,**/*.tar*" \
  --style plain \
  --output public/repomix-output.txt
