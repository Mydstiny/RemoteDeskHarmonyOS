# Settings accordion bottom-clipping fix

## Goal

Keep the expanded Data Security and Windows RDP cards fully visible after
their settings rows grow, including the card bottom radius and outer bottom
spacing.

## Scope

- Replace the two stale hard-coded accordion caps with centralized,
  content-derived height policies.
- Account for the Data Security secret-visibility action row.
- Account for the taller stacked RDP selector rows used outside the `md` and
  `lg` breakpoints.
- Add policy tests for every supported breakpoint and future row growth.

No password behavior, RDP transport, input, rendering, persistence, cloud
sync, or protocol settings semantics change.

## Validation

- `default@OhosTestCompileArkTS`
- signed `assembleHap`
- Light open-source compliance
- `git diff --check`
- independent review of the incremental layout-policy scope
