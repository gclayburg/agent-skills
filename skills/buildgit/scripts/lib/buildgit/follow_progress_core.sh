# Compatibility aggregator for follow_progress_core.sh (split into focused modules).
_FOLLOW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_FOLLOW_LIB_DIR}/follow_progress_stages.sh"
source "${_FOLLOW_LIB_DIR}/follow_progress_render.sh"
