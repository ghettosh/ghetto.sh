#!/usr/bin/env bash

# An ondemand vpn builder.

set -e -o pipefail

# setup
declare -A regions
regions["tokyo"]="ap-northeast-1"
regions["oregon"]="us-west-2"
regions["sydney"]="ap-southeast-2"
regions["ireland"]="eu-west-1"
regions["germany"]="eu-central-1"
regions["sao_paulo"]="sa-east-1"
regions["signapore"]="ap-southeast-1"

# disabled regions: high number of failed builds / slow entropy
# regions["california"]="us-west-1"
# regions["virginia"]="us-east-1"

cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1
if [[ ! -d ./bash-concurrent ]]; then
  git clone https://github.com/themattrix/bash-concurrent > /dev/null 2>&1
fi
source "$(pwd)/bash-concurrent/concurrent.lib.sh"

#-----------------------------------------------------------------------------
# the builder
build_vm(){
  regions_count="${#regions[@]}"
  regions_friendly=( ${!regions[*]} )
  regions_random_chosen="${regions_friendly[ $(( RANDOM % regions_count )) ]}"

  # we set these as globals
  ip="$(_get_ip)"
  name="$(_random_name)"
  region="${regions_random_chosen}"
  keyfile="keys/${name}/${name}"
  cc_file="cloud-init-scripts/${name}.yml"
  aws_region="${regions[${region}]}"
  output_file="$(mktemp)"

  args=(
    - "choosing a region"           echo_region
    - "making a random name"        echo_random_name
    - "detecting my ip address"     echo_get_ip

    - "building private key"        build_private_key
    - "building cloud-config"       build_cloud_config

    - "creating security group"     create_security_group
    - "authorize tcp 22"            authorize_security_group ingress 22 tcp
    - "authorize udp 1194"          authorize_security_group ingress 1194 udp
    - "sending build command"       run_instances
    - "setting instance tags"       set_instance_tags

    - "getting public IP"           store_public_ip
    - "updating /etc/hosts"         update_etc_hosts
    - "sending SIGHUP to dnsmasq"   sighup_dnsmasq

    - "wait for ssh"                wait_for_ssh

    - "send openvpn scripts"        send_openvpn_scripts
    - "setup openvpn server"        run_vpnserver_setup

    --require  "choosing a region"
    --require  "making a random name"
    --require  "detecting my ip address"
    --before   "building private key"

    --require  "building private key"
    --before   "building cloud-config"

    --require  "creating security group"
    --before   "authorize tcp 22"
    --before   "authorize udp 1194"

    --require  "building cloud-config"
    --require  "creating security group"
    --before   "sending build command"

    --require  "sending build command"
    --before   "setting instance tags"

    --require  "sending build command"
    --before   "getting public IP"

    --require  "getting public IP"
    --before   "updating /etc/hosts"

    --require  "updating /etc/hosts"
    --before   "sending SIGHUP to dnsmasq"

    --require  "getting public IP"
    --before   "wait for ssh"

    --require "wait for ssh"
    --before "send openvpn scripts"

    --require "send openvpn scripts"
    --before "setup openvpn server"

  )
  concurrent "${args[@]}"
}


#-----------------------------------------------------------------------------
# functions
build_cloud_config(){
  mkdir -p ./cloud-init-scripts
  touch ${cc_file}
  chmod 600 ${cc_file}

  public_key="$(ssh-keygen -y -f ${keyfile} 2>/dev/null)"

  cat << EOT > ${cc_file}
#cloud-config
hostname: "${name}"
coreos:
  update:
    reboot-strategy: "reboot"
users:
  - name: "squirrel"
    groups:
      - "wheel"
      - "sudo"
      - "docker"
    ssh-authorized-keys:
      - ${public_key}
EOT
  echo "( cloud-config built: $cc_file )" >&3
  return 0
}


build_private_key(){
  local rc
  mkdir -p keys/${name}
  chmod 700 keys/${name}
  ssh-keygen -t ed25519 -C "hello" -N '' -f ${keyfile}; rc=$?
  echo "( private key built: ${name} )" >&3
  return ${rc}
}

create_security_group(){
  local rc
  aws ec2 --region ${aws_region} create-security-group \
    --group-name ${name} \
    --description "awesomest security group"; rc=$?
  echo "( security group created: ${name} )" >&3
  return ${rc}
}

authorize_security_group(){
  sleep $(( (RANDOM % 10 ) + 5 )) # give AWS some time.
  local rc
  local gress=$1
  local port=$2
  local protocol=$3
  aws ec2 --region ${aws_region} authorize-security-group-${gress} \
    --group-name ${name} \
    --protocol ${protocol} \
    --port ${port} \
    --cidr ${ip}/32; rc=$?
  echo "( authorized $ip/32 for $port (${protocol}) ${gress} )" >&3
  return $rc
}

run_instances(){
  local rc
  local ami=$(_get_ami)
  local isntance_id

  run_instances_json=$(aws --region ${aws_region} ec2 run-instances \
    --image-id ${ami} \
    --count 1 \
    --instance-type t2.micro \
    --user-data file://${cc_file} \
    --security-group-ids ${name} ); rc=$?

  instance_id="$(echo ${run_instances_json} | \
    jq '.["Instances"][0].InstanceId' -r)"

  echo -n "${instance_id}" > ${output_file}.instanceid
  echo "( sent build command for ${ami}, we are ${instance_id} )" >&3

  return ${rc}
}

set_instance_tags(){
  local instance_id="$( cat ${output_file}.instanceid )"
  local tag_name=${name}
  local tag_type="openvpn server"

  aws ec2 --region ${aws_region} create-tags \
    --resources ${instance_id} \
    --tags "Key=Name,Value=${tag_name}" 

  aws ec2 --region ${aws_region} create-tags \
    --resources ${instance_id} \
    --tags "Key=Type,Value=${tag_type}"

  echo "( set tags on the instance: $instance_id )" >&3
  return 0
}

store_public_ip(){
  local rc=1
  local found=0
  local timeout=30
  local instance_id="$( cat ${output_file}.instanceid )"

  set +e
  until (( found != 0 || timeout == 0 )); do
    sleep 1
    public_ip="$(aws --region ${aws_region} \
      ec2 describe-instances --instance-id ${instance_id} | \
      jq '.["Reservations"][0]["Instances"][0]["PublicIpAddress"]' -r)"
    if [[ ! -z ${public_ip} ]]; then
      found=1
      echo -n "${public_ip}" > ${output_file}.publicipaddress
      echo "( we got ip address $public_ip )" >&3
    fi
    ((--timeout))
  done
  set -e
  return 0
}

update_etc_hosts(){
  local rc
  local publicipaddress="$(cat ${output_file}.publicipaddress)"
  local instance_id="$( cat ${output_file}.instanceid )"
  grep "^${publicipaddress}" /etc/hosts > /dev/null 2>&1 ||
    echo \
      "${publicipaddress} ${name} #v,${instance_id},${aws_region},$(date +%s)"|\
      sudo tee -a /etc/hosts; rc=$?

  echo "( added ${publicipaddress} ${name} to /etc/hosts )" >&3
  return $rc
}

sighup_dnsmasq(){
  sudo pkill -HUP dnsmasq && \
  echo "( sighup sent )" >&3
  return 0
}

wait_for_ssh(){
  local rc=
  local up=0
  local publicipaddress="$(cat ${output_file}.publicipaddress)"

  local ssh_opts=" -l squirrel -tt -i ${keyfile} "
  ssh_opts+=" -o ConnectTimeout=5 "
  ssh_opts+=" -o UserKnownHostsFile=/dev/null "
  ssh_opts+=" -o StrictHostKeyChecking=no "

  set +e
  set -x
  until [[ $up -ne 0 ]]; do
    server_time=$(timeout 5 ssh ${ssh_opts} ${publicipaddress} "date" 2>/dev/null)
    if [[ $? -eq 0 ]]; then
      echo "( it's up, server time is $server_time )" >&3
      up=1
    fi
    sleep 5
    ((--timeout))
  done
  set -e
}

send_openvpn_scripts(){
  local rc=
  local sent=0
  local publicipaddress="$(cat ${output_file}.publicipaddress)"

  local ssh_opts=" -i ${keyfile} "
  ssh_opts+=" -o ConnectTimeout=5 "
  ssh_opts+=" -o UserKnownHostsFile=/dev/null "
  ssh_opts+=" -o StrictHostKeyChecking=no "

  set +e
  until [[ $sent -ne 0 ]]; do
    timeout 10 scp ${ssh_opts} \
      ./setup_scripts/setup_openvpn_on_target.sh \
      ./setup_scripts/setup_client_for_target.sh \
      squirrel@${publicipaddress}:/tmp > /dev/null 2>&1; rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "( sent the scripts to the server )" >&3
      sent=1
    else
      sleep 10
    fi
  done
  set -e
}

run_vpnserver_setup(){
  local rc
  local publicipaddress="$(cat ${output_file}.publicipaddress)"

  local ssh_opts=" -l squirrel -tt -i ${keyfile} "
  ssh_opts+=" -o ConnectTimeout=5 "
  ssh_opts+=" -o UserKnownHostsFile=/dev/null "
  ssh_opts+=" -o StrictHostKeyChecking=no "

  ssh ${ssh_opts} ${publicipaddress} \
    "chmod +x /tmp/*.sh && CN=${publicipaddress} /tmp/setup_openvpn_on_target.sh"
  rc=$?
  return $rc
}

#-----------------------------------------------------------------------------
# internal functions

_get_ip(){
  local ua="Mozilla/5.0 (Windows NT 6.1; rv:38.0)Gecko/20100101 Firefox/38.0"
  ip="$(timeout 30 curl -sqA "${ua}" \
    https://icanhazip.com 2>/dev/null)"
  echo -n "${ip}"
}

_random_name(){
  local ua="Mozilla/5.0 (Windows NT 6.1; rv:38.0)Gecko/20100101 Firefox/38.0"
  name="$(timeout 30 curl \
    -H 'Content-Type: application/json' \
    -A "${ua}" \
    https://randomuser.me/api/ 2>/dev/null \
      | jq -r .results[0].user.username)"
  echo -n "${name}"
}

_get_ami(){
  local rc
  local ua="Mozilla/5.0 (Windows NT 6.1; rv:38.0)Gecko/20100101 Firefox/38.0"
  ami=$(timeout 30 curl -sqA ${ua} -H 'X-COREOS-INCREDIBLE' -H 'X-COREOS-AMAZING' \
    https://coreos.com/dist/aws/aws-stable.json 2>/dev/null | \
      jq '.["'${aws_region}'"]["hvm"]' -r )
  echo -n "${ami}"
}

_check_dependencies(){
  dependencies=( jq aws curl timeout sudo tee )
  for dep in ${dependencies[@]}; do
    which $dep > /dev/null 2>&1 || { echo "FATAL: dependency not met $dep"; 
      exit 2; }
  done
}

create_client_config(){
  local rc=
  local publicipaddress="${publicipaddress:-$(cat ${output_file}.publicipaddress)}"
  local target="${target:-$(awk '/^'${publicipaddress}'/{print $2}' /etc/hosts)}"
  local payload="chmod +x /tmp/setup_client_for_target.sh && /tmp/setup_client_for_target.sh"
  local keyfile="keys/${target}/${target}"

  local ssh_opts=" -l squirrel -tt -i ${keyfile} "
  ssh_opts+=" -o ConnectTimeout=5 "
  ssh_opts+=" -o UserKnownHostsFile=/dev/null "
  ssh_opts+=" -o StrictHostKeyChecking=no "
  echo "STDERR: Attempting to create a client config on ${target}" >&2
  ssh ${ssh_opts} ${target} ${payload}; rc=$?
  return $rc
}

usage(){
cat << EOT >&2

        #               m      m                   #     
  mmmm  # mm    mmm   mm#mm  mm#mm   mmm     mmm   # mm  
 #" "#  #"  #  #"  #    #      #    #" "#   #   "  #"  # 
 #   #  #   #  #""""    #      #    #   #    """m  #   # 
 "#m"#  #   #  "#mm"    "mm    "mm  "#m#" # "mmm"  #   # 
  m  #                                                         
   ""

   a VPN builder.
EOT
  echo "                                                               " >&2   
  echo "Usage: $0 [ -b, --build | targetvpn666 >foo.ovpn ]             " >&2
  echo "                                                               " >&2
  echo "  -b, --build: builds an openvpn instance in a random AWS site " >&2
  echo "  targetvpn666: short name of vpn instance, found in /etc/hosts" >&2
  echo "                                                               " >&2   
  exit 1
}

#-----------------------------------------------------------------------------
# cosmetic functions to help the output look nice
echo_get_ip(){
  echo "( we shall authorize ${ip} )" 1>&3
}
echo_random_name(){
  echo "( we got name: ${name} )" 1>&3
}
echo_region(){
  echo "( we got region: ${aws_region} (${region}) )" >&3
}

if [[ "${1}" == "-h"     || \
      "${1}" == "--help" || \
      "${1}" == "-?"     || \
      "$#"   -gt 1       || \
      "$#"   -le 0       ]]; then
  usage
elif [[ "${1}" == "-b" || ${1} == "--build" ]]; then
  _check_dependencies
  build_vm 
elif grep "${1}" /etc/hosts >/dev/null 2>&1 ; then
  export target="${1}"
  export publicipaddress="$(awk '$2 ~ /'${1}'/{print $1}' /etc/hosts)"
  create_client_config
else
  echo
  echo
  echo "FATAL: Could not find ${1} in /etc/hosts"
  echo
  echo
  usage
fi
