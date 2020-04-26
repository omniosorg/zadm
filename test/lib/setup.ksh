#/!/bin/ksh

# Copyright 2020 OmniOS Community Edition (OmniOSce) Association.

[ -n "$_ZADMTEST_LIB_SETUP" ] && return
_ZADMTEST_LIB_SETUP=1

# The temporary dataset to use for disk volumes and zone roots
dataset=rpool/zadmtest
# and its mount point
datasetmp=/zadmtestds
# The temporary etherstub on which zone VNICs will be created
etherstub=zadmtest0
# A VNIC for the GZ
vnic=zadmgz0
# The GZ IP address that will be created on the test etherstub
testip=172.20.111.254/24
# The network prefix for zone addresses
testnet=172.20.111

brands="ipkg lipkg sparse pkgsrc illumos kvm bhyve lx"

