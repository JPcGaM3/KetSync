#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync mail-setup — point this machine's postfix at the relay the conf
#  names, so changing mail provider is a conf edit plus one command.
# -----------------------------------------------------------------------------
#  The engine is contrib/mail-satellite.sh, unchanged: it can still be run by
#  hand with explicit flags, and doing so is still correct. What this verb
#  adds is WHERE the answers live. A relay typed on a command line is correct
#  once; the same relay in conf/ketsync.conf, next to the addresses that use
#  it, is the machine's mail transport written down - and the day the
#  provider changes, the edit and the command that applies it are one file
#  and one line of shell history apart.
#
#  What lives where, and why:
#
#    KS_MAIL_RELAY    '[host]:port'  which provider carries the mail
#    KS_MAIL_USER     login          whatever the provider's SMTP page shows:
#                                    Brevo generates one, SendGrid uses the
#                                    literal word apikey
#    KS_MAIL_KEYFILE  path           the PATH to the key, never the key.
#                                    ketsync.conf is read by every verb,
#                                    quoted in bug reports, and copied places
#                                    a secret must not travel. The key itself
#                                    stays in one root-readable file per
#                                    machine, exactly as before.
#
#  --test sends the proof mail to KS_MAIL_INFRA from KS_MAIL_FROM - the same
#  addresses watch uses, which is the point: a test that arrives proves the
#  path watch's own mail will take, not some other path.
#
#  Per machine, like the script it drives: postfix is machine config. Run it
#  ON the master and ON the backup node, not once from one of them.
# =============================================================================
cmd_mail_setup(){
  local dotest=0 a
  for a in "$@"; do
    case "$a" in
      --test) dotest=1;;
      *) say "refused: unknown argument '$a' - mail-setup takes only --test"
         say "  the relay, user and keyfile come from conf/ketsync.conf, not from flags."
         return 2;;
    esac
  done

  # Everything has to be said. An empty relay is not "no relay", it is an
  # unanswered question, and the answer belongs in the conf where the next
  # operator can read it - so every missing key is named in ONE refusal
  # rather than being discovered one run at a time.
  local -a missing=()
  [[ -n "${KS_MAIL_RELAY:-}"   ]] || missing+=(KS_MAIL_RELAY)
  [[ -n "${KS_MAIL_USER:-}"    ]] || missing+=(KS_MAIL_USER)
  [[ -n "${KS_MAIL_KEYFILE:-}" ]] || missing+=(KS_MAIL_KEYFILE)
  if (( dotest )); then
    [[ -n "${KS_MAIL_FROM:-}"  ]] || missing+=(KS_MAIL_FROM)
    [[ -n "${KS_MAIL_INFRA:-}" ]] || missing+=(KS_MAIL_INFRA)
  fi
  if (( ${#missing[@]} )); then
    say "refused: conf/ketsync.conf is missing: ${missing[*]}"
    say "  mail-setup reads the relay from the conf so that changing provider is an"
    say "  edit there plus this one command - see the mail block in ketsync.conf.sample."
    return 2
  fi

  local SAT="$KS_BASE/contrib/mail-satellite.sh"
  if [[ ! -x "$SAT" ]]; then
    say "ERROR: $SAT is missing or not executable - NOTHING was run"
    say "ERROR:   contrib/ is committed in this repo, so this is a broken checkout"
    say "ERROR:   rather than a clone step somebody skipped."
    return 2
  fi

  declare -a ARGS=(--relay "$KS_MAIL_RELAY" --user "$KS_MAIL_USER" --keyfile "$KS_MAIL_KEYFILE")
  (( dotest )) && ARGS+=(--test "$KS_MAIL_INFRA" --from "$KS_MAIL_FROM")
  # exec: the script's exit code is the contract, and nothing this layer could
  # usefully do after postfix has been rewritten is worth a chance of losing it.
  exec "$SAT" "${ARGS[@]}"
}
