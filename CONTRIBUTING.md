# Contributing

Start with [STATUS.md](STATUS.md), [build instructions](docs/building.md), and [graphics notes](docs/graphics.md). Run `./script/test_core.sh` after core, protocol, or input changes. Explain the behavior change, reproduction steps, tests run, and remaining guest-validation limits in a pull request.

Keep changes scoped to Astra, its VM engine, viewer, and owned graphics implementation. Preserve VM identity and disk/firmware/TPM together. Do not edit game or launcher files, weaken Windows security, or silently turn graceful shutdown into forced power-off. Clipboard sharing must remain opt-in, bounded, and foreground-only.

Never commit credentials, cookies, signing keys/certificates, personal usernames or paths, VM data, runtime binaries, game captures, or diagnostic logs. Review issue attachments locally before sharing. Run `python3 script/check_public_source.py` before publication; its static checks are an aid and do not replace review.

Graphics trees contain unshipped experiments. Reconstruct and qualify candidates in separate workspaces, retain the accepted binaries, and report source/hash checks separately from live Windows or performance results.

Third-party notices must remain intact. Original contributions use the root MIT license; changes to third-party components follow those components' upstream licenses.
