#!/bin/bash
set -ex

# Set the file path
join_env="/tmp/join_env"

# Check if the file exists
if [ -e "$join_env" ]; then
    # Source the file
    source "$join_env"
    echo "Join command env is sourced successfully."
else
    echo "The join command env file : $file_path , is missing. Please add it from control-plane"
fi

k8s_version=$K8S_VERSION

# User input path of the packages with node ip
path=/tmp

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

# echo "Check deb packages integrity"
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

#Join worker nodes
eval "sudo $JOIN_COMMAND"
