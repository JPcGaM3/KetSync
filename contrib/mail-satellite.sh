#!/usr/bin/env bash
# =============================================================================
#  mail-satellite.sh — point this machine's postfix at an authenticated relay,
#  so `ketsync watch` can hand mail to sendmail and stop thinking about it.
# -----------------------------------------------------------------------------
#  One transport for the whole fleet, chosen deliberately: the tool calls the
#  machine's own sendmail, postfix relays through the provider (SendGrid, or
#  anything speaking authenticated SMTP), and the API key lives in ONE root-
#  readable file per infra machine - never in this repo, never in a customer
#  container, never on an argv where `ps` can read it. The day the provider
#  changes, this script runs again and no tool changes at all.
#
#  Run it BY HAND, once per infra machine, as root:
#
#    ./contrib/mail-satellite.sh --relay '[smtp-relay.brevo.com]:587' \
#                                --user 'b5c6b3001@smtp-brevo.com' \
#                                --keyfile /root/.brevo.key \
#                                [--test you@example.com --from verified@you.com]
#
#  The key file holds the bare secret, one line. The user is whatever the
#  provider's SMTP page shows as the login: Brevo generates one, SendGrid
#  uses the literal word `apikey`. --from must be an address the provider
#  has VERIFIED as a sender - relays reject a From they have never heard
#  of, and a test mail with no From goes out as root@<hostname>, which no
#  provider has.
#
#  Everything has to be said; nothing is defaulted. A relay this script
#  guessed would be a fleet quietly mailing through the wrong provider.
# =============================================================================
set -uo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

LOGSEP='##############################################################################'
hr(){  printf '%s\n' "$LOGSEP"; }
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*"; }
die(){ log "ERROR: $*"; exit 2; }

RELAY=""; SMTPUSER=""; KEYFILE=""; TESTTO=""; FROMADDR=""
while (( $# )); do
  case "$1" in
    --relay)   RELAY="${2:-}";    shift 2 || die "--relay needs a value";;
    --user)    SMTPUSER="${2:-}"; shift 2 || die "--user needs a value";;
    --keyfile) KEYFILE="${2:-}";  shift 2 || die "--keyfile needs a value";;
    --test)    TESTTO="${2:-}";   shift 2 || die "--test needs an address";;
    --from)    FROMADDR="${2:-}"; shift 2 || die "--from needs an address";;
    *) die "unknown argument '$1' - see the header of this script";;
  esac
done

[[ -n "$RELAY" ]]    || die "say --relay '[host]:port' - nothing is defaulted here"
[[ -n "$SMTPUSER" ]] || die "say --user (for SendGrid it is the literal word: apikey)"
[[ -n "$KEYFILE" ]]  || die "say --keyfile <path> - the key travels in a file, never on argv"
[[ -r "$KEYFILE" ]]  || die "cannot read $KEYFILE"
[[ -s "$KEYFILE" ]]  || die "$KEYFILE is empty - that would configure a relay that rejects everything"
[[ "$(id -u)" == 0 ]] || die "this rewrites /etc/postfix - run it as root"
if [[ -n "$TESTTO" && -z "$FROMADDR" ]]; then
  die "--test needs --from <address the provider has VERIFIED as a sender> - without it the mail goes out as root@$(hostname 2>/dev/null || echo '?'), which every relay rejects"
fi

for c in postconf postmap systemctl sendmail; do
  command -v "$c" >/dev/null || die "$c is missing - install postfix first (apt-get install postfix, choose 'Satellite system')"
done
# postfix's smtp client does the AUTH, and on a minimal install (PVE included)
# the SASL plugins it needs are a separate package. Without them every attempt
# ends in "SASL authentication failed ... no mechanism available" - AFTER the
# queue has already accepted the mail, which is the silent half. Found the hard
# way on this fleet; refused here, before anything is configured.
ls /usr/lib/*/sasl2/libplain*.so* >/dev/null 2>&1 \
  || die "libsasl2-modules is missing - postfix cannot AUTH to any relay. Fix: apt-get install -y libsasl2-modules"

KEY="$(head -1 "$KEYFILE")"

hr
log "postfix -> $RELAY as $SMTPUSER (key from $KEYFILE)"

# The map postfix reads the credential from. 0600 before the secret goes in,
# not after - the window where a world-readable file holds a key is exactly
# the kind of window this fleet exists to not have.
install -m 0600 /dev/null /etc/postfix/sasl_passwd
printf '%s %s:%s\n' "$RELAY" "$SMTPUSER" "$KEY" > /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
chmod 0600 /etc/postfix/sasl_passwd.db 2>/dev/null || true

postconf -e "relayhost = $RELAY"
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_tls_security_level = encrypt"
# A satellite relays and receives nothing: nothing on this machine should be
# reachable by mail, and an open listener on an infra node is one more door.
postconf -e "inet_interfaces = loopback-only"

systemctl reload postfix 2>/dev/null || systemctl restart postfix \
  || die "postfix would not reload - read 'systemctl status postfix' before trusting any alert"

log "postfix is a satellite now - every sendmail on this machine relays through $RELAY"

if [[ -n "$TESTTO" ]]; then
  hr
  log "test mail -> $TESTTO (watch the provider's activity log, not just this exit code)"
  {
    printf 'From: %s\n' "$FROMADDR"
    printf 'To: %s\n' "$TESTTO"
    printf 'Subject: [ketsync] mail-satellite test from %s\n' "$(hostname 2>/dev/null || echo '?')"
    printf '\nIf you can read this, %s relays through %s.\n' "$(hostname 2>/dev/null || echo '?')" "$RELAY"
  } | sendmail -t -i -f "$FROMADDR" || die "sendmail refused the test mail - the relay is not working yet"
  log "if nothing arrives: journalctl -u postfix -n 30 has the provider's answer"
  log "  535 = wrong user/key . 550 sender = --from is not a VERIFIED sender there"
  log "handed to postfix - delivery is the provider's half; check the inbox"
fi
hr
log "done. Point ketsync watch at this transport by setting KS_MAIL_* in conf/ketsync.conf"
