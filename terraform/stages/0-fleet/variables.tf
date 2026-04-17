# stages/0-fleet variables.
#
# Fleet identity is sourced from clusters/_fleet.yaml (see main.tf locals).
# Stage 0 is currently fully parameterless — everything it needs lives in
# that file. If/when tflint flags this as empty we will add it back via a
# real input (cluster inventory override, rotation TTL, etc.).
