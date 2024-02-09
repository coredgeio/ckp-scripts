#!/bin/bash
set -ex

#example kubernetesVersion v1.26.10, v1.27.6, v1.28.3 , v1.29.0


# Check if both arguments are provided
if [ $# -ne 2 ]; then
    echo "Usage: $0 <kubernetes_version> <control_plane_ip>"
    exit 1
fi

kubernetesVersion=$1
control_plane_ip=$2
vip=$3
network_interface=$4

kubeadm_config=$(cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
dns:
  imageRepository: docker.io/coredgeio
kubernetesVersion: "$kubernetesVersion"
imageRepository: docker.io/coredgeio
controlPlaneEndpoint: ""
networking:
  podSubnet: "10.244.0.0/16"
EOF
)


echo "$kubeadm_config" > /tmp/kubeadm-config.yaml


configfile="/tmp/kubeadm-config.yaml"
k8s_version=$(echo "$kubeadm_config" | awk '/kubernetesVersion:/ {print $2}' | sed 's/v//' | tr -d '"')
pod_subnet=$(awk '/podSubnet:/ {print $2}' /tmp/kubeadm-config.yaml | tr -d '"')
path="/tmp"
kube_vip_version=v0.6.2



mkdir -p local-bin/
curl -L https://carvel.dev/install.sh | K14SIO_INSTALL_BIN_DIR=local-bin bash
export PATH=$PWD/local-bin/:$PATH
mkdir -p $path/${k8s_version}
imgpkg pull  -i index.docker.io/coredgeio/byoh-bundle-ubuntu_20.04.1_x86-64_k8s:v$k8s_version -o $path/${k8s_version}

check_integrity() {
    sudo apt-get update
    sudo apt install dpkg-sig unzip -y
    rm -Rf /tmp/ckp-gpg
    git clone https://github.com/coredgeio/ckp-gpg.git /tmp/ckp-gpg
    gpg --import /tmp/ckp-gpg/Coredge-public-key-1.29.0.key

    # if [ "$(echo "$k8s_version 1.29" | awk '{print ($1 >= $2) ? "true" : "false"}')" == "true" ]; then
    #     gpg --import /tmp/ckp-gpg/Coredge-public-key-1.29.0.key
    # else
    #     gpg --import /tmp/ckp-gpg/Coredge-public-key-1.26-1.28.key
    # fi

    for component in "kubeadm" "kubelet"; do
        dpkg-sig --verify "$path/${k8s_version}/${component}.deb"
        component_integrity=$(dpkg-sig --verify "$path/${k8s_version}/${component}.deb")
        maintainer_check=$(dpkg-deb --field "$path/${k8s_version}/${component}.deb" Maintainer)
        if [ $? -ne 0 ]; then
            echo "${component} integrity check failed. Exiting."
            exit 1
        elif [ "$maintainer_check" != "Coredge.io" ]; then
            echo "Deb package is not signed by coredge.io. Exiting."
            exit 1
        else
            echo "${component} integrity check passed."
            echo "Integrity Status: $component_integrity"
            echo "Maintainer: $maintainer_check"
            echo ""
        fi
    done
}


installGeneralDependencies()
{
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl
    sudo apt install make
    sudo apt-get install conntrack socat
}

#Function to Install Containerd
installContainerd()
{
    # Create config.toml
    sudo mkdir -p /etc/containerd
    CONTAINERD_CONFIG=$(cat <<EOF
version = 2
[plugins]
[plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "docker.io/coredgeio/pause:3.9"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
EOF
    )

    echo "$CONTAINERD_CONFIG" | sudo tee /etc/containerd/config.toml > /dev/null
    
    sudo tar -xvf $path/${k8s_version}/containerd.tar -C / --exclude='etc/cni/net.d/10-containerd-net.conflist'
    
    # Start containerd as a service
    sudo systemctl daemon-reload
    sudo systemctl enable --now containerd
}

#Function to Install runc
# installRunc()
# {
#     curl -fsSLo runc.amd64 https://github.com/opencontainers/runc/releases/download/v1.1.9/runc.amd64
#     sudo install -m 755 runc.amd64 /usr/local/sbin/runc
# }


forwardIpv4()
{
    cat <<EOF |
    sudo tee /etc/modules-load.d/k8s.conf
    overlay
    br_netfilter
EOF
    sudo modprobe -a overlay br_netfilter

    # sysctl params required by setup, params persist across reboots
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
    net.bridge.bridge-nf-call-iptables  = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward                 = 1
EOF


    # Apply sysctl params without reboot
    sudo sysctl --system
}


installKube()
{
    kubectl=$path/${k8s_version}/kubectl.deb
    kubeadm=$path/${k8s_version}/kubeadm.deb
    kubelet=$path/${k8s_version}/kubelet.deb

	sudo apt-get update
	sudo apt-get install -y $kubeadm $kubelet $kubectl
	sudo apt-mark hold kubeadm kubelet kubectl

}

swapDisable()
{
    # See if swap is enabled
    swapon --show

    # Turn off swap
    sudo swapoff -a

    # Disable swap completely
    sudo sed -i -e '/swap/d' /etc/fstab
}

createCluster()
{
    sudo kubeadm init --config=$configfile --upload-certs
}

configureKubectl()
{
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
}

# installCniplugin()
# {
#     kubernetes_cni="${path}/${k8s_version}/kubernetes-cni.deb"
#     sudo apt-get install -y $kubernetes_cni
# }

installCNI()
{
    kubectl create ns kube-flannel
    kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged
    helm repo add flannel https://flannel-io.github.io/flannel/
    helm install flannel --set podCidr=$pod_subnet --namespace kube-flannel flannel/flannel
}

installHelm()
{
    curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
}

kubeVip()
{
     sudo ctr image pull ghcr.io/kube-vip/kube-vip:${kube_vip_version}
     sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${kube_vip_version} vip /kube-vip manifest pod --interface ${network_interface} --address ${vip} --controlplane --services --arp --leaderElection > /tmp/kube_vip_manifest.yaml
     sudo cp  /tmp/kube_vip_manifest.yaml /etc/kubernetes/manifests/kube-vip.yaml
}

echo "Check deb packages integrity"
check_integrity

echo "Installing general dependencies"
installGeneralDependencies

echo "Installing Containerd"
installContainerd

# echo "Installing runc"
# installRunc

echo "Forwarding IPv4 and let iptables see bridged network traffic"
forwardIpv4

echo "Installing kubeadm, kubelet & kubectl"
installKube

echo "Disabling Swap"
swapDisable


if [ -n "$vip" ] && [ -n "$network_interface" ]; then
    echo "Preparing kube-vip manifest"
    kubeVip
    #update the controlPlaneEndpoint ip with vip
    sed -i "s/controlPlaneEndpoint: \".*\"/controlPlaneEndpoint: \"$vip:6443\"/" /tmp/kubeadm-config.yaml
else
    #Since kubevip parameters are not passed, use the control_plane_ip variable for controlPlaneEndpoint
    sed -i "s/controlPlaneEndpoint: \".*\"/controlPlaneEndpoint: \"$control_plane_ip:6443\"/" /tmp/kubeadm-config.yaml
fi


echo "Crete Cluster"
createCluster

echo "configure Kubectl"
configureKubectl

echo "Installing Helm"
installHelm

# echo "Installing Cniplugin"
# installCniplugin

echo "Installing Cni"
installCNI

#Create env variable file for the worker node addition
join_command=$(kubeadm token create --print-join-command)
echo "export JOIN_COMMAND=\"$join_command\"" > /tmp/join_env
echo "export K8S_VERSION=\"$k8s_version\"" >> /tmp/join_env

echo "\n To join the Worker nodes, place the file /tmp/join_env (which is created by this script) in same of path of the worker node and run the worker-addition script"