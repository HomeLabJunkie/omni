
# Talos Omni template

This is a template for Omni that can be used to create a 6-node cluster (3 ControlPlane and 3 Worker) with a predefined configurations.

## Features

- Enable Kube-Span.
- Disable CNI (flannel).
- Disable Kube-proxy.
- Apply manifests :
    - Install Cilium CNI.
    - Add an IP Pool for Cilium L2 Annoucements.
    - Active Cilium L2 Annoucements.
    - Install Longhorn and add 1 additional disk per node

## Usage

To use this template, you need to have the Omni CLI installed. You can find the installation instructions [here](https://omni.siderolabs.com/how-to-guides/install-and-configure-omnictl).

To check differences between the template and the current cluster configuration, run:
```bash
omnictl cluster template diff --file k8s-cluster-template.yaml
```

To apply the template to the cluster, run:
```bash
omnictl cluster template sync --file k8s-cluster-template.yaml
```
![image](https://github.com/user-attachments/assets/c169fc6a-eb86-41a5-979f-6761006190bc)


![image](https://github.com/user-attachments/assets/d57dbfbd-b3b7-413a-9ccb-bfaa955d2238)
