# highlight.sh — colorize demo output for the terminal recording (act1.tape).
#
#   Skyflow tokens  ([NAME_x], [DRUG_y], [HEALTHCARE_NUMBER_z] …)  -> green
#   raw PII         (the values in $HL_SENSITIVE, pipe-delimited)  -> red
#
# Source this, then pipe any beat through `hi`:  curl … | jq -r … | hi
# The raw-PII list comes from the scenario file ($HL_SENSITIVE), read from the
# environment at call time — so re-skinning the scenario re-skins the highlighting
# with nothing to change here.
hi() {
  perl -pe '
    BEGIN {
      my $p = $ENV{HL_SENSITIVE} // "";
      $PII = join "|", map { quotemeta } grep { length } split /\|/, $p;
    }
    s/(\[[A-Za-z0-9_]+\])/\e[1;32m$1\e[0m/g;          # Skyflow tokens -> green
    s/($PII)/\e[1;31m$1\e[0m/g if $PII;               # raw PII        -> red
  '
}
