# Public UI previews

These PNGs render the actual native application and widget view code with synthetic accounts and invented usage values. They are illustrative previews, not captures of live accounts. No real organization name, email, account identifier, credential, desktop background or unrelated application is present. The settings preview identifies its standalone renderer as a development build.

- `overview.png`: main dashboard.
- `settings.png`: menu account selection, appearance and refresh settings.
- `menu-bar.png`: production meter drawing and percentage formatting on a neutral background.
- `widget-small.png`, `widget-medium.png`, `widget-large.png`: one, two and three accounts.

Regenerate on macOS with Xcode installed:

```sh
python3 scripts/render-previews.py
```

The renderer uses an empty temporary configuration, never starts polling, never calls a reset, and does not write the user's widget snapshot. Temporary source copies expose the initial tab and widget family for rendering; production source files are not changed.
