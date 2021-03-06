#!/bin/bash

echo $(date) " - Starting Script"

set -e

SUDOUSER=$1
PASSWORD="$2"
PRIVATEKEY=$3
MASTER=$4
MASTERPUBLICIPHOSTNAME=$5
MASTERPUBLICIPADDRESS=$6
INFRA=$7
NODE=$8
NODECOUNT=$9
INFRACOUNT=${10}
MASTERCOUNT=${11}
ROUTING=${12}
REGISTRYSA=${13}
ACCOUNTKEY="${14}"
TENANTID=${15}
SUBSCRIPTIONID=${16}
AADCLIENTID=${17}
AADCLIENTSECRET="${18}"
RESOURCEGROUP=${19}
LOCATION=${20}
STORAGEACCOUNT1=${21}
SAKEY1=${22}

MASTERLOOP=$((MASTERCOUNT - 1))
INFRALOOP=$((INFRACOUNT - 1))
NODELOOP=$((NODECOUNT - 1))

# Generate private keys for use by Ansible
echo $(date) " - Generating Private keys for use by Ansible for OpenShift Installation"

runuser -l $SUDOUSER -c "echo \"$PRIVATEKEY\" > ~/.ssh/id_rsa"
runuser -l $SUDOUSER -c "chmod 600 ~/.ssh/id_rsa*"

echo $(date) "- Configuring SSH ControlPath to use shorter path name"

sed -i -e "s/^# control_path = %(directory)s\/%%h-%%r/control_path = %(directory)s\/%%h-%%r/" /etc/ansible/ansible.cfg
sed -i -e "s/^#host_key_checking = False/host_key_checking = False/" /etc/ansible/ansible.cfg
sed -i -e "s/^#pty=False/pty=False/" /etc/ansible/ansible.cfg

# Create playbook to update ansible.cfg file

cat > updateansiblecfg.yaml <<EOF
#!/usr/bin/ansible-playbook

- hosts: localhost
  gather_facts: no
  tasks:
  - lineinfile:
      dest: /etc/ansible/ansible.cfg
      regexp: '^library '
      insertafter: '#library        = /usr/share/my_modules/'
      line: 'library = /home/${SUDOUSER}/openshift-ansible/library/'
EOF

# Run Ansible Playbook to update ansible.cfg file

echo $(date) " - Updating ansible.cfg file"

ansible-playbook ./updateansiblecfg.yaml

# Create Ansible Playbooks for Post Installation tasks
echo $(date) " - Create Ansible Playbooks for Post Installation tasks"

# Run on all masters - Create Inital OpenShift User on all Masters

cat > /home/${SUDOUSER}/addocpuser.yml <<EOF
---
- hosts: masters
  gather_facts: no
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Create OpenShift Users"
  tasks:
  - name: create directory
    file: path=/etc/origin/master state=directory
  - name: add initial OpenShift user
    shell: htpasswd -cb /etc/origin/master/htpasswd ${SUDOUSER} "${PASSWORD}"
EOF

# Run on MASTER-0 - Make initial OpenShift User a Cluster Admin

cat > /home/${SUDOUSER}/assignclusteradminrights.yml <<EOF
---
- hosts: master0
  gather_facts: no
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Make user cluster admin"
  tasks:
  - name: make OpenShift user cluster admin
    shell: oadm policy add-cluster-role-to-user cluster-admin $SUDOUSER --config=/etc/origin/master/admin.kubeconfig
EOF

# Run on MASTER-0 - configure registry to use Azure Storage

cat > /home/${SUDOUSER}/dockerregistry.yml <<EOF
---
- hosts: master0
  gather_facts: no
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Set registry to use Azure Storage"
  tasks:
  - name: Configure docker-registry to use Azure Storage
    shell: oc env dc docker-registry -e REGISTRY_STORAGE=azure -e REGISTRY_STORAGE_AZURE_ACCOUNTNAME=$REGISTRYSA -e REGISTRY_STORAGE_AZURE_ACCOUNTKEY=$ACCOUNTKEY -e REGISTRY_STORAGE_AZURE_CONTAINER=registry
EOF

# Run on MASTER-0 - configure Storage Class
cat > /home/${SUDOUSER}/configurestorageclass.yml <<EOF
---
- hosts: master0
  gather_facts: no
  remote_user: ${SUDOUSER}
  become: yes
  become_method: sudo
  vars:
    description: "Create Storage Class"
  tasks:
  - name: Create Storage Class with StorageAccountPV1
    shell: oc create -f /home/${SUDOUSER}/storageClass.yml
EOF

# Create vars.yml file for use by setup-azure-config.yml playbook

cat > /home/${SUDOUSER}/vars.yml <<EOF
g_tenantId: $TENANTID
g_subscriptionId: $SUBSCRIPTIONID
g_aadClientId: $AADCLIENTID
g_aadClientSecret: $AADCLIENTSECRET
g_resourceGroup: $RESOURCEGROUP
g_location: $LOCATION
g_storageaccount: $STORAGEACCOUNT1
EOF

# Create Azure Cloud Provider configuration Playbook for Master Config

cat > /home/${SUDOUSER}/setup-azure-master.yml <<EOF
#!/usr/bin/ansible-playbook 
- hosts: masters
  gather_facts: no
  serial: 1
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    master_conf: /etc/origin/master/master-config.yaml
  handlers:
  - name: restart origin-master-api
    systemd:
      state: restarted
      name: origin-master-api

  - name: restart origin-master-controllers
    systemd:
      state: restarted
      name: origin-master-controllers

  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"

  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
          aadClientId : {{ g_aadClientId }}
          aadClientSecret : {{ g_aadClientSecret }}
          subscriptionId : {{ g_subscriptionId }}
          tenantID : {{ g_tenantId }}
          aadTenantID : {{ g_tenantId }}
          resourceGroup: {{ g_resourceGroup }}
          location: {{ g_location }}
    notify:
    - restart origin-master-api
    - restart origin-master-controllers

  - name: insert the azure disk config into the master
    modify_yaml:
      dest: "{{ master_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubernetesMasterConfig.apiServerArguments.cloud-config
      value:
      - "{{ azure_conf }}"

    - key: kubernetesMasterConfig.apiServerArguments.cloud-provider
      value:
      - azure

    - key: kubernetesMasterConfig.controllerArguments.cloud-config
      value:
      - "{{ azure_conf }}"

    - key: kubernetesMasterConfig.controllerArguments.cloud-provider
      value:
      - azure
    notify:
    - restart origin-master-api
    - restart origin-master-controllers
EOF

# Create Azure Cloud Provider configuration Playbook for Node Config (Master Nodes)

cat > /home/${SUDOUSER}/setup-azure-node-master.yml <<EOF
#!/usr/bin/ansible-playbook 
- hosts: masters
  serial: 1
  gather_facts: no
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    node_conf: /etc/origin/node/node-config.yaml
  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"

  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
          aadClientId : {{ g_aadClientId }}
          aadClientSecret : {{ g_aadClientSecret }}
          subscriptionId : {{ g_subscriptionId }}
          tenantID : {{ g_tenantId }}
          aadTenantID : {{ g_tenantId }}
          resourceGroup: {{ g_resourceGroup }}
          location: {{ g_location }}
  - name: insert the azure disk config into the node
    modify_yaml:
      dest: "{{ node_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubeletArguments.cloud-config
      value:
      - "{{ azure_conf }}"

    - key: kubeletArguments.cloud-provider
      value:
      - azure
EOF

# Create Azure Cloud Provider configuration Playbook for Node Config (Non-Master Nodes)

cat > /home/${SUDOUSER}/setup-azure-node.yml <<EOF
#!/usr/bin/ansible-playbook 
- hosts: nodes:!masters
  serial: 1
  gather_facts: no
  vars_files:
  - vars.yml
  become: yes
  vars:
    azure_conf_dir: /etc/azure
    azure_conf: "{{ azure_conf_dir }}/azure.conf"
    node_conf: /etc/origin/node/node-config.yaml
  post_tasks:
  - name: make sure /etc/azure exists
    file:
      state: directory
      path: "{{ azure_conf_dir }}"

  - name: populate /etc/azure/azure.conf
    copy:
      dest: "{{ azure_conf }}"
      content: |
          aadClientId : {{ g_aadClientId }}
          aadClientSecret : {{ g_aadClientSecret }}
          subscriptionId : {{ g_subscriptionId }}
          tenantID : {{ g_tenantId }}
          aadTenantID : {{ g_tenantId }}
          resourceGroup: {{ g_resourceGroup }}
          location: {{ g_location }}
  - name: insert the azure disk config into the node
    modify_yaml:
      dest: "{{ node_conf }}"
      yaml_key: "{{ item.key }}"
      yaml_value: "{{ item.value }}"
    with_items:
    - key: kubeletArguments.cloud-config
      value:
      - "{{ azure_conf }}"

    - key: kubeletArguments.cloud-provider
      value:
      - azure
EOF


# moved storage Class creation here 

cat <<EOF > /home/${SUDOUSER}/storageClass.yml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: disk
  annotations:
    storageclass.beta.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/azure-disk
parameters:
  location: ${LOCATION}
  storageAccount: ${STORAGEACCOUNT1}
EOF

# Create Ansible Hosts File
echo $(date) " - Create Ansible Hosts file"

cat > /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes
etcd
master0
new_nodes

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=true
openshift_deployment_type=origin
openshift_release=v3.7
docker_udev_workaround=True
openshift_use_dnsmasq=True
openshift_master_default_subdomain=$ROUTING
openshift_override_hostname_check=true
osm_use_cockpit=false
#os_sdn_network_plugin_name='redhat/openshift-ovs-multitenant'
#console_port=443
openshift_cloudprovider_kind=azure
osm_default_node_selector='type=app'
openshift_disable_check=disk_availability,memory_availability
# default selectors for router and registry services
openshift_router_selector='type=infra'
openshift_registry_selector='type=infra'

openshift_master_cluster_method=native
openshift_master_cluster_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_vip=$MASTERPUBLICIPADDRESS

# Enable HTPasswdPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]



##### 
# Enable service catalog
openshift_enable_service_catalog=false
# Enable template service broker (requires service catalog to be enabled, above)
template_service_broker_install=false
# Configure one of more namespaces whose templates will be served by the TSB
openshift_template_service_broker_namespaces=['openshift']
# Configure the multi-tenant SDN plugin (default is 'redhat/openshift-ovs-subnet')
os_sdn_network_plugin_name='redhat/openshift-ovs-multitenant'
# Disable the OpenShift SDN plugin
openshift_use_openshift_sdn=true

### Metrics #####
openshift_metrics_install_metrics=false
openshift_metrics_cassandra_storage_type=emptydir
openshift_metrics_cassandra_pvc_size=10Gi
openshift_metrics_storage_volume_size=10Gi
openshift_metrics_install_metrics=false 
### logging #####
openshift_logging_install_logging=false
openshift_logging_es_pvc_size=20Gi

# host group for masters
[masters]
$MASTER-[0:${MASTERLOOP}]

# host group for etcd
[etcd]
$MASTER-[0:${MASTERLOOP}] 

[master0]
$MASTER-0

# host group for nodes
[nodes]
EOF

# Loop to add Masters

for (( c=0; c<$MASTERCOUNT; c++ ))
do
  echo "$MASTER-$c openshift_node_labels=\"{'type': 'master', 'zone': 'default'}\" openshift_hostname=$MASTER-$c" >> /etc/ansible/hosts
done

# Loop to add Infra Nodes

for (( c=0; c<$INFRACOUNT; c++ ))
do
  echo "$INFRA-$c openshift_node_labels=\"{'type': 'infra', 'zone': 'default'}\" openshift_hostname=$INFRA-$c" >> /etc/ansible/hosts
done

# Loop to add Nodes

for (( c=0; c<$NODECOUNT; c++ ))
do
  echo "$NODE-$c openshift_node_labels=\"{'type': 'app', 'zone': 'default'}\" openshift_hostname=$NODE-$c" >> /etc/ansible/hosts
done

# Create new_nodes group

cat >> /etc/ansible/hosts <<EOF

# host group for adding new nodes
[new_nodes]
EOF

echo $(date) " - Removing and Cloning openshift-ansible repo for use in installation"
runuser -l $SUDOUSER -c "rm -rf /home/$SUDOUSER/openshift-ansible "

runuser -l $SUDOUSER -c "git clone https://github.com/openshift/openshift-ansible /home/$SUDOUSER/openshift-ansible "
#export mypath=$PWD
runuser -l $SUDOUSER -c "cd /home/$SUDOUSER/openshift-ansible && git checkout origin/release-3.7  "
#runuser #-l $SUDOUSER -c "git --git-dir=/home/$SUDOUSER/openshift-ansible/.git checkout origin/release-3.7"


echo $(date) " - Running network_manager.yml playbook" 
DOMAIN=`domainname -d` 

# Setup NetworkManager to manage eth0 
runuser -l $SUDOUSER -c "ansible-playbook openshift-ansible/playbooks/byo/openshift-node/network_manager.yml" 

echo $(date) " - Setting up NetworkManager on eth0" 
# Configure resolv.conf on all hosts through NetworkManager 

runuser -l $SUDOUSER -c "ansible all -b -m service -a \"name=NetworkManager state=restarted\"" 
sleep 5 
runuser -l $SUDOUSER -c "ansible all -b -m command -a \"nmcli con modify eth0 ipv4.dns-search $DOMAIN\"" 
runuser -l $SUDOUSER -c "ansible all -b -m service -a \"name=NetworkManager state=restarted\"" 

# Initiating installation of OpenShift Container Platform using Ansible Playbook
echo $(date) " - Installing OpenShift Container Platform via Ansible Playbook"

runuser -l $SUDOUSER -c "ansible-playbook openshift-ansible/playbooks/byo/config.yml"

echo $(date) " - Modifying sudoers"

sed -i -e "s/Defaults    requiretty/# Defaults    requiretty/" /etc/sudoers
sed -i -e '/Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"/aDefaults    env_keep += "PATH"' /etc/sudoers

# Deploying Registry
echo $(date) "- Registry automatically deployed to infra nodes"

# Deploying Router
echo $(date) "- Router automaticaly deployed to infra nodes"

echo $(date) "- Re-enabling requiretty"

sed -i -e "s/# Defaults    requiretty/Defaults    requiretty/" /etc/sudoers

# Adding user to OpenShift authentication file
echo $(date) "- Adding OpenShift user"

runuser -l $SUDOUSER -c "ansible-playbook ~/addocpuser.yml"

# Assigning cluster admin rights to OpenShift user
echo $(date) "- Assigning cluster admin rights to user"

runuser -l $SUDOUSER -c "ansible-playbook ~/assignclusteradminrights.yml"

# Create Storage Class
echo $(date) "- Creating Storage Class"

runuser -l $SUDOUSER -c "ansible-playbook ~/configurestorageclass.yml"

# Configure Docker Registry to use Azure Storage Account
echo $(date) "- Configuring Docker Registry to use Azure Storage Account"

runuser -l $SUDOUSER -c "ansible-playbook ~/dockerregistry.yml"
runuser -l $SUDOUSER -c "ansible-playbook ~/dockerregistry.yml"

echo $(date) "- Sleep for 120"
sleep 20

# Execute setup-azure-master and setup-azure-node playbooks to configure Azure Cloud Provider
echo $(date) "- Configuring OpenShift Cloud Provider to be Azure"

runuser -l $SUDOUSER -c "ansible-playbook ~/setup-azure-master.yml"
runuser -l $SUDOUSER -c "ansible-playbook ~/setup-azure-node-master.yml"

runuser -l $SUDOUSER -c "ansible-playbook ~/setup-azure-node.yml"

sleep 20
## restart the required service 
echo $(date) "- Restarting ovs   "

runuser -l $SUDOUSER -c  "ansible all -b  -m service -a 'name=openvswitch state=restarted' "

echo $(date) "- Restarting origin nodes after 20 seconds    "
sleep 20
runuser -l $SUDOUSER -c  "ansible nodes -b  -m service -a 'name=origin-node state=restarted' "

echo " Sleeping 60 "
sleep 60
## echo Deployong metric collection 
echo $(date) "- Deploying metrics"
runuser -l $SUDOUSER -c "ansible-playbook openshift-ansible/playbooks/byo/openshift-cluster/openshift-metrics.yml    -e openshift_metrics_cassandra_storage_type=pv  -e openshift_metrics_install_metrics=True"
## echo deploying logging 
echo $(date) "-  Deploying logging"
sleep 20
#runuser -l $SUDOUSER -c "nohup ansible-playbook openshift-ansible/playbooks/byo/openshift-cluster/openshift-logging.yml -e openshift_logging_es_pvc_dynamic=True -e openshift_logging_es_pvc_size=100G  -e openshift_logging_install_logging=True -e openshift_logging_es_pvc_storage_class_name=disk  -e openshift_logging_storage_kind=dynamic -e openshift_logging_es_memory_limit=1G  &>/dev/null &"



#runuser -l $SUDOUSER -c "ansible-playbook ~/deletestucknodes.yml"

# Delete postinstall files
echo $(date) "- Deleting post installation files"


#rm /home/${SUDOUSER}/addocpuser.yml
#rm /home/${SUDOUSER}/assignclusteradminrights.yml
#rm /home/${SUDOUSER}/dockerregistry.yml
#rm /home/${SUDOUSER}/vars.yml
#rm /home/${SUDOUSER}/setup-azure-master.yml
#rm /home/${SUDOUSER}/setup-azure-node-master.yml
#rm /home/${SUDOUSER}/setup-azure-node.yml
#rm /home/${SUDOUSER}/deletestucknodes.yml

echo $(date) " - Script complete"
