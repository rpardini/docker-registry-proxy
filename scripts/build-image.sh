#!/bin/sh
echo Start build image
set -ex
source ./scripts/common.sh

IMAGE=${1}
shift

docker_login

docker build -t ${IMAGE}:${CIRCLE_SHA1} "$@"

docker push ${IMAGE}:${CIRCLE_SHA1}

docker_tag_and_push latest

if [ ! -z ${CIRCLE_BRANCH} ]; then
    docker_tag_and_push ${CIRCLE_BRANCH}
fi

set +x
echo End build image
