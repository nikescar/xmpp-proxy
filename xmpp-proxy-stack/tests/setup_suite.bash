# xmpp-proxy-stack/tests/setup_suite.bash
setup_suite() {
    export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    export PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
}
