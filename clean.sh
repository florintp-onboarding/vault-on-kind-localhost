#!/bin/bash
#
rm -rf vault-data
rm -f vault.hcl vault.log init-keys.json

vpid=$(pgrep -o vault) && kill $vpid
