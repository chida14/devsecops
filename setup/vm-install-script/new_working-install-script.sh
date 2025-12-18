#!/usr/bin/env bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo -e "\n.........----------------#################._.-.- $* -.-._.#################----------------.........\n"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

APT_GET="apt-get -y -o Dpkg::Options::=--force-confnew"

ARCH_DEB="$(dpkg --print-architecture)"
case "$ARCH_DEB" in
  amd64) K8S_ARCH="amd64" ;;
  arm64) K8S_ARCH="arm64" ;;
  *) echo "Unsupported architecture: ${ARCH_DEB}"; exit 1 ;;
esac

install_k8s_binaries() {
  local RELEASE="$1"          # e.g. v1.35.2
  local DOWNLOAD_DIR="/usr/local/bin"
  local KREL_TEMPLATES_VERSION="v0.16.2"

  log "FALLBACK: INSTALL KUBEADM/KUBELET/KUBECTL VIA BINARIES (${RELEASE})"

  mkdir -p "${DOWNLOAD_DIR}"

  curl -fsSL -o "${DOWNLOAD_DIR}/kubeadm"  "https://dl.k8s.io/release/${RELEASE}/bin/linux/${K8S_ARCH}/kubeadm"
  curl -fsSL -o "${DOWNLOAD_DIR}/kubelet"  "https://dl.k8s.io/release/${RELEASE}/bin/linux/${K8S_ARCH}/kubelet"
  curl -fsSL -o "${DOWNLOAD_DIR}/kubectl"  "https://dl.k8s.io/release/${RELEASE}/bin/linux/${K8S_ARCH}/kubectl"
  chmod +x "${DOWNLOAD_DIR}/kubeadm" "${DOWNLOAD_DIR}/kubelet" "${DOWNLOAD_DIR}/kubectl"

  curl -fsSL "https://raw.githubusercontent.com/kubernetes/release/${KREL_TEMPLATES_VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service" \
    | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" > /usr/lib/systemd/system/kubelet.service

  mkdir -p /usr/lib/systemd/system/kubelet.service.d
  curl -fsSL "https://raw.githubusercontent.com/kubernetes/release/${KREL_TEMPLATES_VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" \
    | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" > /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf

  systemctl daemon-reload
  systemctl enable --now kubelet || true
}

log "BASE SETUP"

if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf || true
fi

$APT_GET update
$APT_GET install \
  ca-certificates ca-certificates-java apt-transport-https \
  curl wget gpg gnupg lsb-release \
  jq python3 python3-pip \
  dmidecode vim build-essential \
  tar software-properties-common \
  socat conntrack iptables ebtables ethtool iproute2 ipset

update-ca-certificates -f || true
dpkg-reconfigure -f noninteractive ca-certificates-java || true

swapoff -a || true
sed -ri '/\sswap\s/s/^#?/# /' /etc/fstab || true

modprobe br_netfilter || true
cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl --system || true

log "CONTAINERD"

$APT_GET install containerd
mkdir -p /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable --now containerd

log "KUBERNETES TOOLING (APT, WITH BINARY FALLBACK)"

RELEASE="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
KUBE_MINOR="$(echo "${RELEASE}" | awk -F. '{print $1 "." $2}')"

rm -f /etc/apt/sources.list.d/kubernetes.list
mkdir -p /etc/apt/keyrings

rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/ /
EOF

$APT_GET update

set +e
$APT_GET install kubelet kubeadm kubectl
APT_RC=$?
set -e

if [[ "${APT_RC}" -eq 0 ]]; then
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable --now kubelet || true
else
  echo "APT install of kubelet/kubeadm/kubectl failed (likely kubernetes-cni dependency). Falling back to binaries."
  $APT_GET -f install || true
  $APT_GET purge kubelet kubeadm kubectl kubernetes-cni || true
  $APT_GET autoremove || true
  install_k8s_binaries "${RELEASE}"
fi

log "CNI PLUGINS"

CNI_PLUGINS_VERSION="v1.9.0"
mkdir -p /opt/cni/bin
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${K8S_ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
  | tar -C /opt/cni/bin -xz

log "PYTHON UTILITIES"

pip3 install --no-cache-dir jc
jc dmidecode | jq -r '.[1].values.uuid' || true

log "KUBERNETES CLUSTER INIT"

kubeadm reset -f || true
rm -f /root/.kube/config || true

systemctl restart containerd

kubeadm init --pod-network-cidr '10.244.0.0/16' --service-cidr '10.96.0.0/16' --skip-token-print

mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

for i in {1..30}; do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 5
done

kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
kubectl taint nodes --all node-role.kubernetes.io/master- || true
kubectl get nodes -o wide || true

log "DOCKER"

$APT_GET install docker.io
systemctl enable --now docker
getent group docker >/dev/null || groupadd docker

mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "storage-driver": "overlay2"
}
EOF

systemctl daemon-reload
systemctl restart docker

log "JAVA 21 + MAVEN"

# Ubuntu 22.04 usually has Java 21 in jammy-updates/jammy-security now.
# If it's not available in your image, we add the OpenJDK PPA as a fallback.
set +e
$APT_GET install openjdk-21-jdk maven
JAVA_RC=$?
set -e

if [[ "${JAVA_RC}" -ne 0 ]]; then
  log "JAVA 21 NOT FOUND IN DEFAULT REPOS - ADDING PPA"
  add-apt-repository -y ppa:openjdk-r/ppa
  $APT_GET update
  $APT_GET install openjdk-21-jdk maven
fi

java -version
mvn -v

log "JENKINS"

rm -f /etc/apt/sources.list.d/jenkins.list
mkdir -p /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian/jenkins.io-2023.key

cat >/etc/apt/sources.list.d/jenkins.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian binary/
EOF

$APT_GET update
$APT_GET install jenkins

systemctl daemon-reload
systemctl enable --now jenkins

usermod -aG docker jenkins || true
systemctl restart jenkins || true

echo "jenkins ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/jenkins-nopasswd
chmod 440 /etc/sudoers.d/jenkins-nopasswd

log "COMPLETED"

echo "If Jenkins is not running, check:"
echo "  systemctl status jenkins --no-pager -l"
echo "  journalctl -xeu jenkins --no-pager | tail -n 120"
