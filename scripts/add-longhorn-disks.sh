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
