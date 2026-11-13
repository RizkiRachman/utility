# VENDORED: @firecrawl/opencode

- Upstream: https://github.com/firecrawl/opencode-firecrawl (Firecrawl org, first-party)
- Vendored version: 1.4.0 (pinned), license: ISC (see LICENSE)
- Vendored for offline operation: this stack builds and runs air-gapped, so the plugin source lives in-tree instead of being pulled at runtime.
- Runtime dependency: zod ^4.1.8 only (installed from the pre-install store at image build; see Dockerfile). Build-time devDependencies of upstream (@opencode/plugin, typescript, @types/node) are NOT needed at runtime; OpenCode 2 loads .ts plugin files directly.
- Byte fidelity: all 29 vendored files match upstream main (commit tree c0fd83fef4b0127bc3db2592407c788f410071bc) by git blob SHA1.
- Rule docs: `skills/firecrawl/rules/install.md` and `skills/firecrawl/rules/security.md` are vendored with the skill because `SKILL.md` links to them; they were missing from the first 27-file snapshot.

## Upgrade procedure

1. Fetch the new upstream tree (`https://api.github.com/repos/firecrawl/opencode-firecrawl/git/trees/main?recursive=1`).
2. Re-download each source file from `https://raw.githubusercontent.com/firecrawl/opencode-firecrawl/main/<path>` over the files in this directory.
3. Verify each file's git blob SHA1 against the new tree.
4. Bump the version pin in VENDORED.md, README.md, and engine/README.md.
5. If the zod range changed, re-resolve it once, update the pre-install store pin (populate-preinstall.sh + pre-install README), and rebuild.

## Runtime notes

- `firecrawl_developer_search` works with NO API key and no CLI.
- `firecrawl_alexandria` and the full CLI skills (scrape/crawl/map/search/agent) need `FIRECRAWL_API_KEY` (or OAuth) and the vendored `firecrawl-cli` (binary: `firecrawl`).
