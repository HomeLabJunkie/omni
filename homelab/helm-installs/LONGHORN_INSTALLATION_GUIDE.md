# Longhorn Storage Installation Guide for Talos Linux

## Overview

This guide provides step-by-step instructions for installing Longhorn distributed block storage on a Talos Linux cluster managed by Omni. This configuration uses Helm for deployment and includes necessary workarounds for Talos-specific requirements.

**Cluster Configuration:**
- Platform: Talos Linux v1.12.0
- Kubernetes: v1.35.0
- CNI: Cilium v1.18.5 (kube-proxy replacement enabled)
- Management: Omni by Sidero Labs
- Storage: 5 nodes × 500GB SSD (CT500MX500SSD1)
- Total Capacity: ~2.3TB usable

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Step 1: Verify Machine Patches](#step-1-verify-machine-patches)
3. [Step 2: Install Longhorn via Helm](#step-2-install-longhorn-via-helm)
4. [Step 3: Patch DaemonSet for Storage Access](#step-3-patch-daemonset-for-storage-access)
5. [Step 4: Configure Longhorn Node Disks](#step-4-configure-longhorn-node-disks)
6. [Step 5: Verify Installation](#step-5-verify-installation)
7. [Step 6: Access Longhorn UI](#step-6-access-longhorn-ui)
8. [Troubleshooting](#troubleshooting)
9. [Important Notes](#important-notes)

---

## Prerequisites

Before installing Longhorn, ensure the following are in place:

### 1. Talos Cluster Requirements

- ✅ Talos Linux cluster deployed via Omni
- ✅ Cilium CNI installed and configured
- ✅ kube-proxy replacement enabled in Cilium
- ✅ Minimum 3 nodes (5 recommended for high availability)

### 2. Talos System Extensions

Each Talos node must have the following system extensions installed:

- `siderolabs/iscsi-tools` - For iSCSI support
- `siderolabs/util-linux-tools` - For disk utilities

**Verify extensions:**
```bash
# Method 1: Via Omni dashboard
# Navigate to: Cluster → Machines → Select a machine → Overview
# Look for "System Extensions" section

# Method 2: Via talosctl
talosctl get extensions -n <node-ip>

# Method 3: Check machine config
talosctl get machineconfig -n <node-ip> -o yaml | grep -A10 "schematic:"
```

### 3. Storage Disks

- Physical disks attached to each node (SSD recommended)
- Machine patches applied to format and mount disks at `/var/mnt/storage`

---

## Step 1: Verify Machine Patches

Machine patches configure the storage disks on each Talos node. These should already be applied via Omni.

### Check Patches in Omni

```bash
omnictl get configpatches | grep storage-disk
```

**Expected output:**
```
500-231-storage-disk
500-232-storage-disk
500-233-storage-disk
500-234-storage-disk
500-235-storage-disk
```

### Verify Disk Mounts

Check that disks are mounted on the nodes. In the Omni dashboard:

1. Navigate to **Machines**
2. Select any node
3. Check **Disks** section
4. Verify `/var/mnt/storage` is mounted with ~490GB available

**Or verify mounts exist on the nodes:**

You cannot directly check mounts via kubectl since Talos doesn't expose this information through the Kubernetes API. Instead, use one of these methods:

```bash
# Method 1: Via Omni dashboard (recommended)
# Navigate to: Cluster → Machines → Select a machine → Disks
# Verify /var/mnt/storage shows ~490GB available

# Method 2: Via talosctl (requires node access)
talosctl -n <node-ip> list /var/mnt/storage
# Should show: NODE    NAME
#              <ip>    .

# Method 3: Check from inside a pod that has host mounts
# We'll verify this in Step 3 after Longhorn pods are running
```

The machine patches should contain configuration similar to:
```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/storage
        type: bind
        source: /var/mnt/storage
        options:
          - bind
          - rshared
          - rw
  disks:
      - device: /dev/disk/by-id/ata-CT500MX500SSD1_<SERIAL>
        partitions:
          - mountpoint: /var/mnt/storage
```

---

## Step 2: Install Longhorn via Helm

### Add Longhorn Helm Repository

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

### Install Longhorn

Execute the following command to install Longhorn with all required configurations:

```bash
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultDataPath=/var/mnt/storage \
  --set defaultSettings.disableRevisionCounter=true \
  --set defaultSettings.kubernetesClusterAutoscalerEnabled=false \
  --set enablePSP=false \
  --set defaultSettings.createDefaultDiskLabeledNodes=true \
  --set-string 'namespaceLabels.pod-security\.kubernetes\.io/enforce=privileged' \
  --set-string 'namespaceLabels.pod-security\.kubernetes\.io/audit=privileged' \
  --set-string 'namespaceLabels.pod-security\.kubernetes\.io/warn=privileged' \
  --set-string 'service.ui.annotations.omni-kube-service-exposer\.sidero\.dev/port=80' \
  --set-string 'service.ui.annotations.omni-kube-service-exposer\.sidero\.dev/label=Longhorn' \
  --set-string 'service.ui.annotations.omni-kube-service-exposer\.sidero\.dev/protocol=http' \
  --set-string 'service.ui.annotations.omni-kube-service-exposer\.sidero\.dev/icon=PHN2ZyB3aWR0aD0iNDgiIGhlaWdodD0iNDgiIHZpZXdCb3g9IjAgMCA0OCA0OCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZD0iTTI0IDQ4QzM3LjI1NDggNDggNDggMzcuMjU0OCA0OCAyNEM0OCAxMC43NDUyIDM3LjI1NDggMCAyNCAwQzEwLjc0NTIgMCAwIDEwLjc0NTIgMCAyNEMwIDM3LjI1NDggMTAuNzQ1MiA0OCAyNCA0OFoiIGZpbGw9IiNGRjYwMDAiLz4KPHBhdGggZD0iTTM2IDE4SDEyQzEwLjg5NTQgMTggMTAgMTguODk1NCAxMCAyMFYzMkMxMCAzMy4xMDQ2IDEwLjg5NTQgMzQgMTIgMzRIMzZDMzcuMTA0NiAzNCAzOCAzMy4xMDQ2IDM4IDMyVjIwQzM4IDE4Ljg5NTQgMzcuMTA0NiAxOCAzNiAxOFoiIGZpbGw9IndoaXRlIi8+Cjwvc3ZnPgo='
```

### Configuration Explained

| Parameter | Purpose |
|-----------|---------|
| `defaultSettings.defaultDataPath` | Sets storage location to `/var/mnt/storage` |
| `disableRevisionCounter` | Improves performance by disabling revision tracking |
| `kubernetesClusterAutoscalerEnabled=false` | Prevents conflicts with cluster autoscaler |
| `enablePSP=false` | Disables PodSecurityPolicy (deprecated in K8s 1.25+) |
| `createDefaultDiskLabeledNodes=true` | Attempts auto-discovery (manual config still needed) |
| `namespaceLabels.pod-security.*` | Allows privileged pods (required for Longhorn) |
| `service.ui.annotations.omni-kube-service-exposer.*` | Exposes UI through Omni proxy |

### Wait for Initial Deployment

```bash
kubectl -n longhorn-system get pods -w
```

**Expected behavior:**
- Pods will start deploying
- `longhorn-manager` pods will show `1/2` READY (this is expected)
- `longhorn-ui` pods should show `1/1` READY
- Some pods may show warnings about PodSecurity violations (these are expected)

**Wait until you see:**
```
NAME                                        READY   STATUS    RESTARTS   AGE
longhorn-driver-deployer-xxxxx              0/1     Init:0/1  0          2m
longhorn-manager-xxxxx                      1/2     Running   0          2m
longhorn-manager-xxxxx                      1/2     Running   0          2m
longhorn-manager-xxxxx                      1/2     Running   0          2m
longhorn-manager-xxxxx                      1/2     Running   0          2m
longhorn-manager-xxxxx                      1/2     Running   0          2m
longhorn-ui-xxxxx                           1/1     Running   0          2m
longhorn-ui-xxxxx                           1/1     Running   0          2m
```

> **Note:** The `longhorn-manager` pods showing `1/2` READY is normal at this stage. They will become fully ready after Step 3.

---

## Step 3: Patch DaemonSet for Storage Access

**⚠️ CRITICAL STEP:** The Longhorn Helm chart does not automatically mount custom storage paths into the manager pods. This manual patching is required for Longhorn to access `/var/mnt/storage`.

### Why This Step is Necessary

The Helm chart's `longhornManager.volumes` and `longhornManager.volumeMounts` values are not properly applied to the DaemonSet. We must manually patch the DaemonSet to add the storage volume.

### Add the Storage Volume

```bash
kubectl -n longhorn-system patch daemonset longhorn-manager --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "longhorn-default-disk",
      "hostPath": {
        "path": "/var/mnt/storage",
        "type": "DirectoryOrCreate"
      }
    }
  }
]'
```

### Add the Volume Mount to Container

```bash
kubectl -n longhorn-system patch daemonset longhorn-manager --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "longhorn-default-disk",
      "mountPath": "/var/mnt/storage",
      "mountPropagation": "Bidirectional"
    }
  }
]'
```

**Expected output:**
```
daemonset.apps/longhorn-manager patched
daemonset.apps/longhorn-manager patched
```

### Wait for Rolling Restart

The DaemonSet will automatically perform a rolling restart of all `longhorn-manager` pods.

```bash
kubectl -n longhorn-system get pods -l app=longhorn-manager -w
```

Wait until all pods are running with new versions:
```
NAME                     READY   STATUS    RESTARTS   AGE
longhorn-manager-xxxxx   2/2     Running   0          1m
longhorn-manager-xxxxx   2/2     Running   0          1m
longhorn-manager-xxxxx   2/2     Running   0          1m
longhorn-manager-xxxxx   2/2     Running   0          1m
longhorn-manager-xxxxx   2/2     Running   0          1m
```

### Verify Storage Mount

Verify that the storage is now accessible inside the pods:

```bash
kubectl -n longhorn-system exec \
  $(kubectl -n longhorn-system get pods -l app=longhorn-manager -o jsonpath='{.items[0].metadata.name}') \
  -c longhorn-manager -- df -h 2>/dev/null | grep storage
```

**Expected output:**
```
/dev/sda1       466G  9.0G  457G   2% /var/mnt/storage
```

If you see this output, the mount is working correctly! ✅

---

## Step 4: Configure Longhorn Node Disks

Even with the storage path configured, Longhorn nodes do not automatically detect disks on Talos. You must manually add the disks to each Longhorn node.

### Create Disk Configuration Script

```bash
cat > /tmp/add-longhorn-disks.sh <<'EOF'
#!/bin/bash

# Add storage disks to all Longhorn nodes
for node in omni-talos-1 omni-talos-2 omni-talos-3 omni-talos-4 omni-talos-5; do
  kubectl -n longhorn-system patch nodes.longhorn.io/$node --type=json -p='[
    {
      "op": "replace",
      "path": "/spec/disks",
      "value": {
        "default-disk": {
          "allowScheduling": true,
          "evictionRequested": false,
          "path": "/var/mnt/storage",
          "storageReserved": 0,
          "tags": []
        }
      }
    }
  ]'
  echo "✓ Patched $node"
done

echo ""
echo "All Longhorn nodes configured successfully!"
EOF

chmod +x /tmp/add-longhorn-disks.sh
```

### Run the Script

```bash
/tmp/add-longhorn-disks.sh
```

**Expected output:**
```
node.longhorn.io/omni-talos-1 patched
✓ Patched omni-talos-1
node.longhorn.io/omni-talos-2 patched
✓ Patched omni-talos-2
node.longhorn.io/omni-talos-3 patched
✓ Patched omni-talos-3
node.longhorn.io/omni-talos-4 patched
✓ Patched omni-talos-4
node.longhorn.io/omni-talos-5 patched
✓ Patched omni-talos-5

All Longhorn nodes configured successfully!
```

### Verify Disk Configuration

```bash
kubectl get nodes.longhorn.io -n longhorn-system -o yaml | grep -A10 "disks:"
```

**Expected output (for each node):**
```yaml
    disks:
      default-disk:
        allowScheduling: true
        diskType: filesystem
        evictionRequested: false
        path: /var/mnt/storage
        storageReserved: 0
        tags: []
```

---

## Step 5: Verify Installation

### Check Node Status

```bash
kubectl get nodes.longhorn.io -n longhorn-system
```

**Expected output:**
```
NAME           READY   ALLOWSCHEDULING   SCHEDULABLE   AGE
omni-talos-1   True    true              True          10m
omni-talos-2   True    true              True          10m
omni-talos-3   True    true              True          10m
omni-talos-4   True    true              True          10m
omni-talos-5   True    true              True          10m
```

All nodes should show:
- ✅ `READY: True`
- ✅ `ALLOWSCHEDULING: true`
- ✅ `SCHEDULABLE: True`

### Check Disk Status

```bash
kubectl -n longhorn-system get nodes.longhorn.io omni-talos-1 -o yaml | grep -A20 "diskStatus:"
```

**Expected output:**
```yaml
  diskStatus:
    default-disk:
      conditions:
      - lastProbeTime: ""
        lastTransitionTime: "2025-12-31T17:56:00Z"
        message: Disk default-disk(/var/mnt/storage) on node omni-talos-1 is ready
        reason: ""
        status: "True"
        type: Ready
      - lastProbeTime: ""
        lastTransitionTime: "2025-12-31T17:56:00Z"
        message: Disk default-disk(/var/mnt/storage) on node omni-talos-1 is schedulable
        reason: ""
        status: "True"
        type: Schedulable
      diskDriver: ""
      diskName: default-disk
      diskPath: /var/mnt/storage
      diskType: filesystem
      diskUUID: 9190d70e-97c2-4ad0-a19c-51c44d492107
      filesystemType: xfs
```

### Verify Storage Capacity

```bash
kubectl -n longhorn-system get nodes.longhorn.io omni-talos-1 -o yaml | grep -A5 "storageAvailable\|storageMaximum"
```

You should see capacity around 490GB per node.

### Test Volume Creation

Create a test PersistentVolumeClaim:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOF
```

**Check PVC status:**
```bash
kubectl get pvc longhorn-test-pvc
```

**Expected output:**
```
NAME                STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
longhorn-test-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            longhorn       5s
```

Status should be `Bound` ✅

**Clean up test PVC:**
```bash
kubectl delete pvc longhorn-test-pvc
```

### Check All Pods

```bash
kubectl -n longhorn-system get pods
```

After a few minutes, you should see additional pods:
- `csi-attacher-*` (3 replicas)
- `csi-provisioner-*` (3 replicas)
- `csi-resizer-*` (3 replicas)
- `csi-snapshotter-*` (3 replicas)
- `engine-image-*` (5 replicas, one per node)
- `instance-manager-*` (5 replicas, one per node)
- `longhorn-csi-plugin-*` (5 replicas, one per node)
- `longhorn-driver-deployer-*` (1 replica)
- `longhorn-manager-*` (5 replicas, one per node) - **2/2 READY**
- `longhorn-ui-*` (2 replicas)

All pods should be in `Running` status.

---

## Step 6: Access Longhorn UI

The Longhorn UI is automatically exposed through Omni's proxy service.

### Access via Omni Dashboard

1. Open your Omni dashboard in a web browser
2. Look for **"Longhorn"** in the left sidebar menu (with an orange icon)
3. Click the Longhorn menu item
4. The Longhorn UI will open in a new tab/window

### Verify Service Annotations

If the Longhorn menu item doesn't appear in Omni, verify the service annotations:

```bash
kubectl get service longhorn-frontend -n longhorn-system -o yaml | grep -A10 "annotations:"
```

**Expected annotations:**
```yaml
  annotations:
    meta.helm.sh/release-name: longhorn
    meta.helm.sh/release-namespace: longhorn-system
    omni-kube-service-exposer.sidero.dev/icon: PHN2ZyB3aWR0aD0i...
    omni-kube-service-exposer.sidero.dev/label: Longhorn
    omni-kube-service-exposer.sidero.dev/port: "80"
    omni-kube-service-exposer.sidero.dev/protocol: http
```

**Required annotations:**
- ✅ `port: "80"`
- ✅ `label: "Longhorn"`
- ✅ `protocol: "http"` (important!)
- ✅ `icon: "<base64-encoded-svg>"`

If the `protocol: http` annotation is missing, add it:

```bash
kubectl annotate service longhorn-frontend -n longhorn-system \
  omni-kube-service-exposer.sidero.dev/protocol="http" \
  --overwrite
```

Wait 30-60 seconds for Omni to detect the changes, then refresh the dashboard.

### What to Check in the UI

Once in the Longhorn UI, verify:

1. **Dashboard** shows:
   - 5 nodes healthy
   - ~2.3TB total capacity
   - ~2.3TB schedulable capacity

2. **Node** tab shows:
   - All 5 nodes with status "Ready"
   - Each node showing ~490GB capacity
   - Scheduling enabled on all nodes

3. **Volume** tab:
   - Should be empty (no volumes yet)
   - This is normal for a fresh installation

---

## Troubleshooting

### Pods Stuck in CrashLoopBackOff

**Symptom:** `longhorn-manager` pods continuously crash

**Cause:** Namespace missing privileged security labels

**Solution:**
```bash
# Check namespace labels
kubectl get namespace longhorn-system -o yaml | grep pod-security

# Should see:
#   pod-security.kubernetes.io/enforce: privileged
#   pod-security.kubernetes.io/audit: privileged
#   pod-security.kubernetes.io/warn: privileged

# If missing, add them:
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged
```

### longhorn-manager Pods Show 1/2 READY

**Symptom:** Pods remain at `1/2` READY indefinitely

**Cause:** Storage path not mounted in pods (Step 3 not completed)

**Solution:**
1. Verify Step 3 DaemonSet patches were applied
2. Force restart all manager pods:
   ```bash
   kubectl -n longhorn-system delete pods -l app=longhorn-manager
   ```
3. Wait for pods to restart and verify mount:
   ```bash
   kubectl -n longhorn-system exec \
     $(kubectl -n longhorn-system get pods -l app=longhorn-manager -o jsonpath='{.items[0].metadata.name}') \
     -c longhorn-manager -- df -h 2>/dev/null | grep storage
   ```

### No Disks Showing in Longhorn Nodes

**Symptom:** `kubectl get nodes.longhorn.io` shows nodes but `disks: {}`

**Cause:** Step 4 disk configuration not completed

**Solution:**
1. Run the disk configuration script from Step 4
2. Verify with:
   ```bash
   kubectl get nodes.longhorn.io -n longhorn-system -o yaml | grep -A5 "disks:"
   ```

### Storage Path Not Found in Pods

**Symptom:** Error: `ls: cannot access '/var/mnt/': No such file or directory`

**Cause:** Machine patches not applied or nodes not restarted after patch application

**Solution:**
1. Verify machine patches exist in Omni:
   ```bash
   omnictl get configpatches | grep storage-disk
   ```
2. Check Omni dashboard → Machines → Select node → Disks
3. If mounts missing, reboot the affected nodes:
   ```bash
   # Via Omni dashboard: Machines → Select node → Reboot
   # Or via talosctl:
   talosctl reboot -n <node-ip>
   ```

### UI Not Accessible Through Omni

**Symptom:** Clicking Longhorn in Omni menu shows SSL error or 404

**Cause:** Missing `protocol: http` annotation

**Solution:**
```bash
# Verify annotations
kubectl get service longhorn-frontend -n longhorn-system \
  -o jsonpath='{.metadata.annotations}' | jq

# Add protocol annotation
kubectl annotate service longhorn-frontend -n longhorn-system \
  omni-kube-service-exposer.sidero.dev/protocol="http" \
  --overwrite

# Wait 30-60 seconds, then refresh Omni dashboard
```

### Webhook "Operation Not Permitted" Errors in Logs

**Symptom:** Manager pod logs show:
```
Failed to check endpoint https://longhorn-admission-webhook.longhorn-system.svc:9502/v1/healthz
error="dial tcp 10.x.x.x:9502: connect: operation not permitted"
```

**Cause:** Known issue with Talos + Cilium + kube-proxy replacement

**Is this a problem?** No, this is expected behavior and does not affect functionality.

**Why it happens:** Cilium's eBPF datapath and Talos security policies block direct pod-to-ClusterIP connections on certain ports.

**What Longhorn does:** Retries continuously and eventually succeeds. Longhorn remains functional despite these logs.

**Action:** No action required. These warnings can be safely ignored.

---

## Important Notes

### Why Helm Instead of Static Manifests?

Longhorn can be deployed via static YAML manifests, but on **Talos Linux with Cilium CNI and kube-proxy replacement**, there are known issues:

❌ **Issues with manifest deployment:**
- Admission webhooks cannot connect to ClusterIP services
- Talos security restrictions block pod-to-service communication
- Cilium's eBPF datapath requires special handling
- Pods crash with "operation not permitted" errors

✅ **Why Helm works better:**
- Handles retries and timing more gracefully
- Easier to configure and update
- Better resource management
- Webhook issues are the same, but less impactful

### Known Limitations on Talos

1. **Manual DaemonSet patching required (Step 3)**
   - Helm chart doesn't support custom volume mounts via values
   - Must manually patch DaemonSet to add `/var/mnt/storage`
   - This is a one-time operation per installation

2. **Manual disk configuration required (Step 4)**
   - Auto-discovery doesn't work on Talos
   - Even with `createDefaultDiskLabeledNodes: true`
   - Must manually add disks to each Longhorn node

3. **Webhook warnings in logs**
   - "Operation not permitted" errors are expected
   - Do not affect functionality
   - Cannot be fully eliminated on Talos + Cilium

4. **Node reboots may require disk re-configuration**
   - Machine patches should persist across reboots
   - If disks disappear from Longhorn, re-run Step 4

### Performance Considerations

**Storage Path:** `/var/mnt/storage` is on dedicated SSDs
- ✅ Better performance than system disk
- ✅ Isolated from OS I/O
- ✅ Full 500GB available per node

**Replication:** Default is 3 replicas
- Each volume consumes 3× the requested storage
- Example: 10GB volume = 30GB total used
- Adjust via StorageClass or volume settings

**Network:** Longhorn uses Cilium for pod networking
- Ensure sufficient network bandwidth between nodes
- 1Gbps minimum, 10Gbps recommended for production

### Security Considerations

**Privileged Namespace:** longhorn-system runs with privileged security
- Required for direct disk access
- Pods run with elevated capabilities
- Acceptable for storage infrastructure

**Data at Rest:** No encryption by default
- Consider using encrypted disks (LUKS)
- Or use application-level encryption

**Data in Transit:** No encryption between replicas
- Runs over pod network (Cilium)
- Consider mesh encryption for production

---

## Summary

### Installation Steps Recap

1. ✅ **Verify machine patches** - Ensure storage disks are mounted on nodes
2. ✅ **Install Longhorn via Helm** - Deploy with complete configuration
3. ✅ **Patch DaemonSet** - Add `/var/mnt/storage` volume mounts (CRITICAL)
4. ✅ **Configure node disks** - Manually add disks to each Longhorn node
5. ✅ **Verify installation** - Test volume creation and check all pods
6. ✅ **Access UI** - Open Longhorn through Omni dashboard

### Key Configuration Values

| Setting | Value | Purpose |
|---------|-------|---------|
| Storage Path | `/var/mnt/storage` | Location of Longhorn data |
| Default Replicas | 3 | High availability |
| Namespace | `longhorn-system` | Isolated namespace |
| Storage Class | `longhorn` | Default storage class |
| UI Access | Omni proxy | Secure access through Omni |

### Cluster Capacity

- **Total Raw Storage:** 2.5TB (5 × 500GB)
- **Usable Storage:** ~2.3TB (after formatting)
- **Effective Capacity:** ~767GB (with 3× replication)
- **Per-Node Storage:** ~490GB usable

### Installation Time

- **Helm installation:** ~2-3 minutes
- **Pod startup:** ~3-5 minutes
- **Disk configuration:** ~1 minute
- **Total:** ~10-15 minutes

---

## Next Steps

### Configure Backups

Set up S3-compatible backup target: [ See Trilium Notes - Minio S3 on TrueNAS for Longhorn Backup Target ]]
```bash
# Example: Configure AWS S3 backup
kubectl -n longhorn-system create secret generic aws-secret \
  --from-literal=AWS_ACCESS_KEY_ID=<access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret-key>
```

Then configure in Longhorn UI:
- Settings → General → Backup Target
- Enter: `s3://bucket-name@region/`

### Create Storage Classes

Create custom storage classes for different workloads:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-fast
provisioner: driver.longhorn.io
allowVolumeExpansion: true
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "30"
  fsType: "ext4"
```

### Set up Recurring Backups

Configure automated backups in Longhorn UI:
- Volume → Create Recurring Job
- Type: Backup or Snapshot
- Schedule: Cron expression

### Monitor Storage

- Enable Prometheus metrics
- Configure Grafana dashboards
- Set up alerts for capacity thresholds

---

## Support and Resources

### Official Documentation

- [Longhorn Documentation](https://longhorn.io/docs/)
- [Talos Linux Documentation](https://www.talos.dev/latest/)
- [Omni Documentation](https://omni.siderolabs.com/docs/)
- [Cilium Documentation](https://docs.cilium.io/)

### Community Support

- [Longhorn Slack](https://slack.cncf.io/) - #longhorn channel
- [Talos Linux Slack](https://slack.dev.talos-systems.io/)
- [GitHub Issues](https://github.com/longhorn/longhorn/issues)

### Maintenance

- Regularly check for Longhorn updates
- Monitor disk usage and capacity
- Review backup success/failures
- Test disaster recovery procedures

---

## License

This guide is provided as-is for use with Longhorn on Talos Linux clusters.

**Version:** 1.0  
**Last Updated:** December 31, 2025  
**Longhorn Version:** v1.10.1  
**Talos Version:** v1.12.0  
**Kubernetes Version:** v1.35.0
