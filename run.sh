#!/bin/bash
read -p "Enter your localhost sudo password: " sudo_pass
echo "$sudo_pass" | sudo -S `su -`
declare -a IPS=()
PS3='Please enter your choice: '
options=("Option 1: Create Vagrant VMs" "Option 2: Already have VMs" "Quit")
select opt in "${options[@]}"
do
    case $opt in
        "Option 1: Create Vagrant VMs")
            read -p "Please enter number of nodes:" NodeCount   
            echo "==> Installing Vagrant and VirtualBox"
            if [[ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]]; then
                wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
            fi
            sudo apt update && apt upgrade -y
            echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

            sudo apt install -qq -y virtualbox vagrant #>/dev/null 2>&1

            existing_vm=false                     
            sed -i "s/NodeCount = .*/NodeCount = $NodeCount/" ./Vagrantfile
            echo "==> Creating Vagrant VM(s)"
            vagrant up
            vms=$(vagrant status | grep "running " | awk '{print $1}')            
            for vm in $vms; do vm_ip="$(vagrant ssh $vm -c "hostname -I | cut -d' ' -f2")"; vm_ip=$(echo "$vm_ip" | tr -d '\r'); IPS+=($vm_ip); done               
            vm_user=vagrant    
            vm_pass=vagrant 
            vm_root_pass=vagrant
            break
            ;;
        "Option 2: Already have VMs")            
            existing_vm=true
            read -p "Enter your server's username: " vm_user
            read -p "Enter your server's password: " vm_pass
            read -p "Enter your server's root password (to create or login): " vm_root_pass
            read -p "Enter your server's ip with root user: " vm_ip            
            IPS+=($vm_ip)            
            break
            ;;        
        "Quit")
            break
            exit 0
            ;;
        *) echo "invalid option $REPLY";;
    esac
done

# TODO create venv, git clone kubespray, git clone customized values and install requirements and charts
if [[ ! -f ~/.ssh/id_rsa ]]; then
    ssh-keygen -t rsa -q -f "~/.ssh/id_rsa" -N "" <<< $'\ny'
fi
for vm_ip in ${IPS[@]}; do    
    if [ "$existing_vm" = true ] ; then
        cp bootstrap.sh bootstrap_tmp.sh
        sed -i "s/nvagrant/n$vm_root_pass/" ./bootstrap_tmp.sh
        sed -i "s/vagrant/$vm_root_pass/" ./bootstrap_tmp.sh        
        sshpass -vvv -p $vm_pass ssh -o StrictHostKeyChecking=no $vm_user@$vm_ip 'bash -s' < bootstrap_tmp.sh
        cat bootstrap_tmp.sh
        rm bootstrap_tmp.sh
    fi      
    # ssh-keygen -f "~/.ssh/known_hosts" -R $vm_ip
    sshpass -vvv -p $vm_pass ssh-copy-id -f -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa.pub $vm_user@$vm_ip

    sshpass -vvv -p $vm_root_pass ssh-copy-id -f -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa.pub root@$vm_ip
done


echo "==> Install essential packages"
sudo apt update && apt upgrade -y
sudo apt install software-properties-common -y
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt install -qq -y ssh git python3.8 python3-pip python3.8-venv apt-transport-https ca-certificates curl #>/dev/null 2>&1
if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
sudo apt-get update && apt-get install -y kubectl

echo "==> Create virtual environment"
if [ -d venv ]; then
    echo "venv already exists"
else
    python3 -m venv ./venv
fi

echo "==> Editing kubespray addons.yml based on number of nodes"
if [[ ${#IPS[@]} -gt 1 ]]; then
    echo "You have multiple nodes, copying addons_multinode.yml addons.yml ..."
    cp addons_multinode.yml addons.yml
elif [[ ${#IPS[@]} -eq 1 ]]; then
    echo "You have single node, copying addons_singlenode.yml addons.yml ..."
    cp addons_singlenode.yml addons.yml
else echo "You have not enough nodes"
fi

echo "==> Copying files from current DIR to venv"
cp -r bootstrap.sh phpmyadmin-values.yaml wordpress-values.yaml run.sh Vagrantfile .vagrant addons.yml ./venv
cd ./venv

source ./bin/activate
echo "==> Clone kubespray git repo"
if [ -d kubespray ]; then
    echo "Git repo files already exist."
else
    echo "Git repo files not exist, so cloning ..."
    git clone https://github.com/kubernetes-sigs/kubespray.git
fi
# install metalLB, Cert Manager and nginx  ingress controller by kubespray
lower_range=$(echo ${IPS[0]} | sed -e "s/`echo ${IPS[0]} | cut -d'.' -f4`/240/") 
upper_range=$(echo ${IPS[0]} | sed -e "s/`echo ${IPS[0]} | cut -d'.' -f4`/250/") 
sed -i "s/LowerRange-UpperRange/$lower_range-$upper_range/" ./addons.yml
sed -i "s/kube_proxy_strict_arp: .*/kube_proxy_strict_arp: true/" ./kubespray/inventory/sample/group_vars/k8s_cluster/k8s-cluster.yml
sed -i "s/kube_network_plugin: .*/kube_network_plugin: flannel/" ./kubespray/inventory/sample/group_vars/k8s_cluster/k8s-cluster.yml
cp addons.yml ./kubespray/inventory/sample/group_vars/k8s_cluster/addons.yml

cd kubespray
sed -i "s/ansible==7.6.0/ansible==6.7.0/" ./requirements.txt
sed -i "s/2.14.0/2.13.0/" ./meta/runtime.yml
sed -i "s/2.14.0/2.13.0/" ./playbooks/ansible_version.yml
pip3 install -r ./requirements.txt

cp -rfp inventory/sample inventory/mycluster
CONFIG_FILE=inventory/mycluster/hosts.yaml python3 contrib/inventory_builder/inventory.py ${IPS[@]}
echo "==> Creating cluster by kubespray"
ansible-playbook -i ./inventory/mycluster/hosts.yaml  -u root --become --become-user=root cluster.yml

cd ..

echo "==> Copying k8s admin.conf from master node to localhost"
mkdir -p ~/.kube
scp root@${IPS[0]}:/etc/kubernetes/admin.conf ~/.kube/config_wordpress_k8s
current_context=$(kubectl config current-context --kubeconfig ~/.kube/config_wordpress_k8s)
sed -i "s/127.0.0.1/${IPS[0]}/" ~/.kube/config_wordpress_k8s
cat ~/.kube/config_wordpress_k8s >> ~/.kube/config
kubectl config set-context $current_context
rm -f ~/.kube/config_wordpress_k8s

# install nginx  ingress controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install nginx-ingress-ctl ingress-nginx/ingress-nginx --set rbac.create=true --set controller.publishService.enabled=true


# install longhorn
echo "==> installing longhorn"
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.5.1/deploy/longhorn.yaml

echo "==> Creating certificate secret"
openssl genrsa -out server.key 2048
openssl req -key server.key -new -out server.csr -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=example"
openssl x509 -signkey server.key -in server.csr -req -days 365 -out server.crt 
kubectl create secret tls wp-cert --key server.key --cert server.crt

# install wordpress and phpmyadmin
echo "==> Installing wordpress and phpmyadmin by helm"
helm repo add bitnami https://charts.bitnami.com/bitnami
if [[ ! -d wordpress ]]; then
    helm pull bitnami/wordpress --version 17.1.3
    tar -zxvf wordpress*.tgz    
fi
if [[ ! -d phpmyadmin ]]; then
    helm pull bitnami/phpmyadmin --version 12.1.0
    tar -zxvf phpmyadmin*.tgz    
fi
helm upgrade --install -f wordpress-values.yaml wordpress ./wordpress
helm upgrade --install -f phpmyadmin-values.yaml phpmyadmin ./phpmyadmin

echo "$(kubectl get svc -A | grep LoadBalancer | awk '{print $5}') sajjad.maxtld.dev" | sudo tee -a /etc/hosts