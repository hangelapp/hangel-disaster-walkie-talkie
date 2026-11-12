# Security policy

This plugin is used in emergencies, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report privately by either:

* GitHub: **Security → Report a vulnerability** on this repository (private vulnerability reporting), or
* e-mail **info@socialbusinessglobal.org** with the subject `SECURITY: hangel-disaster-walkie-talkie`.

Include affected versions/platforms, steps to reproduce, impact and, if possible, a proof of concept. You may write in English or
Turkish.

We aim to acknowledge reports within 7 days and to agree on a disclosure date with you (normally within 90 days). We will credit
you in the release notes unless you prefer otherwise. We cannot offer a bug bounty.

## Scope and known limitations (not vulnerabilities)

These are documented design limits, see README → Privacy and Limitations:

* Channel content is encrypted with a key derived from a public constant and the channel id; anyone who knows the channel id can
  read it. Mesh v3 messages (presence, help calls, invitations) and announcements are plain text.
* There is no sender authentication; names and messages can be spoofed.
* Bluetooth LE links are not paired or encrypted at the link layer.

Reports that show these limits causing a **new** kind of harm (for example remote code execution, crashes reachable from radio
input, denial of service of the whole mesh, de-anonymisation beyond the masked name and location, battery drain attacks) are in scope.

## Supported versions

Only the latest release on the `main` branch receives fixes.
