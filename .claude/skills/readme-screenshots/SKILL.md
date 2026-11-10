---
name: readme-screenshots
description: Regenerate the README screenshots from the app's demo data and update the README to match. Use when opening or updating a PR that changes anything the menus or Settings draw (Sources/ReviewQueue views, Styles, card details, block rules, labels or wording), when the user asks to "update the screenshots", "refresh README images" or "regenerate screenshots", or when a new screen should appear in the README.
---

# README screenshots

The README's images are generated, never hand-captured: `make screenshots` launches the app with
`--screenshots <shot>` on built-in fake data and captures each screen with `screencapture -l` into `docs/images/`.
Real screenshots would leak people, repos and stories, so never replace a generated image with a capture of the
running app.

## When a PR needs this

Run it when the PR changes what any screen shows: a SwiftUI view in `Sources/ReviewQueue/`, `Styles.swift`, a card
detail, block placement or filtering in `Sources/ReviewQueueCore/`, or any user-visible wording. Skip it for changes
the screens cannot show (networking, parsing, notifications, tests only) and say so in the PR.

## Steps

1. **Make the change visible in the demo data.** Read `Sources/ReviewQueueCore/DemoData.swift`. If the new behaviour
   would not appear on screen with the current fixtures (a new row, badge, block note, toggle), add or adjust fixtures
   so it does. Keep each menu fitting without scrolling: the review queue shows one expanded High priority card and
   collapsed rows elsewhere. Update `Tests/ReviewQueueCoreTests/DemoDataTests.swift` to pin what the images rely on.
2. **New screen?** Add a case to `ScreenshotStage.Shot` in `Sources/ReviewQueue/ScreenshotStage.swift` and handle it in
   `present`. The script reads the list from `ReviewQueue --screenshots list`, so there is nothing else to register.
3. **Generate.** Run `make screenshots` in the foreground. Each shot takes focus for a moment; tell the user before
   running it, since it steals focus from whatever they are doing about five times.
4. **Look at every PNG** in `docs/images/` (open each image file and inspect it) and check:
   - glass is tinted (coloured cards, purple GitHub Review / indigo Linear Review buttons, accent-coloured toggles),
     not grey; grey means the app was not active, so rerun;
   - nothing is clipped and Settings tabs show their whole form;
   - the change the PR is about is actually visible;
   - only fake data: the people, repos and tickets in `DemoData.swift` and the public bots `cursor`,
     `datadog-official` and Cursor Bugbot.
5. **Update the README.** Every image is referenced by relative path (`docs/images/<shot>.png`): the two menus at the
   top, the three Settings tabs under "Settings", the two pill-state strips under "Menu bar pills". Add an `<img>` for any new shot where it belongs, and update prose that
   describes what the images show.
6. **Stage, don't commit.** `git add docs/images README.md` plus any fixture or stage changes, run `make test`, then
   report the images and ask the user before committing. Mention in the PR description that screenshots were
   regenerated.

## Requirements and failures

- The terminal running it needs Screen Recording (for `screencapture`) and Automation access to System Events (the
  script uses it to bring each run to the front). Without them the run fails; it never writes grey images silently.
- `could not become the active app`: another app held focus. Rerun without touching the keyboard or mouse.
- `screenshot mode exited early` or `no window reported`: run
  `build/ReviewQueue.app/Contents/MacOS/ReviewQueue --screenshots <shot>` directly to see the error.
- Images are 2x only when the main display is Retina. Check `sips -g pixelWidth docs/images/*.png`: menus are 1064
  wide and Settings 1080 at 2x. Do not commit a 1x set over a 2x one.
- Keep PR numbers in fixtures under 1000: `PrRow` formats numbers with locale grouping, so 1000 and up render as
  `#1,000`.
