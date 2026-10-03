# CURRENT.md archive (2026-10-04)

Moved verbatim from `docs/codex/CURRENT.md` to keep the short card within 120 lines.

- M5 final gates: testCompile BUILD SUCCESSFUL in 24 s 782 ms; signed Debug BUILD SUCCESSFUL in 36 s 942 ms; Release BUILD SUCCESSFUL in 49 s 746 ms. Light/diff and Runtime pruning independently PASS. ABC 1211b5ab54a2090731ee37b3836aa89a14d7a2221e054ed11a1c6e1267d6a9db; shared HAP included unreviewed M6 work, outside M5 review.
- M5 PC current gates: testCompile 19 s 518 ms, signed Debug 24 s 154 ms, Release 36 s 906 ms, exit 0; independent Light/diff/Release pruning PASS. ABC 05f4687700cf203ae6e212e1cf8bebadfd2d1cee7a816af279930ceb885c3449. Exact 3fc4a578 independent review PASS; real PC/system acceptance pending.
- M5 RDP current gates: testCompile 4 s 909 ms; signed Debug 1 min 3 s 383 ms (SignHap 877 ms); Release 32 s 723 ms (SignHap 949 ms), exit 0. Independent Light/diff/actual Release pruning PASS; ABC 54043c4f4eb725ea4a0f38c3de5e9af7cb1eaf005482c2b0cb6830cb87f3df31. Production pipeline 2084838 and snapshot 9632 observations, both ABI syntax and five ARM64 fence sites independently PASS; device EGL is unverified. Review-record gates: compile 5 s 349 ms, signed 6 s 198 ms (SignHap 942 ms), Light/diff/state PASS; four identical generated resource duplicates were removed.
