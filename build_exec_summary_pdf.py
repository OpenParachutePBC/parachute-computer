"""Generate ES_Parachute.pdf — NVC Executive Summary.
Brand fonts, accent color, proper table styling. Max 3 pages.
1.5 line spacing, 12pt body, 1-inch margins per NVC requirements."""

from fpdf import FPDF

FONTS = '/home/sandbox/parachute-computer/fonts'
ACCENT = (74, 124, 89)      # #4a7c59
FG = (44, 42, 38)            # #2c2a26
FG_MUTED = (107, 104, 96)   # #6b6860
FG_DIM = (154, 150, 144)    # #9a9690
BG_SOFT = (243, 240, 234)   # #f3f0ea
BORDER = (228, 224, 216)    # #e4e0d8


class ExecSummaryPDF(FPDF):
    def __init__(self):
        super().__init__('P', 'in', 'Letter')
        self.set_auto_page_break(auto=True, margin=1.0)
        self.set_margins(1.0, 1.0, 1.0)
        self.lh = 0.24  # ~1.5 spacing at 12pt

        # Brand fonts
        self.add_font('Sans', '', f'{FONTS}/DMSans-Variable.ttf')
        self.add_font('Sans', 'I', f'{FONTS}/DMSans-Italic-Variable.ttf')
        # Use DM Sans bold via variable font (fpdf2 handles weight)
        self.add_font('SansB', '', f'{FONTS}/DMSans-Variable.ttf')
        self.add_font('Serif', '', f'{FONTS}/InstrumentSerif-Regular.ttf')
        self.add_font('Serif', 'I', f'{FONTS}/InstrumentSerif-Italic.ttf')
        # Fallback for bold (Vera)
        self.add_font('Vera', '', '/usr/local/lib/python3.13/site-packages/reportlab/fonts/Vera.ttf')
        self.add_font('Vera', 'B', '/usr/local/lib/python3.13/site-packages/reportlab/fonts/VeraBd.ttf')

    def footer(self):
        if self.page_no() > 1:
            self.set_y(-0.6)
            self.set_font('Sans', '', 8)
            self.set_text_color(*FG_DIM)
            self.cell(0, 0.2, f'Open Parachute PBC \u2014 Executive Summary', align='L')
            self.cell(0, 0.2, f'{self.page_no()}', align='R', new_x="LMARGIN")

    def heading(self, text):
        self.ln(0.08)
        self.set_font('Vera', 'B', 12)
        self.set_text_color(*ACCENT)
        self.cell(0, 0.24, text.upper(), new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(*FG)
        self.ln(0.04)

    def body(self, text, after=0.04):
        self.set_font('Sans', '', 12)
        self.set_text_color(*FG_MUTED)
        self.multi_cell(0, self.lh, text)
        self.set_text_color(*FG)
        self.ln(after)

    def bold_body(self, bold, rest, after=0.04):
        self.set_font('Vera', 'B', 12)
        self.set_text_color(*FG)
        bw = self.get_string_width(bold)
        self.cell(bw, self.lh, bold)
        self.set_font('Sans', '', 12)
        self.set_text_color(*FG_MUTED)
        rw = self.w - self.l_margin - self.r_margin - bw
        self.multi_cell(rw, self.lh, rest)
        self.set_text_color(*FG)
        self.ln(after)

    def bullet(self, bold, rest, after=0.04):
        indent = 0.25
        self.set_font('Sans', '', 12)
        self.set_text_color(*FG_DIM)
        self.cell(indent, self.lh, '\u2022 ')
        if bold:
            self.set_font('Vera', 'B', 12)
            self.set_text_color(*FG)
            bw = self.get_string_width(bold)
            self.cell(bw, self.lh, bold)
        self.set_font('Sans', '', 12)
        self.set_text_color(*FG_MUTED)
        rw = self.w - self.l_margin - self.r_margin - indent
        self.multi_cell(rw, self.lh, rest)
        self.set_text_color(*FG)
        self.ln(after)

    def divider(self):
        self.set_draw_color(*BORDER)
        self.line(self.l_margin, self.get_y(), self.w - self.r_margin, self.get_y())
        self.ln(0.08)


pdf = ExecSummaryPDF()
pdf.add_page()

# ── Title block ──
pdf.set_font('Serif', '', 22)
pdf.set_text_color(*FG)
pdf.cell(0, 0.35, 'Open Parachute PBC', new_x="LMARGIN", new_y="NEXT")
pdf.set_font('Sans', '', 12)
pdf.set_text_color(*FG_MUTED)
pdf.cell(0, 0.28, 'Executive Summary \u2014 CU New Venture Challenge 2026', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.12)

# Contact block
pdf.set_font('Vera', 'B', 10)
pdf.set_text_color(*FG)
pdf.cell(0, 0.2, 'Aaron Gabriel Neyer, Founder', new_x="LMARGIN", new_y="NEXT")
pdf.set_font('Sans', '', 10)
pdf.set_text_color(*FG_MUTED)
pdf.cell(0, 0.2, 'aaron@parachute.computer \u2022 Boulder, CO \u2022 parachute.computer', new_x="LMARGIN", new_y="NEXT")
pdf.cell(0, 0.2, 'Team: Jon Bo (Daily Co-lead), Lucian Hymer (Computer Co-lead), Marvin Melzer (Hardware), Neil Yarnal (Design)', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.08)
pdf.divider()

# ═══════ OPPORTUNITY SUMMARY ═══════
pdf.heading('Opportunity Summary')

pdf.body(
    'Personal agentic computing is the defining shift in how people interact with technology. '
    'Over 100 million people already pay $20+/month for AI. Tools like OpenClaw (300K+ GitHub stars in three months), '
    'Claude Cowork, ZoComputer, and Manus validate massive demand. The agentic AI market is projected to exceed '
    '$50B by 2030 at a 44% CAGR.'
)

pdf.body(
    'But nearly every player is building for the power user \u2014 roughly 5% of the addressable market. '
    'The other 95% \u2014 artists, small business owners, everyday people \u2014 have no accessible entry point. '
    'Parachute bridges that gap with two products: Parachute Daily, a voice-first journaling app that gently '
    'introduces AI, and Parachute Computer, a full open-source agentic platform. Daily builds the context '
    'that makes Computer powerful, creating a compounding moat no competitor can shortcut.'
)

# ═══════ PRODUCT OR SERVICE ═══════
pdf.heading('Product or Service')

pdf.bold_body(
    'Parachute Daily ',
    'is a voice-first journal. Speak into a wearable pendant or phone \u2014 on a walk, in the car, wherever '
    'thinking happens. Entries are transcribed (offline via on-device models), organized, and enhanced with '
    'AI reflections, pattern recognition, and weekly synthesis. Free offline; cloud transcription at $5/mo, '
    'AI features at $10/mo.'
)

pdf.bold_body(
    'Parachute Computer ',
    'is a full agentic computing platform with a knowledge graph (Brain) connecting journals, conversations, '
    'and structured data. Multi-agent teams, trust-tiered execution, and connectors to Telegram, Discord, '
    'and Matrix. Hosted at $40/mo or fully self-hosted for free.'
)

pdf.body(
    'The critical insight: context compounds. Every journal entry builds a richer knowledge graph. After months '
    'of Daily use, a user\'s system already understands how they think. When they upgrade to Computer, their '
    'brain comes with them. No competitor can replicate months of accumulated personal context.'
)

pdf.bold_body(
    'Current state: ',
    'Working Python/FastAPI server, Flutter app (macOS, Android, web), graph-native memory, local voice '
    'transcription (Sherpa-ONNX), multi-agent system, three bot connectors. Functional pendant prototype. '
    'Daily beta launching this month; production launch targeted June 2026. PBC incorporated in Colorado.'
)

# ═══════ COMPETITIVE DIFFERENTIATION ═══════
pdf.heading('Competitive Differentiation')

pdf.body(
    'Key players: OpenClaw, TwinMind ($5.7M at $60M val), Mem.ai ($28.6M raised), ZoComputer, Perplexity Computer, Manus. '
    'Parachute differentiates on three axes:'
)

pdf.bullet('The bridge to the 95%. ',
    'Competitors target power users. Daily gives everyday people a voice-first entry point requiring zero '
    'technical sophistication \u2014 just talk.')

pdf.bullet('Open source as trust. ',
    'Fully open source (AGPL-3.0) and local-first \u2014 data on user\'s device, portable, exportable. '
    'Public Benefit Corporation: legally mandated to serve users, not just shareholders.')

pdf.bullet('Context compounds as the moat. ',
    'Software gets cloned in a day. Compounding personal context cannot. Switching cost grows through '
    'genuine accumulated value, not lock-in.')

# ═══════ MARKET & CUSTOMER ANALYSIS ═══════
pdf.heading('Market & Customer Analysis')

pdf.body(
    'Agentic AI market: $50B+ by 2030 at 44% CAGR. Comparables: TwinMind ($5.7M raised, $60M val), '
    'Obsidian (~$25M ARR), Day One (~$4.8M ARR), Mem.ai ($28.6M raised). Two customer segments, one funnel:'
)

pdf.bullet('Daily users (mass market): ',
    'Entry at free, cloud transcription at $5/mo, AI features at $10/mo. The 95% who want AI to help but '
    'don\'t know where to start.')

pdf.bullet('Computer users (power users): ',
    '$40/mo hosted or free self-hosted. Builders who create tools and workflows benefiting the ecosystem.')

pdf.bold_body('Validation: ',
    '300+ community members ready to onboard. 13 builders completed first Learn Vibe Build AI cohort. '
    'Active private beta users providing feedback.')

# ═══════ INTELLECTUAL PROPERTY ═══════
pdf.heading('Intellectual Property')

pdf.body(
    'Open source under AGPL-3.0 \u2014 anyone running a modified version as a service must share changes, '
    'protecting against proprietary forks. Defensible advantages: compounding user context, knowledge graph '
    'architecture, community ecosystem, and trust earned by building in the open.', after=0.02
)

# ═══════ MANAGEMENT TEAM ═══════
pdf.heading('Management Team')

pdf.bullet('Aaron Gabriel Neyer (Founder) \u2014 ',
    'MA Ecopsychology, MS Creative Technology & Design (CU ATLAS). Founding engineer at two startups. '
    'Former Google. 10+ years full stack. Boulder Human Relations Commission Chair.')
pdf.bullet('Jon Bo \u2014 ', 'Daily co-lead. Founding engineer at multiple startups.')
pdf.bullet('Lucian Hymer \u2014 ', 'Computer co-lead. Founding engineer at multiple startups.')
pdf.bullet('Marvin Melzer \u2014 ', 'Hardware lead. Pendant prototype.')
pdf.bullet('Neil Yarnal \u2014 ', 'Brand and design.')
pdf.body('3\u20134 additional builders available for hire, scaling team from 4\u20135 to 9\u201310.', after=0.02)

# ═══════ FINANCIAL PROJECTIONS ═══════
pdf.heading('Financial Projections')

# Styled table
headers = ['', '2026', '2027', '2028']
data = [
    ['Free + sync users', '5,000', '50,000', '250,000'],
    ['Paid subscribers ($2\u201340/mo)', '500', '5,000', '25,000'],
    ['Avg rev / subscriber', '~$7/mo', '~$9/mo', '~$12/mo'],
    ['ARR', '~$42K', '~$540K', '~$3.6M'],
    ['Team costs', '~$150K', '~$400K', '~$800K'],
    ['Infra + COGS', '~$15K', '~$130K', '~$500K'],
    ['Total opex', '~$165K', '~$530K', '~$1.3M'],
]

col_w = [2.3, 1.15, 1.15, 1.15]
rh = 0.22
table_w = sum(col_w)
x_start = pdf.l_margin

# Header row with background
pdf.set_fill_color(*BG_SOFT)
pdf.set_draw_color(*BORDER)
pdf.set_font('Vera', 'B', 10)
pdf.set_text_color(*FG_DIM)
for i, h in enumerate(headers):
    pdf.cell(col_w[i], rh, h, border=1, align='L' if i == 0 else 'C', fill=True)
pdf.ln()

# Data rows
for r, row in enumerate(data):
    is_highlight = r == 3  # ARR row
    if is_highlight:
        pdf.set_fill_color(232, 245, 236)  # light green
    else:
        pdf.set_fill_color(255, 255, 255)

    for c, val in enumerate(row):
        if c == 0:
            pdf.set_font('Vera', 'B', 10)
            pdf.set_text_color(*FG)
        elif is_highlight:
            pdf.set_font('Vera', 'B', 10)
            pdf.set_text_color(*ACCENT)
        else:
            pdf.set_font('Sans', '', 10)
            pdf.set_text_color(*FG_MUTED)
        pdf.cell(col_w[c], rh, val, border=1, align='L' if c == 0 else 'C', fill=True)
    pdf.ln()

pdf.ln(0.06)
pdf.set_text_color(*FG)

pdf.bold_body('Revenue model: ',
    'Free (offline, zero cost), $2/mo (sync), $5/mo (cloud transcription), $10/mo (AI reflections + synthesis), '
    '$40/mo (hosted Computer). Margins improve as model costs decline.',
    after=0.03)

pdf.bold_body('Path to profitability: ',
    'Year two approaches breakeven (~$540K ARR vs ~$530K opex). Year three clearly profitable '
    '(~$3.6M ARR vs ~$1.3M opex). Self-funded to date: $0 outside investment.',
    after=0.03)

# ═══════ INVESTMENT ═══════
pdf.heading('Investment')

pdf.body(
    'Raising $300,000 via SAFE note (YC standard) at $5,000,000 valuation cap. Early-believer terms \u2014 '
    'TwinMind raised at $60M valuation with 30K users; we are raising before public launch.'
)

pdf.bold_body('Use of funds: ',
    'Core team full-time through 2026, infrastructure costs, production launch by June 2026. '
    'Goal: revenue immediately upon launch, growth to raise subsequent round by early 2027.')

pdf.body(
    'NVC prize funds ($50,000) would accelerate timeline \u2014 faster team ramp-up and broader beta distribution.'
)

# ── Save ──
pdf_path = '/home/sandbox/parachute-computer/website/nvc/ES_Parachute.pdf'
pdf.output(pdf_path)

with open(pdf_path, 'rb') as f:
    content = f.read()
    pages = content.count(b'/Type /Page') - content.count(b'/Type /Pages')
print(f'Saved PDF to {pdf_path} ({pages} pages)')
