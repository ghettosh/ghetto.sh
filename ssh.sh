#!/usr/bin/env bash

# a wapper for ssh'ing to the vpn instance

# TODO: implement a ssh-keyscan in build_vpn.sh so we can specify
# a custom knownhostsfile here in order to be safe from mitm
set -x
host=${1:?usage $0 <target>}
ssh squirrel@${host} -i keys/${host}/${host} \
  -o UserKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=no

