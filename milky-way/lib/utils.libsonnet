// The cluster's DNS domain (k3s/Kubernetes default). Used to build in-cluster Service FQDNs.
local clusterDomain = 'cluster.local';

// Turn an array into an object keyed by an injective mapping. `injectiveMap` maps each value to
// its uniquely identifying string; the result maps that string back to the value. Assert
// injectivity FIRST (distinct-key count == element count), so a non-injective map fails with the
// descriptive message below instead of the object comprehension's own opaque "Duplicate field
// name" error -- the assert is evaluated before the comprehension is forced.
local convertArrayWithInjectiveMapping(array, injectiveMap) = (
  local keys = std.map(injectiveMap, array);
  local distinctKeys = std.set(keys);
  assert std.length(distinctKeys) == std.length(array) : (
    // Surface a concrete collision: the first key shared by >1 element, and two such elements.
    local collidingKey =
      std.filter(function(k) std.length(std.find(k, keys)) > 1, distinctKeys)[0];
    local collidingIndices = std.find(collidingKey, keys);
    'convertArrayWithInjectiveMapping: injectiveMap is not injective over the array -- ' +
    std.toString(std.length(array)) + ' elements map to only ' +
    std.toString(std.length(distinctKeys)) + ' distinct keys. Key ' +
    std.toString(collidingKey) + ' is shared by ' +
    std.toString(array[collidingIndices[0]]) + ' and ' +
    std.toString(array[collidingIndices[1]])
  );
  { [injectiveMap(value)]: value for value in array }
);

{
  local this = self,

  assertEqualAndReturn(got, expected):: (
    assert got == expected : 'Expected ' + std.toString(expected) + ', got ' + std.toString(got);
    got
  ),
  assertAndReturn(value, predicate, message=('Value ' + std.toString(value) + ' did not satisfy predicate')):: (
    assert predicate(value) : message;
    value
  ),

  // Public alias for convertArrayWithInjectiveMapping: key an array by an injective mapping,
  // asserting the mapping really is injective over the array.
  associateBy(array, injectiveMap):: convertArrayWithInjectiveMapping(array, injectiveMap),

  // Convenience wrapper for an array of objects: key each object by one of its own properties.
  // Lets callers look up "the element whose <property> is X" by name instead of by a hardcoded
  // array index -- a missing X then fails loudly (missing-key access errors), and a duplicate X
  // trips the injectivity assert in convertArrayWithInjectiveMapping.
  associateObjectsByKey(arrayOfObjects, injectiveProperty)::
    this.associateBy(arrayOfObjects, function(value) value[injectiveProperty]),

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
