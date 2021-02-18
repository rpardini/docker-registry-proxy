![GitHub Workflow Status](https://img.shields.io/github/workflow/status/rpardini/docker-registry-proxy/master-latest?label=%3Alatest%20from%20master)
![GitHub tag (latest by date)](https://img.shields.io/github/v/tag/rpardini/docker-registry-proxy?label=last%20tagged%20release)
![GitHub Workflow Status](https://img.shields.io/github/workflow/status/rpardini/docker-registry-proxy/tags?label=last%20tagged%20release)
![Docker Image Size (latest semver)](https://img.shields.io/docker/image-size/rpardini/docker-registry-proxy?sort=semver)
![Docker Pulls](https://img.shields.io/docker/pulls/rpardini/docker-registry-proxy)
## TL,DR

A caching proxy for Docker; allows centralised management of (multiple) registries and their authentication; caches images from *any* registry.
Caches the potentially huge blob/layer requests (for bandwidth/time savings), and optionally caches manifest requests ("pulls") to avoid rate-limiting.

### NEW: avoiding DockerHub Pull Rate Limits with Caching

Starting November 2nd, 2020, DockerHub will 
[supposedly](https://www.docker.com/blog/docker-hub-image-retention-policy-delayed-and-subscription-updates/) 
[start](https://www.docker.com/blog/scaling-docker-to-serve-millions-more-developers-network-egress/)
[rate-limiting pulls](https://docs.docker.com/docker-hub/download-rate-limit/), 
also known as the _Docker Apocalypse_. 
The main symptom is `Error response from daemon: toomanyrequests: Too Many Requests. Please see https://docs.docker.com/docker-hub/download-rate-limit/` during pulls.
Many unknowing Kubernetes clusters will hit the limit, and struggle to configure `imagePullSecrets` and `imagePullPolicy`.

Since version `0.6.0`, this proxy can be configured with the env var `ENABLE_MANIFEST_CACHE=true` which provides 
configurable caching of the manifest requests that DockerHub throttles. You can then fine-tune other parameters to your needs.
Together with the possibility to centrally inject authentication (since 0.3x), this is probably one of the best ways to bring relief to your distressed cluster, while at the same time saving lots of bandwidth and time. 

Note: enabling manifest caching, in its default config, effectively makes some tags **immutable**. Use with care. The configuration ENVs are explained in the [Dockerfile](./Dockerfile), relevant parts included below.

```dockerfile
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
```


## What?

Essentially, it's a [man in the middle](https://en.wikipedia.org/wiki/Man-in-the-middle_attack): an intercepting proxy based on `nginx`, to which all docker traffic is directed using the `HTTPS_PROXY` mechanism and injected CA root certificates. 

The main feature is Docker layer/image caching, including layers served from S3, Google Storage, etc. 

As a bonus it allows for centralized management of Docker registry credentials, which can in itself be the main feature, eg in Kubernetes environments.

You configure the Docker clients (_err... Kubernetes Nodes?_) once, and then all configuration is done on the proxy -- 
for this to work it requires inserting a root CA certificate into system trusted root certs.

## master/:latest is unstable/beta

- `:latest` and `:latest-debug` Docker tag is unstable, built from master, and amd64-only
- Production/stable is `0.6.2`, see [0.6.2 tag on Github](https://github.com/rpardini/docker-registry-proxy/tree/0.6.2) - this image is multi-arch amd64/arm64
- The previous version is `0.5.0`, without any manifest caching, see [0.5.0 tag on Github](https://github.com/rpardini/docker-registry-proxy/tree/0.5.0) - this image is multi-arch amd64/arm64

## Also hosted on GitHub Container Registry (ghcr.io)

- DockerHub image is at `rpardini/docker-registry-proxy:<version>`
- GitHub image is at `ghcr.io/rpardini/docker-registry-proxy:<version>`
- Since 0.5.x, they both carry the same images
- This can be useful if you're already hitting DockerHub's rate limits and can't pull the proxy from DockerHub

## Usage (running the Proxy server)

- Run the proxy on a host close (network-wise: high bandwidth, same-VPC, etc) to the Docker clients
- Expose port 3128 to the network
- Map volume `/docker_mirror_cache` for up to `CACHE_MAX_SIZE` (32gb by default) of cached images across all cached registries
- Map volume `/ca`, the proxy will store the CA certificate here across restarts. **Important** this is security sensitive.
- Env `ALLOW_OWN_AUTH` (default `false`): Allow overridding the `AUTH_REGISTRIES` authentication with own Docker credentials if provided (to support `docker login` as another user).
- Env `ALLOW_PUSH` (default `false`): This bypasses the proxy when pushing, default to false - if kept to false, pushing will not work. For more info see this [commit](https://github.com/rpardini/docker-registry-proxy/commit/536f0fc8a078d03755f1ae8edc19a86fc4b37fcf).
- Env `ALLOW_PUSH_WITH_OWN_AUTH` (default `false`): Allow bypassing the proxy when pushing only if own authentication is provided.
- Env `CACHE_MAX_SIZE` (default `32g`): set the max size to be used for caching local Docker image layers. Use [Nginx sizes](http://nginx.org/en/docs/syntax.html).
- Env `ENABLE_MANIFEST_CACHE`, see the section on pull rate limiting.
- Env `REGISTRIES`: space separated list of registries to cache; no need to include DockerHub, its already done internally.
- Env `AUTH_REGISTRIES`: space separated list of `hostname:username:password` authentication info.
  - `hostname`s listed here should be listed in the REGISTRIES environment as well, so they can be intercepted.
- Env `AUTH_REGISTRIES_DELIMITER` to change the separator between authentication info. By default, a space: "` `". If you use keys that contain spaces (as with Google Cloud Registry), you should update this variable, e.g. setting it to `AUTH_REGISTRIES_DELIMITER=";;;"`. In that case, `AUTH_REGISTRIES` could contain something like `registry1.com:user1:pass1;;;registry2.com:user2:pass2`.
- Env `AUTH_REGISTRY_DELIMITER` to change the separator between authentication info *parts*. By default, a colon: "`:`". If you use keys that contain single colons, you should update this variable, e.g. setting it to `AUTH_REGISTRIES_DELIMITER=":::"`. In that case, `AUTH_REGISTRIES` could contain something like `registry1.com:::user1:::pass1 registry2.com:::user2:::pass2`.
- Timeouts ENVS - all of them can pe specified to control different timeouts, and if not set, the defaults will be the ones from `Dockerfile`. The directives will be added into `http` block.:
  - SEND_TIMEOUT : see [send_timeout](http://nginx.org/en/docs/http/ngx_http_core_module.html#send_timeout)
  - CLIENT_BODY_TIMEOUT : see [client_body_timeout](http://nginx.org/en/docs/http/ngx_http_core_module.html#client_body_timeout)
  - CLIENT_HEADER_TIMEOUT : see [client_header_timeout](http://nginx.org/en/docs/http/ngx_http_core_module.html#client_header_timeout)
  - KEEPALIVE_TIMEOUT : see [keepalive_timeout](http://nginx.org/en/docs/http/ngx_http_core_module.html#keepalive_timeout
  - PROXY_READ_TIMEOUT : see [proxy_read_timeout](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_read_timeout)
  - PROXY_CONNECT_TIMEOUT : see [proxy_connect_timeout](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_connect_timeout)
  - PROXY_SEND_TIMEOUT : see [proxy_send_timeout](http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_send_timeout)
  - PROXY_CONNECT_READ_TIMEOUT : see [proxy_connect_read_timeout](https://github.com/chobits/ngx_http_proxy_connect_module#proxy_connect_read_timeout)
  - PROXY_CONNECT_CONNECT_TIMEOUT : see [proxy_connect_connect_timeout](https://github.com/chobits/ngx_http_proxy_connect_module#proxy_connect_connect_timeout)
  - PROXY_CONNECT_SEND_TIMEOUT : see [proxy_connect_send_timeout](https://github.com/chobits/ngx_http_proxy_connect_module#proxy_connect_send_timeout))


### Simple (no auth, all cache)
```bash
docker run --rm --name docker_registry_proxy -it \
       -p 0.0.0.0:3128:3128 -e ENABLE_MANIFEST_CACHE=true \
       -v $(pwd)/docker_mirror_cache:/docker_mirror_cache \
       -v $(pwd)/docker_mirror_certs:/ca \
       rpardini/docker-registry-proxy:0.6.2
```

### DockerHub auth

For Docker Hub authentication:
- `hostname` should be `auth.docker.io`
- `username` should NOT be an email, use the regular username

```bash
docker run --rm --name docker_registry_proxy -it \
       -p 0.0.0.0:3128:3128 -e ENABLE_MANIFEST_CACHE=true \
       -v $(pwd)/docker_mirror_cache:/docker_mirror_cache \
       -v $(pwd)/docker_mirror_certs:/ca \
       -e REGISTRIES="k8s.gcr.io gcr.io quay.io your.own.registry another.public.registry" \
       -e AUTH_REGISTRIES="auth.docker.io:dockerhub_username:dockerhub_password your.own.registry:username:password" \
       rpardini/docker-registry-proxy:0.6.2
```

### Simple registries auth (HTTP Basic auth)

For regular registry auth (HTTP Basic), the `hostname` should be the registry itself... unless your registry uses a different auth server.

See the example above for DockerHub, adapt the `your.own.registry` parts (in both ENVs).

This should work for quay.io also, but I have no way to test.

### GitLab auth

GitLab may use a different/separate domain to handle the authentication procedure.

Just like DockerHub uses `auth.docker.io`, GitLab uses its primary (git) domain for the authentication.

If you run GitLab on `git.example.com` and its registry on `reg.example.com`, you need to include both in `REGISTRIES` and use the primary domain for `AUTH_REGISTRIES`.

For GitLab.com itself the authentication domain should be `gitlab.com`.

```bash
docker run  --rm --name docker_registry_proxy -it \
       -p 0.0.0.0:3128:3128 -e ENABLE_MANIFEST_CACHE=true \
       -v $(pwd)/docker_mirror_cache:/docker_mirror_cache \
       -v $(pwd)/docker_mirror_certs:/ca \
       -e REGISTRIES="reg.example.com git.example.com" \
       -e AUTH_REGISTRIES="git.example.com:USER:PASSWORD" \
       rpardini/docker-registry-proxy:0.6.2
```

### Google Container Registry (GCR) auth

For Google Container Registry (GCR), username should be `_json_key` and the password should be the contents of the service account JSON. 
Check out [GCR docs](https://cloud.google.com/container-registry/docs/advanced-authentication#json_key_file). 

The service account key is in JSON format, it contains spaces ("` `") and colons ("`:`"). 

To be able to use GCR you should set `AUTH_REGISTRIES_DELIMITER` to something different than space (e.g. `AUTH_REGISTRIES_DELIMITER=";;;"`) and `AUTH_REGISTRY_DELIMITER` to something different than a single colon (e.g. `AUTH_REGISTRY_DELIMITER=":::"`).

Example with GCR using credentials from a service account from a key file `servicekey.json`:

```bash
docker run --rm --name docker_registry_proxy -it \
       -p 0.0.0.0:3128:3128 -e ENABLE_MANIFEST_CACHE=true \
       -v $(pwd)/docker_mirror_cache:/docker_mirror_cache \
       -v $(pwd)/docker_mirror_certs:/ca \
       -e REGISTRIES="k8s.gcr.io gcr.io quay.io your.own.registry another.public.registry" \
       -e AUTH_REGISTRIES_DELIMITER=";;;" \
       -e AUTH_REGISTRY_DELIMITER=":::" \
       -e AUTH_REGISTRIES="gcr.io:::_json_key:::$(cat servicekey.json);;;auth.docker.io:::dockerhub_username:::dockerhub_password" \
       rpardini/docker-registry-proxy:0.6.2
```

## Configuring the Docker clients using Docker Desktop for Mac

Separate instructions for Mac clients available in [this dedicated Doc Desktop for Mac document](Docker-for-Mac.md).

## Configuring the Docker clients / Kubernetes nodes / Linux clients

Let's say you setup the proxy on host `192.168.66.72`, you can then `curl http://192.168.66.72:3128/ca.crt` and get the proxy CA certificate.

On each Docker host that is to use the cache:

- [Configure Docker proxy](https://docs.docker.com/config/daemon/systemd/#httphttps-proxy) pointing to the caching server
- Add the caching server CA certificate to the list of system trusted roots.
- Restart `dockerd`

Do it all at once, tested on Ubuntu Xenial, Bionic, and Focal, all systemd based:

```bash
# Add environment vars pointing Docker to use the proxy
mkdir -p /etc/systemd/system/docker.service.d
cat << EOD > /etc/systemd/system/docker.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://192.168.66.72:3128/"
Environment="HTTPS_PROXY=http://192.168.66.72:3128/"
EOD

### UBUNTU
# Get the CA certificate from the proxy and make it a trusted root.
curl http://192.168.66.72:3128/ca.crt > /usr/share/ca-certificates/docker_registry_proxy.crt
echo "docker_registry_proxy.crt" >> /etc/ca-certificates.conf
update-ca-certificates --fresh
###

### CENTOS
# Get the CA certificate from the proxy and make it a trusted root.
curl http://192.168.66.72:3128/ca.crt > /etc/pki/ca-trust/source/anchors/docker_registry_proxy.crt
update-ca-trust
###

# Reload systemd
systemctl daemon-reload

# Restart dockerd
systemctl restart docker.service
```

## Testing

Clear `dockerd` of everything not currently running: `docker system prune -a -f` *beware*

Then do, for example, `docker pull k8s.gcr.io/kube-proxy-amd64:v1.10.4` and watch the logs on the caching proxy, it should list a lot of MISSes.

Then, clean again, and pull again. You should see HITs! Success.

Do the same for `docker pull ubuntu` and rejoice.

Test your own registry caching and authentication the same way; you don't need `docker login`, or `.docker/config.json` anymore.

## Developing/Debugging

Since `0.4` there is a separate `-debug` version of the image, which includes `nginx-debug`, and (since 0.5.x) has a `mitmproxy` (actually `mitmweb`) inserted after the CONNECT proxy but before the caching logic, and a second `mitmweb` between the caching layer and DockerHub.
This allows very in-depth debugging. Use sparingly, and definitely not in production.

```bash
docker run --rm --name docker_registry_proxy -it 
       -e DEBUG_NGINX=true -e DEBUG=true -e DEBUG_HUB=true -p 0.0.0.0:8081:8081 -p 0.0.0.0:8082:8082 \
       -p 0.0.0.0:3128:3128 -e ENABLE_MANIFEST_CACHE=true \
       -v $(pwd)/docker_mirror_cache:/docker_mirror_cache \
       -v $(pwd)/docker_mirror_certs:/ca \
       rpardini/docker-registry-proxy:0.6.2-debug
```

- `DEBUG=true` enables the mitmweb proxy between Docker clients and the caching layer, accessible on port 8081
- `DEBUG_HUB=true` enables the mitmweb proxy between the caching layer and DockerHub, accessible on port 8082 (since 0.5.x)
- `DEBUG_NGINX=true` enables nginx-debug and debug logging, which probably is too much. Seriously.

## Gotchas

- If you authenticate to a private registry and pull through the proxy, those images will be served to any client that can reach the proxy, even without authentication. *beware*
- Repeat, **this will make your private images very public if you're not careful**.
- ~~**Currently you cannot push images while using the proxy** which is a shame. PRs welcome.~~ **SEE `ALLOW_PUSH` ENV FROM USAGE SECTION.**
- Setting this on Linux is relatively easy. 
  - On Mac and Windows the CA-certificate part will be very different but should work in principle.
  - Please send PRs with instructions for Windows and Mac if you succeed!

### Why not use Docker's own registry, which has a mirror feature?

Yes, Docker offers [Registry as a pull through cache](https://docs.docker.com/registry/recipes/mirror/), *unfortunately* 
it only covers the DockerHub case. It won't cache images from `quay.io`, `k8s.gcr.io`, `gcr.io`, or any such, including any private registries.

That means that your shiny new Kubernetes cluster is now a bandwidth hog, since every image will be pulled from the 
Internet on every Node it runs on, with no reuse.

This is due to the way the Docker "client" implements `--registry-mirror`, it only ever contacts mirrors for images 
with no repository reference (eg, from DockerHub).
When a repository is specified `dockerd` goes directly there, via HTTPS (and also via HTTP if included in a 
`--insecure-registry` list), thus completely ignoring the configured mirror.

### Docker itself should provide this.

Yeah. Docker Inc should do it. So should NPM, Inc. Wonder why they don't. 😼

### TODO:

- [x] Basic Docker-for-Mac set-up instructions
- [ ] Basic Docker-for-Windows set-up instructions. 
- [ ] Test and make auth work with quay.io, unfortunately I don't have access to it (_hint, hint, quay_)
- [x] Hide the mitmproxy building code under a Docker build ARG.
- [ ] "Developer Office" proxy scenario, where many developers on a fast LAN share a proxy for bandwidth and speed savings (already works for pulls, but messes up pushes, which developers tend to use a lot)
