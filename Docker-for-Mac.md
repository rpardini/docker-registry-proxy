# Using a Docker Desktop for Mac as a client for the proxy

First, know this is a MiTM, and could break with new Docker Desktop for Mac releases or during resets/reinstalls/upgrades.

These instructions tested on Mac OS Catalina, and:
- Docker Desktop for Mac `2.5.0.0` (Stable) (which provides Docker `19.03`)
- Docker Desktop for Mac `2.4.2.0` (Edge) (which provides Docker `20.10.0-beta1`)

This assumes you have `docker-registry-proxy` running _somewhere else_, eg, on a different machine on your local network.

See the main [README.md](README.md) for instructions. (If you're trying to run both proxy and client on the same machine, see below).

For these examples I will assume it is successfully running on `http://192.168.1.2:3128/`

- Make sure you can access the proxy. On your Mac/Terminal (not Docker), run:
  ```shell script
  # with wget...
  wget --quiet -O - "http://192.168.1.2:3128/"
  # ... or, with curl:
  curl "http://192.168.1.2:3128/"
  ```
- Make sure your Docker Desktop for Mac install is pristine like new, go into Troubleshoot > "Reset to Factory defaults".
- Inject the CA certificates into the Docker install inside the HyperKit VM running LinuxKit that is used by Docker Desktop for Mac.
  To do that, we use a privileged container. `justincormack/nsenter1` does the job nicely: 
  ```shell script
  docker run -it --privileged --pid=host justincormack/nsenter1 /bin/bash -c "wget -O - http://192.168.1.2:3128/ca.crt | tee -a /containers/services/docker/lower/etc/ssl/certs/ca-certificates.crt"
  ```
- Go into `Docker > Preferences`, and set `Resources > Proxies` to 
  - "Manual proxy configuration" to ON
    - HTTP proxy: `http://192.168.1.2:3128/`
    - HTTPS proxy: `http://192.168.1.2:3128/`
  - (Optional) I also recommend "Enable CLI experimental features" under "Experimental Features" (since I use `buildx` a lot)
  - Click button "Apply & Restart", wait for it to restart.
- Try a `docker pull` now. It should be using the proxy (watch the logs on the proxy server).
- Important: **push**es done with this configured will either not work, or use the auth you configured on the proxy, if any. Beware, and report back.  
  

# Using Docker Desktop for Mac to both host the proxy server and use it as a client

@TODO: This has a bunch of chicken-and-egg issues. 

You need to pre-pull the proxy itself and `justincormack/nsenter1`.

Then set up the proxy server, and then follow the instructions above (without the Factory Reset).

Do NOT use 127.0.0.1, instead use your machine's local LAN IP address. (Hint: there's a good chance 192.168.64.1 is useable, due the the way Docker Desktop for Mac sets networking up).

Make sure to bring the proxy up after applying/restarting the Docker Engine.
