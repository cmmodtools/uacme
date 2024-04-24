#!/bin/sh
exec "${0%/*}/nsupdate.sh" begin dns-01 "$CERTBOT_DOMAIN" "" "$CERTBOT_VALIDATION"
