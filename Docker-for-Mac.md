# Attention: don't use Docker's own GUI to set the proxy!

- See https://github.com/docker/for-mac/issues/2467
- In `Docker > Preferences`, in `Resources > Proxies`, make sure you're NOT using manual proxies
- Use the hack below to set the environment var directly in LinuxKit
- The issue is that setting it in the GUI affects containers too (!!!), and we don't want that in this scenario
- If you actually need an upstream proxy (for company proxy etc) this will NOT work.

# Using a Docker Desktop for Mac as a client for the proxy

First, know this is a MiTM, and could break with new Docker Desktop for Mac releases or during resets/reinstalls/upgrades.

These instructions tested on Mac OS Catalina, and:
- Docker Desktop for Mac `2.4.2.0` (Edge) (which provides Docker `20.10.0-beta1`)
- Docker Desktop for Mac `2.5.0.0` (Stable) (which provides Docker `19.03`)

This assumes you have `docker-registry-proxy` running _somewhere else_, eg, on a different machine on your local network.

See the main [README.md](README.md) for instructions. (If you're trying to run both proxy and client on the same machine, see below).

We'll inject the CA certificates and the HTTPS_PROXY env into the Docker install inside the HyperKit VM running LinuxKit that is used by Docker Desktop for Mac.

To do that, we use a privileged container. `justincormack/nsenter1` does the job nicely. 

First things first:

### 1) Factory Reset Docker Desktop for Mac...
... or make sure it's pristine (just installed).

- Go into Troubleshoot > "Reset to Factory defaults"
- it will take a while to reset/restart everything and require your password.
 
### 2) Inject config into Docker's VM

For these examples I will assume it is successfully running on `http://192.168.1.2:3128/` -- 
change the `export DRP_PROXY` as appropriate. Do not include slashes.

Run these commands in your Mac terminal.

```bash
set -e
export DRP_PROXY="192.168.66.100:3129" # Format IP:port, change this 
wget -O - "http://${DRP_PROXY}/" # Make sure you can reach the proxy
# Inject the CA certificate
docker run -it --privileged --pid=host justincormack/nsenter1 \
  /bin/bash -c "wget -O - http://$DRP_PROXY/ca.crt \
 | tee -a /containers/services/docker/lower/etc/ssl/certs/ca-certificates.crt"

# Preserve original config.
docker run -it --privileged --pid=host justincormack/nsenter1 /bin/bash -c "cp /containers/services/docker/config.json /containers/services/docker/config.json.orig"

# Inject the HTTPS_PROXY enviroment variable. I dare you find a better way.
docker run -it --privileged --pid=host justincormack/nsenter1 /bin/bash -c "sed -ibeforedockerproxy -e  's/\"PATH=/\"HTTPS_PROXY=http:\/\/$DRP_PROXY\/\",\"PATH=/' /containers/services/docker/config.json"
```

### 3) Restart, test.

- Restart Docker. (Quit & Open again, or just go into Preferences and give it more RAM, then Restart.) 
- Try a `docker pull` now. It should be using the proxy (watch the logs on the proxy server).
- Test that no crazy proxy has been set: `docker run -it curlimages/curl:latest http://ifconfig.me` and `docker run -it curlimages/curl:latest https://ifconfig.me` both work.
- Important: **push**es done with this configured will either not work, or use the auth you configured on the proxy, if any. Beware, and report back.  
  

# Using Docker Desktop for Mac to both host the proxy server and use it as a client

@TODO: This has a bunch of chicken-and-egg issues. 

You need to pre-pull the proxy itself and `justincormack/nsenter1`.

Follow the instructions above, but pre-pull after the Factory Reset.

Do NOT use 127.0.0.1, instead use your machine's local LAN IP address.

Make sure to bring the proxy up after applying/restarting the Docker Engine.
