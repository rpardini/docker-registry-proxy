#!/bin/sh
echo Start publish image
set -ex

source ./scripts/common.sh

IMAGE=${1}
TAG=${2:-$CIRCLE_TAG}

docker_login

docker pull ${IMAGE}:${CIRCLE_SHA1}

docker_tag_and_push ${TAG}

set +x
echo End publish image
