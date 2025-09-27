# SOP

We need to this manually because tanka cannot vendor helm charts that require value overriding with secrets (without exposing the secret).

For more information, see https://tailscale.com/kb/1236/kubernetes-operator#static-manifests-with-kubectl.

1. Download the [Tailscale Operator manifest file](https://github.com/tailscale/tailscale/blob/main/cmd/k8s-operator/deploy/manifests/operator.yaml).

```sh
curl -L -o operator.yaml https://raw.githubusercontent.com/tailscale/tailscale/refs/heads/main/cmd/k8s-operator/deploy/manifests/operator.yaml
```

2. Edit the file to set the `client_id` and `client_secret` values.
    - Use quotes, just as a YAML best practice.

3. Apply to the cluster.

```sh
kubectl apply -f operator.yaml
```