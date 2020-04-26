#/!/bin/ksh

# Copyright 2020 OmniOS Community Edition (OmniOSce) Association.

[ -n "$_ZADMTEST_LIB_TESTENV" ] && return
_ZADMTEST_LIB_TESTENV=1

. lib/setup.ksh
. lib/macro.ksh

nocleanup=0
debug=0

function dlog {
	[ $debug -gt 0 ] || return 0
	echo "+ $*"
}

function delete_dataset {
	zfs destroy -r $dataset 2>/dev/null
}

function setup_dataset {
	delete_dataset >/dev/null 2>&1
	dlog "Creating ZFS dataset $dataset"
	set -e
	zfs create -o mountpoint=$datasetmp $dataset
	set +e
}

function delete_net {
	ipadm delete-addr $vnic/v4
	ipadm delete-if $vnic
	dladm show-vnic -p -o link,over | grep ":$etherstub\$" \
	    | cut -d: -f1 | xargs -i dladm delete-vnic {}
	dladm delete-etherstub $etherstub
}

function setup_net {
	delete_net >/dev/null 2>&1
	dlog "Creating etherstub $etherstub"
	set -e
	dladm create-etherstub $etherstub
	dlog "Creating GZ VNIC $vnic - $testip"
	dladm create-vnic -l $etherstub $vnic
	ipadm create-if $vnic
	ipadm create-addr -T static -a local=$testip $vnic/v4
	set +e
}

function detokenise {
	sed "
		s^__ZADMROOT__^$zadmroot^g
		s^__GLOBALNIC__^$etherstub^g
		s^__NET__^$testnet^g
		s^__IP__^${testip%/*}^g
		s^__DATASET__^$dataset^g
	"
}

function tokenise {
	sed "
		s^$zadmroot^__ZADMROOT__^g
		s^$etherstub^__GLOBALNIC__^g
		s^$testnet^__NET__^g
		s^$testip^__IP__^g
		s^$dataset^__DATASET__^g
	"
}

function setup_root {
	set -e
	zfs create $dataset/root
	zfs create $dataset/root/zones
	zadmroot=$datasetmp/root
	dlog "Creating test root at $zadmroot"
	mkdir -p $zadmroot/etc/zones
	mkdir -p $zadmroot/var/run

	zadmindex=$zadmroot/etc/zones/index
	cp /etc/zones/SUNW*.xml $zadmroot/etc/zones/
	cp /etc/zones/OMNI*xml $zadmroot/etc/zones/

	echo global:installed:/ > $zadmindex

	mkfile 1m $zadmroot/test.iso
	set +e
}

function cleanup_root {
	:
}

function create_zone {
	typeset zone="${1:?zone}"
	typeset brand="${2:?brand}"

	zonecfg -z "$zone" delete -F 1>/dev/null 2>&1

	zonecfg -z "$zone" "
		create -t $brand
		set zonepath=$zadmroot/zones/$zone
		set limitpriv=default
		exit"

	sed -i "/^$zone:/s/configured/installed/" $zadmroot/etc/zones/index
}

function zone_state {
	typeset zone="${1:?zone}"
	typeset state="${2:?state}"

	sed -i "/^$zone:/s/:[^:]*/:$state/" $zadmroot/etc/zones/index
}

function start_environment {
	[ "`zonename`" != global ] && echo "Must be run in the GZ" && exit 1

	[ -z "_ZADM_ENVIRONMENT_STARTED" ] && _ZADM_ENVIRONMENT_STARTED=0
	(( _ZADM_ENVIRONMENT_STARTED++ ))

	[ "$_ZADM_ENVIRONMENT_STARTED" -gt 1 ] && return

	setup_dataset
	setup_net
	setup_root

	export __ZADMTEST=1
	export __ZADM_ALTROOT=$zadmroot
	export __ZADM_ZONECFG_ARGS="-R $zadmroot"
	export __ZADM_ZONEADM_ARGS="-R $zadmroot"
	export ZADM=../bin/zadm
}

function stop_environment {
	(( _ZADM_ENVIRONMENT_STARTED-- ))
	[ "$_ZADM_ENVIRONMENT_STARTED" -eq 0 ] || return
	if [ $nocleanup -eq 0 ]; then
		cleanup_root
		delete_dataset
		delete_net
	fi
	results
}

function usage {
	cat <<- EOM
	Usage: $0 [-dk]
	    -d	Enable debug mode
	    -k	Keep (do not cleanup) test data (dataset, vnics etc)
	EOM
	exit 1
}

while getopts dk name; do
	case $name in
	    d)		((debug++)); export __ZADMDEBUG=1 ;;
	    k)		nocleanup=1 ;;
	    ?)		usage ;;
	esac
done
shift $(($OPTIND - 1))

