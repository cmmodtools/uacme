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

	unset zone primary
	answer=$("$DIG"${UACME_DIG_KEY:+ -k "$UACME_DIG_KEY"} +noall +nottl +noclass +answer +authority "$name" SOA) || return 1

	while read -r owner type rdata; do
		case "$type" in
		CNAME)
			name=$rdata
			;;
		DNAME)
			[ "$rdata" = . ] && name=${name%$owner} || name=${name%$owner}$rdata
			;;
		SOA)
			zone=$owner
			set -- $rdata && primary=$1
			;;
		esac
	done <<-EOF
		$answer
		EOF

	[ -n "$zone" ] && [ -n "$primary" ] || return 1

	"$NSUPDATE"${UACME_NSUPDATE_KEY:+ -k "$UACME_NSUPDATE_KEY"} -v <<-EOF || return 1
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

	readonly retries=10
	try=0
	while sleep $((1<<try)); do
		case "$action" in
		add)
			is_present $nameservers || { [ $? -gt 1 ] && is_present ;} && return
			;;
		del|delete)
			is_present $nameservers || { [ $? -gt 1 ] && is_present ;} || { [ $? -eq 1 ] && return ;}
			;;
		esac
		[ $try -lt $retries ] || break
		try=$((try+1))
	done

	return 1
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
