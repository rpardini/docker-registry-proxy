# We start from my nginx fork which includes the proxy-connect module from tEngine
# Source is available at https://github.com/rpardini/nginx-proxy-connect-stable-alpine
# Its equivalent to nginx:stable-alpine 1.14.0, with alpine 3.7
FROM rpardini/nginx-proxy-connect-stable-alpine:latest

# Add openssl, bash and ca-certificates, then clean apk cache -- yeah complain all you want.
RUN apk add --update openssl bash ca-certificates && rm -rf /var/cache/apk/*

# Create the cache directory and CA directory
RUN mkdir -p /docker_mirror_cache /ca

# Expose it as a volume, so cache can be kept external to the Docker image
VOLUME /docker_mirror_cache

# Expose /ca as a volume. Users are supposed to volume mount this, as to preserve it across restarts.
# Actually, its required; if not, then docker clients will reject the CA certificate when the proxy is run the second time
VOLUME /ca

# Add our configuration
ADD nginx.conf /etc/nginx/nginx.conf

# Add our very hackish entrypoint and ca-building scripts, make them executable
ADD entrypoint.sh /entrypoint.sh
ADD create_ca_cert.sh /create_ca_cert.sh
RUN chmod +x /create_ca_cert.sh /entrypoint.sh

# Clients should only use 3128, not anything else.
EXPOSE 3128

## Default envs.
# A space delimited list of registries we should proxy and cache; this is in addition to the central DockerHub.
ENV REGISTRIES="k8s.gcr.io gcr.io quay.io"
# A space delimited list of registry:user:password to inject authentication for
ENV AUTH_REGISTRIES="some.authenticated.registry:oneuser:onepassword another.registry:user:password"
# Should we verify upstream's certificates? Default to true.
ENV VERIFY_SSL="true"

# Did you want a shell? Sorry. This only does one job; use exec /bin/bash if you wanna inspect stuff
ENTRYPOINT ["/entrypoint.sh"]