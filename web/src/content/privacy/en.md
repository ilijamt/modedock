---
title: "Privacy · ModeDock"
description: "What ModeDock's optional, anonymous usage data holds, what it never collects, and how to turn it off."
---

# Privacy

ModeDock works without sending anything. If you agree, it sends anonymous counts of the features you use. They tell me what to improve.

## Off until you say yes

On first launch ModeDock asks: *Share anonymous usage data?* Nothing is sent unless you choose Share. You can change this any time in Settings → General.

## What is sent

About every 8 hours, and only if something was counted:

- How often you used each feature, like opening the panel or changing brightness. Only the count, never what was on screen.
- How ModeDock is set up, like how many profiles and external screens you have. Never their names.
- The app and macOS version, the app's language, and whether the Mac is Apple silicon or Intel.
- A random install ID. It's made when you opt in and deleted when you opt out, and it isn't tied to you, your Mac or your Apple account.

To see a report exactly as it's sent, use Show Data… in Settings → General.

## What the server adds

The day the report arrived and your country. Cloudflare, which runs the server, looks up the country. The server doesn't read or store your IP address, and its logs are off.

## What is never collected

- Your name, email, Apple account or anything you type
- IP addresses, serial numbers or other hardware IDs
- Names of screens, profiles or files, and file contents
- Screenshots or anything on your screens

## Where it's kept

In a Cloudflare database in the European Union, through `telemetry.modedock.app`. Only the ModeDock maintainer can read it.

## What is made public

The home page shows totals for the last 30 days: active installs, the most used features, macOS versions and countries. Each number covers at least 5 installs, so nobody can be picked out. Install IDs and single reports are never published.

## Turning it off

Uncheck Share anonymous usage statistics in Settings → General. ModeDock stops sending and deletes its install ID and its counts. If you turn it back on, you get a new install ID.

To delete reports already sent, open an issue on [GitHub](https://github.com/ilijamt/modedock/issues) with the install ID shown in Show Data…, before you turn sharing off.

## Update checks

About once a day ModeDock asks GitHub, where its releases are, whether there's a new version. The
request only carries the app's version. Turn it off in Settings → General → Updates.

## Permissions

ModeDock needs macOS permission for three features, and asks the first time you use each one.

- Accessibility lets the brightness keys change every screen. ModeDock only asks for it if you turn that on in Settings → Displays.
- Screen Recording is for screenshots. macOS calls it Screen & System Audio Recording, but ModeDock doesn't record audio, and your screenshots stay on your Mac.
- Automation lets Empty Trash ask Finder to empty the Trash.

From version 0.1.1, Settings → Permissions shows what ModeDock is allowed to do, with buttons to allow the rest.

<figure><picture style="display: contents"><source srcset="/img/permissions-light.avif" type="image/avif"><img class="only-light" src="/img/permissions-light.png" width="600" height="295" alt="ModeDock's Permissions settings with Accessibility, Screen Recording and Automation allowed" loading="lazy" decoding="async"></picture><picture style="display: contents"><source srcset="/img/permissions-dark.avif" type="image/avif"><img class="only-dark" src="/img/permissions-dark.png" width="600" height="295" alt="ModeDock's Permissions settings with Accessibility, Screen Recording and Automation allowed" loading="lazy" decoding="async"></picture></figure>

## The code

The app and the server are both open source: see [Telemetry.swift](https://github.com/ilijamt/modedock/blob/main/Packages/ModeDockKit/Sources/ModeDockCore/Telemetry.swift) and [server/telemetry](https://github.com/ilijamt/modedock/tree/main/server/telemetry).

Last updated 16 November 2026.
