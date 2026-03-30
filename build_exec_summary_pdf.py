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
        self.set_x(self.l_margin)
        self.set_font('Sans', '', 12)
        self.set_text_color(*FG_MUTED)
        rw = self.w - self.l_margin - self.r_margin - indent
        text = f'\u2022  {bold}{rest}' if bold else f'\u2022  {rest}'
        # Use left margin + indent for wrapped lines
        old_margin = self.l_margin
        self.set_left_margin(self.l_margin + indent)
        self.set_x(self.l_margin)
        self.multi_cell(rw, LINE_H, text)
        self.set_left_margin(old_margin)
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
pdf.cell(0, 0.3, 'A memory layer for humans and AI to think and remember together.', align='C', new_x="LMARGIN", new_y="NEXT")
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
    'aaron@parachute.computer \u2022 (513) 593-1721',
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
pdf.cell(0, 0.2, 'Aaron Gabriel Neyer, Founder \u2014 aaron@parachute.computer \u2014 (513) 593-1721 \u2014 Boulder, CO', new_x="LMARGIN", new_y="NEXT")
pdf.cell(0, 0.2, 'Team: Jon Bo (Daily Co-lead), Lucian Hymer (Server Co-lead), Marvin Melzer (Hardware), Neil Yarnal (Design)', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.06)
pdf.divider()

pdf.heading('Opportunity Summary')

pdf.body(
    'Over 100 million people pay $20+/month for AI. The agentic AI market will exceed $50B by 2030 '
    '(44% CAGR). But every platform\'s memory is shallow \u2014 one big text file. It remembers your '
    'name, not six months of your thinking. And there\'s no good way to think for yourself and have '
    'that become context \u2014 you can talk to AI, but it\'s always a conversation with AI in the middle.'
)

pdf.body(
    'Parachute solves both. Parachute Daily is a voice-first journal that captures your thinking '
    'naturally. Notes live in a graph database any AI can access via MCP (Model Context Protocol). '
    'You don\'t switch AI tools \u2014 you add Parachute, and whatever AI you use gets better.'
)

pdf.heading('Product or Service')

pdf.bold_body(
    'Parachute Daily: ',
    'Users speak into a wearable pendant or phone. Entries are transcribed (offline via on-device '
    'models), organized, and structured in a graph database built on three primitives: Things, Tags, '
    'and Tools. Because the system speaks MCP, any AI can read, search, and create structure \u2014 '
    'generating people nodes, project nodes, linking contact info. Notes become a living knowledge graph.'
)

pdf.bold_body(
    'The Pendant: ',
    'Wearable voice capture \u2014 press a button, talk, thoughts transcribed and structured. Working prototype.'
)

pdf.bold_body(
    'Current state: ',
    'Python/FastAPI server, Flutter app (macOS, Android, web), graph-native storage, local transcription '
    '(Sherpa-ONNX), MCP server. Beta launching April 2026, production June 2026. PBC incorporated.',
    after=0.04
)

pdf.heading('Competitive Differentiation')

pdf.body(
    'Rather than joining the race to build another AI agent (TwinMind, Mem.ai, Manus, ZoComputer), '
    'Parachute is the layer underneath all of them:', after=0.04
)

pdf.bullet('Agent-native \u2014 ',
    'Works with whatever AI you use via MCP. Every AI user is a potential customer.', after=0.02)
pdf.bullet('Capture over conversation \u2014 ',
    'Think for yourself first, bring AI in when ready. Independent thinking makes AI most useful.', after=0.02)
pdf.bullet('Deep memory \u2014 ',
    'A graph database queryable across months, not a flat text file.', after=0.02)
pdf.bullet('Open source (AGPL-3.0), local-first, PBC \u2014 ',
    'Trust required for people to share their deepest thinking.', after=0.02)
pdf.bullet('Context compounds \u2014 ',
    'Accumulated personal context can\'t be cloned. Switching cost is genuine value.',
    after=0.04)

pdf.heading('Market & Customer Analysis')

pdf.body(
    'Every AI subscriber is a potential customer \u2014 100M+ and growing. Comparables: TwinMind '
    '($5.7M at $60M val), Obsidian (~$25M ARR), Day One (~$4.8M ARR), Mem.ai ($28.6M raised). '
    'Two segments: (1) AI users wanting better context ($2/mo sync + MCP); (2) non-AI users wanting '
    'a great voice journal that gradually opens the AI ecosystem.'
)

pdf.bold_body('Validation: ',
    '300+ community members ready to onboard. We also run Learn Vibe Build, an AI learning school '
    'that teaches people to build with these tools \u2014 a direct organic growth channel where every '
    'participant becomes a Parachute user. Cohort 0 complete, Cohort 1 launching April 2026. '
    'Active private beta users.', after=0.04)

pdf.heading('Intellectual Property')

pdf.body(
    'AGPL-3.0 \u2014 copyleft license preventing proprietary forks. Defensible advantages: '
    'compounding user context, graph architecture, MCP integration, community trust.', after=0.04
)

pdf.heading('Management Team')

pdf.bullet('Aaron Gabriel Neyer (Founder) \u2014 ',
    'MA Ecopsychology, MS Creative Technology & Design (CU ATLAS, graduating May 2026). '
    'Founding engineer at two startups. Former Google. 10+ years full-stack.', after=0.02)
pdf.bullet('Jon Bo \u2014 ', 'Daily co-lead. Founding engineer at multiple startups.', after=0.02)
pdf.bullet('Lucian Hymer \u2014 ', 'Server co-lead. Founding engineer at multiple startups.', after=0.02)
pdf.bullet('Marvin Melzer \u2014 ', 'Hardware lead. Pendant prototype.', after=0.02)
pdf.bullet('Neil Yarnal \u2014 ', 'Brand and design.', after=0.02)
pdf.body('3\u20134 additional builders available, scaling team from 5 to 9\u201310.', after=0.04)

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

pdf.ln(0.04)
pdf.set_text_color(*FG)

pdf.bold_body('Revenue model: ',
    'Free (offline, $0 cost), $2/mo (sync + MCP), $5/mo (transcription), $10/mo (AI + vector search). '
    'Low COGS \u2014 transcription/embeddings, not heavy inference. Profitable by year three. '
    'Self-funded to date.', after=0.04)

pdf.heading('Investment')

pdf.body(
    'Raising $300,000 via SAFE (YC standard) at $5M cap. Early-believer terms \u2014 TwinMind raised '
    'at $60M with 30K users; we are raising pre-launch. Use of funds: core team full-time through '
    '2026, infrastructure, production launch June 2026. Revenue on launch, growth to raise next '
    'round by early 2027.', after=0.04
)

pdf.bold_body('NVC prize funds ($50,000): ',
    'Accelerate team ramp-up, broader beta distribution, earlier path to growth metrics.')

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
