# Shared helpers for the skill tests. Sourced, not run. bash 3.2 compatible.
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/skills-test.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }

# expect_eq LABEL EXPECTED ACTUAL
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
# expect_match LABEL ERE TEXT
expect_match() { if printf '%s\n' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1" "no match for /$2/ in: $(printf '%s' "$3" | head -c 300)"; fi; }
expect_nomatch() { if printf '%s\n' "$3" | grep -qE -- "$2"; then bad "$1" "unexpected match for /$2/"; else ok "$1"; fi; }

# check_skill DIR: SKILL.md exists, front-matter starts on line 1, name = dir name (lowercase,
# digits, hyphens, max 64), description present (max 1024 chars), body not empty, every
# ${CLAUDE_SKILL_DIR}/... path it mentions exists, every script there is executable and parses.
check_skill() {
  d="$1"; n="$(basename "$d")"; f="$d/SKILL.md"
  if [ ! -f "$f" ]; then bad "$n: SKILL.md exists"; return; fi
  ok "$n: SKILL.md exists"
  expect_eq "$n: front-matter opens on line 1" "---" "$(sed -n 1p "$f")"
  close=$(awk 'NR>1 && /^---[[:space:]]*$/ {print NR; exit}' "$f")
  if [ -z "$close" ]; then bad "$n: front-matter closes"; return; fi
  ok "$n: front-matter closes"
  fm=$(sed -n "2,$((close-1))p" "$f")
  name=$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1)
  expect_eq "$n: name matches directory" "$n" "$name"
  expect_match "$n: name is lowercase-hyphen, <= 64" '^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$' "$name"
  desc=$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -1)
  if [ -n "$desc" ] && [ "${#desc}" -le 1024 ]; then ok "$n: description present, ${#desc} chars"; else bad "$n: description present, <= 1024 chars" "${#desc} chars"; fi
  expect_match "$n: description says when to use it" '[Uu]se (it )?when|[Uu]se this when|Trigger' "$desc"
  bad_keys=$(printf '%s\n' "$fm" | grep -E '^[A-Za-z_-]+:' | sed 's/:.*//' | grep -vxE 'name|description|when_to_use|argument-hint|allowed-tools|disable-model-invocation|user-invocable|license|compatibility|metadata' || true)
  expect_eq "$n: only known front-matter keys" "" "$bad_keys"
  body_lines=$(sed -n "$((close+1)),\$p" "$f" | grep -c '[^[:space:]]')
  [ "$body_lines" -ge 10 ] && ok "$n: body has instructions ($body_lines lines)" || bad "$n: body has instructions" "$body_lines lines"
  [ "$(wc -l < "$f")" -le 500 ] && ok "$n: SKILL.md under 500 lines" || bad "$n: SKILL.md under 500 lines"
  for p in $(grep -oE '\$\{CLAUDE_SKILL_DIR\}/[A-Za-z0-9._/-]+' "$f" | sort -u | sed 's/^\${CLAUDE_SKILL_DIR}\///' | grep -v '/$'); do
    [ -e "$d/$p" ] && ok "$n: referenced file $p exists" || bad "$n: referenced file $p exists"
  done
  for s in "$d"/scripts/*.sh; do
    [ -e "$s" ] || continue
    [ -x "$s" ] && ok "$n: $(basename "$s") is executable" || bad "$n: $(basename "$s") is executable"
    bash -n "$s" 2>/dev/null && ok "$n: $(basename "$s") parses" || bad "$n: $(basename "$s") parses"
  done
}

summary() { printf '%s: %d passed, %d failed\n' "$1" "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }
