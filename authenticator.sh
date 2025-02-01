#!/bin/sh
exec "${0%/*}/nsupdate.sh" begin "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION"
