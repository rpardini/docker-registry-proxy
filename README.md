## docker-registry-proxy

### TL,DR

A caching proxy for Docker; allows centralised management of registries and their authentication; caches images from *any* registry.

### What?

Created as an evolution and simplification of [docker-caching-proxy-multiple-private](https://github.com/rpardini/docker-caching-proxy-multiple-private) 
using the `HTTPS_PROXY` mechanism and injected CA root certificates instead of `/etc/hosts` hacks and `--insecure-registry` 

Main feature is Docker layer/image caching, even from S3, Google Storage, etc. As a bonus it allows for centralized management of Docker registry credentials. 
 
You configure the Docker clients (_err... Kubernetes Nodes?_) once, and then all configuration is done on the proxy -- 
for this to work it requires inserting a root CA certificate into system trusted root certs.

### Usage

- Run the proxy on a host close to the Docker clients
- Expose port 3128 to the network
- Map volume `/docker_mirror_cache` for up to 32gb of cached images from all registries
- Map volume `/ca`, the proxy will store the CA certificate here across restarts
- Env `REGISTRIES`: space separated list of registries to cache; no need to include Docker Hub, its already there.
- Env `AUTH_REGISTRIES`: space separated list of `hostname:username:password` authentication info. 
  - `hostname`s listed here should be listed in the REGISTRIES environment as well, so they can be intercepted.
  - For Docker Hub authentication, `hostname` should be `auth.docker.io`, username should NOT be an email, use the regular username.
  - For regular registry auth (HTTP Basic), `hostname` here should be the same... unless your registry uses a different auth server. This should work for quay.io also, but I have no way to test.
  - For Google Container Registry (GCR), username should be `_json_key` and the password should be the contents of the service account JSON. Check out [GCR docs](https://cloud.google.com/container-registry/docs/advanced-authentication#json_key_file)
  

```bash
docker run --rm --name docker_registry_proxy -it \
       -p 0.0.0.0:3128:3128 \
       -v $(pwd)/docker_mirror_cache:/docker_mirror_cache \
       -v $(pwd)/docker_mirror_certs:/ca \
       -e REGISTRIES="k8s.gcr.io gcr.io quay.io your.own.registry another.public.registry" \
       -e AUTH_REGISTRIES="auth.docker.io:dockerhub_username:dockerhub_password your.own.registry:username:password" \
       rpardini/docker-registry-proxy:0.2.4
```

Let's say you did this on host `192.168.66.72`, you can then `curl http://192.168.66.72:3128/ca.crt` and get the proxy CA certificate.

#### Configuring the Docker clients / Kubernetes nodes

On each Docker host that is to use the cache:

- [Configure Docker proxy](https://docs.docker.com/config/daemon/systemd/#httphttps-proxy) pointing to the caching server
- Add the caching server CA certificate to the list of system trusted roots.
- Restart `dockerd`

Do it all at once, tested on Ubuntu Xenial, which is systemd based:

```bash
# Add environment vars pointing Docker to use the proxy
mkdir -p /etc/systemd/system/docker.service.d
cat << EOD > /etc/systemd/system/docker.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://192.168.66.72:3128/"
Environment="HTTPS_PROXY=http://192.168.66.72:3128/"
EOD

# Get the CA certificate from the proxy and make it a trusted root.
curl http://192.168.66.72:3128/ca.crt > /usr/share/ca-certificates/docker_registry_proxy.crt
echo "docker_registry_proxy.crt" >> /etc/ca-certificates.conf
update-ca-certificates --fresh

# Reload systemd
systemctl daemon-reload

# Restart dockerd
systemctl restart docker.service
```

### Testing

Clear `dockerd` of everything not currently running: `docker system prune -a -f` *beware*

Then do, for example, `docker pull k8s.gcr.io/kube-proxy-amd64:v1.10.4` and watch the logs on the caching proxy, it should list a lot of MISSes.

Then, clean again, and pull again. You should see HITs! Success.

Do the same for `docker pull ubuntu` and rejoice.

Test your own registry caching and authentication the same way; you don't need `docker login`, or `.docker/config.json` anymore.

### Gotchas

- If you authenticate to a private registry and pull through the proxy, those images will be served to any client that can reach the proxy, even without authentication. *beware*
- Repeat, this will make your private images very public if you're not careful.
- **Currently you cannot push images while using the proxy** which is a shame. PRs welcome.
- Setting this on Linux is relatively easy. On Mac and Windows the CA-certificate part will be very different but should work in principle.

#### Why not use Docker's own registry, which has a mirror feature?

Yes, Docker offers [Registry as a pull through cache](https://docs.docker.com/registry/recipes/mirror/), *unfortunately* 
it only covers the DockerHub case. It won't cache images from `quay.io`, `k8s.gcr.io`, `gcr.io`, or any such, including any private registries.

That means that your shiny new Kubernetes cluster is now a bandwidth hog, since every image will be pulled from the 
Internet on every Node it runs on, with no reuse.

This is due to the way the Docker "client" implements `--registry-mirror`, it only ever contacts mirrors for images 
with no repository reference (eg, from DockerHub).
When a repository is specified `dockerd` goes directly there, via HTTPS (and also via HTTP if included in a 
`--insecure-registry` list), thus completely ignoring the configured mirror.

#### Docker itself should provide this.

Yeah. Docker Inc should do it. So should NPM, Inc. Wonder why they don't. 😼

### TODO:

- Allow using multiple credentials for DockerHub; this is possible since the `/token` request includes the wanted repo as a query string parameter.
- Test and make auth work with quay.io, unfortunately I don't have access to it (_hint, hint, quay_)
- Make the cache size configurable, today it's fixed at 32gb.
- Hide the mitmproxy building code under a Docker build ARG.
- I hope that in the future this can also be used as a "Developer Office" proxy, where many developers on a fast local network
  share a proxy for bandwidth and speed savings; work is ongoing in this direction.
