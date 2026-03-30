"""Build NVC pitch deck by screenshotting the web version of each slide.
Produces pixel-perfect PPTX that matches the web styling exactly."""

import http.server
import os
import tempfile
import threading
from pathlib import Path
from playwright.sync_api import sync_playwright
from pptx import Presentation
from pptx.util import Inches

SITE_DIR = Path(__file__).parent / "website" / "_site"
PORT = 8765
DECK_URL = f"http://localhost:{PORT}/nvc/deck/"
SLIDE_WIDTH = Inches(13.333)
SLIDE_HEIGHT = Inches(7.5)
VIEWPORT_W = 1280
VIEWPORT_H = 720
DEVICE_SCALE = 2  # 2x for crisp output (2560x1440 actual pixels)


def _start_server():
    """Start a local HTTP server serving the _site directory."""
    handler = http.server.SimpleHTTPRequestHandler
    server = http.server.HTTPServer(("localhost", PORT), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def screenshot_slides(output_dir: str) -> list[str]:
    """Open the deck page and screenshot each .slide section."""
    os.chdir(SITE_DIR)
    server = _start_server()
    paths = []
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(
            viewport={"width": VIEWPORT_W, "height": VIEWPORT_H},
            device_scale_factor=DEVICE_SCALE,
        )
        page.goto(DECK_URL, wait_until="networkidle")

        # Hide the fixed download bar so it doesn't overlay slides
        page.evaluate("document.querySelector('div[style*=\"position: fixed\"]')?.remove()")

        slides = page.query_selector_all("section.slide")
        print(f"Found {len(slides)} slides")

        for i, slide in enumerate(slides):
            # Scroll slide into view and force it to fill the viewport
            slide.scroll_into_view_if_needed()
            # Screenshot at exact 16:9 ratio
            box = slide.bounding_box()
            path = os.path.join(output_dir, f"slide_{i+1:02d}.png")

            # Set slide to exact viewport dimensions for clean capture
            page.evaluate("""(el) => {
                el.style.minHeight = '100vh';
                el.style.height = '100vh';
                el.style.maxHeight = '100vh';
                el.style.overflow = 'hidden';
            }""", slide)
            slide.scroll_into_view_if_needed()
            page.wait_for_timeout(200)  # let fonts settle

            # Take a full-page-width screenshot of just this element
            # Clip to exact 16:9 dimensions
            box = slide.bounding_box()
            page.screenshot(
                path=path,
                clip={
                    "x": 0,
                    "y": box["y"],
                    "width": VIEWPORT_W,
                    "height": VIEWPORT_H,
                },
            )
            paths.append(path)
            print(f"  Captured slide {i+1}")

        browser.close()
    server.shutdown()
    return paths


def build_pptx(image_paths: list[str], output_path: str):
    """Create a PPTX with each screenshot as a full-bleed slide image."""
    prs = Presentation()
    prs.slide_width = SLIDE_WIDTH
    prs.slide_height = SLIDE_HEIGHT
    blank_layout = prs.slide_layouts[6]  # blank

    for img_path in image_paths:
        slide = prs.slides.add_slide(blank_layout)
        slide.shapes.add_picture(img_path, 0, 0, SLIDE_WIDTH, SLIDE_HEIGHT)

    prs.save(output_path)
    print(f"Saved {output_path} ({len(image_paths)} slides)")


def main():
    repo_root = Path(__file__).parent
    output_pptx = repo_root / "nvc-pitch-deck.pptx"
    deploy_pptx = repo_root / "website" / "nvc" / "Parachute.pptx"

    with tempfile.TemporaryDirectory() as tmpdir:
        images = screenshot_slides(tmpdir)
        build_pptx(images, str(output_pptx))

    # Copy to website deployment path
    deploy_pptx.parent.mkdir(parents=True, exist_ok=True)
    import shutil
    shutil.copy2(output_pptx, deploy_pptx)
    print(f"Copied to {deploy_pptx}")


if __name__ == "__main__":
    main()
