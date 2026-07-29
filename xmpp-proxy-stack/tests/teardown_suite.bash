# xmpp-proxy-stack/tests/teardown_suite.bash
teardown_suite() {
    # Clean up any test containers
    docker ps -a --filter "label=xmpp-proxy-test" -q | xargs -r docker rm -f
}
