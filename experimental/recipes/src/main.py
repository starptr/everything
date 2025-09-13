#!/usr/bin/env python3
import argparse
import sys
import time
import subprocess

from kubernetes import client, config

def is_control_plane(node):
    """Check if node has control-plane/master labels."""
    labels = node.metadata.labels or {}
    return any(k in labels for k in [
        "node-role.kubernetes.io/control-plane",
        "node-role.kubernetes.io/master"
    ])

def cordon_node(v1, node_name):
    body = {"spec": {"unschedulable": True}}
    v1.patch_node(node_name, body)

def drain_node(v1, node_name, timeout=600, poll_interval=5):
    """Evict all pods from node and wait until drained."""
    field_selector = f"spec.nodeName={node_name}"
    pods = v1.list_pod_for_all_namespaces(field_selector=field_selector).items

    # Evict pods one by one
    for pod in pods:
        # Skip DaemonSets
        if pod.metadata.owner_references and any(
            owner.kind == "DaemonSet" for owner in pod.metadata.owner_references
        ):
            continue
        # Skip mirror/static pods
        if pod.metadata.annotations and "kubernetes.io/config.mirror" in pod.metadata.annotations:
            continue

        eviction = client.V1Eviction(
            metadata=client.V1ObjectMeta(
                name=pod.metadata.name,
                namespace=pod.metadata.namespace
            ),
            delete_options=client.V1DeleteOptions(grace_period_seconds=30),
        )
        try:
            v1.create_namespaced_pod_eviction(
                name=pod.metadata.name,
                namespace=pod.metadata.namespace,
                body=eviction,
            )
            print(f"Eviction requested: {pod.metadata.namespace}/{pod.metadata.name}")
        except Exception as e:
            print(f"Failed to evict {pod.metadata.namespace}/{pod.metadata.name}: {e}")

    # Wait until no non-DaemonSet, non-mirror pods remain
    start = time.time()
    while True:
        pods = v1.list_pod_for_all_namespaces(field_selector=field_selector).items
        remaining = [
            p for p in pods
            if not (p.metadata.owner_references and any(o.kind == "DaemonSet" for o in p.metadata.owner_references))
            and not (p.metadata.annotations and "kubernetes.io/config.mirror" in p.metadata.annotations)
        ]
        if not remaining:
            print("Node successfully drained.")
            return True
        if time.time() - start > timeout:
            print("Timeout waiting for node to drain.")
            return False
        print(f"Waiting for {len(remaining)} pods to evict...")
        time.sleep(poll_interval)

def shutdown_host(hostname, user="root"):
    print(f"Shutting down host {hostname}...")
    result = subprocess.run(
        ["ssh", f"{user}@{hostname}", "sudo", "shutdown", "-h", "now"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("Failed to shut down host:", result.stderr)
    else:
        print("Shutdown command issued successfully.")

def main():
    parser = argparse.ArgumentParser(description="Drain a Kubernetes node and shut it down.")
    parser.add_argument("node", help="Node hostname to drain and shut down")
    parser.add_argument("--ssh-user", default="root", help="SSH username (default: root)")
    args = parser.parse_args()

    # Load kubeconfig
    config.load_kube_config()
    v1 = client.CoreV1Api()

    # Verify node exists
    try:
        node = v1.read_node(args.node)
    except Exception as e:
        print(f"Error: Could not find node {args.node}: {e}")
        sys.exit(1)

    # Ensure it's not control-plane
    if is_control_plane(node):
        print(f"Error: Node {args.node} is a control-plane node. Refusing to shut it down.")
        sys.exit(1)

    # Cordon and drain
    cordon_node(v1, args.node)
    if not drain_node(v1, args.node):
        sys.exit(1)

    # Shutdown
    shutdown_host(args.node, user=args.ssh_user)

if __name__ == "__main__":
    main()
