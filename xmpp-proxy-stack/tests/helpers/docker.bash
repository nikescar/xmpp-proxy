# xmpp-proxy-stack/tests/helpers/docker.bash

# Wait for Docker container to be healthy
wait_for_service() {
    local container="$1"
    local timeout="${2:-30}"
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if docker ps --filter "name=$container" --filter "health=healthy" | grep -q "$container"; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    return 1
}

# Wait for log message to appear
wait_for_log() {
    local message="$1"
    local timeout="${2:-30}"
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if docker logs xmpp-proxy-stack 2>&1 | grep -q "$message"; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    return 1
}
