"""Generate ES_Parachute.pdf — NVC Executive Summary. Max 3 pages content.
1.5 line spacing, 12pt font, 1-inch margins per NVC requirements."""

from fpdf import FPDF

VERA = '/usr/local/lib/python3.13/site-packages/reportlab/fonts/Vera.ttf'
VERA_BD = '/usr/local/lib/python3.13/site-packages/reportlab/fonts/VeraBd.ttf'
VERA_IT = '/usr/local/lib/python3.13/site-packages/reportlab/fonts/VeraIt.ttf'
VERA_BI = '/usr/local/lib/python3.13/site-packages/reportlab/fonts/VeraBI.ttf'


class ExecSummaryPDF(FPDF):
    def __init__(self):
        super().__init__('P', 'in', 'Letter')
        self.set_auto_page_break(auto=True, margin=1.0)
        self.set_margins(1.0, 1.0, 1.0)
        self.lh = 0.24  # ~1.5 spacing at 12pt
        self.add_font('Vera', '', VERA)
        self.add_font('Vera', 'B', VERA_BD)
        self.add_font('Vera', 'I', VERA_IT)
        self.add_font('Vera', 'BI', VERA_BI)

    def heading(self, text):
        self.ln(0.06)
        self.set_font('Vera', 'B', 12)
        self.cell(0, 0.24, text, new_x="LMARGIN", new_y="NEXT")
        self.ln(0.03)

    def body(self, text, after=0.04):
        self.set_font('Vera', '', 12)
        self.multi_cell(0, self.lh, text)
        self.ln(after)

    def bold_body(self, bold, rest, after=0.04):
        self.set_font('Vera', 'B', 12)
        bw = self.get_string_width(bold)
        self.cell(bw, self.lh, bold)
        self.set_font('Vera', '', 12)
        rw = self.w - self.l_margin - self.r_margin - bw
        self.multi_cell(rw, self.lh, rest)
        self.ln(after)

    def bullet(self, bold, rest, after=0.04):
        indent = 0.25
        self.set_font('Vera', '', 12)
        self.cell(indent, self.lh, '\u2022 ')
        if bold:
            self.set_font('Vera', 'B', 12)
            bw = self.get_string_width(bold)
            self.cell(bw, self.lh, bold)
            self.set_font('Vera', '', 12)
        rw = self.w - self.l_margin - self.r_margin - indent
        self.multi_cell(rw, self.lh, rest)
        self.ln(after)


pdf = ExecSummaryPDF()
pdf.add_page()

# ── Cover info (doesn't count toward page limit) ──
pdf.set_font('Vera', 'B', 16)
pdf.cell(0, 0.3, 'Open Parachute PBC \u2014 Executive Summary', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.08)
pdf.set_font('Vera', '', 10)
for line in [
    'Open Parachute PBC (Colorado Public Benefit Corporation)',
    'Aaron Gabriel Neyer, Founder \u2014 aaron@parachute.computer \u2014 Boulder, CO',
    'Team: Jon Bo (Daily Co-lead), Lucian Hymer (Computer Co-lead), Marvin Melzer (Hardware), Neil Yarnal (Design)',
]:
    pdf.cell(0, 0.2, line, new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.06)
pdf.set_draw_color(180, 180, 180)
pdf.line(1.0, pdf.get_y(), 7.5, pdf.get_y())
pdf.ln(0.06)

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
pdf.heading('Market and Customer Analysis')

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

# ═══════ IP & TEAM (combined to save space) ═══════
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

pdf.set_font('Vera', '', 10)
col_w = [2.2, 1.2, 1.2, 1.2]
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
rh = 0.2

pdf.set_font('Vera', 'B', 10)
for i, h in enumerate(headers):
    pdf.cell(col_w[i], rh, h, border=1, align='L' if i == 0 else 'C')
pdf.ln()

for r, row in enumerate(data):
    for c, val in enumerate(row):
        if c == 0 or (r == 3 and c > 0):
            pdf.set_font('Vera', 'B', 10)
        else:
            pdf.set_font('Vera', '', 10)
        pdf.cell(col_w[c], rh, val, border=1, align='L' if c == 0 else 'C')
    pdf.ln()

pdf.ln(0.06)
pdf.set_font('Vera', '', 12)

pdf.bold_body('Revenue model: ',
    'Free (offline, zero cost), $2/mo (sync), $5/mo (cloud transcription), $10/mo (AI reflections + synthesis), '
    '$40/mo (hosted Computer). Margins improve as model costs decline.',
    after=0.04)

pdf.bold_body('Path to profitability: ',
    'Year two approaches breakeven (~$540K ARR vs ~$530K opex). Year three clearly profitable '
    '(~$3.6M ARR vs ~$1.3M opex). Self-funded to date: $0 outside investment.',
    after=0.04)

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

# Check pages
with open(pdf_path, 'rb') as f:
    content = f.read()
    pages = content.count(b'/Type /Page') - content.count(b'/Type /Pages')
print(f'Saved PDF to {pdf_path} ({pages} pages)')
