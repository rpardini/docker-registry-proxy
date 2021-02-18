#! /bin/bash

set -Eeuo pipefail

logInfo() {
    echo "INFO: $@"
}

PROJ_NAME=DockerMirrorBox
logInfo "Will create certificate with names $ALLDOMAINS"

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

if [ -f "$CA_CRT_FILE" ] ; then
    logInfo "CA already exists. Good. We'll reuse it."
    if [ ! -f "$CA_SRL_FILE" ] ; then
        echo 01 > ${CA_SRL_FILE}
    fi
else
    logInfo "No CA was found. Generating one."
    logInfo "*** Please *** make sure to mount /ca as a volume -- if not, everytime this container starts, it will regenerate the CA and nothing will work."

    openssl genrsa -des3 -passout pass:foobar -out ${CA_KEY_FILE} 4096

    logInfo "generate CA cert with key and self sign it: ${CAID}"
    openssl req -new -x509 -days 1300 -sha256 -key ${CA_KEY_FILE} -out ${CA_CRT_FILE} -passin pass:foobar -subj "/C=NL/ST=Noord Holland/L=Amsterdam/O=ME/OU=IT/CN=${CN_CA}" -extensions IA -config <(
cat <<-EOF
[req]
distinguished_name = dn
[dn]
[IA]
basicConstraints = critical,CA:TRUE
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
EOF
)

    [ "${DEBUG_CA_CERT}" = "true" ] && logInfo "show the CA cert details"
    [ "${DEBUG_CA_CERT}" = "true" ] && openssl x509 -noout -text -in ${CA_CRT_FILE}

    echo "01" > ${CA_SRL_FILE}

fi

cd /certs

logInfo "Generate IA key"
openssl genrsa -des3 -passout pass:foobar -out ia.key 4096 &> /dev/null

logInfo "Create a signing request for the IA: ${CAID}"
openssl req -new -key ia.key -out ia.csr -passin pass:foobar -subj "/C=NL/ST=Noord Holland/L=Amsterdam/O=ME/OU=IT/CN=${CN_IA}" -reqexts IA -config <(
cat <<-EOF
[req]
distinguished_name = dn
[dn]
[IA]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
EOF
)

[ "${DEBUG_CA_CERT}" = "true" ] && logInfo "Show the singing request, to make sure extensions are there"
[ "${DEBUG_CA_CERT}" = "true" ] && openssl req -in ia.csr -noout -text

logInfo "Sign the IA request with the CA cert and key, producing the IA cert"
openssl x509 -req -days 730 -in ia.csr -CA ${CA_CRT_FILE} -CAkey ${CA_KEY_FILE} -CAserial ${CA_SRL_FILE} -out ia.crt -passin pass:foobar -extensions IA -extfile <(
cat <<-EOF
[req]
distinguished_name = dn
[dn]
[IA]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
EOF
) &> /dev/null


[ "${DEBUG_CA_CERT}" = "true" ] && logInfo "show the IA cert details"
[ "${DEBUG_CA_CERT}" = "true" ] && openssl x509 -noout -text -in ia.crt

logInfo "Initialize the serial number for signed certificates"
echo 01 > ia.srl

logInfo "Create the key (w/o passphrase..)"
openssl genrsa -des3 -passout pass:foobar -out web.orig.key 2048 &> /dev/null
openssl rsa -passin pass:foobar -in web.orig.key -out web.key  &> /dev/null

logInfo "Create the signing request, using extensions"
openssl req -new -key web.key -sha256 -out web.csr -passin pass:foobar -subj "/C=NL/ST=Noord Holland/L=Amsterdam/O=ME/OU=IT/CN=${CN_WEB}" -reqexts SAN -config <(cat <(printf "[req]\ndistinguished_name = dn\n[dn]\n[SAN]\nsubjectAltName=${ALLDOMAINS}"))

[ "${DEBUG_CA_CERT}" = "true" ] && logInfo "Show the singing request, to make sure extensions are there"
[ "${DEBUG_CA_CERT}" = "true" ] && openssl req -in web.csr -noout -text

logInfo "Sign the request, using the intermediate cert and key"
openssl x509 -req -days 365 -in web.csr -CA ia.crt -CAkey ia.key -out web.crt -passin pass:foobar -extensions SAN -extfile <(cat <(printf "[req]\ndistinguished_name = dn\n[dn]\n[SAN]\nsubjectAltName=${ALLDOMAINS}"))  &> /dev/null

[ "${DEBUG_CA_CERT}" = "true" ] && logInfo "Show the final cert details"
[ "${DEBUG_CA_CERT}" = "true" ] && openssl x509 -noout -text -in web.crt

logInfo "Concatenating fullchain.pem..."
cat web.crt ia.crt ${CA_CRT_FILE}  > fullchain.pem

logInfo "Concatenating fullchain_with_key.pem"
cat fullchain.pem web.key > fullchain_with_key.pem
