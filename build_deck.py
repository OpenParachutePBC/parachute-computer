"""Build NVC pitch deck for Parachute — pivoted narrative.
9 slides, brand palette, agent-native framing."""

from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
from pptx.oxml.ns import qn

# ── Brand colors ──
BG       = RGBColor(0xFA, 0xF8, 0xF4)
BG_SOFT  = RGBColor(0xF3, 0xF0, 0xEA)
FG       = RGBColor(0x2C, 0x2A, 0x26)
FG_MUTED = RGBColor(0x6B, 0x68, 0x60)
FG_DIM   = RGBColor(0x9A, 0x96, 0x90)
ACCENT   = RGBColor(0x4A, 0x7C, 0x59)
WHITE    = RGBColor(0xFF, 0xFF, 0xFF)
BORDER   = RGBColor(0xE4, 0xE0, 0xD8)

SLIDE_W = Inches(13.333)
SLIDE_H = Inches(7.5)

prs = Presentation()
prs.slide_width = SLIDE_W
prs.slide_height = SLIDE_H

blank_layout = prs.slide_layouts[6]

# ── Font choices (safe for presentation machines) ──
FONT_SERIF = "Georgia"
FONT_SANS = "Calibri"
FONT_MONO = "Courier New"


def set_slide_bg(slide, color=BG):
    bg = slide.background
    fill = bg.fill
    fill.solid()
    fill.fore_color.rgb = color


def add_brand_bar(slide):
    shape = slide.shapes.add_shape(
        MSO_SHAPE.RECTANGLE, 0, 0, SLIDE_W, Inches(0.06))
    shape.fill.solid()
    shape.fill.fore_color.rgb = ACCENT
    shape.line.fill.background()


def add_footer(slide, text="parachute.computer"):
    txBox = slide.shapes.add_textbox(
        Inches(1.2), Inches(7.0), Inches(4), Inches(0.3))
    tf = txBox.text_frame
    p = tf.paragraphs[0]
    p.text = text
    p.font.size = Pt(9)
    p.font.color.rgb = FG_DIM
    p.font.name = FONT_SANS


def add_text_box(slide, left, top, width, height, text, font_size=18,
                 color=FG, bold=False, alignment=PP_ALIGN.LEFT,
                 font_name=FONT_SANS, line_spacing=1.2):
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


def section_label(slide, text, top=Inches(1.2)):
    add_text_box(slide, Inches(1.2), top, Inches(4), Inches(0.4),
                 text.upper(), font_size=11, color=ACCENT, bold=True,
                 font_name=FONT_SANS)


def slide_headline(slide, text, top=Inches(1.7), size=40):
    add_text_box(slide, Inches(1.2), top, Inches(10), Inches(1.5),
                 text, font_size=size, color=FG, bold=False,
                 font_name=FONT_SERIF, line_spacing=1.05)


def new_slide():
    s = prs.slides.add_slide(blank_layout)
    set_slide_bg(s)
    add_brand_bar(s)
    add_footer(s)
    return s


def remove_table_borders(table):
    for row_idx in range(len(table.rows)):
        for col_idx in range(len(table.columns)):
            cell = table.cell(row_idx, col_idx)
            tc = cell._tc
            tcPr = tc.get_or_add_tcPr()
            for border_name in ['a:lnL', 'a:lnR', 'a:lnT', 'a:lnB']:
                ln = tcPr.find(qn(border_name))
                if ln is None:
                    ln = tcPr.makeelement(qn(border_name), {})
                    tcPr.append(ln)
                ln.set('w', '6350')  # 0.5pt
                solidFill = ln.find(qn('a:solidFill'))
                if solidFill is None:
                    solidFill = ln.makeelement(qn('a:solidFill'), {})
                    ln.append(solidFill)
                srgbClr = solidFill.find(qn('a:srgbClr'))
                if srgbClr is None:
                    srgbClr = solidFill.makeelement(qn('a:srgbClr'), {})
                    solidFill.append(srgbClr)
                srgbClr.set('val', 'E4E0D8')


# ═══════════════════════════════════════════════
# SLIDE 1 — The Race
# ═══════════════════════════════════════════════
s = new_slide()

section_label(s, "The Landscape")
slide_headline(s, "Everyone is racing to build\nyour AI agent.")

add_text_box(s, Inches(1.2), Inches(3.5), Inches(10), Inches(1.0),
             "OpenClaw. Claude Cowork. ZoComputer. Perplexity Computer. Manus.\n"
             "Over 100 million people already pay $20+/month for AI.",
             font_size=18, color=FG_MUTED, line_spacing=1.5)

# Market stat
add_text_box(s, Inches(1.2), Inches(5.0), Inches(3), Inches(1.2),
             "$50B+", font_size=64, color=ACCENT, font_name=FONT_SERIF)
add_text_box(s, Inches(4.5), Inches(5.25), Inches(5), Inches(0.8),
             "agentic AI market by 2030 \u00b7 44% CAGR",
             font_size=16, color=FG_MUTED, line_spacing=1.4)

add_text_box(s, Inches(1.2), Inches(6.3), Inches(10), Inches(0.6),
             "Features get cloned in weeks. It\u2019s a race to the bottom. So we stopped trying to win it.",
             font_size=22, color=FG, bold=False, font_name=FONT_SERIF)


# ═══════════════════════════════════════════════
# SLIDE 2 — The Problem
# ═══════════════════════════════════════════════
s = new_slide()

section_label(s, "The Problem")
slide_headline(s, "Memory is shallow.\nCapture is broken.")

add_text_box(s, Inches(1.2), Inches(3.5), Inches(10), Inches(1.5),
             "These platforms all have memory now \u2014 but it\u2019s shallow.\n"
             "Basically one big text file. It remembers your name,\n"
             "not six months of your thinking.",
             font_size=20, color=FG_MUTED, line_spacing=1.5)

add_text_box(s, Inches(1.2), Inches(5.0), Inches(10), Inches(1.2),
             "And there\u2019s a deeper problem: how your thinking gets into\n"
             "the system. You can talk to your AI, but that\u2019s a conversation \u2014\n"
             "the AI is always in the middle.",
             font_size=18, color=FG_MUTED, line_spacing=1.5)

add_text_box(s, Inches(1.2), Inches(6.3), Inches(10), Inches(0.6),
             "Tools that help us think for ourselves \u2014 not just think with AI \u2014\n"
             "produce the quality of thinking that makes AI most useful.",
             font_size=20, color=FG, font_name=FONT_SERIF, line_spacing=1.3)


# ═══════════════════════════════════════════════
# SLIDE 3 — Parachute Daily
# ═══════════════════════════════════════════════
s = new_slide()

section_label(s, "Our Answer")
slide_headline(s, "Parachute Daily.\nJust talk.")

add_text_box(s, Inches(1.2), Inches(3.5), Inches(5.5), Inches(2.8),
             "A voice-first journal.\n\n"
             "Speak into a wearable pendant or your phone \u2014\n"
             "on a walk, in the car, wherever thinking happens.\n\n"
             "Simple for humans. Native for AI.\n"
             "No learning curve. Just talk.",
             font_size=18, color=FG_MUTED, line_spacing=1.5)

# Pendant callout
shape = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                           Inches(7.8), Inches(3.5), Inches(4.5), Inches(3.0))
shape.fill.solid()
shape.fill.fore_color.rgb = BG_SOFT
shape.line.color.rgb = BORDER
shape.line.width = Pt(1)

add_text_box(s, Inches(8.2), Inches(3.8), Inches(3.7), Inches(0.4),
             "THE PENDANT", font_size=11, color=ACCENT, bold=True)
add_text_box(s, Inches(8.2), Inches(4.3), Inches(3.7), Inches(2.0),
             "Wearable voice capture device.\n\n"
             "Press a button. Talk.\n"
             "Your thoughts are transcribed and\n"
             "structured by the time you\u2019re home.\n\n"
             "Working prototype on stage today.",
             font_size=16, color=FG_MUTED, line_spacing=1.45)


# ═══════════════════════════════════════════════
# SLIDE 4 — Agent-Native Architecture
# ═══════════════════════════════════════════════
s = new_slide()

section_label(s, "Agent-Native")
slide_headline(s, "Don\u2019t compete with agents.\nBuild the tool layer they all need.")

# Left column — text (keep within 5.5in to avoid diagram)
add_text_box(s, Inches(1.2), Inches(3.5), Inches(5.2), Inches(1.2),
             "Your data lives in a graph database organized\n"
             "around three primitives: Things, Tags, and Tools.\n"
             "The system speaks MCP \u2014 the open standard for\n"
             "connecting AI to tools.",
             font_size=16, color=FG_MUTED, line_spacing=1.45)

add_text_box(s, Inches(1.2), Inches(4.9), Inches(5.2), Inches(0.9),
             "Your AI can read, search, and create structure.\n"
             "People nodes. Project nodes.\n"
             "A living knowledge graph.",
             font_size=15, color=FG_MUTED, line_spacing=1.45)

# Right column — architecture diagram
diag_left = Inches(7.0)
diag_width = Inches(5.5)
shape = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                           diag_left, Inches(3.0), diag_width, Inches(3.8))
shape.fill.solid()
shape.fill.fore_color.rgb = WHITE
shape.line.color.rgb = BORDER
shape.line.width = Pt(1)

dl = Inches(7.4)  # text left within diagram
add_text_box(s, dl, Inches(3.2), Inches(4.5), Inches(0.3),
             "YOU", font_size=10, color=FG_DIM, bold=True, font_name=FONT_MONO)
add_text_box(s, dl, Inches(3.5), Inches(4.5), Inches(0.4),
             "Parachute Daily  \u00b7  Pendant  \u00b7  Phone", font_size=14, color=FG)

add_text_box(s, Inches(9.2), Inches(3.9), Inches(1), Inches(0.3),
             "\u2193", font_size=14, color=FG_DIM, font_name=FONT_MONO,
             alignment=PP_ALIGN.CENTER)

add_text_box(s, dl, Inches(4.2), Inches(4.5), Inches(0.3),
             "DATA", font_size=10, color=ACCENT, bold=True, font_name=FONT_MONO)

# Accent box for server
inner = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                           Inches(7.3), Inches(4.45), Inches(4.8), Inches(0.5))
inner.fill.solid()
inner.fill.fore_color.rgb = RGBColor(0xE8, 0xF5, 0xEC)
inner.line.color.rgb = ACCENT
inner.line.width = Pt(1)
add_text_box(s, Inches(7.5), Inches(4.5), Inches(4.5), Inches(0.4),
             "Parachute Server \u2014 Things \u00b7 Tags \u00b7 Tools",
             font_size=13, color=ACCENT, bold=True)

add_text_box(s, Inches(9.0), Inches(5.0), Inches(1.5), Inches(0.3),
             "\u2193 MCP", font_size=10, color=FG_DIM, font_name=FONT_MONO,
             alignment=PP_ALIGN.CENTER)

add_text_box(s, dl, Inches(5.3), Inches(4.5), Inches(0.3),
             "AGENTS", font_size=10, color=FG_DIM, bold=True, font_name=FONT_MONO)
add_text_box(s, dl, Inches(5.6), Inches(4.5), Inches(0.4),
             "Claude  \u00b7  ChatGPT  \u00b7  OpenClaw  \u00b7  Any AI", font_size=14, color=FG)

# Thesis line — bottom, full width
add_text_box(s, Inches(1.2), Inches(6.3), Inches(11), Inches(0.6),
             "We\u2019re not trying to build the most intelligent tool. We\u2019re building the most important tool for intelligent systems to use.",
             font_size=18, color=FG, font_name=FONT_SERIF, line_spacing=1.2)


# ═══════════════════════════════════════════════
# SLIDE 5 — Context Compounds
# ═══════════════════════════════════════════════
s = new_slide()

section_label(s, "The Insight")
slide_headline(s, "Context compounds.")

add_text_box(s, Inches(1.2), Inches(3.3), Inches(10), Inches(0.8),
             "Every note, every voice entry builds a richer personal data layer \u2014\n"
             "not a flat text file, but a real graph that can be queried across months and years.",
             font_size=20, color=FG_MUTED, line_spacing=1.5)

# Flywheel
steps = [
    ("01", "Capture thoughts in Daily"),
    ("02", "Build months of personal context"),
    ("03", "Connect any AI via MCP"),
    ("04", "AI already knows you"),
    ("\u2192",  "Switching cost through genuine value"),
]

y = Inches(4.6)
for num, text in steps:
    is_final = num == "\u2192"
    col = ACCENT if is_final else FG
    num_col = ACCENT if is_final else FG_DIM

    add_text_box(s, Inches(1.5), y, Inches(0.6), Inches(0.45),
                 num, font_size=14, color=num_col, font_name=FONT_MONO)
    add_text_box(s, Inches(2.2), y, Inches(6), Inches(0.45),
                 text, font_size=20, color=col, font_name=FONT_SERIF,
                 bold=is_final)
    y += Inches(0.5)

add_text_box(s, Inches(7.5), Inches(4.6), Inches(5), Inches(2.0),
             "Open source (AGPL-3.0)\n"
             "Local-first\n"
             "Public Benefit Corporation\n\n"
             "Your data is yours \u2014\n"
             "portable, exportable, self-hostable.",
             font_size=16, color=FG_MUTED, line_spacing=1.5)


# ═══════════════════════════════════════════════
# SLIDE 6 — Business Model
# ═══════════════════════════════════════════════
s = new_slide()

section_label(s, "Business Model")
slide_headline(s, "Start free.\nGrow with every user.")

tiers = [
    ("Free",    "Offline journal + on-device transcription. Zero hosting cost.",       FG_DIM),
    ("$2/mo",   "Cloud sync + MCP access \u2014 your notes available to any AI",       FG_MUTED),
    ("$5/mo",   "Cloud transcription + cleanup \u2014 server-side, better accuracy",   FG_MUTED),
    ("$10/mo",  "AI reflections, vector search, and synthesis",                        ACCENT),
]

y = Inches(3.4)
tier_spacing = Inches(0.7)
for price, desc, col in tiers:
    is_highlight = price == "$10/mo"
    if is_highlight:
        shape = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                                   Inches(1.0), y - Inches(0.1),
                                   Inches(10.5), Inches(0.55))
        shape.fill.solid()
        shape.fill.fore_color.rgb = RGBColor(0xE8, 0xF5, 0xEC)
        shape.line.fill.background()

    add_text_box(s, Inches(1.2), y, Inches(1.8), Inches(0.4),
                 price, font_size=22, color=col, font_name=FONT_SERIF)
    add_text_box(s, Inches(3.2), y + Inches(0.03), Inches(8), Inches(0.4),
                 desc, font_size=15, color=FG_MUTED)
    y += tier_spacing

add_text_box(s, Inches(1.2), Inches(6.5), Inches(10), Inches(0.6),
             "We\u2019re not competing with anyone\u2019s AI subscription.\n"
             "$2/mo to make whatever AI you\u2019re already paying for dramatically better.",
             font_size=15, color=FG_DIM, line_spacing=1.5)


# ═══════════════════════════════════════════════
# SLIDE 7 — Financial Projections
# ═══════════════════════════════════════════════
s = new_slide()

section_label(s, "Financial Projections")
slide_headline(s, "Profitable by year three.")

headers = ["", "2026", "2027", "2028"]
rows = [
    ["Free users", "5,000", "75,000", "500,000"],
    ["Paid subscribers", "500", "8,000", "50,000"],
    ["Avg rev / subscriber", "~$5/mo", "~$5/mo", "~$5/mo"],
    ["ARR", "~$30K", "~$480K", "~$3M"],
    ["Team costs", "~$150K", "~$400K", "~$800K"],
    ["Infra + COGS", "~$10K", "~$100K", "~$400K"],
    ["Total opex", "~$160K", "~$500K", "~$1.2M"],
]

col_widths = [Inches(2.8), Inches(1.8), Inches(1.8), Inches(1.8)]
table_left = Inches(1.5)
table_top = Inches(3.3)

tbl_shape = s.shapes.add_table(len(rows) + 1, 4, table_left, table_top,
                                sum(col_widths), Inches(3.0))
tbl = tbl_shape.table

for i, w in enumerate(col_widths):
    tbl.columns[i].width = w

# Style header
for i, h in enumerate(headers):
    cell = tbl.cell(0, i)
    cell.text = h
    for p in cell.text_frame.paragraphs:
        p.font.size = Pt(11)
        p.font.color.rgb = FG_DIM
        p.font.bold = True
        p.font.name = FONT_SANS
        p.alignment = PP_ALIGN.CENTER if i > 0 else PP_ALIGN.LEFT
    cell.fill.solid()
    cell.fill.fore_color.rgb = BG_SOFT

# Style data rows
for r, row_data in enumerate(rows):
    for c, val in enumerate(row_data):
        cell = tbl.cell(r + 1, c)
        cell.text = val
        for p in cell.text_frame.paragraphs:
            p.font.size = Pt(12)
            p.font.name = FONT_SANS
            p.alignment = PP_ALIGN.CENTER if c > 0 else PP_ALIGN.LEFT
            if r == 3 and c > 0:  # ARR row highlight
                p.font.color.rgb = ACCENT
                p.font.bold = True
            elif c == 0:
                p.font.color.rgb = FG
                p.font.bold = True
                p.font.size = Pt(11)
            else:
                p.font.color.rgb = FG_MUTED
        cell.fill.solid()
        if r == 3:
            cell.fill.fore_color.rgb = RGBColor(0xF0, 0xF8, 0xF2)
        elif r % 2 == 0:
            cell.fill.fore_color.rgb = WHITE
        else:
            cell.fill.fore_color.rgb = BG

remove_table_borders(tbl)

add_text_box(s, Inches(1.5), Inches(6.5), Inches(9), Inches(0.4),
             "100M+ AI users are all potential customers. Conservative given the scale of the opportunity.",
             font_size=13, color=FG_DIM)


# ═══════════════════════════════════════════════
# SLIDE 8 — Self-funded + Team
# ═══════════════════════════════════════════════
s = new_slide()

section_label(s, "Team & Traction")
slide_headline(s, "Self-funded.\nBuilt from scratch.")

# What exists
items = [
    "Working app with local voice transcription + graph-native storage",
    "MCP server with Things, Tags, Tools architecture",
    "Functional pendant prototype (on stage today)",
    "Daily beta launching this month \u00b7 PBC incorporated in Colorado",
    "Learn Vibe Build AI school (Cohort 0 complete, Cohort 1 launching) \u2014 organic growth channel",
]

y = Inches(3.6)
for item in items:
    add_text_box(s, Inches(1.3), y + Inches(0.02), Inches(0.3), Inches(0.3),
                 "\u2022", font_size=12, color=ACCENT)
    add_text_box(s, Inches(1.7), y, Inches(5), Inches(0.35),
                 item, font_size=13, color=FG_MUTED, line_spacing=1.2)
    y += Inches(0.42)

# Team card
shape = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                           Inches(7.5), Inches(3.3), Inches(5), Inches(3.2))
shape.fill.solid()
shape.fill.fore_color.rgb = BG_SOFT
shape.line.color.rgb = BORDER
shape.line.width = Pt(1)

add_text_box(s, Inches(7.9), Inches(3.5), Inches(4), Inches(0.35),
             "THE TEAM", font_size=11, color=ACCENT, bold=True)

team = [
    ("Aaron Gabriel Neyer", "Founder \u00b7 Product & architecture"),
    ("Jon Bo", "Daily co-lead \u00b7 Founding engineer"),
    ("Lucian Hymer", "Server co-lead \u00b7 Founding engineer"),
    ("Marvin Melzer", "Hardware \u00b7 Pendant prototype"),
    ("Neil Yarnal", "Brand & design"),
]

y = Inches(4.0)
for name, role in team:
    add_text_box(s, Inches(7.9), y, Inches(4.5), Inches(0.28),
                 name, font_size=13, color=FG, bold=True)
    add_text_box(s, Inches(7.9), y + Inches(0.25), Inches(4.5), Inches(0.28),
                 role, font_size=11, color=FG_MUTED)
    y += Inches(0.5)

add_text_box(s, Inches(1.2), Inches(6.5), Inches(10), Inches(0.5),
             "MA Ecopsychology \u00b7 MS Creative Technology & Design (CU ATLAS, graduating May 2026) \u00b7 Founding engineer \u00d72 \u00b7 Ex-Google \u00b7 10+ years full stack",
             font_size=12, color=FG_DIM)


# ═══════════════════════════════════════════════
# SLIDE 9 — The Ask
# ═══════════════════════════════════════════════
s = new_slide()

section_label(s, "The Ask")
slide_headline(s, "Raising $300K to launch\nthe memory layer.")

# Ask card
shape = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                           Inches(1.0), Inches(3.3), Inches(6), Inches(2.2))
shape.fill.solid()
shape.fill.fore_color.rgb = WHITE
shape.line.color.rgb = BORDER
shape.line.width = Pt(1)

ask_items = [
    ("Instrument", "SAFE (YC standard)"),
    ("Use of funds", "Core team full-time through 2026"),
    ("Goal", "Production launch by June \u00b7 revenue immediately"),
]

y = Inches(3.55)
for label, val in ask_items:
    add_text_box(s, Inches(1.4), y, Inches(2.2), Inches(0.4),
                 label, font_size=13, color=FG_DIM)
    add_text_box(s, Inches(3.6), y, Inches(3.2), Inches(0.4),
                 val, font_size=16, color=FG, font_name=FONT_SERIF)
    y += Inches(0.55)

# Closing
add_text_box(s, Inches(1.2), Inches(5.8), Inches(10), Inches(1.0),
             "A memory layer for humans and AI\nto think and remember together.",
             font_size=28, color=FG, font_name=FONT_SERIF, line_spacing=1.3)

add_text_box(s, Inches(1.2), Inches(6.7), Inches(10), Inches(0.4),
             "Aaron Gabriel Neyer  \u00b7  aaron@parachute.computer  \u00b7  (513) 593-1721  \u00b7  Boulder, CO",
             font_size=12, color=FG_DIM)


# ── Save ──
out_path = "/home/sandbox/parachute-computer/nvc-pitch-deck.pptx"
prs.save(out_path)
print(f"Saved to {out_path}")
