#!/bin/sh
exec "${0%/*}/nsupdate.sh" -c /usr/local/etc/certbot/nsupdate.conf done "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION"
