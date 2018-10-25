Content-Type: multipart/mixed; boundary="//"
MIME-Version: 1.0

--//
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="cloud-config.txt"

#cloud-config
cloud_final_modules:
  - [scripts-user, always]

--//
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="userdata.txt"

#!/bin/bash

print() {
  message=$1
  if [ "${message}" != "" ]; then
    message="$(date +'%F %T')  ${message}"
  fi
  echo "${message}" >> /var/log/user-data-output.log
}
print_error() {
  print "ERROR: $1"
}

is_service_loaded() {
  if which systemctl > /dev/null; then
    if systemctl status $1 | grep -qi " Loaded: loaded "; then
      echo "1"
    else
      echo "0"
    fi
  else
    if status $1 | grep -qi "^$1"; then
      echo "1"
    elif service $1 status | grep -qiv " unrecognized service$"; then
      echo "1"
    else
      echo "0"
    fi
  fi
}

is_service_active() {
  if which systemctl > /dev/null; then
    if systemctl status $1 | grep -qi " Active: active (running) "; then
      echo "1"
    else
      echo "0"
    fi
  else
    if status $1 | grep -qi "^$1 start/running,"; then
      echo "1"
    elif service $1 status | grep -qi " is running$"; then
      echo "1"
    else
      echo "0"
    fi
  fi
}

disable_service() {
  if which systemctl > /dev/null; then
    systemctl stop $1
    systemctl disable $1
  else
    if status $1 | grep -qi "^$1"; then
      stop $1
    else
      service $1 stop
    fi
    if which chkconfig > /dev/null; then
      chkconfig $1 off
    else
      update-rc.d $1 disable
    fi
    mv /etc/init/$1.conf /etc/init/$1.conf.disabled
  fi
}

start_service() {
  if which systemctl > /dev/null; then
    systemctl start $1
  else
    if status $1 | grep -qi "^$1"; then
      start $1
    else
      service $1 start
    fi
  fi
}

is_package_installed() {
  if which apt > /dev/null; then
    if apt list $1 --installed | grep -qi "^$1\/"; then echo "1"; else echo "0"; fi
  else
    if yum list installed $1 | grep -qi "^$1\."; then echo "1"; else echo "0"; fi
  fi
}

print "checking for required common commands ..."
let python_command
if which python > /dev/null; then
  python_command=python
elif which python3 > /dev/null; then
  python_command=python3
else
  print_error "python not found"
  exit 1
fi
for command in curl grep; do
  if ! which ${command} > /dev/null; then
    print_error "${command} not found"
    exit 1
  fi
done

print "identifying distro ..."
let distro
if ${python_command} -mplatform | grep -qi "\.amzn1\."; then
  print "distro identified as Amazon Linux 1"
  distro=alinux1
elif ${python_command} -mplatform | grep -qi "\.amzn2\."; then
  print "distro identified as Amazon Linux 2"
  distro=alinux2
elif ${python_command} -mplatform | grep -qi "\-Ubuntu\-14\."; then
  print "distro identified as Ubuntu 14"
  distro=ubuntu14
elif ${python_command} -mplatform | grep -qi "\-Ubuntu\-1[68]\."; then
  print "distro identified as Ubuntu 16+"
  distro=ubuntu16p
elif ${python_command} -mplatform | grep -qi "\-CentOS\-7\."; then
  print "distro identified as CentOS 7"
  distro=centos7
else
  print_error "distro not recognized"
  print "python -mplatform: $(${python_command} -mplatform)"
  exit 1
fi

if [ "$(is_package_installed puppet-agent)" = "1" ]; then
  print "removing puppet ..."
  if which apt-get > /dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get -yq remove puppet-agent
  else
    yum -y remove puppet-agent
  fi
  if "$(is_package_installed puppet-agent)" = "1" ]; then
    print_error "puppet removal failed"
    exit 1
  fi
fi

amazon_ssm_agent_service="snap.amazon-ssm-agent.amazon-ssm-agent.service"
if [ "$(is_service_loaded ${amazon_ssm_agent_service})" = "1" ]; then
  print "systems manager agent already installed"
else
  amazon_ssm_agent_service="amazon-ssm-agent"
  if [ "$(is_service_loaded ${amazon_ssm_agent_service})" = "1" ]; then
    print "systems manager agent already installed"
  else
    print "installing systems manager agent ..."
    mkdir /tmp/ssm
    cd /tmp/ssm
    if which apt-get > /dev/null; then
      wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
      dpkg -i amazon-ssm-agent.deb
    else
      yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
    fi
  fi
fi

if [ "$(is_service_active ${amazon_ssm_agent_service})" = "0" ]; then
  print "starting systems manager agent ..."
  start_service ${amazon_ssm_agent_service}
  sleep 5
  if [ "$(is_service_active ${amazon_ssm_agent_service})" = "1" ]; then
    print "systems manager agent is running"
  else
    print_error "systems manager agent cannot be started"
    exit 1
  fi
else
  print "systems manager agent is running"
fi

if which salt-call > /dev/null; then
  print "salt minion already installed"
else
  print "installing salt minion ..."
  if [ "${distro}" = "alinux2" ]; then
    # AWS-recommended method does not work, so use work-around
    # https://github.com/saltstack/salt-bootstrap/issues/1194
    # install gcc
    yum install -y gcc
    # install pip
    curl -O https://bootstrap.pypa.io/get-pip.py
    ${python_command} get-pip.py
    # install salt
    yes | pip install tornado==4.*
    yes | pip install salt
  else
    # AWS-recommended method
    # https://aws.amazon.com/blogs/mt/running-salt-states-using-amazon-ec2-systems-manager/
    curl -L https://bootstrap.saltstack.com -o bootstrap_salt.sh
    sh bootstrap_salt.sh
  fi
  if ! which salt-call > /dev/null; then
    print_error "salt minion installation failed"
    exit 1
  fi
fi

print "configuring salt minion as masterless ..."
sed -i 's/^#file_client: remote$/file_client: local/' /etc/salt/minion
disable_service salt-minion

print "all succeeded"
print ""

--//

