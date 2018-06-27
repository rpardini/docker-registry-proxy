### What?

An intricate, insecure, and hackish way of caching Docker images from private registries (eg, not from DockerHub).
Caches via HTTP man-in-the-middle.
It is highly dependent on Docker-client behavior, and was only tested against Docker 17.03 on Linux (that's the version recommended by Kubernetes 1.10).

#### Why not use Docker's own registry, which has a mirror feature?

Yes, Docker offers [Registry as a pull through cache](https://docs.docker.com/registry/recipes/mirror/), 
and, in fact, for a caching solution to be complete, you'll want to run one of those. 

**Unfortunately** this only covers the DockerHub case. It won't cache images from `quay.io`, `k8s.gcr.io`, `gcr.io`, or any such, including any private registries.

That means that your shiny new Kubernetes cluster is now a bandwidth hog, since every image will be pulled from the Internet on every Node it runs on, with no reuse.

This is due to the way the Docker "client" implements `--registry-mirror`, it only ever contacts mirrors for images with no repository reference (eg, from DockerHub).
When a repository is specified `dockerd` goes directly there, via HTTPS (and also via HTTP if included in a `--insecure-registry` list), thus completely ignoring the configured mirror.

_Even worse,_ to complement that client-Docker problem, there is also a one-URL limitation on the registry/mirror side of things, so even if it worked we would need to run multiple mirror-registries, one for each mirrored repo.


#### Hey but that sounds like an important limitation on Docker's side. Shouldn't they fix it?

**Hell, yes**. Actually if you search on Github you'll find a lot of people with the same issues.
* This seems to be the  [main issue on the Registry side of things](https://github.com/docker/distribution/issues/1431) and shows a lot of the use cases.
* [Valentin Rothberg](https://github.com/vrothberg) from SUSE has implemented the support 
  the client needs [in PR #34319](https://github.com/moby/moby/pull/34319) but after a lot of discussions and 
  [much frustration](https://github.com/moby/moby/pull/34319#issuecomment-389783454) it is still unmerged. Sigh.


**So why not?** I have no idea; it's easy to especulate that "Docker Inc" has no interest in something that makes their main product less attractive. No matter, we'll just _hack_ our way.   

### How?

This solution involves setting up quite a lot of stuff, including DNS hacks.

You'll need a dedicated host for running two caches, both in containers, but you'll need ports 80, 443, and 5000 available.

I'll refer to the caching proxy host's IP address as 192.168.66.62 in the next sections, substitute for your own. 

#### 0) A regular DockerHub registry mirror

Just follow instructions on [Registry as a pull through cache](https://docs.docker.com/registry/recipes/mirror/) - expose it on 0.0.0.0:5000.
This will only be used for DockerHub caching, and works well enough.

#### 1) This caching proxy

This is an `nginx` configured extensively for reverse-proxying HTTP/HTTPS to the registries, and apply caching to it.

It should be run in a Docker container, and **needs** be mapped to ports 80 and 443. Theres a Docker volume you can mount for storing the cached layers.

```bash
docker run --rm --name docker_caching_proxy -it \ 
           -p 0.0.0.0:80:80 -p 0.0.0.0:443:443 \
           -v /docker_mirror_cache:/docker_mirror_cache \
           rpardini/docker-caching-proxy-multiple-private:latest
```

**Important**: the host running the caching proxy container should not have any extra configuration or DNS hacks shown below. 

The logging is done to stdout, but the format has been tweaked to show cache MISS/HIT(s) and other useful information for this use case.

It goes to great lengths to try and get the highest hitratio possible, to the point of rewriting headers from registries when they try to redirect to a storage service like Amazon S3 or Google Storage.

It is very insecure, anyone with access to the proxy will have access to its cached images regardless of authentication, for example.


#### 2) dockerd DNS hacks

We'll need to convince Docker (actually, `dockerd` on very host) to talk to our caching proxy via some sort of DNS hack.
The simplest for sure is to just include entries in `/etc/hosts` for each registry you want to mirror, plus a fixed address used for redirects:

```bash
# /etc/hosts entries for docker caching proxy
192.168.66.72 docker.proxy
192.168.66.72 k8s.gcr.io
192.168.66.72 quay.io
192.168.66.72 gcr.io
``` 

Only `docker.proxy` is always required, and each registry you want to mirror also needs an entry.

I'm sure you can do stuff to the same effect with your DNS server but I won't go into that.
 
#### 3) dockerd configuration for mirrors and insecure registries

Of course, we don't have a TLS certificate for `quay.io` et al, so we'll need to tell Docker to treat all proxied registries as _insecure_.

We'll also point Docker to the "regular" registry mirror in item 0. 

To do so in one step, edit `/etc/docker/daemon.json` (tested on Docker 17.03 on Ubuntu Xenial only):

```json
{
  "insecure-registries": [
    "k8s.gcr.io",
    "quay.io",
    "gcr.io"
  ],
  "registry-mirrors": [
    "http://192.168.66.72:5000"
  ]
}
```

After that, restart the Docker daemon: `systemctl restart docker.service`

### Testing

Clear the local `dockerd` of everything not currently running: `docker system prune -a -f` (this prunes everything not currently running, beware).
Then do, for example, `docker pull k8s.gcr.io/kube-proxy-amd64:v1.10.4` and watch the logs on the caching proxy, it should list a lot of MISSes.
Then, clean again, and pull again. You should see HITs! Success.

### Gotchas

Of course, this has a lot of limitations

- Any HTTP/HTTPS request to the domains of the registries will be proxied, not only Docker calls. *beware*
- If you want to proxy an extra registry you'll have multiple places to edit (`/etc/hosts` and `/etc/docker/daemon.json`) and restart `dockerd` - very brave thing to do in a k8s cluster, so set it up beforehand
- If you authenticate to a private registry and pull through the proxy, those images will be served to any client that can reach the proxy, even without authentication. *beware*