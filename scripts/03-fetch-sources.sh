#!/usr/bin/env bash
# Fetch third-party sources at the commits pinned in config.sh into vendor/<name>.
# Already-current checkouts are left alone.
#
# Usage: scripts/03-fetch-sources.sh [name...]   (default: every pinned source)
source "$(dirname "$0")/lib.sh"
need git

for entry in "${SOURCES[@]}"; do
  IFS='|' read -r name url commit <<<"$entry"
  if (($#)) && [[ " $* " != *" $name "* ]]; then
    continue
  fi
  dir="$ROOT/vendor/${name:?}"
  if [[ $(git -C "$dir" rev-parse HEAD 2>/dev/null) == "$commit" ]]; then
    log "$name: already at ${commit:0:12}"
    continue
  fi
  log "$name: fetching ${commit:0:12} from $url"
  rm -rf "$dir" && mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" fetch -q --depth 1 "$url" "$commit"
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
done
