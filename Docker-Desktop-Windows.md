# Configure Docker Desktop on Windows to use the proxy and trust its certificate

1. Let's say you set up the proxy on host `192.168.66.72`. Get the certificate using a browser (go to <http://192.168.66.72:3128/ca.crt>) and save it as a file (e.g., to `d:\ca.crt`)

1. Add the certificate to Windows:

   1. Double click the certificate
   1. Chose to _Install certificate..._, then click _Next_
   1. Chose _Current user_, then click _Next_
   1. Select option _Place all certificates in the following store_, click _browse_, and select _Trusted Root Certification Authorities_
   1. Proceed with Ok and confirm to install the certificate. (verify if certificate is installed via _control panel --> Manage computer certificates --> Certificates Local computer --> Trusted Root Certification Authorities --> Certificates_ . If you dont find your certificate here, manually install certificate by importing it by _Action --> All tasks --> Import_). 

   If you are not using the WSL2 backend for Docker, then restart Docker Desktop and skip the next step.

1. If you are using WSL2 for Docker, then you need to add the certificate to WSL too:

   1. Open a terminal

   1. Check the name of the WSL distribution:

      ```
      PS C:\> wsl --list
      Windows Subsystem for Linux Distributions:
      docker-desktop (Default)
      docker-desktop-data
      ```

      The distribution we are looking for is _docker-desktop_. If you installed another distribution, such as Ubuntu, and configured Docker to use that, and proceed with that distribution instead.

   1. Get a shell into WSL

      ```
      PS C:\> wsl --distribution docker-desktop
      XXXYYYZZZ:/tmp/docker-desktop-root/mnt/host/c#
      ```

   1. Copy the certificate into WSL and import it

      Note: The directory and the command below are for the _docker-desktop_ WSL distribution. On other systems you might need to tweak the commands a little, but they seem to be the same for [Ubuntu](https://www.pmichaels.net/2020/12/29/add-certificate-into-wsl/) and [Debian](https://github.com/microsoft/WSL/issues/3161#issue-320777324) as well.

      ```
      XXXYYYZZZ:/tmp/docker-desktop-root/mnt/host/c# cp /mnt/host/d/ca.crt /usr/local/share/ca-certificates/
      XXXYYYZZZ:/tmp/docker-desktop-root/mnt/host/c# update-ca-certificates
      WARNING: ca-certificates.crt does not contain exactly one certificate or CRL: skipping
      ```

      Don't mind the warning, the operation still succeeded.

   1. We are done with WSL, you can `exit` this shell

1. Configure the proxy in Docker Desktop:

   1. Open Docker Desktop settings
   1. Go to _Resources/Proxies_
   1. Enable the proxy and set `http://192.168.66.72:3128` as both the HTTP and HTTPS URL.

1. Done. Verify that pulling works:

   ```
   # execute this in a Windows shell, not in WSL
   docker pull hello-world
   ```

   You can check the logs of the proxy to confirm that it was used.

   If pulling does not work and complains about not trusting the certificate then Docker and/or the WSL distribution might need a restart. You might try restarting Docker, or you can restart Windows too to force WSL to restart.

