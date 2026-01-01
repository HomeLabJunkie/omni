# Talos Cluster Deployment Guide with Omni, Longhorn, and Cloudflare Tunnel

## Overview
This guide provides the complete, tested steps to deploy a 5-node Talos Linux cluster using Omni with:
- Cilium CNI with KubeSpan
- Longhorn distributed storage on dedicated 500GB disks
- Cloudflare Tunnel for external application access
- Domain: anything4cash.com

## Prerequisites
- 5 physical nodes with Dell hardware
- Each node has a 500GB CT500MX500SSD1 SSD for storage
- Omni account and omnictl installed
- kubectl installed
- helm installed
- Access to GitHub for storing configurations
- Cloudflare account with anything4cash.com domain

## Step 1: Deploy the Cluster

### 1.1 Create Cluster Template

The cluster template is stored in your GitHub repository:

**File location**: [`github.com/HomeLabJunkie/omni/k8s-cluster-template.yaml`](https://github.com/HomeLabJunkie/omni/blob/main/k8s-cluster-template.yaml)

This template defines:
- 5-node cluster (3 control plane, 2 workers)
- Workload scheduling enabled on control planes
- Cilium CNI with KubeSpan enabled
- Kubernetes v1.35.0 and Talos v1.12.0
- System extensions: iscsi-tools, util-linux-tools
- Metrics server configuration

### 1.2 Sync the Cluster Template

```bash
omnictl cluster template sync --file k8s-cluster-template.yaml
```

Wait for cluster to initialize:

```bash
# Monitor cluster creation
omnictl get clusters -w

# Once running, get kubeconfig
omnictl kubeconfig --cluster k8s-talos-cluster --merge

# Verify cluster is ready
kubectl get nodes
```

## Step 2: Configure Storage Disks

### 2.1 Apply Machine Patches for Storage Disks

The machine patches configure the 500GB CT500MX500SSD1 disks on each node.

**File location**: [`github.com/HomeLabJunkie/omni/patches/machine-patches.yaml`](https://github.com/HomeLabJunkie/omni/blob/main/patches/machine-patches.yaml)

These patches:
- Mount each node's 500GB SSD at `/var/mnt/storage`
- Configure kubelet extra mounts for Longhorn
- Apply to all 5 nodes (omni-talos-1 through omni-talos-5)

### 2.2 Apply the Patches

```bash
omnictl apply -f machine-patches.yaml
```

Verify patches are applied:

```bash
omnictl get configpatches | grep storage-disk
```

You should see all 5 storage disk patches (500-231 through 500-235).

## Step 3: Install Longhorn

### 3.1 Create Longhorn Values File

The Longhorn Helm values file is stored in your GitHub repository:

**File location**: [`github.com/HomeLabJunkie/omni/longhorn-values.yaml`](https://github.com/HomeLabJunkie/omni/blob/main/longhorn-values.yaml)

This configuration includes:
- Default data path: `/var/mnt/storage`
- PodSecurity labels for privileged namespace
- Cilium webhook compatibility fix (`internalTrafficPolicy: Cluster`)
- Omni service exposer annotations for UI access
- Volume mounts for the storage path

### 3.2 Install Longhorn via Helm

The Helm install command is stored in your GitHub repository:

**File location**: [`github.com/HomeLabJunkie/omni/homelab/helm-installs/longhorn-install.yaml`](https://github.com/HomeLabJunkie/omni/blob/main/homelab/helm-installs/longhorn-install.yaml)

```bash
# Add Longhorn repository
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Install Longhorn using your values file
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  -f https://raw.githubusercontent.com/HomeLabJunkie/omni/main/longhorn-values.yaml
```

### 3.3 Fix Namespace PodSecurity Labels

The namespace needs privileged pod security labels:

```bash
kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label namespace longhorn-system pod-security.kubernetes.io/audit=privileged --overwrite
kubectl label namespace longhorn-system pod-security.kubernetes.io/warn=privileged --overwrite
```

### 3.4 Restart Longhorn Manager Daemonset

```bash
kubectl rollout restart daemonset longhorn-manager -n longhorn-system
```

### 3.5 Wait for Longhorn Pods to be Running

```bash
kubectl get pods -n longhorn-system -w
```

Wait until all pods are running. You should see:
- longhorn-manager pods (daemonset - 5 pods)
- longhorn-driver-deployer
- longhorn-ui pods
- instance-manager pods

### 3.6 Add Storage Disks to Longhorn Nodes

Create and run the disk configuration script:

```bash
cat > /tmp/add-longhorn-disks.sh <<'EOF'
#!/bin/bash
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
  echo "Patched $node"
done
EOF

chmod +x /tmp/add-longhorn-disks.sh
/tmp/add-longhorn-disks.sh
```

### 3.7 Verify Disks are Configured

```bash
# Check that disks are configured
kubectl get nodes.longhorn.io -n longhorn-system -o yaml | grep -A10 "disks:"

# Verify nodes are ready
kubectl get nodes.longhorn.io -n longhorn-system
```

All nodes should show `READY: True` and `SCHEDULABLE: True`.

### 3.8 Configure S3 Backup Target

**Note**: S3 credentials and configuration details are stored in your Trilium Notes application for reference.

**Backup Target Configuration**:
- S3 URL: `s3://longhorn@us-east-1/`
- Secret Name: `longhorn-minio-credentials`

Apply your S3 backup credentials from your GitHub repository:

```bash
# Apply the S3 credentials secret
# File location: helm-installs/s3-backup-creds.yaml in your GitHub repo
kubectl apply -f s3-backup-creds.yaml
```

Configure the backup target in Longhorn:

```bash
# Set the backup target
kubectl -n longhorn-system patch settings.longhorn.io backup-target --type=merge -p '{"value":"s3://longhorn@us-east-1/"}'

# Set the backup target credential secret
kubectl -n longhorn-system patch settings.longhorn.io backup-target-credential-secret --type=merge -p '{"value":"longhorn-minio-credentials"}'
```

Verify the backup target is configured:

```bash
kubectl -n longhorn-system get settings.longhorn.io backup-target -o yaml
kubectl -n longhorn-system get settings.longhorn.io backup-target-credential-secret -o yaml
```

You should see the S3 backup target configured in the Longhorn UI under Settings → General → Backup Target.

## Step 4: Configure Cloudflare Tunnel

### 4.1 Install cloudflared on Development Workstation

On your Omni development workstation (with Homebrew installed):

```bash
# Install cloudflared
brew install cloudflare/cloudflare/cloudflared

# Verify installation
cloudflared --version
```

### 4.2 Authenticate with Cloudflare

```bash
# Login to Cloudflare (opens browser)
cloudflared tunnel login

# This will:
# 1. Open your browser
# 2. Ask you to select your Cloudflare account
# 3. Choose the anything4cash.com domain
# 4. Download cert.pem to ~/.cloudflared/
```

### 4.3 Create Cloudflare Tunnel

```bash
# Create the tunnel
cloudflared tunnel create k8s-talos-tunnel

# This will output:
# - Tunnel ID (e.g., 9cd69028-40bb-4fc4-8055-9fe3911200f3)
# - Credentials file location: ~/.cloudflared/<TUNNEL_ID>.json

# Display the credentials (you'll need these for the Kubernetes secret)
cat ~/.cloudflared/<TUNNEL_ID>.json
```

**Save the Tunnel ID** - you'll need it for the next steps.

### 4.4 Create Cloudflare Tunnel Secret

**File: `cloudflare-tunnel-secret.yaml`** (encrypt with SOPS)

Replace the values with your tunnel credentials from the previous step:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-secret
  namespace: cloudflare
type: Opaque
stringData:
  credentials.json: |
    {
      "AccountTag": "YOUR_ACCOUNT_TAG",
      "TunnelSecret": "YOUR_TUNNEL_SECRET",
      "TunnelID": "YOUR_TUNNEL_ID"
    }
```

### 4.5 Create Cloudflare Tunnel ConfigMap

**File: `cloudflare-tunnel-config.yaml`**

**Note**: This ConfigMap is only used if managing routes via ConfigMap instead of Cloudflare Dashboard. When managing routes through the Cloudflare Dashboard (recommended), this config is simplified.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflare
data:
  config.yaml: |
    tunnel: YOUR_TUNNEL_ID
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true
```

### 4.6 Create Cloudflare Tunnel Deployment

**File: `cloudflared-deployment.yaml`**

**Important**: The deployment includes DNS configuration to properly resolve internal Kubernetes service names.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflare
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflare
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      dnsPolicy: ClusterFirst
      dnsConfig:
        searches:
          - longhorn-system.svc.cluster.local
          - svc.cluster.local
          - cluster.local
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        args:
        - tunnel
        - --config
        - /etc/cloudflared/config/config.yaml
        - run
        livenessProbe:
          httpGet:
            path: /ready
            port: 2000
          failureThreshold: 1
          initialDelaySeconds: 10
          periodSeconds: 10
        volumeMounts:
        - name: config
          mountPath: /etc/cloudflared/config
          readOnly: true
        - name: credentials
          mountPath: /etc/cloudflared/creds
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: cloudflared-config
      - name: credentials
        secret:
          secretName: cloudflared-secret
```

### 4.7 Deploy Cloudflare Tunnel

```bash
# Create namespace
kubectl create namespace cloudflare

# Apply secret (replace with your credentials first)
kubectl apply -f cloudflare-tunnel-secret.yaml
# OR if using SOPS:
# sops -d cloudflare-tunnel-secret.yaml | kubectl apply -f -

# Apply config and deployment
kubectl apply -f cloudflare-tunnel-config.yaml
kubectl apply -f cloudflared-deployment.yaml

# Verify deployment
kubectl get pods -n cloudflare

# Check logs - you should see "Registered tunnel connection" messages
kubectl logs -n cloudflare -l app=cloudflared
```

Expected log output:
```
INF Registered tunnel connection connIndex=0 connection=... location=... protocol=quic
INF Registered tunnel connection connIndex=1 connection=... location=... protocol=quic
```

### 4.8 Configure Routes in Cloudflare Dashboard

**Option A: Via Cloudflare Dashboard (Recommended)**

1. Go to **Zero Trust** → **Networks** → **Tunnels**
2. Click on your `k8s-talos-tunnel`
3. Go to **Public Hostname** tab
4. Click **Add a public hostname**
5. Configure:
   - **Subdomain**: `longhorn`
   - **Domain**: `anything4cash.com`
   - **Service**:
     - Type: `HTTP`
     - URL: `http://longhorn-frontend.longhorn-system:80`
   
   **Important**: Use the short service name format `service-name.namespace:port`, NOT the full FQDN. The DNS search domains will complete it properly.

6. Click **Save hostname**

**Option B: Via cloudflared CLI**

```bash
# Route the subdomain to your tunnel
cloudflared tunnel route dns k8s-talos-tunnel longhorn.anything4cash.com
```

Then configure the route in the Cloudflare Dashboard as described above.

### 4.9 Configure Cloudflare Security Settings

For the tunnel to work properly, configure these settings in your Cloudflare dashboard:

1. **SSL/TLS Settings**:
   - Go to **SSL/TLS** → **Overview**
   - Set to **"Full"** or **"Flexible"** (NOT "Full (strict)" since internal services use HTTP)

2. **Security Settings**:
   - Go to **Security** → **Settings**
   - Set **Security Level** to **"Medium"** or **"Essentially Off"** for testing
   - Disable **Bot Fight Mode** if it's blocking legitimate traffic

3. **Verify DNS**:
   - Go to **DNS** → **Records**
   - Verify the CNAME record exists:
     ```
     longhorn CNAME YOUR_TUNNEL_ID.cfargotunnel.com (Proxied)
     ```

### 4.10 Verify Access

```bash
# Test the tunnel
curl -I https://longhorn.anything4cash.com

# You should see HTTP/2 200 OK
```

Access the Longhorn UI in your browser:
```
https://longhorn.anything4cash.com
```

### 4.11 Troubleshooting

If you get a 403 Forbidden:
- Check Cloudflare security settings (WAF, Bot Fight Mode)
- Verify SSL/TLS mode is set to "Full" or "Flexible"
- Check for any Cloudflare Access policies blocking the subdomain

If you see connection timeouts in cloudflared logs:
- Verify the service name format is correct (short name, not FQDN)
- Check that the service exists: `kubectl get svc -n longhorn-system longhorn-frontend`
- Verify DNS resolution in cloudflared pods works correctly

Check cloudflared logs:
```bash
kubectl logs -n cloudflare -l app=cloudflared --tail=50
```

You should see:
```
INF Registered tunnel connection ...
INF Updated to new configuration ...
```

And NOT see:
```
ERR Unable to reach the origin service ...
ERR dial tcp 104.21.x.x:xxxx: i/o timeout
```


