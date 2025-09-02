{
  local this = self,
  storageClass: {
    apiVersion: "storage.k8s.io/v1",
    kind: "StorageClass",
    metadata: {
      name: "my-local-path-retain",
    },
    provisioner: "rancher.io/local-path",
    reclaimPolicy: "Retain",
    volumeBindingMode: "WaitForFirstConsumer",
    parameters: {
      type: "default",
    },
  },
  nameRef: this.storageClass.metadata.name,
}
