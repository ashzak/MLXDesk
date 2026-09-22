#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
output="$project_dir/THIRD_PARTY_NOTICES.md"
{
    echo "# Third-Party Notices"
    echo
    echo "Generated from the resolved Swift package checkouts. Review before each public release."
    for checkout in "$project_dir"/.build/checkouts/*; do
        [[ -d "$checkout" ]] || continue
        license=$(find "$checkout" -maxdepth 2 -type f \( -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'COPYING' \) | head -1)
        [[ -n "$license" ]] || continue
        echo
        echo "## ${checkout:t}"
        echo
        echo '```text'
        sed -n '1,240p' "$license"
        echo '```'
    done
} > "$output"
echo "Created $output"
