# Outboxx Logos

This directory contains official Outboxx logo assets in SVG format.

## Structure

- `dark/` - Logos for dark backgrounds/themes
- `light/` - Logos for light backgrounds/themes

## Variants

All logos available in both dark and light versions:

- **logo-horizontal.svg** - Full logo with text, horizontal layout (main README)
- **logo-static-icon-only.svg** - Icon without text (docs headers, favicons)
- **logo-static-with-text.svg** - Icon with text below (vertical layout)
- **logo-animated-icon-only.svg** - Animated icon version (optional use)
- **logo-animated-with-text.svg** - Animated full logo (optional use)

## Usage in Markdown

### Theme-aware logo (auto-switches based on GitHub theme):

```markdown
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo/dark/logo-horizontal.svg">
  <source media="(prefers-color-scheme: light)" srcset="logo/light/logo-horizontal.svg">
  <img alt="Outboxx" src="logo/light/logo-horizontal.svg" width="400">
</picture>
```

### Simple logo (single theme):

```markdown
<img src="logo/dark/logo-horizontal.svg" alt="Outboxx" width="400">
```

### Small icon in corner:

```markdown
<img src="logo/dark/logo-static-icon-only.svg" width="48" align="right">
```

## File Sizes

All logos are optimized SVG files (~2-3KB each), suitable for version control.

## License

Same license as the Outboxx project (MIT).
