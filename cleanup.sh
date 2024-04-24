#!/bin/sh
exec "${0%/*}/nsupdate.sh" done dns-01 "$CERTBOT_DOMAIN" "" "$CERTBOT_VALIDATION"
