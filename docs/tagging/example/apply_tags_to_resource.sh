#!/bin/bash



az resource update \
  --ids /subscriptions/<sub-id>/resourceGroups/<rg-name>/providers/<resource-type>/<resource-name> \
  --set tags=@tags.json

