{ writers, lychee, jq }:
writers.writeDashBin "brockman-linkrot" ''
  set -efux

  [ "$#" -eq 1 ] || {
    echo "Usage: $0 CONFIG_JSON" >&2
    exit 1
  }

  tmp=$(mktemp)

  clean() {
    rm -f "$tmp"
  }
  trap clean EXIT

  CONFIG_JSON="$1"

  cp "$CONFIG_JSON" "$(dirname "$CONFIG_JSON")/$(basename $CONFIG_JSON .json)_$(date +%s).json"

  lychee_output=$(${lychee}/bin/lychee --format json "$CONFIG_JSON" || :)

  ${jq}/bin/jq \
    --argjson lycheeResult "$lychee_output" \
    '($lycheeResult.fail_map | to_entries[] | .value | map(.url)) as $brokenUrls
    | .bots |= map_values(.feed as $feed | select($brokenUrls | any(. == $feed) | not))' \
      < "$CONFIG_JSON" > "$tmp"

  cp "$tmp" "$CONFIG_JSON"
''
