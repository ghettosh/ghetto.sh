#!/usr/bin/env bash

# a temporary script until I can figure out how I want to cache the info

set -e

_check_dependencies(){
  dependencies=( jq aws )
  for dep in ${dependencies[@]}; do
    which $dep > /dev/null 2>&1 || { echo "FATAL: dependency not met $dep"; 
      exit 2; }
  done
}

AMI_ID=(  sa-east-1 us-east-1 us-west-2 us-west-1 \
          eu-west-1  eu-central-1 ap-northeast-1 \
          ap-southeast-2 ap-southeast-1 )

( 
  echo
  for region in ${AMI_ID[@]}; do
     aws --region ${region} ec2 describe-instances \
      --query '
        Reservations[].
        Instances[].
        [Tags[?Key==`Name`].Value 
        | [0], 
        InstanceId, 
        Placement.AvailabilityZone, 
        State.Name, 
        PublicIpAddress]
      ' --output text &
  done
  wait
  echo
) | column -t
