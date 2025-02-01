#!/bin/sh
exec "${0%/*}/nsupdate.sh" done "$CERTBOT_DOMAIN" "$CERTBOT_VALIDATION"
