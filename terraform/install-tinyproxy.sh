#!/bin/bash
sudo apt-get update
sudo apt-get install tinyproxy azure-cli -y
sudo echo "Allow 10.0.0.0/8" >> /etc/tinyproxy/tinyproxy.conf
systemctl restart tinyproxy
sudo az aks install-cli
