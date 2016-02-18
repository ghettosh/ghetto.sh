#!/usr/bin/env bash

CN=${CN:-$(uname -n)}
CLIENTNAME=${CLIENTNAME:-vpnclient${CN}-$((RANDOM))}
CTAG="awsvpn-$(uname -n)"
OVPN_DATA="${CTAG}-vpndata"

docker run --volumes-from $OVPN_DATA \
  --rm -t -i ${CTAG} easyrsa build-client-full ${CLIENTNAME} nopass > /tmp/$$.build.log 2>&1

docker run --volumes-from $OVPN_DATA \
  --rm ${CTAG} ovpn_getclient ${CLIENTNAME} 2>/dev/null
