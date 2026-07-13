# License decision record

The combined RemoteDeskHarmonyOS distribution is licensed under
**GNU Affero General Public License v3.0 or later** (`AGPL-3.0-or-later`).

Rationale: the application statically links and distributes an AGPL RustDesk
bridge. Apache-2.0 project code may be combined into an AGPLv3 work, but a
single Apache-only declaration does not satisfy the obligations of the
combined distribution.

Third-party components are not relicensed. Apache-2.0, BSD, MIT, OpenSSL,
LGPL/GPL and vendor-specific notices remain effective for their respective
files and artifacts. When this record conflicts with an upstream notice, the
upstream notice controls that component.
