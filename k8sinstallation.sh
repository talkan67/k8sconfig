sudo swapoff -a
sudo vi /etc/fstab #disable swap line
sudo apt install docker.io -y

sudo systemctl start docker
sudo systemctl enable docker


sudo apt install -y apt-transport-https curl


curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list



sudo apt update
sudo apt install -y kubelet kubeadm kubectl


sudo apt-mark hold kubelet kubeadm kubectl

(master): sudo kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

