#!/bin/sh
#
#  Copyright (C) 2023-2025 Michal Roszkowski
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2, or (at your option)
#  any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software Foundation,
#  Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

# Commands
DIG=dig
NSUPDATE=nsupdate

# Config
CONFIG_FILE=${0%.*}.conf

readonly E_BADARGS=85

while getopts c: arg; do
	case $arg in
	c)	CONFIG_FILE=$OPTARG;;
	?)	exit $E_BADARGS
	esac
done
shift $(($OPTIND-1))

. "$CONFIG_FILE"

if [ $# -eq 3 ]; then
	set -- "$1" dns-01 "$2" "$3"
elif [ $# -eq 5 ]; then
	set -- "$1" "$2" "$3" "$5"
elif [ $# -ne 4 ]; then
	printf "Usage: %s [-c config] begin|done|failed [dns-01] ident [ignored] auth\n" "${0##*/}" >&2
	exit $E_BADARGS
fi

readonly AUTH=$4
name=_acme-challenge.${3%.}.

is_present()
{
	rc=2
	unset queries
	for ns in ${@:-""}; do (
		answer=$("$DIG"${UACME_DIG_KEY:+ -k "$UACME_DIG_KEY"}${ns:+ "@$ns" +norecurse} +noall +nottl +noclass +answer "$name" TXT) || return 2

		while read -r owner type rdata; do
			[ "$type" = TXT ] && [ "$rdata" = "\"$AUTH\"" ] && return
		done <<-EOF
			$answer
			EOF

		return 1) &
		queries="$queries $!"
	done

	for query in $queries; do
		wait $query
		rc=$(($?>1? rc : rc&1|$?))
	done

	return $rc
}

do_nsupdate()
{
	readonly action=$1

	case "$action" in
	add)		readonly wanted=0;;
	del|delete)	readonly wanted=1;;
	*)		return 1
	esac

	unset zone primary
	answer=$("$DIG"${UACME_DIG_KEY:+ -k "$UACME_DIG_KEY"} +noall +nottl +noclass +answer +authority "$name" SOA) || return 2

	while read -r owner type rdata; do
		case "$type" in
		CNAME)
			name=$rdata
			;;
		DNAME)
			[ "$rdata" = . ] && name=${name%$owner} || name=${name%$owner}$rdata
			;;
		SOA)
			set -- $rdata
			readonly name zone=$owner primary=$1 timeout=$(($4+$5)) negttl=$(($7>0? $7 : 1))
			;;
		esac
	done <<-EOF
		$answer
		EOF

	[ -n "$zone" ] && [ -n "$primary" ] || return 2

	"$NSUPDATE"${UACME_NSUPDATE_KEY:+ -k "$UACME_NSUPDATE_KEY"} -v <<-EOF || return 3
		server ${UACME_NSUPDATE_SERVER:-$primary} $UACME_NSUPDATE_PORT
		zone $zone
		update $action $name 0 IN TXT "$AUTH"
		send
		EOF

	unset nameservers
	answer=$("$DIG"${UACME_DIG_KEY:+ -k "$UACME_DIG_KEY"} +noall +nottl +noclass +answer "$zone" NS)

	while read -r owner type rdata; do
		[ "$type" = NS ] && nameservers="$nameservers $rdata"
	done <<-EOF
		$answer
		EOF

	(trap 'exit=$?; kill $(jobs -p); exit $exit' TERM
	interval=1
	until
		is_present $nameservers || { [ $? -gt 1 ] && is_present ;}
		[ $? -eq $wanted ]
	do
		sleep $interval & wait $!
		interval=$((interval<<1<negttl? interval<<1 : negttl))
	done) & check=$!

	(trap 'kill $(jobs -p); exit' TERM
	sleep "${UACME_PROPAGATION_TIMEOUT:-$timeout}" & wait $!
	kill $check 2>/dev/null) &

	wait $check || return 3
	kill $! 2>/dev/null
	return 0
}

case "$1" in
begin)
	[ "$2" = dns-01 ] && do_nsupdate add
	;;
done|failed)
	[ "$2" = dns-01 ] && do_nsupdate delete
	;;
*)
	printf "%s: invalid method\n" "${0##*/}" >&2
	exit $E_BADARGS
esac
