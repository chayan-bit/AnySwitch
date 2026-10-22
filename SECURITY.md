# Security policy

## Supported versions

AnySwitch has no numbered releases yet.
Only the latest commit on `main` is supported.

## Reporting a vulnerability

Please do not open a public issue for a security problem.
Use GitHub's private reporting instead: open the repository's **Security** tab and choose **Report a vulnerability**.
If that form is unavailable, open a public issue that asks for a private contact and contains no details of the problem.

Include what you found, how to reproduce it, which commit it affects and what an attacker gains.
You will get an answer within a week, and a fix or a decision as soon as the maintainers can make one.
Credit is given in the fix unless you prefer to stay anonymous.

## What is in scope

- The host (`dm/host`) and the iOS app (`dm/ios`), which run untrusted game code and read game files.
  Memory-safety bugs in the parsers and services that handle file contents, IPC from the game, or network input are in scope.
- The packing and extraction tools (`scripts/`, `dm/tools`, `dm/gfx/tools`) when a crafted NSP, NCA, pack file or patch file can run code, write outside the work folder or read files it should not.
- The dev input channel (`docs/dev-control.md`).
  It exists only in dev builds, binds one local address and needs a random token; a way around that is in scope, a product build that contains it is a bug.
- Secrets or game data that were committed to the repository by mistake.

## What is out of scope

- A game crashing, misrendering or misbehaving.
  File a [bug report](https://github.com/chayan-bit/AnySwitch/issues/new/choose) instead.
- Weaknesses in code that lives under `dm/third_party` and is unmodified from its upstream.
  Report those to the upstream project, and tell us so we can update the copy.
- Anything that needs a jailbroken device or physical access to an unlocked device.

## If you find game files or keys in the repository

Do not copy or repost them.
Report it privately as above so the history can be cleaned.
