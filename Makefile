clean:
	rm -rf docker_mirror_cache/*

build:
	docker build --tag docker-registry-proxy .

start:
	docker run --rm --name=docker-registry-proxy -it \
		-p 0.0.0.0:3128:3128 \
		-p 0.0.0.0:8081:8081 \
		-e DEBUG=true \
		-v $(dir $(abspath $(firstword $(MAKEFILE_LIST))))/docker_mirror_cache:/docker_mirror_cache \
		-v $(dir $(abspath $(firstword $(MAKEFILE_LIST))))/docker_mirror_certs:/ca \
		docker-registry-proxy

stop:
	docker stop docker-registry-proxy

test: build start

.INTERMEDIATE: clean stop
