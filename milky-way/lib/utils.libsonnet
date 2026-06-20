// The cluster's DNS domain (k3s/Kubernetes default). Used to build in-cluster Service FQDNs.
local clusterDomain = 'cluster.local';

{
  assertEqualAndReturn(got, expected):: (
    assert got == expected : 'Expected ' + std.toString(expected) + ', got ' + std.toString(got);
    got
  ),
  assertAndReturn(value, predicate, message=('Value ' + std.toString(value) + ' did not satisfy predicate')):: (
    assert predicate(value) : message;
    value
  ),

  // In-cluster DNS FQDN of a Kubernetes Service object: <name>.<namespace>.svc.<clusterDomain>.
  // Validates that the argument really is a core/v1 Service with a name and namespace, throwing a
  // descriptive error otherwise, so a wrong object passed at a wiring point fails at evaluation
  // rather than silently producing a bogus hostname.
  domainOfService(k8sObject):: (
    assert std.isObject(k8sObject) :
      'domainOfService: expected a Kubernetes Service object, got ' + std.toString(k8sObject);
    assert std.objectHas(k8sObject, 'kind') && k8sObject.kind == 'Service' :
      "domainOfService: expected kind 'Service', got " +
      (if std.objectHas(k8sObject, 'kind') then std.toString(k8sObject.kind) else '<missing kind>');
    assert std.objectHas(k8sObject, 'apiVersion') && k8sObject.apiVersion == 'v1' :
      "domainOfService: expected a core Service with apiVersion 'v1', got " +
      (if std.objectHas(k8sObject, 'apiVersion') then std.toString(k8sObject.apiVersion) else '<missing apiVersion>');
    assert std.objectHas(k8sObject, 'metadata') :
      'domainOfService: Service object has no metadata';
    local meta = k8sObject.metadata;
    assert std.objectHas(meta, 'name') && std.isString(meta.name) && meta.name != '' :
      'domainOfService: Service metadata.name is not defined';
    assert std.objectHas(meta, 'namespace') && std.isString(meta.namespace) && meta.namespace != '' :
      'domainOfService: Service metadata.namespace is not defined';
    '%s.%s.svc.%s' % [meta.name, meta.namespace, clusterDomain]
  ),
}
