#! /bin/bash

set -Eeuo pipefail
trap "echo TRAPed signal" HUP INT QUIT TERM

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
if [ "a$VERIFY_SSL" == "atrue" ]; then
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


echo "Testing nginx config..."
nginx -t

echo "Starting nginx! Have a nice day."
nginx -g "daemon off;"
