# Compatibility aggregator for json_output.sh (split into focused modules).
_JSON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_JSON_LIB_DIR}/json_output_core.sh"
source "${_JSON_LIB_DIR}/json_output_nested.sh"
