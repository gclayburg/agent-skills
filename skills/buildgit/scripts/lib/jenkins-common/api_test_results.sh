# Compatibility aggregator for api_test_results.sh (split into focused modules).
_API_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_API_LIB_DIR}/jenkins_api.sh"
source "${_API_LIB_DIR}/test_results_collect.sh"
source "${_API_LIB_DIR}/test_results_format.sh"
