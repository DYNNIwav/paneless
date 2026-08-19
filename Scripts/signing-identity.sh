#!/bin/bash
# Resolve a signing certificate to its hash, for anything that calls codesign.
#
# A team can hold several Developer ID Application certificates and every one of them
# carries the exact same common name, so `codesign -s <name>` bails out with
# "ambiguous (matches ...)". Hashes are unambiguous, and preferring the certificate
# that stays valid longest means a renewal gets used without an edit here.

paneless_developer_id_hash() {
  local valid
  valid="$(security find-identity -v -p codesigning \
    | awk '/Developer ID Application/ { printf "%s ", $2 }')"
  [ -n "$valid" ] || return 0
  security find-certificate -a -c "Developer ID Application" -Z -p 2>/dev/null \
    | awk -v valid="$valid" '
      /^SHA-1 hash:/ { hash = $3 }
      /^-----BEGIN/  { pem = ""; in_pem = 1 }
      in_pem         { pem = pem $0 "\n" }
      /^-----END/    {
        in_pem = 0
        tmp = "/tmp/.paneless-signing-cert.pem"
        printf "%s", pem > tmp
        close(tmp)
        cmd = "openssl x509 -in " tmp " -noout -enddate | cut -d= -f2 | tr -s \" \""
        cmd | getline expiry
        close(cmd)
        cmd = "date -j -f \"%b %d %H:%M:%S %Y %Z\" \"" expiry "\" +%s 2>/dev/null"
        cmd | getline epoch
        close(cmd)
        if (epoch != "" && index(valid, hash) > 0) print epoch, hash
      }
    ' | sort -rn | head -1 | cut -d' ' -f2
}

paneless_apple_development_hash() {
  security find-identity -v -p codesigning \
    | awk '/Apple Development/ { print $2; exit }'
}
