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
	    $ZADM create "$@"
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
	/usr/sbin/zoneadm $__ZADM_ZONEADM_ARGS "$@"
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

