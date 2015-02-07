#!/bin/bash
#
# humbly attempts to set up a cluster of Riak nodes running in docker containers on top of OpenVSwitch
#
# Author: Matteo Cerutti <matteo.cerutti@hotmail.co.uk>"
#

function showhelp() {
  test -n "$1" && { echo "Error: $1"; echo; }
  echo "Usage: `basename $0` <opts>"
  echo
  echo "Options:"
  echo " --docker-host <host>         Docker host (default: $docker_host)"
  echo " --riak-certs-dir <path>      Riak SSL certs directory (default: $riak_certs_dir)"
  echo " --riak-https-port <N>        Riak HTTPS port (default: $riak_https_port)"
  echo " --riak-cluster-size <N>      Riak cluster size (default: $riak_cluster_size)"
  echo " --ovs-bridge <bridge_name>   OVS bridge"
  exit 1
}

riak_cluster_size=1
riak_https_port=8097
riak_certs_dir="$(basename $0)/certs"
docker_host="unix:///var/run/docker.sock"
ovs_bridge="ovsbr0"

while :
do
  case $1 in
    -h | --help)
      showhelp
      ;;

    --docker-host)
      docker_host=$2
      shift 2
      ;;

    --riak-certs-dir)
      riak_certs_dir=$2
      shift 2
      ;;

    --riak-cluster-size)
      riak_cluster_size=$2
      shift 2
      ;;

    --riak-https-port)
      riak_https_port=$2
      shift 2
      ;;

    --ovs-bridge)
      ovs_bridge=$2
      shift 2
      ;;

    --)
      shift
      break
      ;;

    -*)
      showhelp "Unknow option: $1"
      ;;

    *)
      break
  esac
done

ovs-vsctl list-br | egrep "$ovs_bridge" &>/dev/null || showhelp "Failed to find OVS Bridge $ovs_bridge"

if [[ "$docker_host" =~ ^unix:// ]]; then
  real_docker_host="localhost"
else
  real_docker_host=$(echo "$docker_host" | cut -d '/' -f 3 | cut -d ':' -f 1)
fi

if [ -d "$riak_certs_dir" ]; then
  riak_certs_dir=$(readlink -f $riak_certs_dir)
else
  showhelp "Riak certs directory not found"
fi

# quite handy
export DOCKER_HOST=$docker_host

echo
echo "Setting up Riak nodes .."
echo

instance=1
riak_master_node_container_id=
riak_master_node=
riak_nodes=
while [ $instance -le $riak_cluster_size ]; do
  printf " * %-20s" "Starting riak${instance} ... "
  if [ $instance -eq 1 ]; then
    docker run --net=none \
               -v $riak_certs_dir:/etc/riak/ssl \
               -e "RIAK_INSTANCE=1" \
               -e "RIAK_CLUSTER_SIZE=$riak_cluster_size" \
               --name "riak1" \
               --hostname "riak1" \
               --privileged \
               -d "m4ce/docker-riak" >/dev/null
    docker_exitstatus=$?
  else
    docker run --net=none \
               -v $riak_certs_dir:/etc/riak/ssl \
               -e "RIAK_INSTANCE=$instance" \
               -e "RIAK_CLUSTER_SIZE=$riak_cluster_size" \
               -e "RIAK_MASTER_NODE=$riak_master_node" \
               --name "riak${instance}" \
               --hostname "riak${instance}" \
               --privileged \
               -d "m4ce/docker-riak" >/dev/null
    docker_exitstatus=$?

               #--link "riak1:riakcs" \
  fi

  echo -n "["
  if [ $docker_exitstatus -eq 0 ]; then
    docker_container_id=$(docker ps | egrep "riak${instance}[^/]" | cut -d ' ' -f 1)
    #docker_container_port=$(docker port "${docker_container_id}" $riak_https_port | cut -d ':' -f 2)
    echo -n " container_id:$docker_container_id "

    # map eth1 on to our ovs bridge (I could probably use ovs-docker, didn't look into it) 
    ns_pid=$(docker inspect -f '{{.State.Pid}}' $docker_container_id)
    mkdir -p /var/run/netns
    test -h /var/run/netns/$ns_pid || ln -s /proc/$ns_pid/ns/net /var/run/netns/$ns_pid

    # vethe -> external interface (host)
    # vethi -> internal interface (container)

    ovs-vsctl del-port $ovs_bridge vethe${ns_pid} &>/dev/null
    ip link del vethe${ns_pid} &>/dev/null
    ip link add vethi${ns_pid} type veth peer name vethe${ns_pid}
    ovs-vsctl add-port $ovs_bridge vethe${ns_pid}
    ip link set vethe${ns_pid} up

    ip link set vethi${ns_pid} netns $ns_pid
    ip netns exec $ns_pid ip link set dev vethi${ns_pid} name eth0
    ip netns exec $ns_pid ip link set eth0 up

    docker exec $docker_container_id dhclient eth0
    # find ip
    ipaddr=$(docker exec $docker_container_id facter ipaddress)
    if [ $instance -eq 1 ]; then
      riak_master_node=$ipaddr
      riak_master_node_container_id=$docker_container_id
    fi

    test -z "$riak_nodes" && riak_nodes=$ipaddr || riak_nodes="$riak_nodes $ipaddr"
    
    echo -n " container_ipaddr:$ipaddr "

    while true; do
      curl -1 -s -k "https://${ipaddr}:${riak_https_port}/ping" | grep -i 'ok' >/dev/null && break || sleep 1
    done
    echo -n " status:OK "
  else
    echo -n " status:FAIL "
  fi
  echo "]"

  instance=$((instance+1))
done

echo
echo "Waiting a little bit for the cluster to become active .."
sleep 20

echo "Cluster status .."
echo

docker exec $riak_master_node_container_id riak-admin member-status

echo
echo "Testing API .."
echo

# test API
echo " * PUT request to key 'english' in the bucket 'welcome' to Riak node riak@riak_master_node"
curl -1 -k -XPUT https://$riak_master_node:8097/buckets/welcome/keys/english -H 'Content-Type: text/plain' -d 'Hello world'
for riak_node in $riak_nodes; do
  echo " * GET request to key 'english' in the bucket 'welcome' from Riak node riak@$riak_node"
  curl -1 -k https://$riak_node:8097/buckets/welcome/keys/english
  echo
done
