
# Install k3s

If you don't have Kubernetes already installed, you can follow these instructions for deploying K3s (a lightweight Kubernetes environment).

First, start by following the steps found at this URL to prepare your system for K3s:

[https://docs.k3s.io/installation/requirements](https://docs.k3s.io/installation/requirements)

Now, install K3s with the following commands:

```shell
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.33.5+k3s1 sh -s - --disable=traefik
sudo ln -s /usr/local/bin/kubectl /bin/kubectl
sudo kubectl get node -o wide
```

## CoreDNS

Run the following commands to configure DNS within K3s so pods can resolve your chosen hostname to the node internally.

> This step assumes the `sed` configuration step from `README.md` (or `README-STANDALONE-ISPI.md`) has already filled in `IMMUNOPLEX_HOSTNAME` / `IMMUNOPLEX_IP_ADDRESS` in `coredns.yml`. Applying it with the placeholders still in place produces a non-functional Corefile.

```shell
sudo kubectl apply -f k8s-manifests/coredns.yml
sudo kubectl -n kube-system rollout restart deploy coredns
```

## Create immunoplex namespace

These instructions expect all components of immunoplex to be installed in the immunoplex namespace. Run the following command to create the namespace.

```shell
sudo kubectl create ns immunoplex
```

## Install cert-manager

To keep communication secure, `cert-manager` is used to manage the TLS certificates for the environment.  Run the following commands to install cert-manager.

```shell
sudo kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.1/cert-manager.yaml
# Wait for pods to be available before continuing
sudo kubectl wait -n cert-manager --for=condition=ready pod -l app=webhook --timeout=5m
```

Run the following commands to create the `root-ca` certificate.  This certificate will be used to sign the intermediate certificate.

```shell
cat <<EOF | sudo kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: root-ca-issuer-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: root-ca
  secretName: root-ca-secret
  duration: 87600h # 10y
  renewBefore: 78840h # 9y
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    name: root-ca-issuer-selfsigned
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: root-ca-issuer
spec:
  ca:
    secretName: root-ca-secret
EOF
```

Confirm CA is ready by running the following command.  You should see a status of `Ready`.

```shell
sudo kubectl describe ClusterIssuer -n cert-manager
```

Create intermediate CA by running the following commands.

```shell
cat <<EOF | sudo kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: intermediate-ca1
  namespace: cert-manager
spec:
  isCA: true
  commonName: intermediate-ca1
  secretName: intermediate-ca1-secret
  duration: 43800h # 5y
  renewBefore: 35040h # 4y
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    name: root-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: intermediate-ca1-issuer
spec:
  ca:
    secretName: intermediate-ca1-secret
EOF
```

Copy root-ca-secret to immunoplex namespace

```shell
sudo kubectl get secret root-ca-secret --namespace=cert-manager -o yaml \
  | sed 's/namespace: cert-manager/namespace: immunoplex/' \
  | sudo kubectl create -f -
```

Export Root CA certificate. This cert can be imported into user's browsers to trust the encryption between the browser and immunoplex.

```shell
sudo kubectl -n cert-manager get secret root-ca-secret -o jsonpath='{.data.tls\.crt}' | base64 -d > immunoplex-root-ca.crt
```
