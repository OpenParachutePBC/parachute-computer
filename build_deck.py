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
# SLIDE 1 — We Shouldn't Have to Choose
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

add_text_box(s, Inches(1.2), Inches(0.8), Inches(4), Inches(0.4),
             "OPEN PARACHUTE, PBC", font_size=11, color=ACCENT, bold=True)

add_text_box(s, Inches(1.2), Inches(2.0), Inches(10), Inches(2.5),
             "Technology should help us\nlive fully — not demand\nwe stop living to use it.",
             font_size=48, color=FG, font_name="Georgia", line_spacing=1.12)

add_text_box(s, Inches(1.2), Inches(5.0), Inches(8), Inches(1.2),
             "I want to hike up a mountain, share my ideas as I walk,\n"
             "and come back down to a working app.\n"
             "But I also want to hold my nephew. Be outside. Live a full life.\n"
             "We shouldn't have to choose.",
             font_size=20, color=FG_MUTED, line_spacing=1.5)

add_text_box(s, Inches(1.2), Inches(6.6), Inches(6), Inches(0.4),
             "Aaron Gabriel Neyer  ·  aaron@parachute.computer  ·  Boulder, CO",
             font_size=12, color=FG_DIM)


# ═══════════════════════════════════════════════
# SLIDE 2 — The Landscape / Market Validation
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "The Landscape")
slide_headline(s, "Everyone is building\npersonal AI computers.")

# Body content
left, top = Inches(1.2), Inches(3.5)
add_text_box(s, left, top, Inches(10), Inches(1.0),
             "Hundreds of millions of people already pay $20-200/month for AI tools.\n"
             "OpenClaw — 300K+ stars in 3 months. Claude Cowork. ZoComputer. Perplexity Computer. Manus.",
             font_size=18, color=FG_MUTED, line_spacing=1.5)

# Market stat
add_text_box(s, Inches(1.2), Inches(5.2), Inches(3), Inches(1.2),
             "$50B+", font_size=64, color=ACCENT, font_name="Georgia")
add_text_box(s, Inches(4.5), Inches(5.45), Inches(5), Inches(0.8),
             "agentic AI market by 2030 · 44% CAGR\nOpenAI alone projects $200B revenue by 2030",
             font_size=16, color=FG_MUTED, line_spacing=1.4)

# The turn
add_text_box(s, Inches(1.2), Inches(6.5), Inches(10), Inches(0.6),
             "The question isn't whether this market exists — it's who they'll trust.",
             font_size=22, color=FG, bold=False, font_name="Georgia")


# ═══════════════════════════════════════════════
# SLIDE 3 — The 95% Gap
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "The Problem")
slide_headline(s, "The other 95% have\nno way in.")

add_text_box(s, Inches(1.2), Inches(3.5), Inches(10), Inches(1.5),
             "The artist who wants to organize creative ideas.\n"
             "The small business owner tracking their days.\n"
             "The parent who wants a better way to remember and reflect.",
             font_size=22, color=FG_MUTED, line_spacing=1.6, font_name="Georgia")

add_text_box(s, Inches(1.2), Inches(5.7), Inches(10), Inches(1.0),
             "They're not going to adopt a full agentic computer cold.\n"
             "They need a bridge.",
             font_size=20, color=FG, line_spacing=1.5)


# ═══════════════════════════════════════════════
# SLIDE 4 — Parachute Daily (The Bridge)
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "The Solution")
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

# Pendant callout on the right — positioned to not overlap left text
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
# SLIDE 6 — Trust as Foundation
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "Why Us")
slide_headline(s, "Open source is\nthe trust foundation.")

items = [
    ("AGPL-3.0 licensed", "Fully transparent. Proprietary forks must share changes."),
    ("Local-first", "Your data on your device. Portable. Exportable. Yours."),
    ("Public Benefit Corporation", "Legal mandate to serve users, not just shareholders."),
    ("Software is no longer a moat", "Ideas get cloned in a day. Trust and context cannot."),
    ("Community as growth engine", "We're building a learning community around AI tools — users who learn together become power users who build for others."),
]

y = Inches(3.5)
for title, desc in items:
    add_text_box(s, Inches(1.2), y, Inches(3.5), Inches(0.35),
                 title, font_size=18, color=FG, bold=True)
    add_text_box(s, Inches(5.0), y, Inches(7), Inches(0.35),
                 desc, font_size=16, color=FG_MUTED)
    y += Inches(0.65)


# ═══════════════════════════════════════════════
# SLIDE 7 — Business Model
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "Business Model")
slide_headline(s, "Start free.\nGrow with every user.")

tiers = [
    ("Free", "Offline journal + on-device transcription. Zero hosting cost.", FG_DIM),
    ("$1-2/mo", "Cloud sync across devices. Your notes everywhere.", FG_MUTED),
    ("$5/mo", "Cloud transcription + AI reflections, synthesis, pattern surfacing", ACCENT),
    ("$20/mo", "Hosted Parachute Computer — full agentic platform", FG),
]

y = Inches(3.5)
for price, desc, col in tiers:
    is_highlight = price == "$5/mo"
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
             "AI at $5/mo uses cost-efficient models. Margins are real and improve as model costs drop.",
             font_size=15, color=FG_DIM, line_spacing=1.5)


# ═══════════════════════════════════════════════
# SLIDE 8 — Team + Traction
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "Team & Traction")
slide_headline(s, "Built from zero.\nSolo. No funding.")

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


# ═══════════════════════════════════════════════
# SLIDE 9 — Financial Projections
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
    ["Avg rev / subscriber", "~$5/mo", "~$7/mo", "~$8/mo"],
    ["MRR (end of year)", "~$2,500", "~$35,000", "~$200,000"],
    ["ARR (end of year)", "~$30K", "~$420K", "~$2.4M"],
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

add_text_box(s, Inches(1.5), Inches(6.6), Inches(9), Inches(0.5),
             "Funded to date: $0. Entire product built by founder with no outside funding.",
             font_size=14, color=FG_DIM)


# ═══════════════════════════════════════════════
# SLIDE 10 — The Ask + Close
# ═══════════════════════════════════════════════
s = prs.slides.add_slide(blank_layout)
set_slide_bg(s)

section_label(s, "The Ask")
slide_headline(s, "$300K to reach revenue.\nThen scale.")

# Ask details
ask_items = [
    ("Instrument", "SAFE (YC standard)"),
    ("Valuation cap", "$5,000,000"),
    ("Giving away", "< 10%"),
    ("Use of funds", "Core team full-time through 2026 → production launch June"),
]

y = Inches(3.5)
for label, val in ask_items:
    add_text_box(s, Inches(1.2), y, Inches(2.5), Inches(0.4),
                 label, font_size=14, color=FG_DIM)
    add_text_box(s, Inches(3.8), y, Inches(5), Inches(0.4),
                 val, font_size=20, color=FG, font_name="Georgia")
    y += Inches(0.55)

# Closing line — circle back to the mountain
add_text_box(s, Inches(1.2), Inches(5.8), Inches(10), Inches(1.2),
             "I want everyone to be able to hike up that mountain.",
             font_size=28, color=FG, font_name="Georgia")

add_text_box(s, Inches(1.2), Inches(6.6), Inches(10), Inches(0.5),
             "parachute.computer  ·  github.com/OpenParachutePBC  ·  aaron@parachute.computer",
             font_size=13, color=FG_DIM)


# ── Save ──
out_path = "/home/sandbox/parachute-computer/nvc-pitch-deck.pptx"
prs.save(out_path)
print(f"Saved to {out_path}")
