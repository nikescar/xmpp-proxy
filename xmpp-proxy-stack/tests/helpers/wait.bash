# xmpp-proxy-stack/tests/helpers/wait.bash

# Wait with timeout for a condition
wait_for() {
    local condition="$1"
    local timeout="${2:-30}"
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if eval "$condition"; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    return 1
}
