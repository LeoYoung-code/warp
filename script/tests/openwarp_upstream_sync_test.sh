#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

create_commit() {
  local repo_dir="$1"
  local file_name="$2"
  local content="$3"

  printf '%s\n' "$content" >"$repo_dir/$file_name"
  git -C "$repo_dir" add "$file_name"
  git -C "$repo_dir" commit -m "test: $file_name" >/dev/null
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$expected" != "$actual" ]]; then
    printf 'ASSERT_EQ failed: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_ne() {
  local left="$1"
  local right="$2"
  local message="$3"

  if [[ "$left" == "$right" ]]; then
    printf 'ASSERT_NE failed: %s\nboth: %s\n' "$message" "$left" >&2
    exit 1
  fi
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/repos"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

publish_dir="${TEST_PUBLISH_BARE:?}"
upstream_dir="${TEST_UPSTREAM_BARE:?}"

repo_dir_for() {
  case "$1" in
    test/publish) printf '%s\n' "$publish_dir" ;;
    test/upstream) printf '%s\n' "$upstream_dir" ;;
    *)
      echo "unknown repo: $1" >&2
      exit 1
      ;;
  esac
}

if [[ "$1" == "auth" && "$2" == "status" ]]; then
  echo "fake gh auth ok"
  exit 0
fi

if [[ "$1" == "repo" && "$2" == "view" ]]; then
  repo="$3"
  permission="ADMIN"
  if [[ "$repo" == "test/upstream" ]]; then
    permission="READ"
  fi

  printf '{"defaultBranchRef":{"name":"main"},"nameWithOwner":"%s","url":"https://example.com/%s","viewerPermission":"%s"}\n' "$repo" "$repo" "$permission"
  exit 0
fi

if [[ "$1" == "api" ]]; then
  path="$2"
  repo="${path#repos/}"
  repo="${repo%/commits/main}"
  repo_dir="$(repo_dir_for "$repo")"
  git --git-dir "$repo_dir" rev-parse refs/heads/main
  exit 0
fi

if [[ "$1" == "run" && "$2" == "list" ]]; then
  if printf '%s\0' "$@" | grep -Fz -- '--status' >/dev/null 2>&1; then
    echo "0"
  else
    echo "[]"
  fi
  exit 0
fi

if [[ "$1" == "issue" && "$2" == "create" ]]; then
  echo "fake issue create"
  exit 0
fi

echo "unsupported gh invocation: $*" >&2
exit 1
EOF
chmod +x "$TMP_DIR/bin/gh"

cat >"$TMP_DIR/bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$TMP_DIR/bin/cargo"

git init --bare "$TMP_DIR/repos/publish.git" >/dev/null
git init --bare "$TMP_DIR/repos/upstream.git" >/dev/null
git --git-dir "$TMP_DIR/repos/publish.git" symbolic-ref HEAD refs/heads/main
git --git-dir "$TMP_DIR/repos/upstream.git" symbolic-ref HEAD refs/heads/main

git init "$TMP_DIR/repos/seed" >/dev/null
git -C "$TMP_DIR/repos/seed" config user.name "Codex Test"
git -C "$TMP_DIR/repos/seed" config user.email "codex@example.com"
git -C "$TMP_DIR/repos/seed" branch -m main

create_commit "$TMP_DIR/repos/seed" README.md "base"
base_sha="$(git -C "$TMP_DIR/repos/seed" rev-parse HEAD)"

git -C "$TMP_DIR/repos/seed" remote add publish "$TMP_DIR/repos/publish.git"
git -C "$TMP_DIR/repos/seed" remote add upstream "$TMP_DIR/repos/upstream.git"
git -C "$TMP_DIR/repos/seed" push publish main >/dev/null
git -C "$TMP_DIR/repos/seed" push upstream main >/dev/null

git -C "$TMP_DIR/repos/seed" tag openwarp-v2026.05.07.1 "$base_sha"
git -C "$TMP_DIR/repos/seed" push publish openwarp-v2026.05.07.1 >/dev/null

create_commit "$TMP_DIR/repos/seed" upstream.txt "upstream change"
upstream_sha="$(git -C "$TMP_DIR/repos/seed" rev-parse HEAD)"
git -C "$TMP_DIR/repos/seed" push upstream main >/dev/null

git clone "$TMP_DIR/repos/publish.git" "$TMP_DIR/worktree" >/dev/null
git -C "$TMP_DIR/worktree" config user.name "Codex Test"
git -C "$TMP_DIR/worktree" config user.email "codex@example.com"
git -C "$TMP_DIR/worktree" switch main >/dev/null

env \
  PATH="$TMP_DIR/bin:$PATH" \
  TEST_PUBLISH_BARE="$TMP_DIR/repos/publish.git" \
  TEST_UPSTREAM_BARE="$TMP_DIR/repos/upstream.git" \
  PUBLISH_REPO="test/publish" \
  UPSTREAM_REPO="test/upstream" \
  PUBLISH_REMOTE_URL="$TMP_DIR/repos/publish.git" \
  UPSTREAM_REMOTE_URL="$TMP_DIR/repos/upstream.git" \
  bash -c "cd \"$TMP_DIR/worktree\" && bash \"$ROOT_DIR/script/openwarp_upstream_sync\" --execute" \
  >/tmp/openwarp-upstream-sync-test.log 2>&1

publish_main_sha="$(git --git-dir "$TMP_DIR/repos/publish.git" rev-parse refs/heads/main)"
new_tag_target="$(git --git-dir "$TMP_DIR/repos/publish.git" rev-list -n 1 "openwarp-v$(date +%Y.%m.%d).1" 2>/dev/null || true)"

assert_eq "$upstream_sha" "$publish_main_sha" "publish main should advance to upstream when old publish SHA already has a release tag"
assert_eq "$upstream_sha" "$new_tag_target" "new daily release tag should point at synchronized main SHA"
assert_ne "$base_sha" "$publish_main_sha" "publish main should not stay at the previously tagged commit"

printf 'openwarp_upstream_sync regression test passed\n'
