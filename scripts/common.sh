#!/bin/bash
export TAG=${CIRCLE_TAG:-$(git describe --tags)}

docker_tag_and_push(){
    local tag=${1}

    docker tag ${IMAGE}:${CIRCLE_SHA1} ${IMAGE}:${tag}

    docker push ${IMAGE}:${tag}
}

docker_login(){
    docker login -u ${DOCKER_USER} -p "${DOCKER_PASSWORD}" ${DOCKER_REGISTRY}
}
