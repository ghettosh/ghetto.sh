# ghetto.sh VPN Builder

tl;dr: I really wanted to use
[themattrix/bash-concurrent.](https://github.com/themattrix/bash-concurrent)


This is a simple openvpn server provisioner - meant to provide clients with a
regularly rotating internet entrypoint using AWS t2 micros.


This is primarily for personal use, but it's not totally unsociable. I made it
because other solutions required too much money or were too unwieldy. I wanted
some flexibility and a low degree of complexity/dependencies.


The intention is to use this script to generate new openvpn servers every so
often. After connecting to these instances, you should only use Tor from your
machine, using a transparent proxy. The goal is to conceal your activity from
your home ISP. If you need a picture:


    [you:vpn][tor] -> internet


## Required Reading

These projects are used:

  * [themattrix/bash-concurrent](https://github.com/themattrix/bash-concurrent)
  * [kylemanna/docker-openvpn](https://github.com/kylemanna/docker-openvpn)

I am very thankful for these people and their hard work. 

If you are looking for user-friendliness/convenience/configuration management:

  * [jlund/streisand](https://github.com/jlund/streisand)
  * TODO: others?

## Requirements


`build_vpn.sh` will only run from a Linux host. Additionally, you will need:


  * jq
  * git
  * bash
  * awscli (can be virtualenv!)
  * openssh


## Bastion Host


The ideal scenario is that you have an AWS account tied to an identity other
than your own. The bastion host represents the station you use to maintain a
particular identity. It can be the machine you're attempting to anonymize from.
It can also be a router instance on a Qubes machine for example.  In my
examples below it is the default gateway in the LAN that houses the machines
used to maintain this identity.


## Virtualenv


On this secure host you should have a virtualenv. Set it up however you want,
but here is the minimum:


    virtualenv ~/aws
    pip install awscli
    mkdir ~/.aws


Keep in mind, you will probably need development libraries to build some of the
crypto extensions.


You must also have a file in your home directory containing your AWS access key
id and secret access key


    $ cat ~/.aws/credentials
    [default]
    aws_access_key_id =  abcd123
    aws_secret_access_key = 456qewrty


## What Does it Look Like?


assuming you have a virtualenv in `~aws` with `awscli` installed, and a
bastion host at `bastion`, a client would somehow execute the following to roll
a new VPN. This is flexible enough to be worked into embedded devices and even
crappy GUI functions like `menu -> new vpn`.


    hidden $ ssh bastion "source ~/aws/bin/activate && ~/ghetto.sh/build_vpn.sh --build" # returns lazybear627
    hidden $ ssh bastion "source ~/aws/bin/activate && ~/ghetto.sh/build_vpn.sh lazybear666" | sudo tee /etc/openvpn/aws.conf
    hidden $ sudo systemctl restart openvpn@aws


At this point you are def-1 routed through a new openvpn server in AWS, that
only you can communicate with.


## An Example Workflow


For example: we decide we want to build a new VPN instance, so we ssh to our
secure bastion host and direct it to build us a new instance


    04:20:00 ~ > ssh -t 172.16.2.1 "source ~/aws/bin/activate && ~/ghetto.sh/build_vpn.sh --build" 
       OK   choosing a region ( we got region: eu-central-1 (germany) )
       OK   making a random name ( we got name: crazybird420 )
       OK   detecting my ip address ( we shall authorize 123.123.123.123 )
       OK   building private key ( private key built: crazybird420 )
       OK   building cloud-config ( cloud-config built: cloud-init-scripts/crazybird420.yml )
       OK   creating security group ( security group created: crazybird420 )
       OK   authorize tcp 22 ( authorized 123.123.123.123/32 for 22 (tcp) ingress )
       OK   authorize udp 1194 ( authorized 123.123.123.123/32 for 1194 (udp) ingress )
       OK   sending build command ( sent build command for ami-f0e8f09c, we are i-d000000000000000d )
       OK   setting instance tags ( set tags on the instance: i-d000000000000000d )
       OK   getting public IP ( we got ip address 456.456.456.456 )
       OK   updating /etc/hosts ( added 456.456.456.456 crazybird420 to /etc/hosts )
       OK   sending SIGHUP to dnsmasq ( sighup sent )
       OK   wait for ssh ( it's up, server time is Wed Apr 20 04:20:02 UTC 2016
       OK   send openvpn scripts ( sent the scripts to the server )
       OK   setup openvpn server


We have created a new vpn instance, let's look at our current routing table. we
can see that we're already using an openvpn def-1 route to `789.789.789.789`:


    04:20:04 ~ > ip rou sh
    0.0.0.0/1 via 192.168.255.5 dev tun0 
    default via 172.16.2.1 dev br0  src 172.16.2.25  metric 204 
    789.789.789.789 via 172.16.2.1 dev br0 
    128.0.0.0/1 via 192.168.255.5 dev tun0 
    172.16.2.0/24 dev br0  proto kernel  scope link  src 172.16.2.25  metric 204 
    192.168.255.1 via 192.168.255.5 dev tun0 
    192.168.255.5 dev tun0  proto kernel  scope link  src 192.168.255.6 


So we login to our bastion host and pass the shortname of the vpn instance we
just received to the `build.sh` script.


    04:20:06 ~ > ssh 172.16.2.1 "source ~/aws/bin/activate && ~/ghetto.sh/build_vpn.sh crazybird420" | \
    > sudo tee /etc/openvpn/aws.conf && sudo systemctl restart openvpn@aws
    STDERR: Attempting to create a client config on crazybird420
    [ truncated ]


This echo'd out an openvpn configuration, and overwrote whatever was in
/etc/openvpn/aws.conf - if that was successful. it restarted openvpn. We now
have a new default gateway:


    04:20:08 ~ > ip rou sh
    0.0.0.0/1 via 192.168.255.5 dev tun0 
    default via 172.16.2.1 dev br0  src 172.16.2.25  metric 204 
    456.456.456.456 via 172.16.2.1 dev br0 
    128.0.0.0/1 via 192.168.255.5 dev tun0 
    172.16.2.0/24 dev br0  proto kernel  scope link  src 172.16.2.25  metric 204 
    192.168.255.1 via 192.168.255.5 dev tun0 
    192.168.255.5 dev tun0  proto kernel  scope link  src 192.168.255.6 


## TODO


  * write a `cleanup()` function and try to handle wherever applicable
  * create a way to terminate instances easily, also cleaning /etc/hosts
  * investigate how we could cause the traffic to enter AWS and exit through
    another instance. The two hosts could build in parallel :-)
