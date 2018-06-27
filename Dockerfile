# Use stable nginx on alpine for a light container
FROM nginx:stable-alpine

# Add openssl and clean apk cache
RUN apk add --update openssl && rm -rf /var/cache/apk/*

# Generate a self-signed SSL certificate. It will be ignored by Docker clients due to insecure-registries.
RUN mkdir -p /etc/ssl && \
    cd /etc/ssl && \
    openssl genrsa -des3 -passout pass:x -out key.pem 2048 && \
    cp key.pem key.pem.orig && \
    openssl rsa -passin pass:x -in key.pem.orig -out key.pem && \
    openssl req -new -key key.pem -out cert.csr -subj "/C=BR/ST=BR/L=Nowhere/O=Fake Docker Mirror/OU=Docker/CN=docker.proxy" && \
    openssl x509 -req -days 3650 -in cert.csr -signkey key.pem -out cert.pem

# Create the cache directory
RUN mkdir -p /docker_mirror_cache

# Expose it as a volume, so cache can be kept external to the Docker image
VOLUME /docker_mirror_cache

# Add our configuration
ADD nginx.conf /etc/nginx/nginx.conf

# Test that the configuration is OK
RUN nginx -t
