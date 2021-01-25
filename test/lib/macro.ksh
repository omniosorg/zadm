#/!/bin/ksh

# Copyright 2020 OmniOS Community Edition (OmniOSce) Association.

[ -n "$_ZADMTEST_LIB_MACRO" ] && return
_ZADMTEST_LIB_MACRO=1

logf=`mktemp`

c_highlight="`tput setaf 2`"
c_error="`tput setaf 1`"
c_note="`tput setaf 6`"
c_reset="`tput sgr0`"

function note {
	echo "$c_note"
	echo "***"
	echo "*** $*"
	echo "***"
	echo "$c_reset"
}

function zadm {
	$ZADM "$@"
}

function zadmshow {
	typeset zone="${1:?zone}"; shift

	$ZADM show $zone | tokenise
}

function zadmcreate {
	typeset sf=`mktemp`

	echo :wq > $sf
	VISUAL=/usr/bin/vim __ZADM_EDITOR_ARGS="-u NONE -n -s $sf" \
	    $ZADM create "$@" 2>&1 |&
	pid=$!
	expect $pid 'with all defaults'
	print -p "yes\n"
	wait $pid
	ret=$?
	rm -f $sf
	return $ret
}

function zadmedit {
	typeset -i rollback=1

	# Flags
	if [[ "$1" = -* ]]; then
		[[ $1 = *n* ]] && rollback=0
		dlog "Rollback: $rollback"
		shift
	fi

	typeset zone="${1:?zone}"; shift

	[ ! -f $zadmroot/etc/zones/$zone.xml ] && echo "No such zone" && exit 1

	typeset sf=`mktemp`
	typeset tmpf=`mktemp`

	echo :sleep 1 > $sf
	echo "$*" >> $sf
	sed -i 's/\^\[//g' $sf

	cp $zadmroot/etc/zones/$zone.xml $tmpf

	VISUAL=/usr/bin/vim __ZADM_EDITOR_ARGS="-u NONE -n -s $sf" \
	    $ZADM edit $zone
	ret=$?
	[ $ret -ne 0 -a $rollback -eq 1 ] \
	    && cp $tmpf $zadmroot/etc/zones/$zone.xml
	rm -f $sf $tmpf
	return $ret
}

function validate {
	typeset zone="${1:?zone}"
	typeset tag="${2:?tag}"
	tag="validate $zone $tag"

	if [ ! -f $zadmroot/etc/zones/$zone.xml ]; then
		result "$tag" "ZONE MISSING"
		return 1
	fi

	if zadmedit $zone :wq; then
		result "$tag" "PASS"
		return 0
	else
		result "$tag" "SAVE ERROR"
		return 1
	fi
}

function zoneadm {
	typeset -i z=0
	typeset zone=
	typeset last=
	for last in "$@"; do
		[ "$z" -eq 1 ] && zone=$last && z=0
		[ "$last" = "-z" ] && z=1
	done
	echo "zoneadm ($zone) - last=[$LAST]" >> /dev/stderr
	case "$last" in
		install)	zone_state $zone installed ;;
		uninstall)	zone_state $zone configured ;;
		*)		/usr/sbin/zoneadm $__ZADM_ZONEADM_ARGS "$@" ;;
	esac
}

function zonecfg {
	/usr/sbin/zonecfg $__ZADM_ZONECFG_ARGS "$@"
}

function result {
	typeset name="$1"
	typeset status="$2"

	[ "$status" = PASS ] && cc="$c_highlight" || cc="$c_error"

	printf "%-40s - %s%s%s\n" "$name" "$cc" "$status" "$c_reset" \
	    | tee -a $logf
}

function results {

	[ "_ZADM_ENVIRONMENT_STARTED" -gt 1 ] && return

	echo "****************************************************************"
	echo "** Test results"
	echo "****************************************************************"
	cat $logf
	rm -f $logf
}

function compare {
	typeset name="$1"
	typeset output="$2"
	typeset expected="$3"

	noutput=`mktemp`
	nexpected=`mktemp`

	sed "s^$zadmroot^^g" < "$output" > "$noutput"
	sed "s^$zadmroot^^g" < "$expected" > "$nexpected"

	if cmp -s "$noutput" "$nexpected"; then
		result "$name" PASS
	else
		result "$name" FAIL
		gdiff -u $nexpected $noutput
	fi
	rm -f $noutput $nexpected
}

function expect {
	typeset -i debug=0
	[ "$1" = "-d" ] && debug=1 && shift
	typeset -i pid="$1"; shift
	typeset pattern="$@"

	typeset -i notseen=1
	typeset line

	[ $debug -eq 1 ] && echo "DEBUG: waiting for $pattern"
	while read -p -t 5 line; do
		[ $debug -eq 1 ] && echo "DEBUG: line - $line"
		if echo $line | egrep -s "$pattern"; then
			[ $debug -eq 1 ] && echo "DEBUG: Saw - $pattern"
			notseen=0
			break
		fi
		kill -0 $pid || break
	done
	return $notseen
}

