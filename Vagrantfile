# -*- mode: ruby -*-
# vi: set ft=ruby :

ENV['VAGRANT_NO_PARALLEL'] = 'yes'

Vagrant.configure(2) do |config|

  config.vm.provision "shell", path: "bootstrap.sh"

  NodeCount = 1

  (1..NodeCount).each do |i|
    config.vm.define "k8s#{i}" do |node|
      node.vm.box = "generic/ubuntu2204"
      node.vm.hostname = "k8s#{i}.example.com"
      node.vm.network "private_network", ip: "172.16.16.13#{i}"
      node.vm.provider "virtualbox" do |v|
        v.name = "k8s#{i}"
        v.memory = 10240
        v.cpus = 4
      end
    end
  end

end
