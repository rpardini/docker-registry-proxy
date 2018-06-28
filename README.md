## docker-registry-proxy

### TL,DR

A caching proxy for Docker; allows centralized management of registries and their authentication; caches images from *any* registry.

### What?

Created as an evolution and simplification of [docker-caching-proxy-multiple-private](https://github.com/rpardini/docker-caching-proxy-multiple-private) 
using the `HTTPS_PROXY` mechanism and injected CA root certificates instead of `/etc/hosts` hacks and _`--insecure-registry` 

As a bonus it allows for centralized management of Docker registry credentials. 
 
You configure the Docker clients (_err... Kubernetes Nodes?_) once, and then all configuration is done on the proxy -- 
for this to work it requires inserting a root CA certificate into system trusted root certs.

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

### Usage

- Run the proxy on a dedicated machine.
- Expose port 3128
- Map volume `/docker_mirror_cache` for up to 32gb of cached images from all registries
- Map volume `/ca`, the proxy will store the CA certificate here across restarts
- Env `REGISTRIES`: space separated list of registries to cache; no need to include Docker Hub, its already there
- Env `AUTH_REGISTRIES`: space separated list of `registry:username:password` authentication info. Registry hosts here should be listed in the above ENV as well.

```bash
docker run --rm --name docker_caching_proxy -it \
       -p 0.0.0.0:3128:3128 \  
       -v $(pwd)/docker_mirror_cache:/docker_mirror_cache  \
       -v $(pwd)/docker_mirror_certs:/ca  \
       -e REGISTRIES="k8s.gcr.io gcr.io quay.io your.own.registry another.private.registry" \ 
       -e AUTH_REGISTRIES="your.own.registry:username:password another.private.registry:user:pass"  \ 
       rpardini/docker-caching-proxy:latest
```

Let's say you did this on host `192.168.66.72`, you can then `curl http://192.168.66.72:3128/ca.crt` and get the proxy CA certificate.

#### Configuring the Docker clients / Kubernetes nodes

On each Docker host that is to use the cache:

- [Configure Docker proxy](https://docs.docker.com/network/proxy/) pointing to the caching server
- Add the caching server CA certificate to the list of system trusted roots.
- Restart `dockerd`

Do it all at once, tested on Ubuntu Xenial:

```bash
# Add environment vars pointing Docker to use the proxy
cat << EOD > /etc/systemd/system/docker.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://192.168.66.72:3128/"
Environment="HTTPS_PROXY=http://192.168.66.72:3128/"
EOD

# Get the CA certificate from the proxy and make it a trusted root.
curl http://192.168.66.123:3128/ca.crt > /usr/share/ca-certificates/docker_caching_proxy.crt
echo docker_caching_proxy.crt >> /etc/ca-certificates.conf
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
