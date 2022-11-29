#!/bin/bash

echo "Entrypoint starting."

set -Eeuo pipefail
trap "echo TRAPed signal" HUP INT QUIT TERM

logInfo() {
    echo "INFO: $*"
}

logErr() {
    echo "ERR: $*" >&2
}

function creatCa() {
    declare -i DEBUG=0

    PROJ_NAME=DockerMirrorBox
    logInfo "Will create certificate with names ${1}"

    CADATE=$(date "+%Y.%m.%d %H:%M")
    CAID="$(hostname -f) ${CADATE}"

    CN_CA="${PROJ_NAME} CA Root ${CAID}"
    CN_IA="${PROJ_NAME} Intermediate IA ${CAID}"
    CN_WEB="${PROJ_NAME} Web Cert ${CAID}"

    CN_CA=${CN_CA:0:64}
    CN_IA=${CN_IA:0:64}
    CN_WEB=${CN_WEB:0:64}

    mkdir -p /certs /ca
    cd /ca

    CA_KEY_FILE=${CA_KEY_FILE:-/ca/ca.key}
    CA_CRT_FILE=${CA_CRT_FILE:-/ca/ca.crt}
    CA_SRL_FILE=${CA_SRL_FILE:-/ca/ca.srl}

    if [[ -f "${CA_CRT_FILE}" ]]; then
        logInfo "CA already exists. Good. We'll reuse it."
        if [[ ! -f "${CA_SRL_FILE}" ]]; then
            echo 01 >"${CA_SRL_FILE}"
        fi
    else
        logInfo "No CA was found. Generating one."
        logInfo "*** Please *** make sure to mount /ca as a volume -- if not, everytime this container starts, it will regenerate the CA and nothing will work."

        openssl genrsa -des3 -passout pass:foobar -out "${CA_KEY_FILE}" 4096

        logInfo "generate CA cert with key and self sign it: ${CAID}"
        openssl req \
            -new \
            -x509 \
            -days 1300 \
            -sha256 \
            -key "${CA_KEY_FILE}" \
            -out "${CA_CRT_FILE}" \
            -passin pass:foobar \
            -subj "/C=NL/ST=Noord Holland/L=Amsterdam/O=ME/OU=IT/CN=${CN_CA}" \
            -extensions IA \
            -config <(printf '[req]\ndistinguished_name = dn\n[dn]\n[IA]\nbasicConstraints = critical,CA:TRUE\nkeyUsage = critical, digitalSignature, cRLSign, keyCertSign\nsubjectKeyIdentifier = hash')

        if [[ "${DEBUG}" ]]; then
            logInfo "show the CA cert details"
            openssl x509 -noout -text -in "${CA_CRT_FILE}"
        fi
        echo 01 >"${CA_SRL_FILE}"
    fi

    cd /certs

    logInfo "Generate IA key"
    openssl genrsa -des3 -passout pass:foobar -out ia.key 4096 &>/dev/null

    logInfo "Create a signing request for the IA: ${CAID}"
    openssl req \
        -new \
        -key ia.key \
        -out ia.csr \
        -passin pass:foobar \
        -subj "/C=NL/ST=Noord Holland/L=Amsterdam/O=ME/OU=IT/CN=${CN_IA}" \
        -reqexts IA \
        -config <(printf '[req]\ndistinguished_name = dn\n[dn]\n[IA]\nbasicConstraints = critical,CA:TRUE,pathlen:0\nkeyUsage = critical, digitalSignature, cRLSign, keyCertSign\nsubjectKeyIdentifier = hash')

    if [[ "${DEBUG}" ]]; then
        logInfo "Show the singing request, to make sure extensions are there"
        openssl req -in ia.csr -noout -text
    fi

    logInfo "Sign the IA request with the CA cert and key, producing the IA cert"
    openssl x509 \
        -req \
        -days 730 \
        -in ia.csr \
        -CA "${CA_CRT_FILE}" \
        -CAkey "${CA_KEY_FILE}" \
        -CAserial "${CA_SRL_FILE}" \
        -out ia.crt \
        -passin pass:foobar \
        -extensions IA \
        -extfile <(printf '[req]\ndistinguished_name = dn\n[dn]\n[IA]\nbasicConstraints = critical,CA:TRUE,pathlen:0\nkeyUsage = critical, digitalSignature, cRLSign, keyCertSign\nsubjectKeyIdentifier = hash') &>/dev/null

    if [[ "${DEBUG}" ]]; then
        logInfo "show the IA cert details"
        openssl x509 -noout -text -in ia.crt
    fi

    logInfo "Initialize the serial number for signed certificates"
    echo 01 >ia.srl

    logInfo "Create the key (w/o passphrase..)"
    openssl genrsa -des3 -passout pass:foobar -out web.orig.key 2048 &>/dev/null
    openssl rsa -passin pass:foobar -in web.orig.key -out web.key &>/dev/null

    logInfo "Create the signing request, using extensions"
    openssl req \
        -new \
        -key web.key \
        -sha256 \
        -out web.csr \
        -passin pass:foobar \
        -subj "/C=NL/ST=Noord Holland/L=Amsterdam/O=ME/OU=IT/CN=${CN_WEB}" \
        -reqexts SAN \
        -config <(printf '[req]\ndistinguished_name = dn\n[dn]\n[SAN]\nsubjectAltName=%s' "${1}")

    if [[ "${DEBUG}" ]]; then
        logInfo "Show the singing request, to make sure extensions are there"
        openssl req -in web.csr -noout -text
    fi

    logInfo "Sign the request, using the intermediate cert and key"
    openssl x509 \
        -req \
        -days 365 \
        -in web.csr \
        -CA ia.crt \
        -CAkey ia.key \
        -out web.crt \
        -passin pass:foobar \
        -extensions SAN \
        -extfile <(printf '[req]\ndistinguished_name = dn\n[dn]\n[SAN]\nsubjectAltName=%s' "${1}") &>/dev/null

    if [[ "${DEBUG}" ]]; then
        logInfo "Show the final cert details"
        openssl x509 -noout -text -in web.crt
    fi

    logInfo "Concatenating fullchain.pem..."
    cat web.crt ia.crt "${CA_CRT_FILE}" >fullchain.pem

    logInfo "Concatenating fullchain_with_key.pem"
    cat fullchain.pem web.key >fullchain_with_key.pem

}
# configure nginx DNS settings to match host, why must we do that nginx?
# this leads to a world of problems. ipv6 format being different, etc.
# below is a collection of hacks contributed over the years.

logInfo "-- resolv.conf:"
cat /etc/resolv.conf
logInfo "-- end resolv"

# Podman adds a "%3" to the end of the last resolver? I don't get it. Strip it out.
RESOLVERS=$(sed -e 's/%3//g' /etc/resolv.conf | awk '$1 == "nameserver" {print ($2 ~ ":")? "["$2"]": $2}' ORS=' ' | sed 's/ *$//g')
if [[ -z "${RESOLVERS}" ]]; then
    logErr "Unable to determine DNS resolvers for nginx"
    exit 66
fi

logInfo "DEBUG, determined RESOLVERS from /etc/resolv.conf: '${RESOLVERS}'"

conf=""
for RESOLVER in ${RESOLVERS}; do
    logInfo "Possible resolver: ${RESOLVER}"
    conf="resolver ${RESOLVER}; "
done

logInfo "Final chosen resolver: ${conf}"
confpath="/etc/nginx/resolvers.conf"
if [[ ! -f ${confpath} ]]; then
    logInfo "Using auto-determined resolver '${conf}' via '${confpath}'"
    echo "${conf}" >${confpath}
else
    logInfo "Not using resolver config, keep existing '${confpath}' -- mounted by user?"
fi

# The list of SAN (Subject Alternative Names) for which we will create a TLS certificate.
ALLDOMAINS=""

# Interceptions map, which are the hosts that will be handled by the caching part.
# It should list exactly the same hosts we have created certificates for -- if not, Docker will get TLS errors, of course.
touch /etc/nginx/docker.intercept.map

# Some hosts/registries are always needed, but others can be configured in env var REGISTRIES
for ONEREGISTRYIN in docker.caching.proxy.internal registry-1.docker.io auth.docker.io ${REGISTRIES}; do
    ONEREGISTRY=$(echo "${ONEREGISTRYIN}" | xargs) # Remove whitespace
    logInfo "Adding certificate for registry: ${ONEREGISTRY}"
    ALLDOMAINS="${ALLDOMAINS},DNS:${ONEREGISTRY}"
    echo "${ONEREGISTRY} 127.0.0.1:443;" >>/etc/nginx/docker.intercept.map
done

# Clean the list and generate certificates.
# export ALLDOMAINS=${ALLDOMAINS:1} # remove the first comma and export
creatCa "${ALLDOMAINS:1}" # This uses ALLDOMAINS to generate the certificates.

# Target host interception. Empty by default. Used to intercept outgoing requests
# from the proxy to the registries.
touch /etc/nginx/docker.targetHost.map

# Now handle the auth part.
touch /etc/nginx/docker.auth.map

# Only configure auth registries if the env var contains values
if [[ "${AUTH_REGISTRIES}" ]]; then
    # Ref: https://stackoverflow.com/a/47633817/219530
    AUTH_REGISTRIES_DELIMITER=${AUTH_REGISTRIES_DELIMITER:-" "}
    s=${AUTH_REGISTRIES}${AUTH_REGISTRIES_DELIMITER}
    auth_array=()
    while [[ ${s} ]]; do
        auth_array+=("${s%%"$AUTH_REGISTRIES_DELIMITER"*}")
        s=${s#*"$AUTH_REGISTRIES_DELIMITER"}
    done

    AUTH_REGISTRY_DELIMITER=${AUTH_REGISTRY_DELIMITER:-":"}

    for ONEREGISTRY in "${auth_array[@]}"; do
        s=${ONEREGISTRY}${AUTH_REGISTRY_DELIMITER}

        registry_array=()
        while [[ ${s} ]]; do
            registry_array+=("${s%%"$AUTH_REGISTRY_DELIMITER"*}")
            s=${s#*"$AUTH_REGISTRY_DELIMITER"}
        done
        AUTH_HOST="${registry_array[0]}"
        AUTH_USER="${registry_array[1]}"
        AUTH_PASS="${registry_array[2]}"
        AUTH_BASE64=$(echo -n "${AUTH_USER}:${AUTH_PASS}" | base64 -w0 | xargs)
        logInfo "Adding Auth for registry '${AUTH_HOST}' with user '${AUTH_USER}'."
        printf '"%s" "%s";' "${AUTH_HOST}" "${AUTH_BASE64}" >>/etc/nginx/docker.auth.map
    done
fi

# create default config for the caching layer to listen on 443.
echo "        listen 443 ssl default_server;" >/etc/nginx/caching.layer.listen
echo "error_log  /var/log/nginx/error.log warn;" >/etc/nginx/error.log.debug.warn

# Set Docker Registry cache size, by default, 32 GB ('32g')
CACHE_MAX_SIZE=${CACHE_MAX_SIZE:-32g}

# The cache directory. This can get huge. Better to use a Docker volume pointing here!
# Set to 32gb which should be enough
echo "proxy_cache_path /docker_mirror_cache levels=1:2 max_size=${CACHE_MAX_SIZE} inactive=60d keys_zone=cache:10m use_temp_path=off;" >/etc/nginx/conf.d/cache_max_size.conf

# Manifest caching configuration. We generate config based on the environment vars.
touch /etc/nginx/nginx.manifest.caching.config.conf

if [[ "${ENABLE_MANIFEST_CACHE}" == true ]]; then
    if [[ -n "${MANIFEST_CACHE_PRIMARY_REGEX}" ]]; then
        cat >>/etc/nginx/nginx.manifest.caching.config.conf <<EOD
    # First tier caching of manifests; configure via MANIFEST_CACHE_PRIMARY_REGEX and MANIFEST_CACHE_PRIMARY_TIME
    location ~ ^/v2/(.*)/manifests/${MANIFEST_CACHE_PRIMARY_REGEX} {
        set \$docker_proxy_request_type "manifest-primary";
        proxy_cache_valid ${MANIFEST_CACHE_PRIMARY_TIME};
        include "/etc/nginx/nginx.manifest.stale.conf";
    }
EOD
    fi
    if [[ -n "${MANIFEST_CACHE_SECONDARY_REGEX}" ]]; then
        cat >>/etc/nginx/nginx.manifest.caching.config.conf <<EOD
    # Secondary tier caching of manifests; configure via MANIFEST_CACHE_SECONDARY_REGEX and MANIFEST_CACHE_SECONDARY_TIME
    location ~ ^/v2/(.*)/manifests/${MANIFEST_CACHE_SECONDARY_REGEX} {
        set \$docker_proxy_request_type "manifest-secondary";
        proxy_cache_valid ${MANIFEST_CACHE_SECONDARY_TIME};
        include "/etc/nginx/nginx.manifest.stale.conf";
    }
EOD
    fi
    cat >>/etc/nginx/nginx.manifest.caching.config.conf <<EOD
    # Default tier caching for manifests. Caches for ${MANIFEST_CACHE_DEFAULT_TIME} (from MANIFEST_CACHE_DEFAULT_TIME)
    location ~ ^/v2/(.*)/manifests/ {
        set \$docker_proxy_request_type "manifest-default";
        proxy_cache_valid ${MANIFEST_CACHE_DEFAULT_TIME};
        include "/etc/nginx/nginx.manifest.stale.conf";
    }
EOD
else
    cat >>/etc/nginx/nginx.manifest.caching.config.conf <<EOD
    # Manifest caching is disabled. Enable it with ENABLE_MANIFEST_CACHE=true
    location ~ ^/v2/(.*)/manifests/ {
        set \$docker_proxy_request_type "manifest-default-disabled";
        proxy_cache_valid 0s;
        include "/etc/nginx/nginx.manifest.stale.conf";
    }
EOD
fi

logInfo "Manifest caching config: ---"
cat /etc/nginx/nginx.manifest.caching.config.conf
logInfo "---"

if [[ "${ALLOW_PUSH}" == true ]]; then
    cat <<EOF >/etc/nginx/conf.d/allowed.methods.conf
    # allow to upload big layers
    client_max_body_size 0;

    # only cache GET requests
    proxy_cache_methods GET;
EOF
else
    cat <<'EOF' >/etc/nginx/conf.d/allowed.methods.conf
    # Block POST/PUT/DELETE. Don't use this proxy for pushing.
    if ($request_method = POST) {
        return 405 "POST method is not allowed";
    }
    if ($request_method = PUT) {
        return 405 "PUT method is not allowed";
    }
    if ($request_method = DELETE) {
        return 405  "DELETE method is not allowed";
    }
EOF
fi

# normally use non-debug version of nginx
NGINX_BIN="/usr/sbin/nginx"

if [[ "${DEBUG}" == true ]]; then
    if [[ ! -f /usr/bin/mitmweb ]]; then
        logErr "To debug, you need the -debug version of this image, eg: :latest-debug"
        exit 3
    fi

    # in debug mode, change caching layer to listen on 444, so that mitmproxy can sit in the middle.
    echo "        listen 444 ssl default_server;" >/etc/nginx/caching.layer.listen

    logErr "Starting in DEBUG MODE (mitmproxy)."
    logInfo "Run mitmproxy with reverse pointing to the same certs..."
    mitmweb --no-web-open-browser --set web_host=0.0.0.0 --set confdir=~/.mitmproxy-incoming \
        --set termlog_verbosity=error --set stream_large_bodies=128k --web-port 8081 \
        --set keep_host_header=true --set ssl_insecure=true \
        --mode reverse:https://127.0.0.1:444 --listen-host 0.0.0.0 \
        --listen-port 443 --certs /certs/fullchain_with_key.pem &
    logInfo "Access mitmweb via http://127.0.0.1:8081/ "
fi

if [[ "${DEBUG_HUB}" == true ]]; then
    if [[ ! -f /usr/bin/mitmweb ]]; then
        logErr "To debug, you need the -debug version of this image, eg: :latest-debug"
        exit 3
    fi

    # in debug hub mode, we remap targetHost to point to mitmproxy below
    echo '"registry-1.docker.io" "127.0.0.1:445";' >/etc/nginx/docker.targetHost.map

    logErr "Debugging outgoing DockerHub connections via mitmproxy on 8082."
    # this one has keep_host_header=false so we don't need to modify nginx config
    mitmweb --no-web-open-browser --set web_host=0.0.0.0 --set confdir=~/.mitmproxy-outgoing-hub \
        --set termlog_verbosity=error --set stream_large_bodies=128k --web-port 8082 \
        --set keep_host_header=false --set ssl_insecure=true \
        --mode reverse:https://registry-1.docker.io --listen-host 0.0.0.0 \
        --listen-port 445 --certs /certs/fullchain_with_key.pem &

    logErr "Warning, DockerHub outgoing debugging disables upstream SSL verification for all upstreams."
    VERIFY_SSL=false

    logInfo "Access mitmweb for outgoing DockerHub requests via http://127.0.0.1:8082/"
    if [[ ! -f /usr/sbin/nginx-debug ]]; then
        logErr "To debug, you need the -debug version of this image, eg: :latest-debug"
        exit 4
    fi

    logInfo "Starting in DEBUG MODE (nginx)."
    echo "error_log  /var/log/nginx/error.log debug;" >/etc/nginx/error.log.debug.warn
    # use debug binary
    NGINX_BIN="/usr/sbin/nginx-debug"
fi

# Timeout configurations
touch /etc/nginx/nginx.timeouts.config.conf
cat <<EOD >>/etc/nginx/nginx.timeouts.config.conf
  # Timeouts

  # ngx_http_core_module
  keepalive_timeout  ${KEEPALIVE_TIMEOUT};
  send_timeout ${SEND_TIMEOUT};
  client_body_timeout ${CLIENT_BODY_TIMEOUT};
  client_header_timeout ${CLIENT_HEADER_TIMEOUT};

  # ngx_http_proxy_module
  proxy_read_timeout ${PROXY_READ_TIMEOUT};
  proxy_connect_timeout ${PROXY_CONNECT_TIMEOUT};
  proxy_send_timeout ${PROXY_SEND_TIMEOUT};

  # ngx_http_proxy_connect_module - external module
  proxy_connect_read_timeout ${PROXY_CONNECT_READ_TIMEOUT};
  proxy_connect_connect_timeout ${PROXY_CONNECT_CONNECT_TIMEOUT};
  proxy_connect_send_timeout ${PROXY_CONNECT_SEND_TIMEOUT};
EOD

logInfo "Timeout configs: ---"
cat /etc/nginx/nginx.timeouts.config.conf
logInfo "---"

# Request buffering
echo "" > /etc/nginx/proxy.request.buffering.conf
if [[ "a${PROXY_REQUEST_BUFFERING}" == "afalse" ]]; then
  cat << EOD > /etc/nginx/proxy.request.buffering.conf
  proxy_max_temp_file_size 0;
  proxy_request_buffering off;
  proxy_http_version 1.1;
EOD
fi

echo -e "\nRequest buffering: ---"
cat /etc/nginx/proxy.request.buffering.conf
echo -e "---\n"

# Upstream SSL verification.
touch /etc/nginx/docker.verify.ssl.conf
if [[ "${VERIFY_SSL}" == true ]]; then
    cat <<EOD >/etc/nginx/docker.verify.ssl.conf
    # We actually wanna be secure and avoid mitm attacks.
    # Fitting, since this whole thing is a mitm...
    # We'll accept any cert signed by a CA trusted by Mozilla (ca-certificates-bundle in alpine)
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_verify_depth 2;
EOD
    logInfo "Upstream SSL certificate verification enabled."
else
    logInfo "Upstream SSL certificate verification is DISABLED."
fi

logInfo "Testing nginx config..."
${NGINX_BIN} -t

logInfo "Starting nginx! Have a nice day."
${NGINX_BIN} -g "daemon off;"
