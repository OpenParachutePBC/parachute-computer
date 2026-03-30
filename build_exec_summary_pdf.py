"""Generate ES_Parachute.pdf — NVC Executive Summary.
Cover page (doesn't count) + 3 content pages + financial appendix (up to 2 pages).
1.5 line spacing, 12pt body, 1-inch margins per NVC requirements.
Line spacing/font requirements apply to body text, not titles/tables/graphs."""

from fpdf import FPDF

FONTS = '/home/sandbox/parachute-computer/fonts'
ACCENT = (74, 124, 89)
FG = (26, 26, 26)
FG_MUTED = (85, 85, 85)
FG_DIM = (154, 150, 144)
BORDER = (221, 221, 221)
BG_SOFT = (245, 245, 245)

# 12pt * 1.5 line spacing = 18pt = 0.25in
LINE_H = 0.25


class ExecSummaryPDF(FPDF):
    def __init__(self):
        super().__init__('P', 'in', 'Letter')
        self.set_auto_page_break(auto=True, margin=1.0)
        self.set_margins(1.0, 1.0, 1.0)

        self.add_font('Sans', '', f'{FONTS}/DMSans-Variable.ttf')
        self.add_font('Sans', 'I', f'{FONTS}/DMSans-Italic-Variable.ttf')
        self.add_font('Serif', '', f'{FONTS}/InstrumentSerif-Regular.ttf')
        self.add_font('Serif', 'I', f'{FONTS}/InstrumentSerif-Italic.ttf')
        self.add_font('Vera', '', '/usr/local/lib/python3.13/site-packages/reportlab/fonts/Vera.ttf')
        self.add_font('Vera', 'B', '/usr/local/lib/python3.13/site-packages/reportlab/fonts/VeraBd.ttf')

        self._is_cover = False
        self._is_appendix = False

    def footer(self):
        if self._is_cover:
            return
        self.set_y(-0.6)
        self.set_font('Sans', '', 8)
        self.set_text_color(*FG_DIM)
        label = 'Appendix' if self._is_appendix else 'Executive Summary'
        self.cell(0, 0.2, f'Open Parachute PBC \u2014 {label}', align='L')
        # Page number excluding cover
        self.cell(0, 0.2, f'{self.page_no() - 1}', align='R', new_x="LMARGIN")

    def heading(self, text):
        self.ln(0.08)
        self.set_font('Vera', 'B', 11)
        self.set_text_color(*ACCENT)
        self.cell(0, 0.22, text.upper(), new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(*FG)
        self.ln(0.04)

    def body(self, text, after=0.06):
        self.set_font('Sans', '', 12)
        self.set_text_color(*FG_MUTED)
        self.multi_cell(0, LINE_H, text)
        self.set_text_color(*FG)
        self.ln(after)

    def bold_body(self, bold, rest, after=0.06):
        self.set_font('Vera', 'B', 12)
        self.set_text_color(*FG)
        bw = self.get_string_width(bold)
        self.cell(bw, LINE_H, bold)
        self.set_font('Sans', '', 12)
        self.set_text_color(*FG_MUTED)
        rw = self.w - self.l_margin - self.r_margin - bw
        self.multi_cell(rw, LINE_H, rest)
        self.set_text_color(*FG)
        self.ln(after)

    def bullet(self, bold, rest, after=0.04):
        indent = 0.25
        self.set_font('Sans', '', 12)
        self.set_text_color(*FG_DIM)
        self.cell(indent, LINE_H, '\u2022 ')
        if bold:
            self.set_font('Vera', 'B', 12)
            self.set_text_color(*FG)
            bw = self.get_string_width(bold)
            self.cell(bw, LINE_H, bold)
        self.set_font('Sans', '', 12)
        self.set_text_color(*FG_MUTED)
        rw = self.w - self.l_margin - self.r_margin - indent
        self.multi_cell(rw, LINE_H, rest)
        self.set_text_color(*FG)
        self.ln(after)

    def divider(self):
        self.set_draw_color(*BORDER)
        self.line(self.l_margin, self.get_y(), self.w - self.r_margin, self.get_y())
        self.ln(0.1)


pdf = ExecSummaryPDF()

# ═══════════════════════════════════════════
# COVER PAGE (does not count toward 3 pages)
# ═══════════════════════════════════════════
pdf._is_cover = True
pdf.add_page()

pdf.ln(2.5)

pdf.set_font('Serif', '', 36)
pdf.set_text_color(*FG)
pdf.cell(0, 0.5, 'Parachute', align='C', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.15)

pdf.set_font('Sans', '', 14)
pdf.set_text_color(*FG_MUTED)
pdf.cell(0, 0.3, 'The personal data layer for every AI', align='C', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.6)

pdf.set_draw_color(*ACCENT)
mid = pdf.w / 2
pdf.line(mid - 0.75, pdf.get_y(), mid + 0.75, pdf.get_y())
pdf.ln(0.6)

pdf.set_font('Sans', '', 11)
pdf.set_text_color(*FG_MUTED)
cover_lines = [
    'Executive Summary',
    'CU New Venture Challenge 2026',
    '',
    'Open Parachute, PBC',
    'Colorado Public Benefit Corporation',
    '',
    'Aaron Gabriel Neyer, Founder',
    'aaron@parachute.computer \u2022 (720) 616-7550',
    'Boulder, Colorado',
    '',
    'Team: Jon Bo, Lucian Hymer, Marvin Melzer, Neil Yarnal',
]
for line in cover_lines:
    pdf.cell(0, 0.25, line, align='C', new_x="LMARGIN", new_y="NEXT")

pdf._is_cover = False

# ═══════════════════════════════════════════
# PAGE 1 of 3
# ═══════════════════════════════════════════
pdf.add_page()

# Contact block at top of page 1
pdf.set_font('Vera', 'B', 10)
pdf.set_text_color(*FG)
pdf.cell(0, 0.2, 'Open Parachute, PBC \u2014 Colorado Public Benefit Corporation', new_x="LMARGIN", new_y="NEXT")
pdf.set_font('Sans', '', 10)
pdf.set_text_color(*FG_MUTED)
pdf.cell(0, 0.2, 'Aaron Gabriel Neyer, Founder \u2014 aaron@parachute.computer \u2014 (720) 616-7550 \u2014 Boulder, CO', new_x="LMARGIN", new_y="NEXT")
pdf.cell(0, 0.2, 'Team: Jon Bo (Daily Co-lead), Lucian Hymer (Server Co-lead), Marvin Melzer (Hardware), Neil Yarnal (Design)', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.06)
pdf.divider()

pdf.heading('Opportunity Summary')

pdf.body(
    'Over 100 million people pay $20+/month for AI tools like Claude, ChatGPT, and emerging '
    'agentic platforms. The agentic AI market is projected to exceed $50B by 2030 at a 44% CAGR. '
    'But every platform\'s memory is shallow \u2014 basically one big text file. It remembers your '
    'name, not six months of your thinking. There\'s no structured knowledge about your projects, '
    'people, or patterns over time.'
)

pdf.body(
    'There\'s also an upstream problem: how your thinking gets into the system. You can talk to '
    'your AI, but that\'s a conversation \u2014 the AI is always in the middle. There\'s no good way '
    'to think for yourself, capture that thinking naturally, and have it become context that '
    'makes your AI better.'
)

pdf.body(
    'Parachute solves both. Parachute Daily is a voice-first journaling app that captures your '
    'thinking naturally. Under the hood, notes live in a graph database that any AI can access '
    'via MCP (Model Context Protocol). You don\'t switch AI tools \u2014 you add Parachute, and '
    'whatever AI you already use gets dramatically better.'
)

pdf.heading('Product or Service')

pdf.bold_body(
    'Parachute Daily ',
    'is the first product. Users speak into a wearable pendant or their phone. Entries are '
    'transcribed (offline-capable via on-device models), organized, and structured in a graph '
    'database built on three primitives: Things, Tags, and Tools. A journal entry is a Thing. '
    'A person mentioned across entries becomes a Thing. A project is a Thing with linked tasks '
    'and notes. The graph grows organically from natural thinking.'
)

pdf.body(
    'Because the system speaks MCP, any AI agent can read, search, and create structure in the '
    'graph \u2014 scanning journals to generate people nodes, project nodes, pull in contact info. '
    'Your notes become a living knowledge graph that compounds over time.'
)

pdf.bold_body(
    'The Pendant: ',
    'a wearable voice capture device \u2014 press a button, talk, and your thoughts are '
    'transcribed and structured. Working prototype with custom enclosure.'
)

pdf.bold_body(
    'Current state: ',
    'Python/FastAPI server, Flutter app (macOS, Android, web), graph-native storage, local '
    'voice transcription via Sherpa-ONNX, MCP server. Daily beta launching April 2026, '
    'production launch June 2026. OpenParachute PBC incorporated.'
)

# ═══════════════════════════════════════════
# PAGE 2 of 3
# ═══════════════════════════════════════════

pdf.heading('Competitive Differentiation')

pdf.body(
    'The personal AI space is crowded (TwinMind, Mem.ai, Granola, Day One, plus agent platforms '
    'like Manus and ZoComputer). Rather than competing, Parachute is the layer underneath:'
)

pdf.bullet('Agent-native, not agent-competitive. ',
    'Works with whatever AI you already use via MCP. Every AI user is a potential customer.')

pdf.bullet('Capture over conversation. ',
    'Tools for thinking for yourself, not just with AI. Independent thinking is what makes AI most useful.')

pdf.bullet('Deep memory. ',
    'A real graph database queryable across months and years, not a flat text file of preferences.')

pdf.bullet('Open source (AGPL-3.0), local-first, PBC. ',
    'The trust required for people to share their deepest thinking.')

pdf.bullet('Context compounds. ',
    'Months of accumulated personal context cannot be cloned. The switching cost is genuine value.',
    after=0.06)

pdf.heading('Market & Customer Analysis')

pdf.body(
    'Because Parachute complements rather than competes, every AI subscriber is a potential '
    'customer \u2014 100M+ people and growing. Adjacent comparables: TwinMind ($5.7M raised at '
    '$60M valuation), Obsidian (~$25M ARR), Day One (~$4.8M ARR), Mem.ai ($28.6M raised).'
)

pdf.body(
    'Two target segments: (1) AI users who want better context \u2014 $2/month for sync + MCP '
    'is a no-brainer add to an existing subscription; (2) Non-AI users who want a great '
    'journal \u2014 voice-first capture with a wearable that gradually opens the AI ecosystem.'
)

pdf.bold_body('Validation: ',
    '300+ community members in our Boulder ecosystem ready to onboard. 13 builders completed '
    'our first Learn Vibe Build AI learning cohort. Active users in private beta.')

pdf.heading('Intellectual Property')

pdf.body(
    'Open source under AGPL-3.0 \u2014 a copyleft license that prevents proprietary forks while '
    'keeping the codebase transparent. Defensible advantages: compounding user context, graph '
    'database architecture, MCP integration layer, community trust.'
)

# ═══════════════════════════════════════════
# PAGE 3 of 3
# ═══════════════════════════════════════════

pdf.heading('Management Team')

pdf.bullet('Aaron Gabriel Neyer (Founder) \u2014 ',
    'MA Ecopsychology, MS Creative Technology & Design (CU ATLAS). Founding engineer at two '
    'startups. Former Google. 10+ years full-stack. Boulder Human Relations Commission Chair.')
pdf.bullet('Jon Bo \u2014 ', 'Daily co-lead. Founding engineer at multiple startups.')
pdf.bullet('Lucian Hymer \u2014 ', 'Server co-lead. Founding engineer at multiple startups.')
pdf.bullet('Marvin Melzer \u2014 ', 'Hardware lead. Pendant prototype.')
pdf.bullet('Neil Yarnal \u2014 ', 'Brand and design.', after=0.02)
pdf.body('3\u20134 additional builders available for hire, scaling team from 5 to 9\u201310.')

pdf.heading('Financial Projections')

# 3-year summary table (tables exempt from line spacing rules)
headers = ['', '2026', '2027', '2028']
data = [
    ['Free users', '5,000', '75,000', '500,000'],
    ['Paid subscribers', '500', '8,000', '50,000'],
    ['Revenue (ARR)', '$30K', '$480K', '$3M'],
    ['Total opex', '$160K', '$500K', '$1.2M'],
    ['Net profit (loss)', '($130K)', '($20K)', '$1.8M'],
    ['Cash position', '$170K', '$150K', '$1.95M'],
]

col_w = [2.3, 1.15, 1.15, 1.15]
rh = 0.2

pdf.set_fill_color(*BG_SOFT)
pdf.set_draw_color(*BORDER)
pdf.set_font('Vera', 'B', 9)
pdf.set_text_color(*FG_DIM)
for i, h in enumerate(headers):
    pdf.cell(col_w[i], rh, h, border=1, align='L' if i == 0 else 'C', fill=True)
pdf.ln()

for r, row in enumerate(data):
    is_rev = r == 2
    is_profit = r == 4
    for c, val in enumerate(row):
        if c == 0:
            pdf.set_font('Vera', 'B', 9)
            pdf.set_text_color(*FG)
        elif is_rev or is_profit:
            pdf.set_font('Vera', 'B', 9)
            pdf.set_text_color(*ACCENT)
        else:
            pdf.set_font('Sans', '', 9)
            pdf.set_text_color(*FG_MUTED)
        pdf.set_fill_color(255, 255, 255)
        pdf.cell(col_w[c], rh, val, border=1, align='L' if c == 0 else 'C', fill=True)
    pdf.ln()

pdf.ln(0.06)
pdf.set_text_color(*FG)

pdf.bold_body('Revenue model: ',
    'Free (offline, zero cost), $2/mo (sync + MCP), $5/mo (transcription), $10/mo (AI + vector '
    'search). COGS are low \u2014 transcription and embeddings, not heavy inference. '
    'Profitable by year three. Self-funded to date: $0 outside investment.')

pdf.heading('Investment')

pdf.body(
    'Raising $300,000 via SAFE note (YC standard) at $5M valuation cap. Early-believer '
    'terms \u2014 TwinMind raised at $60M with 30K users; we are raising pre-launch.'
)

pdf.bold_body('Use of funds: ',
    'Core team (founder + two co-leads) full-time through 2026, infrastructure, production '
    'launch by June 2026. Revenue on launch, growth to raise a subsequent round by early 2027.')

pdf.bold_body('NVC prize funds ($50,000): ',
    'Accelerate team ramp-up, broader beta distribution, and earlier path to growth metrics '
    'for our next raise.')

# ═══════════════════════════════════════════
# APPENDIX — Detailed Financial Information
# ═══════════════════════════════════════════
pdf._is_appendix = True
pdf.add_page()

pdf.set_font('Vera', 'B', 14)
pdf.set_text_color(*FG)
pdf.cell(0, 0.3, 'Appendix: Detailed Financial Projections', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.2)

# 5-year table
pdf.set_font('Vera', 'B', 10)
pdf.set_text_color(*FG)
pdf.cell(0, 0.25, '5-Year Projections', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.08)

headers5 = ['', '2026', '2027', '2028', '2029', '2030']
data5 = [
    ['Free users', '5,000', '75,000', '500,000', '1,500,000', '4,000,000'],
    ['Paid subscribers', '500', '8,000', '50,000', '200,000', '600,000'],
    ['Avg rev / sub', '~$5/mo', '~$5/mo', '~$5/mo', '~$5/mo', '~$6/mo'],
    ['Revenue (ARR)', '$30K', '$480K', '$3M', '$12M', '$43M'],
    ['', '', '', '', '', ''],
    ['Team costs', '$150K', '$400K', '$800K', '$2.5M', '$7M'],
    ['Infra + COGS', '$10K', '$100K', '$400K', '$1.5M', '$5M'],
    ['Total opex', '$160K', '$500K', '$1.2M', '$4M', '$12M'],
    ['', '', '', '', '', ''],
    ['Net profit (loss)', '($130K)', '($20K)', '$1.8M', '$8M', '$31M'],
    ['Cash position', '$170K', '$150K', '$1.95M', '$9.95M', '$41M'],
]

col5 = [1.7, 0.82, 0.82, 0.82, 0.82, 0.82]
rh5 = 0.22

pdf.set_fill_color(*BG_SOFT)
pdf.set_draw_color(*BORDER)
pdf.set_font('Vera', 'B', 9)
pdf.set_text_color(*FG_DIM)
for i, h in enumerate(headers5):
    pdf.cell(col5[i], rh5, h, border=1, align='L' if i == 0 else 'C', fill=True)
pdf.ln()

for row in data5:
    is_blank = all(v == '' for v in row[1:])
    is_rev = row[0] == 'Revenue (ARR)'
    is_profit = row[0] == 'Net profit (loss)'
    is_cash = row[0] == 'Cash position'

    if is_blank:
        pdf.ln(0.06)
        continue

    for c, val in enumerate(row):
        if c == 0:
            pdf.set_font('Vera', 'B', 9)
            pdf.set_text_color(*FG)
        elif is_rev or is_profit or is_cash:
            pdf.set_font('Vera', 'B', 9)
            pdf.set_text_color(*ACCENT)
        else:
            pdf.set_font('Sans', '', 9)
            pdf.set_text_color(*FG_MUTED)
        pdf.set_fill_color(255, 255, 255)
        pdf.cell(col5[c], rh5, val, border=1, align='L' if c == 0 else 'C', fill=True)
    pdf.ln()

pdf.ln(0.25)

# Key Assumptions
pdf.set_font('Vera', 'B', 10)
pdf.set_text_color(*FG)
pdf.cell(0, 0.25, 'Key Assumptions', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.08)

assumptions = [
    'Revenue tiers: Free (offline journal, $0 hosting cost), $2/mo (cloud sync + MCP access), '
    '$5/mo (cloud transcription + cleanup), $10/mo (AI reflections, vector search, synthesis).',

    'Average revenue per paid subscriber holds at ~$5/mo through 2029, increasing to ~$6/mo '
    'in 2030 as AI features mature and higher tiers see adoption.',

    'Free-to-paid conversion rate: 10% (conservative; Obsidian sees ~4% on a less sticky product).',

    'COGS are structurally low: transcription and embeddings cost a fraction of heavy AI inference. '
    'No agentic workloads \u2014 we store and serve structured data via MCP. Margins improve as model costs decline.',

    'Team scales from 5 (2026) to ~10 (2028) to ~25 (2030). '
    'Avg fully-loaded cost per team member: $100\u2013120K early, rising to ~$140K at scale.',

    'Cash position assumes $300K SAFE raise in 2026. No additional raises modeled, '
    'though a Series A in 2027 is likely.',

    'Funding to date: $0. Entire product built by founder with no outside investment.',
]

for a in assumptions:
    indent = 0.25
    pdf.set_font('Sans', '', 10)
    pdf.set_text_color(*FG_DIM)
    pdf.cell(indent, 0.18, '\u2022 ')
    pdf.set_text_color(*FG_MUTED)
    rw = pdf.w - pdf.l_margin - pdf.r_margin - indent
    pdf.multi_cell(rw, 0.18, a)
    pdf.ln(0.04)

# ── Save ──
pdf_path = '/home/sandbox/parachute-computer/website/nvc/ES_Parachute.pdf'
pdf.output(pdf_path)

with open(pdf_path, 'rb') as f:
    content = f.read()
    pages = content.count(b'/Type /Page') - content.count(b'/Type /Pages')
print(f'Saved PDF to {pdf_path} ({pages} pages)')
