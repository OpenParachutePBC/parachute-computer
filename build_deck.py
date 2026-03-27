"""Build NVC pitch deck for Parachute — 5 minute pitch."""

from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE

# ── Brand colors ──
BG       = RGBColor(0xFA, 0xF8, 0xF4)
BG_SOFT  = RGBColor(0xF3, 0xF0, 0xEA)
FG       = RGBColor(0x2C, 0x2A, 0x26)
FG_MUTED = RGBColor(0x6B, 0x68, 0x60)
FG_DIM   = RGBColor(0x9A, 0x96, 0x90)
ACCENT   = RGBColor(0x4A, 0x7C, 0x59)
WHITE    = RGBColor(0xFF, 0xFF, 0xFF)

SLIDE_W = Inches(13.333)
SLIDE_H = Inches(7.5)

prs = Presentation()
prs.slide_width = SLIDE_W
prs.slide_height = SLIDE_H

# Use blank layout
blank_layout = prs.slide_layouts[6]


def set_slide_bg(slide, color=BG):
    bg = slide.background
    fill = bg.fill
    fill.solid()
    fill.fore_color.rgb = color


def add_text_box(slide, left, top, width, height, text, font_size=18,
                 color=FG, bold=False, alignment=PP_ALIGN.LEFT,
                 font_name="Calibri", line_spacing=1.2):
    txBox = slide.shapes.add_textbox(left, top, width, height)
    tf = txBox.text_frame
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.text = text
    p.font.size = Pt(font_size)
    p.font.color.rgb = color
    p.font.bold = bold
    p.font.name = font_name
    p.alignment = alignment
    p.space_after = Pt(0)
    p.space_before = Pt(0)
    if line_spacing != 1.0:
        p.line_spacing = line_spacing
    return tf


def add_multiline_box(slide, left, top, width, height, lines, font_size=18,
                      color=FG, font_name="Calibri", alignment=PP_ALIGN.LEFT,
                      line_spacing=1.2):
    """lines is a list of (text, bold, color_override) tuples."""
    txBox = slide.shapes.add_textbox(left, top, width, height)
    tf = txBox.text_frame
    tf.word_wrap = True
    for i, (text, bold, col) in enumerate(lines):
        if i == 0:
            p = tf.paragraphs[0]
        else:
            p = tf.add_paragraph()
        p.text = text
        p.font.size = Pt(font_size)
        p.font.color.rgb = col or color
        p.font.bold = bold
        p.font.name = font_name
        p.alignment = alignment
        p.line_spacing = line_spacing
        p.space_after = Pt(2)
        p.space_before = Pt(2)
    return tf


def add_rich_paragraph(tf, parts, font_size=18, alignment=PP_ALIGN.LEFT,
                       line_spacing=1.2):
    """Add a paragraph with mixed formatting. parts = [(text, bold, color)]"""
    p = tf.add_paragraph()
    for text, bold, color in parts:
        run = p.add_run()
        run.text = text
        run.font.size = Pt(font_size)
        run.font.bold = bold
        run.font.color.rgb = color
        run.font.name = "Calibri"
    p.alignment = alignment
    p.line_spacing = line_spacing
    p.space_after = Pt(4)
    return p


def section_label(slide, text, top=Inches(1.2)):
    add_text_box(slide, Inches(1.2), top, Inches(4), Inches(0.4),
                 text.upper(), font_size=11, color=ACCENT, bold=True,
                 font_name="Calibri")


def slide_headline(slide, text, top=Inches(1.7), size=40):
    add_text_box(slide, Inches(1.2), top, Inches(10), Inches(1.5),
                 text, font_size=size, color=FG, bold=False,
                 font_name="Georgia", line_spacing=1.05)


def slide_body_start(slide, top=Inches(3.4)):
    """Return (left, top) for body content."""
    return Inches(1.2), top


# ═══════════════════════════════════════════════
# SLIDE 1 — The Landscape
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "The Landscape")
slide_headline(s, "Everyone is building\npersonal AI computers.")

left, top = Inches(1.2), Inches(3.5)
add_text_box(s, left, top, Inches(10), Inches(1.0),
             "Over 100 million people already pay $20+/month for AI.\n"
             "OpenClaw. Claude Cowork. ZoComputer. Perplexity Computer. Manus.",
             font_size=18, color=FG_MUTED, line_spacing=1.5)

# Market stat
add_text_box(s, Inches(1.2), Inches(5.0), Inches(3), Inches(1.2),
             "$50B+", font_size=64, color=ACCENT, font_name="Georgia")
add_text_box(s, Inches(4.5), Inches(5.25), Inches(5), Inches(0.8),
             "agentic AI market by 2030 · 44% CAGR",
             font_size=16, color=FG_MUTED, line_spacing=1.4)

# The turn
add_text_box(s, Inches(1.2), Inches(6.3), Inches(10), Inches(0.6),
             "But they're building walled gardens — and only for the 5% who are already power users.",
             font_size=22, color=FG, bold=False, font_name="Georgia")


# ═══════════════════════════════════════════════
# SLIDE 2 — The 95% Gap
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "The Opportunity")
slide_headline(s, "The other 95% just want\nsomething that works.")

add_text_box(s, Inches(1.2), Inches(3.5), Inches(10), Inches(1.5),
             "The artist who wants to organize creative ideas.\n"
             "The small business owner tracking their days.\n"
             "The parent who wants a better way to remember and reflect.",
             font_size=22, color=FG_MUTED, line_spacing=1.6, font_name="Georgia")

add_text_box(s, Inches(1.2), Inches(5.7), Inches(10), Inches(1.0),
             "They need a system that learns them —\n"
             "not one that demands they learn it.",
             font_size=22, color=FG, line_spacing=1.5, font_name="Georgia")


# ═══════════════════════════════════════════════
# SLIDE 3 — Parachute Computer (Trust + Open Source woven in)
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "Our Answer")
slide_headline(s, "Parachute Computer.\nThe personal AI you can trust.")

# Slim bullet points
bullets = [
    "Open source (AGPL-3.0) · local-first · self-hostable",
    "Your data stays on your device — portable and exportable",
    "Knowledge graph connects your journals, conversations, and thinking",
    "Public Benefit Corporation — legally mandated to serve users",
]

y = Inches(3.5)
for b in bullets:
    add_text_box(s, Inches(1.5), y, Inches(9), Inches(0.4),
                 "·   " + b, font_size=18, color=FG_MUTED, line_spacing=1.3)
    y += Inches(0.55)

add_text_box(s, Inches(1.2), Inches(5.8), Inches(10), Inches(0.8),
             "Software gets cloned in a day.\nTrust and context cannot.",
             font_size=22, color=FG, font_name="Georgia", line_spacing=1.3)

add_text_box(s, Inches(1.2), Inches(6.6), Inches(10), Inches(0.5),
             "But most people don't want to self-host a server.",
             font_size=18, color=FG_MUTED, font_name="Georgia")


# ═══════════════════════════════════════════════
# SLIDE 4 — Parachute Daily (The Bridge)
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "The Bridge")
slide_headline(s, "Parachute Daily.\nJust talk.")

add_text_box(s, Inches(1.2), Inches(3.5), Inches(5.5), Inches(2.8),
             "A voice-first journal.\n\n"
             "Speak into a wearable pendant or your phone —\n"
             "on a walk, in the car, wherever thinking happens.\n\n"
             "AI weaves through gently:\n"
             "  ·  Daily reflections on your entries\n"
             "  ·  Pattern recognition over time\n"
             "  ·  Weekly synthesis of your thinking",
             font_size=18, color=FG_MUTED, line_spacing=1.5)

add_text_box(s, Inches(1.2), Inches(6.5), Inches(5.5), Inches(0.5),
             "No learning curve. No technical sophistication required.",
             font_size=18, color=FG, line_spacing=1.2)

# Pendant callout on the right
shape = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                           Inches(7.8), Inches(3.5), Inches(4.5), Inches(3.0))
shape.fill.solid()
shape.fill.fore_color.rgb = BG_SOFT
shape.line.color.rgb = RGBColor(0xE4, 0xE0, 0xD8)
shape.line.width = Pt(1)

add_text_box(s, Inches(8.2), Inches(3.8), Inches(3.7), Inches(0.4),
             "THE PENDANT", font_size=11, color=ACCENT, bold=True)
add_text_box(s, Inches(8.2), Inches(4.3), Inches(3.7), Inches(2.0),
             "Wearable voice capture device.\n\n"
             "Go for a walk. Talk.\n"
             "Your thoughts become structured\n"
             "knowledge by the time you're home.\n\n"
             "Working prototype on stage today.",
             font_size=16, color=FG_MUTED, line_spacing=1.45)


# ═══════════════════════════════════════════════
# SLIDE 5 — Context Compounds (The Flywheel)
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "The Insight")
slide_headline(s, "Context compounds.")

add_text_box(s, Inches(1.2), Inches(3.3), Inches(10), Inches(0.8),
             "Every day you use Parachute, your AI gets meaningfully better.\n"
             "No competitor can shortcut months of accumulated personal context.",
             font_size=20, color=FG_MUTED, line_spacing=1.5)

# Flywheel steps
steps = [
    ("01", "Start journaling in Daily"),
    ("02", "Build months of personal context"),
    ("03", "Upgrade to Parachute Computer"),
    ("04", "Brain ingests your history instantly"),
    ("→",  "System already knows you"),
]

y = Inches(4.6)
for num, text in steps:
    is_final = num == "→"
    col = ACCENT if is_final else FG
    num_col = ACCENT if is_final else FG_DIM

    add_text_box(s, Inches(1.5), y, Inches(0.6), Inches(0.45),
                 num, font_size=14, color=num_col, font_name="Courier New")
    add_text_box(s, Inches(2.2), y, Inches(6), Inches(0.45),
                 text, font_size=20, color=col, font_name="Georgia",
                 bold=is_final)
    y += Inches(0.5)


# ═══════════════════════════════════════════════
# SLIDE 6 — Business Model / Pricing
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "Business Model")
slide_headline(s, "Start free.\nGrow with every user.")

tiers = [
    ("Free", "Offline journal + on-device transcription. Zero hosting cost.", FG_DIM),
    ("$2/mo", "Cloud sync across devices. Your notes everywhere.", FG_MUTED),
    ("$10/mo", "Cloud transcription + AI — reflections, synthesis, pattern surfacing", ACCENT),
    ("$40/mo", "Hosted Parachute Computer — full agentic platform with bundled AI", FG),
]

y = Inches(3.5)
for price, desc, col in tiers:
    is_highlight = price == "$10/mo"
    if is_highlight:
        shape = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                                   Inches(1.0), y - Inches(0.15),
                                   Inches(10.5), Inches(0.65))
        shape.fill.solid()
        shape.fill.fore_color.rgb = RGBColor(0xE8, 0xF5, 0xEC)
        shape.line.fill.background()

    add_text_box(s, Inches(1.2), y, Inches(1.8), Inches(0.4),
                 price, font_size=24, color=col, font_name="Georgia")
    add_text_box(s, Inches(3.2), y + Inches(0.05), Inches(8), Inches(0.4),
                 desc, font_size=16, color=FG_MUTED)
    y += Inches(0.7)

add_text_box(s, Inches(1.2), Inches(6.3), Inches(10), Inches(0.8),
             "Free tier has zero hosting cost — no subsidizing free users.\n"
             "AI at $10/mo uses cost-efficient models. Margins are real and improve as model costs drop.",
             font_size=15, color=FG_DIM, line_spacing=1.5)


# ═══════════════════════════════════════════════
# SLIDE 7 — Financial Projections
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "Financial Projections")
slide_headline(s, "Profitable by year three.")

# Table
headers = ["", "2026", "2027", "2028"]
rows = [
    ["Free + sync users", "5,000", "50,000", "250,000"],
    ["Paid subscribers", "500", "5,000", "25,000"],
    ["Avg rev / subscriber", "~$10/mo", "~$12/mo", "~$14/mo"],
    ["MRR (end of year)", "~$5,000", "~$60,000", "~$350,000"],
    ["ARR (end of year)", "~$60K", "~$720K", "~$4.2M"],
    ["Team (salaried)", "3", "5-6", "9-10"],
    ["Operating costs", "~$170K", "~$550K", "~$900K"],
]

col_widths = [Inches(2.8), Inches(1.8), Inches(1.8), Inches(1.8)]
table_left = Inches(1.5)
table_top = Inches(3.3)

tbl = s.shapes.add_table(len(rows) + 1, 4, table_left, table_top,
                         sum(col_widths), Inches(3.2)).table

for i, w in enumerate(col_widths):
    tbl.columns[i].width = w

# Style header
for i, h in enumerate(headers):
    cell = tbl.cell(0, i)
    cell.text = h
    for p in cell.text_frame.paragraphs:
        p.font.size = Pt(12)
        p.font.color.rgb = FG_DIM
        p.font.bold = True
        p.font.name = "Calibri"
        p.alignment = PP_ALIGN.CENTER if i > 0 else PP_ALIGN.LEFT
    cell.fill.solid()
    cell.fill.fore_color.rgb = BG_SOFT

# Style data rows
for r, row_data in enumerate(rows):
    for c, val in enumerate(row_data):
        cell = tbl.cell(r + 1, c)
        cell.text = val
        for p in cell.text_frame.paragraphs:
            p.font.size = Pt(13)
            p.font.name = "Calibri"
            p.alignment = PP_ALIGN.CENTER if c > 0 else PP_ALIGN.LEFT
            # Highlight ARR row
            if r == 4 and c > 0:
                p.font.color.rgb = ACCENT
                p.font.bold = True
            elif c == 0:
                p.font.color.rgb = FG
                p.font.bold = True
                p.font.size = Pt(12)
            else:
                p.font.color.rgb = FG_MUTED
        cell.fill.solid()
        cell.fill.fore_color.rgb = WHITE if r % 2 == 0 else BG


# ═══════════════════════════════════════════════
# SLIDE 8 — Bootstrapped + Team
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "Team & Traction")
slide_headline(s, "Self-funded.\nBuilt from scratch.")

# What exists
add_text_box(s, Inches(1.2), Inches(3.5), Inches(5.5), Inches(3.0),
             "What exists today:\n\n"
             "  ·  Working server, app, and graph-native memory\n"
             "  ·  Local voice transcription (fully offline)\n"
             "  ·  Multi-agent system with trust tiers\n"
             "  ·  Telegram, Discord, Matrix connectors\n"
             "  ·  Functional pendant prototype\n"
             "  ·  Beta launching next month\n"
             "  ·  PBC incorporated in Colorado",
             font_size=16, color=FG_MUTED, line_spacing=1.55)

# Team on the right
add_text_box(s, Inches(7.8), Inches(3.3), Inches(4), Inches(0.35),
             "THE TEAM", font_size=11, color=ACCENT, bold=True)

team = [
    ("Aaron Gabriel Neyer", "Founder · Product & architecture"),
    ("Jon Bo", "Daily co-lead · Founding engineer"),
    ("Lucian Hymer", "Computer co-lead · Founding engineer"),
    ("Marvin Melzer", "Hardware · Pendant prototype"),
    ("Neil Yarnal", "Brand & design"),
]

y = Inches(3.9)
for name, role in team:
    add_text_box(s, Inches(7.8), y, Inches(4.5), Inches(0.3),
                 name, font_size=14, color=FG, bold=True)
    add_text_box(s, Inches(7.8), y + Inches(0.28), Inches(4.5), Inches(0.3),
                 role, font_size=12, color=FG_MUTED)
    y += Inches(0.6)

# Founder bio at bottom
add_text_box(s, Inches(1.2), Inches(6.5), Inches(10), Inches(0.5),
             "MA Ecopsychology · MS Creative Technology & Design (CU ATLAS) · Founding engineer ×2 · Ex-Google · 10+ years full stack",
             font_size=13, color=FG_DIM)


# ═══════════════════════════════════════════════
# SLIDE 9 — The Ask
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "The Ask")
slide_headline(s, "Raising $300K to hire\nthe core team.")

# Simpler ask details
ask_items = [
    ("Instrument", "SAFE (YC standard)"),
    ("Use of funds", "Core team full-time through 2026"),
    ("Goal", "Production launch by June · revenue immediately"),
]

y = Inches(3.5)
for label, val in ask_items:
    add_text_box(s, Inches(1.2), y, Inches(2.5), Inches(0.4),
                 label, font_size=14, color=FG_DIM)
    add_text_box(s, Inches(3.8), y, Inches(7), Inches(0.4),
                 val, font_size=20, color=FG, font_name="Georgia")
    y += Inches(0.55)

# Closing line
add_text_box(s, Inches(1.2), Inches(5.5), Inches(10), Inches(1.2),
             "Open source. Local-first.\nBalance and choice — from the foundation.",
             font_size=28, color=FG, font_name="Georgia", line_spacing=1.3)

add_text_box(s, Inches(1.2), Inches(6.5), Inches(10), Inches(0.5),
             "Aaron Gabriel Neyer  ·  aaron@parachute.computer  ·  Boulder, CO",
             font_size=13, color=FG_DIM)

add_text_box(s, Inches(1.2), Inches(6.9), Inches(10), Inches(0.4),
             "parachute.computer  ·  github.com/OpenParachutePBC",
             font_size=12, color=FG_DIM)


# ── Save ──
out_path = "/home/sandbox/parachute-computer/nvc-pitch-deck.pptx"
prs.save(out_path)
print(f"Saved to {out_path}")
