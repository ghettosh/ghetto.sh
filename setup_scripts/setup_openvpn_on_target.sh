#!/usr/bin/env bash

CN=${CN:-$(uname -n)}
OVPN_DATA=${OVPN_DATA:-vpndata-${CN}}
CLIENTNAME=${CLIENTNAME:-vpnclient${CN}-$((RANDOM))}
GENCONFIG_OPTS=${GENCONFIG_OPTS:- -C AES-256-CBC -a SHA256}
PROTOCOL="udp"
PORT=1194
CTAG="awsvpn-$(uname -n)"
OVPN_DATA="${CTAG}-vpndata"

if [ ! -d /tmp/docker-openvpn ]; then
  cd /tmp
  git clone https://github.com/kylemanna/docker-openvpn.git
  cd docker-openvpn
  sed -i 's/^easyrsa build-ca/easyrsa --batch build-ca/g' bin/ovpn_initpki
  docker build --force-rm -t ${CTAG} . || exit 6
fi

docker rm ${OVPN_DATA} > /dev/null 2>&1

# This step builds a docker volume, a persistent datastore that you can pass
# between containers, or hand to a new/or rebilt one.
timeout 1m docker run --name $OVPN_DATA -v /etc/openvpn busybox || exit 5
sleep 5

# This step runs 'ovpn_genconfig' script inside of a container from the imate
# '${CTAG}'. This script writes to files in /etc/openvpn/ , which are
# in that datastore we just created.
timeout 1m docker run --volumes-from $OVPN_DATA \
  --rm ${CTAG} \
    ovpn_genconfig ${GENCONFIG_OPTS} \
    -u ${PROTOCOL}://${CN}:${PORT} >/dev/null 2>&1 || exit 4
  sleep 5

# This step initializes the PKI.
timeout 10m docker run --volumes-from $OVPN_DATA \
  -e OVPN_CN=${CN} \
  --rm \
  -i ${CTAG} \
    bash /usr/local/bin/ovpn_initpki nopass >/dev/null 2>&1 || exit 3
sleep 5

# This step actually runs openvpn
timeout 1m docker run --restart=always \
  --volumes-from $OVPN_DATA \
  -d -p ${PORT}:${PORT}/${PROTOCOL} --cap-add=NET_ADMIN ${CTAG} || exit 2


