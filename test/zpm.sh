#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
project=$(mktemp -d)
trap 'rm -rf "$project"' EXIT
mkdir -p "$project/.zpm/kb/feedback"
cp .zpm/mounts.json "$project/.zpm/"
cp .zpm/kb/knowledge.pl "$project/.zpm/kb/"
cp .zpm/kb/feedback/knowledge.pl .zpm/kb/feedback/journal.wal "$project/.zpm/kb/feedback/"
cd "$project"

# Each command reopens the project, including replay of its journals.
expect_query() {
    result=$(zpm query-logic --memory "$1" --goal "$2")
    if [ "$result" != "$3" ]; then
        echo "$1: $2 returned $result (expected $3)" >&2
        exit 1
    fi
}

zpm remember-fact --memory default --fact "adr(example, title, choice)" >/dev/null
expect_query default "current_decision(example, choice)" '[{}]'
zpm remember-fact --memory default --fact "supersedes(replacement, example)" >/dev/null
expect_query default "current_decision(example, choice)" '[]'

expect_query feedback "feedback:rule(rule_hexagonal_layers, architecture, _, high, _)" '[{}]'
zpm remember-fact --memory feedback --fact "feedback:trigger(test_rule, 'example.zig', file)" >/dev/null
expect_query feedback "feedback:applicable(test_rule, 'src/example.zig')" '[{}]'
