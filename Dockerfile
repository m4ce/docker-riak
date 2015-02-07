#
# My fancy riak docker container
#
# Author: Matteo Cerutti <matteo.cerutti@hotmail.co.uk>
#

FROM centos
MAINTAINER Matteo Cerutti <matteo.cerutti@hotmail.co.uk>

RUN mkdir -p /etc/puppet/modules

# Adding epel repository, needed to install Puppet etc.
ADD files/epel.repo /etc/yum.repos.d/epel.repo
ADD files/hiera.yaml /etc/puppet/hiera.yaml
ADD files/Puppetfile /etc/puppet/Puppetfile

# Get going
RUN yum install -y wget git puppet hostname initscripts openssl dhclient
RUN gem install librarian-puppet
RUN cd /etc/puppet && librarian-puppet install

# For this test, I will use a master-less puppet setup
RUN puppet apply --test --ordering manifest --hiera_config /etc/puppet/hiera.yaml --modulepath=/etc/puppet/modules -e "class {'riak': enable => false, ensure => 'stopped'}"; [[ $? -eq 0 || $? -eq 2 ]] && exit 0 || exit 1

# Riak volumes
VOLUME /var/lib/riak
VOLUME /var/log/riak

# Expose https
EXPOSE 8097

# Some good clean-up
RUN yum clean all && rm -rf /var/cache/yum/* /tmp/* /var/tmp/*

ADD files/riak-cs.sh /usr/local/bin/riak-cs

ENTRYPOINT ["/usr/local/bin/riak-cs"]
CMD ["start"]
