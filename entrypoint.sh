#! /bin/bash

set -Eeuo pipefail
trap "echo TRAPed signal" HUP INT QUIT TERM

#configure nginx DNS settings to match host, why must we do that nginx?
conf="resolver $(/usr/bin/awk 'BEGIN{ORS=" "} $1=="nameserver" {print $2}' /etc/resolv.conf) ipv6=off; # Avoid ipv6 addresses for now"
[ "$conf" = "resolver ;" ] && echo "no nameservers found" && exit 0
confpath=/etc/nginx/resolvers.conf
if [ ! -e $confpath ] || [ "$conf" != "$(cat $confpath)" ]
then
    echo "$conf" > $confpath
fi

# The list of SAN (Subject Alternative Names) for which we will create a TLS certificate.
ALLDOMAINS=""

# Interceptions map, which are the hosts that will be handled by the caching part.
# It should list exactly the same hosts we have created certificates for -- if not, Docker will get TLS errors, of course.
echo -n "" > /etc/nginx/docker.intercept.map

# Some hosts/registries are always needed, but others can be configured in env var REGISTRIES
for ONEREGISTRYIN in docker.caching.proxy.internal registry-1.docker.io auth.docker.io ${REGISTRIES}; do
    ONEREGISTRY=$(echo ${ONEREGISTRYIN} | xargs) # Remove whitespace
    echo "Adding certificate for registry: $ONEREGISTRY"
    ALLDOMAINS="${ALLDOMAINS},DNS:${ONEREGISTRY}"
    echo "${ONEREGISTRY} 127.0.0.1:443;" >> /etc/nginx/docker.intercept.map
done

# Clean the list and generate certificates.
export ALLDOMAINS=${ALLDOMAINS:1} # remove the first comma and export
/create_ca_cert.sh # This uses ALLDOMAINS to generate the certificates.

# Now handle the auth part.
echo -n "" > /etc/nginx/docker.auth.map

for ONEREGISTRYIN in ${AUTH_REGISTRIES}; do
    ONEREGISTRY=$(echo -n ${ONEREGISTRYIN} | xargs) # Remove whitespace
    AUTH_HOST=$(echo -n ${ONEREGISTRY} | cut -d ":" -f 1 | xargs)
    AUTH_USER=$(echo -n ${ONEREGISTRY} | cut -d ":" -f 2 | xargs)
    AUTH_PASS=$(echo -n ${ONEREGISTRY} | cut -d ":" -f 3 | xargs)
    AUTH_BASE64=$(echo -n ${AUTH_USER}:${AUTH_PASS} | base64 | xargs)
    echo "Adding Auth for registry '${AUTH_HOST}' with user '${AUTH_USER}'."
    echo "\"${AUTH_HOST}\" \"${AUTH_BASE64}\";" >> /etc/nginx/docker.auth.map
done

echo "" > /etc/nginx/docker.verify.ssl.conf
if [[ "a${VERIFY_SSL}" == "atrue" ]]; then
    cat << EOD > /etc/nginx/docker.verify.ssl.conf
    # We actually wanna be secure and avoid mitm attacks.
    # Fitting, since this whole thing is a mitm...
    # We'll accept any cert signed by a CA trusted by Mozilla (ca-certificates in alpine)
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_verify_depth 2;
EOD
    echo "Upstream SSL certificate verification enabled."
fi

# create default config for the caching layer to listen on 443.
echo "        listen 443 ssl default_server;" > /etc/nginx/caching.layer.listen
echo "error_log  /var/log/nginx/error.log warn;" > /etc/nginx/error.log.debug.warn

# normally use non-debug version of nginx
NGINX_BIN="nginx"

if [[ "a${DEBUG}" == "atrue" ]]; then
  # in debug mode, change caching layer to listen on 444, so that mitmproxy can sit in the middle.
  echo "        listen 444 ssl default_server;" > /etc/nginx/caching.layer.listen

  echo "Starting in DEBUG MODE (mitmproxy)."
  echo "Run mitmproxy with reverse pointing to the same certs..."
  mitmweb --no-web-open-browser --web-iface 0.0.0.0 --web-port 8081 \
          --set keep_host_header=true --set ssl_insecure=true \
          --mode reverse:https://127.0.0.1:444 --listen-host 0.0.0.0 \
          --listen-port 443 --certs /certs/fullchain_with_key.pem \
          -w /ca/outfile &
  echo "Access mitmweb via http://127.0.0.1:8081/ "
fi

if [[ "a${DEBUG_NGINX}" == "atrue" ]]; then
  echo "Starting in DEBUG MODE (nginx)."
  echo "error_log  /var/log/nginx/error.log debug;" > /etc/nginx/error.log.debug.warn
  # use debug binary
  NGINX_BIN="nginx-debug"
fi

echo "Testing nginx config..."
${NGINX_BIN} -t

echo "Starting nginx! Have a nice day."
${NGINX_BIN} -g "daemon off;"
