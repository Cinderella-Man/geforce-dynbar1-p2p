# shellcheck shell=bash source-path=SCRIPTDIR
# Old location, kept for one release (README, Build and install: Old paths): the scripts moved to contrib/. Sources
# contrib/common.sh with the settings of this directory's config.sh unless P2P_CONFIG is set.
P2P_CONFIG=${P2P_CONFIG:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/config.sh}
# shellcheck source=../common.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../common.sh"
