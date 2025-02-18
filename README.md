Install script to set up nomad daemonized

How to use:

Running the install script

<sudo ./install.sh>

Running the uninstall script

<sudo ./uninstall.sh>

UPDATE INFO:

Updating the nomad version:

1. Change the NOMAD_VERSION variable in install.sh to the desired version (e.g. 1.9.7)

2. run uninstall.sh

3. run install.sh

Updating the client.hcl:

1. Make a release for the new client.hcl in the nomadClientConfig repo (https://github.com/Quok-it/nomadClientConfig/tags)

2. Change GITHUB_CONFIG_REPO in install.sh to the link to the new zip archive for the new release

3. Change the tag in GITHUB_RELEASE_DIR in install.sh -> nomadClientConfig-(tag).zip to the tag for the new release

4. run uninstall.sh

5. run install.sh

