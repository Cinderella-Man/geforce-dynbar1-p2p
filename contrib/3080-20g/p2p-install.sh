#!/bin/bash
# Old location, kept for one release (README, Build and install: Old paths): runs contrib/<this name> with the
# settings of this directory's config.sh unless P2P_CONFIG is set.
d=$(dirname "$(readlink -f "$0")")
echo "note: contrib/3080-20g/ is deprecated and goes in the next release; use contrib/${0##*/} (settings: contrib/config.sh)" >&2
export P2P_CONFIG=${P2P_CONFIG:-$d/config.sh}
exec "$d/../${0##*/}" "$@"
