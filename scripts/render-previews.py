#!/usr/bin/env python3
"""Render native views using synthetic data, without opening accounts or running Docker."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="mockusage-previews-") as staging:
    stage = pathlib.Path(staging)
    sources = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        if path.name == "MockUsageApp.swift":
            continue
        text = path.read_text()
        if path.name == "Views.swift":
            text = text.replace('@State private var tab = "overview"', '@State var tab = "overview"')
        target = stage / path.name
        target.write_text(text)
        sources.append(str(target))
    for name in ["MockUsageWidget.swift", "UsageConfiguration.swift"]:
        text = (root / "Widget" / name).read_text()
        if name == "MockUsageWidget.swift":
            text = text.split("@main")[0].replace('.containerBackground(.background, for: .widget)', '')
            text = text.replace('@Environment(\\.widgetFamily) private var family', 'var family: WidgetFamily')
        target = stage / name
        target.write_text(text)
        sources.append(str(target))
    # Reuse the production status-meter drawing code, rather than recreating its appearance.
    menu = (root / "Sources/MockUsage/MenuBarController.swift").read_text()
    drawing = menu.split('            let image = NSImage(size:', 1)[1].split('            item.button?.image = image', 1)[0]
    harness = (root / "scripts/previews/Render.swift").read_text()
    harness += '\n@MainActor func previewMeters(_ meters: [(Double?, NSColor)]) -> NSImage {\nlet image = NSImage(size:' + drawing + '\nreturn image\n}\n'
    target = stage / "Render.swift"
    target.write_text(harness)
    sources.append(str(target))
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", "-D", "WIDGET_SUPPORT", "-o", str(stage / "render"), *sources], check=True)
    subprocess.run([str(stage / "render"), str(root / "docs/images")], check=True)
print("Exported synthetic native UI previews to docs/images.")
