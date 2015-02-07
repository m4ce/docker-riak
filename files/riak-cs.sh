#!/bin/sh
#
# start up script for Riak
#
# Author: Matteo Cerutti <matteo.cerutti@hotmail.co.uk>
#

function setup_cluster() {
  local timeout=30
  local count=0

  # waiting for the service to become ready
  while [ $count -lt $timeout ]; do
    curl -1 -s -k "https://localhost:8097/ping" | grep -i 'ok' >/dev/null && break || sleep 1
    count=$((count+1))
  done

  # post request
  #if [ -n "$RIAKCS_PORT_8097_TCP_ADDR" ]; then
  #  riak-admin cluster join riak@$RIAKCS_PORT_8097_TCP_ADDR
  #fi
  if [ -n "$RIAK_MASTER_NODE" ]; then
    riak-admin cluster join riak@$RIAK_MASTER_NODE
  fi

  # check if we are the last node in the cluster
  if [ $RIAK_INSTANCE -eq $RIAK_CLUSTER_SIZE ]; then
    if [ $(riak-admin member-status | egrep -c '^(joining|valid)') -eq $RIAK_CLUSTER_SIZE ]; then
      riak-admin cluster plan && riak-admin cluster commit
    fi
  fi
}

pid_file=/var/run/riak.pid

# wait for the interface to come up
ipaddr=
while [ -z "$ipaddr" ]; do
  ipaddr=$(facter ipaddress_eth0)
  sleep 1
done

case $1 in
  "start")
    # set node name
    sed -i "s/^nodename.*/nodename = riak@${ipaddr}/" /etc/riak/riak.conf

    setup_cluster &

    # get going
    runuser -l riak -c "$(ls -d /usr/lib64/riak/erts*)/bin/run_erl /tmp/riak /var/log/riak '/usr/sbin/riak console'"
    ;;

  "stop")
    echo "not yet supported :>"
    ;;

  "status")
    pgrep -f /usr/sbin/riak &>/dev/null && echo "running" || echo "not running"
    ;;

  *)
    echo "Usage: `basename $0` <start|stop|status>"
esac

exit 0
