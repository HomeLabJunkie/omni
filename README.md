
# Talos Omni template

This is a template for Omni that can be used to create a cluster with a predefined configurations.

## Features

- Enable Kube-Span.
- Disable CNI (flannel).
- Disable Kube-proxy.
- Apply manifests :
    - Install Cilium CNI.
    - Add an IP Pool for Cilium L2 Annoucements.
    - Active Cilium L2 Annoucements.
    - Install Longhorn

## Usage

To use this template, you need to have the Omni CLI installed. You can find the installation instructions [here](https://omni.siderolabs.com/how-to-guides/install-and-configure-omnictl).

To check differences between the template and the current cluster configuration, run:
```bash
omnictl cluster template diff --file template.yaml
```

To apply the template to the cluster, run:
```bash
omnictl cluster template sync --file template.yaml
```
