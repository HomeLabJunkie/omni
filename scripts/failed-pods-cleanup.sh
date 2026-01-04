#!/bin/bash
# Failed Pods Cleanup script

kubectl get pods --field-selector 'status.phase=Failed' --all-namespaces | awk '{if ($4 != "Running") system ("kubectl -n " $1 " delete pods " $2 )}'
