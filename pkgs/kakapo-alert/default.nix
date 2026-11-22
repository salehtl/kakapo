# kakapo-alert: the one way kakapo's own units alert Saleh, so every alert has
# the same title, levels and channels (modules/notify.nix, dns-health in
# modules/services/adguard.nix).
#
#   kakapo-alert LEVEL SOURCE SUBJECT [--mail] [--click URL] < BODY
#
# Title:  [kakapo] LEVEL SOURCE: SUBJECT     (mail subject the same)
#
# | LEVEL | ntfy priority      | mail                          |
# |-------|--------------------|-------------------------------|
# | fail  | high               | yes                           |
# | warn  | default            | no                            |
# | ok    | low                | only with --mail (a recovery  |
# |       |                    | from a mailed fail)           |
# | info  | low                | no                            |
#
# The push carries the first 20 lines of BODY (ntfy keeps 4 KiB); the mail
# carries all of it. Exit 0 when the alert reached Saleh: the mail when one is
# sent (it is the path that works while the house network or ntfy is down),
# else the push. A caller that keeps state retries on exit 1.
{
  writeShellApplication,
  curl,
  msmtp,
  coreutils,
  hostName,
  mailTo,
}:
writeShellApplication {
  name = "kakapo-alert";
  runtimeInputs = [
    curl
    msmtp
    coreutils
  ];
  text = ''
    usage() { echo "usage: kakapo-alert fail|warn|ok|info SOURCE SUBJECT [--mail] [--click URL] < BODY" >&2; exit 64; }
    [ $# -ge 3 ] || usage
    level=$1 source=$2 subject=$3
    shift 3
    mail=0 click=
    while [ $# -gt 0 ]; do
      case "$1" in
        --mail) mail=1 ;;
        --click) click=''${2:?--click needs a URL}; shift ;;
        *) usage ;;
      esac
      shift
    done
    case "$level" in
      fail) prio=high tags=rotating_light mail=1 ;;
      warn) prio=default tags=warning ;;
      ok) prio=low tags=white_check_mark ;;
      info) prio=low tags=information_source ;;
      *) usage ;;
    esac
    body=
    [ -t 0 ] || body=$(cat)
    [ -n "$body" ] || body=$subject
    title="[${hostName}] ''${level^^} $source: $subject"

    headers=(-H "Title: $title" -H "Priority: $prio" -H "Tags: $tags")
    [ -n "$click" ] && headers+=(-H "Click: $click")
    pushed=0
    if printf '%s\n' "$body" | head -n 20 | head -c 3500 |
      curl -fsS --max-time 10 --retry 2 -o /dev/null "''${headers[@]}" --data-binary @- \
        http://127.0.0.1:2586/kakapo; then
      pushed=1
    else
      echo "kakapo-alert: ntfy push failed" >&2
    fi

    if [ "$mail" = 1 ]; then
      if {
        printf 'To: %s\nFrom: %s\nSubject: %s\n\n' "${mailTo}" "${mailTo}" "$title"
        printf '%s\n\n-- \n%s on %s, %s\n' "$body" "$source" "${hostName}" "$(date -Iseconds)"
      } | msmtp -t; then
        exit 0
      fi
      echo "kakapo-alert: mail failed" >&2
      exit 1
    fi
    [ "$pushed" = 1 ]
  '';
}
