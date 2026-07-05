# Compatibility aggregator for stage_display.sh (split into focused modules).
_STAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_STAGE_LIB_DIR}/stage_display_core.sh"
source "${_STAGE_LIB_DIR}/stage_display_parallel.sh"
