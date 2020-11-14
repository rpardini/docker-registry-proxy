# How to use docker-registry-proxy with kops 

## Install docker-registry-proxy

For running docker-registry-proxy with kops you will need to run it outside the cluster you want to configure, you can either use and EC2 instance and run:

```bash
docker run --rm --name docker_registry_proxy -it \
       -p 0.0.0.0:3128:3128 -e ENABLE_MANIFEST_CACHE=true \
       -v $(pwd)/docker_mirror_cache:/docker_mirror_cache \
       -v $(pwd)/docker_mirror_certs:/ca \
       rpardini/docker-registry-proxy:0.6.0
```

or you can run it from another cluster, maybe a management/observability one with provided yaml, in this case, you will need to change the following lines:

```
  annotations:
    external-dns.alpha.kubernetes.io/hostname: docker-registry-proxy.<your_domain>
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
```

with the correct domain name, so then you can reference the proxy as `http://docker-registry-proxy.<your_domain>:3128`

## Test the connection to the proxy

A simple curl should return:

```
❯ curl docker-registry-proxy.<your_domain>:3128
docker-registry-proxy: The docker caching proxy is working!%
```

## Configure kops to use the proxy

Kops has the option to configure a cluster wide proxy, as explained [here](https://github.com/kubernetes/kops/blob/master/docs/http_proxy.md) but this wont work, as nodeup will fail to download the images, what you need is to use `additionalUserData`, which is part of the instance groups configuration.

So consider a node configuration like this one:

```
apiVersion: kops.k8s.io/v1alpha2
kind: InstanceGroup
metadata:
  labels:
    kops.k8s.io/cluster: spot.k8s.local
  name: spotgroup
spec:
  image: 099720109477/ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-20200528
  machineType: c3.xlarge
  maxSize: 15
  minSize: 2
  mixedInstancesPolicy:
    instances:
    - c3.xlarge
    - c4.xlarge
    - c5.xlarge
    - c5a.xlarge
    onDemandAboveBase: 0
    onDemandBase: 0
    spotAllocationStrategy: capacity-optimized
  nodeLabels:
    kops.k8s.io/instancegroup: spotgroup
  role: Node
  subnets:
  - us-east-1a
  - us-east-1b
  - us-east-1c
```

you will need to add the following:

```
  additionalUserData:
    - name: docker-registry-proxy.sh
      type: text/x-shellscript
      content: |
        #!/bin/sh

        # Add environment vars pointing Docker to use the proxy
        # https://docs.docker.com/config/daemon/systemd/#httphttps-proxy

        mkdir -p /etc/systemd/system/docker.service.d
        cat << EOD > /etc/systemd/system/docker.service.d/http-proxy.conf
        [Service]
        Environment="HTTP_PROXY=http://docker-registry-proxy.<your_domain>:3128/"
        Environment="HTTPS_PROXY=http://docker-registry-proxy.<your_domain>:3128/"
        EOD

        # Get the CA certificate from the proxy and make it a trusted root.
        curl http://docker-registry-proxy.<your_domain>:3128/ca.crt > /usr/share/ca-certificates/docker_registry_proxy.crt
        echo "docker_registry_proxy.crt" >> /etc/ca-certificates.conf
        update-ca-certificates --fresh

        # Reload systemd
        systemctl daemon-reload

        # Restart dockerd
        systemctl restart docker.service
```

so the final InstanceGroup will look like this:

```
apiVersion: kops.k8s.io/v1alpha2
kind: InstanceGroup
metadata:
  labels:
    kops.k8s.io/cluster: spot.k8s.local
  name: spotgroup
spec:
  additionalUserData:
    - name: docker-registry-proxy.sh
      type: text/x-shellscript
      content: |
        #!/bin/sh

        # Add environment vars pointing Docker to use the proxy
        # https://docs.docker.com/config/daemon/systemd/#httphttps-proxy

        mkdir -p /etc/systemd/system/docker.service.d
        cat << EOD > /etc/systemd/system/docker.service.d/http-proxy.conf
        [Service]
        Environment="HTTP_PROXY=http://docker-registry-proxy.<your_domain>:3128/"
        Environment="HTTPS_PROXY=http://docker-registry-proxy.<your_domain>:3128/"
        EOD

        # Get the CA certificate from the proxy and make it a trusted root.
        curl http://docker-registry-proxy.<your_domain>:3128/ca.crt > /usr/share/ca-certificates/docker_registry_proxy.crt
        echo "docker_registry_proxy.crt" >> /etc/ca-certificates.conf
        update-ca-certificates --fresh

        # Reload systemd
        systemctl daemon-reload

        # Restart dockerd
        systemctl restart docker.service
  image: 099720109477/ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-20200528
  machineType: c3.xlarge
  maxSize: 15
  minSize: 2
  mixedInstancesPolicy:
    instances:
    - c3.xlarge
    - c4.xlarge
    - c5.xlarge
    - c5a.xlarge
    onDemandAboveBase: 0
    onDemandBase: 0
    spotAllocationStrategy: capacity-optimized
  nodeLabels:
    kops.k8s.io/instancegroup: spotgroup
  role: Node
  subnets:
  - us-east-1a
  - us-east-1b
  - us-east-1c
```

Now all you need is to upgrade your cluster and do a rolling-update of the nodes, all images will be cached from now on.
