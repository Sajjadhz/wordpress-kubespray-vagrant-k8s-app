#!/bin/bash

# Enable ssh password authentication
sudo su -
echo "==> Enable ssh password authentication"
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Enable root ssh login
echo "==> Enable ssh root login"
sed -i 's/.*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

systemctl reload sshd

# Set Root password
echo "==> Set root password"
# echo root:vagrant | chpasswd
echo -e "vagrant\nvagrant" | passwd root
echo "export TERM=xterm" >> /etc/bash.bashrc



