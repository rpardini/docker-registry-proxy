# We start from my nginx fork which includes the proxy-connect module from tEngine
# Source is available at https://github.com/rpardini/nginx-proxy-connect-stable-alpine
# This is already multi-arch!
ARG BASE_IMAGE="rpardini/nginx-proxy-connect-stable-alpine:nginx-1.18.0-alpine-3.12.1"
# Could be "-debug"
ARG BASE_IMAGE_SUFFIX=""
FROM ${BASE_IMAGE}${BASE_IMAGE_SUFFIX}

# Link image to original repository on GitHub
LABEL org.opencontainers.image.source https://github.com/rpardini/docker-registry-proxy

# apk packages that will be present in the final image both debug and release
RUN apk add --no-cache --update bash ca-certificates-bundle coreutils openssl

# If set to 1, enables building mitmproxy, which helps a lot in debugging, but is super heavy to build.
ARG DEBUG_BUILD="0"
ENV DO_DEBUG_BUILD="$DEBUG_BUILD"

# Build mitmproxy via pip. This is heavy, takes minutes do build and creates a 90mb+ layer. Oh well.
RUN [ "$DO_DEBUG_BUILD" = "1" ] && { echo "Debug build ENABLED." \
 && apk add --no-cache --update su-exec git g++ libffi libffi-dev libstdc++ openssl-dev python3 python3-dev py3-pip py3-wheel py3-six py3-idna py3-certifi py3-setuptools \
 && LDFLAGS=-L/lib pip install mitmproxy==5.2 \
 && apk del --purge git g++ libffi-dev openssl-dev python3-dev py3-pip py3-wheel \
 && rm -rf ~/.cache/pip \
 ; } || { echo "Debug build disabled." ; }

# Required for mitmproxy
ENV LANG=en_US.UTF-8

# Check the installed mitmproxy version, if built.
RUN [ "$DO_DEBUG_BUILD" = "1" ] && { mitmproxy --version && mitmweb --version ; } || { echo "Debug build disabled."; }

# Create the cache directory and CA directory
RUN mkdir -p /docker_mirror_cache /ca

# Expose it as a volume, so cache can be kept external to the Docker image
VOLUME /docker_mirror_cache

# Expose /ca as a volume. Users are supposed to volume mount this, as to preserve it across restarts.
# Actually, its required; if not, then docker clients will reject the CA certificate when the proxy is run the second time
VOLUME /ca

# Add our configuration
ADD nginx.conf /etc/nginx/nginx.conf
ADD nginx.manifest.common.conf /etc/nginx/nginx.manifest.common.conf
ADD nginx.manifest.stale.conf /etc/nginx/nginx.manifest.stale.conf

# Add our very hackish entrypoint and ca-building scripts, make them executable
ADD entrypoint.sh /entrypoint.sh
ADD create_ca_cert.sh /create_ca_cert.sh
RUN chmod +x /create_ca_cert.sh /entrypoint.sh

# Clients should only use 3128, not anything else.
EXPOSE 3128

# In debug mode, 8081 exposes the mitmweb interface (for incoming requests from Docker clients)
EXPOSE 8081
# In debug-hub mode, 8082 exposes the mitmweb interface (for outgoing requests to DockerHub)
EXPOSE 8082

## Default envs.
# A space delimited list of registries we should proxy and cache; this is in addition to the central DockerHub.
ENV REGISTRIES="auth.docker.io registry-1.docker.io docker.caching.proxy.internal k8s.gcr.io gcr.io quay.io gitlab.com registry.gitlab.com"
# A space delimited list of registry:user:password to inject authentication for
# (e.g. AUTH_REGISTRIES="auth.docker.io:dhuser:dhpass gitlab.com:gluser:glpass")
ENV AUTH_REGISTRIES=""
# Should we verify upstream's certificates? Default to true.
ENV VERIFY_SSL="true"

# Enable debugging mode; this inserts mitmproxy/mitmweb between the CONNECT proxy and the caching layer
ENV DEBUG="false"
# Enable debugging mode; this inserts mitmproxy/mitmweb between the caching layer and DockerHub's registry
ENV DEBUG_HUB="false"
# Enable nginx debugging mode; this uses nginx-debug binary and enabled debug logging, which is VERY verbose so separate setting
ENV DEBUG_NGINX="false"
# Enable debugging mode for creating CA certificate
ENV DEBUG_CA_CERT="false"

# Set Docker Registry cache size, by default, 32 GB ('32g')
ENV CACHE_MAX_SIZE="32g"

# Manifest caching tiers. Disabled by default, to mimick 0.4/0.5 behaviour.
# Setting it to true enables the processing of the ENVs below.
# Once enabled, it is valid for all registries, not only DockerHub.
# The envs *_REGEX represent a regex fragment, check entrypoint.sh to understand how they're used (nginx ~ location, PCRE syntax).
ENV ENABLE_MANIFEST_CACHE="false"

# 'Primary' tier defaults to 10m cache for frequently used/abused tags.
# - People publishing to production via :latest (argh) will want to include that in the regex
# - Heavy pullers who are being ratelimited but don't mind getting outdated manifests should (also) increase the cache time here
ENV MANIFEST_CACHE_PRIMARY_REGEX="(stable|nightly|production|test)"
ENV MANIFEST_CACHE_PRIMARY_TIME="10m"

# 'Secondary' tier defaults any tag that has 3 digits or dots, in the hopes of matching most explicitly-versioned tags.
# It caches for 60d, which is also the cache time for the large binary blobs to which the manifests refer.
# That makes them effectively immutable. Make sure you're not affected; tighten this regex or widen the primary tier.
ENV MANIFEST_CACHE_SECONDARY_REGEX="(.*)(\d|\.)+(.*)(\d|\.)+(.*)(\d|\.)+"
ENV MANIFEST_CACHE_SECONDARY_TIME="60d"

# The default cache duration for manifests that don't match either the primary or secondary tiers above.
# In the default config, :latest and other frequently-used tags will get this value.
ENV MANIFEST_CACHE_DEFAULT_TIME="1h"

# Should we allow overridding with own authentication, default to false.
ENV ALLOW_OWN_AUTH="false"

# Should we allow actions different than pull, default to false.
ENV ALLOW_PUSH="false"
# Should we allow push only with own authentication, default to false.
ENV ALLOW_PUSH_WITH_OWN_AUTH="false"

# Timeouts
# ngx_http_core_module
ENV SEND_TIMEOUT="60s"
ENV CLIENT_BODY_TIMEOUT="60s"
ENV CLIENT_HEADER_TIMEOUT="60s"
ENV KEEPALIVE_TIMEOUT="300s"
# ngx_http_proxy_module
ENV PROXY_READ_TIMEOUT="60s"
ENV PROXY_CONNECT_TIMEOUT="60s"
ENV PROXY_SEND_TIMEOUT="60s"
# ngx_http_proxy_connect_module - external module
ENV PROXY_CONNECT_READ_TIMEOUT="60s"
ENV PROXY_CONNECT_CONNECT_TIMEOUT="60s"
ENV PROXY_CONNECT_SEND_TIMEOUT="60s"

# Did you want a shell? Sorry, the entrypoint never returns, because it runs nginx itself. Use 'docker exec' if you need to mess around internally.
ENTRYPOINT ["/entrypoint.sh"]
