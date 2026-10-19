# Changelog

## Unreleased

- Fix "dartograph: Check Impact of Current File". It always failed with "dartograph impact failed — see output" because the changed list was passed to `impact --changed` as inline JSON instead of a file path. The list is now written to a temporary `changes.json` that is deleted after the run. Impacted symbols with `high` risk are now shown as warnings; they were shown as information with `risk: undefined`.

## 0.1.2

- Replace the node D icon with the selected Scout bird mascot.
- Remove the superseded vector source; the extension's analysis behavior is unchanged.

## 0.1.1

- Add the node D icon to the extension and Marketplace listing.
- Exclude unselected icon drafts and vector source from the extension package.

## 0.1.0

- Initial release with workspace findings, change impact, and optional analysis on save.
