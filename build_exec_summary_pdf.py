"""Generate ES_Parachute.pdf — NVC Executive Summary (pivoted narrative).
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
        self.lh = 0.22  # tighter to fit 3 pages

        # Brand fonts
        self.add_font('Sans', '', f'{FONTS}/DMSans-Variable.ttf')
        self.add_font('Sans', 'I', f'{FONTS}/DMSans-Italic-Variable.ttf')
        self.add_font('Serif', '', f'{FONTS}/InstrumentSerif-Regular.ttf')
        self.add_font('Serif', 'I', f'{FONTS}/InstrumentSerif-Italic.ttf')
        # Vera for bold
        self.add_font('Vera', '', '/usr/local/lib/python3.13/site-packages/reportlab/fonts/Vera.ttf')
        self.add_font('Vera', 'B', '/usr/local/lib/python3.13/site-packages/reportlab/fonts/VeraBd.ttf')

    def footer(self):
        if self.page_no() > 1:
            self.set_y(-0.6)
            self.set_font('Sans', '', 8)
            self.set_text_color(*FG_DIM)
            self.cell(0, 0.2, 'Open Parachute PBC \u2014 Executive Summary', align='L')
            self.cell(0, 0.2, f'{self.page_no()}', align='R', new_x="LMARGIN")

    def heading(self, text):
        self.ln(0.06)
        self.set_font('Vera', 'B', 11)
        self.set_text_color(*ACCENT)
        self.cell(0, 0.22, text.upper(), new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(*FG)
        self.ln(0.02)

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
pdf.cell(0, 0.2, 'Team: Jon Bo (Daily Co-lead), Lucian Hymer (Server Co-lead), Marvin Melzer (Hardware), Neil Yarnal (Design)', new_x="LMARGIN", new_y="NEXT")
pdf.ln(0.08)
pdf.divider()

# ═══════ OPPORTUNITY SUMMARY ═══════
pdf.heading('Opportunity Summary')

pdf.body(
    'Over 100 million people pay $20+/month for AI. The agentic AI market is projected to exceed '
    '$50B by 2030 at a 44% CAGR. But features get cloned in weeks \u2014 it\'s a race to the bottom. '
    'And every platform\'s memory is shallow: basically one big text file. No structured knowledge about '
    'your projects, people, or patterns. And there\'s a deeper problem: how does your thinking get into the '
    'system? You can talk to your AI, but there\'s no good way to think for yourself and have that become context.'
)

pdf.body(
    'Parachute solves both. Parachute Daily is a voice-first journal that makes it effortless to capture '
    'your thinking. Under the hood, notes live in a graph database any AI can access via MCP (Model Context '
    'Protocol). You don\'t switch AI tools \u2014 you add Parachute, and whatever AI you use gets better.'
)

# ═══════ PRODUCT OR SERVICE ═══════
pdf.heading('Product or Service')

pdf.bold_body(
    'Parachute Daily ',
    'is the first product. Users speak into a wearable pendant or phone \u2014 on a walk, in the car, '
    'wherever thinking happens. Entries are transcribed (offline via on-device models), organized, and '
    'structured. Free offline; cloud sync + MCP at $2/mo, cloud transcription at $5/mo, '
    'AI reflections + vector search at $10/mo.'
)

pdf.bold_body(
    'Under the hood: ',
    'a graph database organized around three primitives \u2014 Things, Tags, and Tools. '
    'Because the system speaks MCP, any AI can read, search, and create structure: people nodes, '
    'project nodes, linked contact info. Your notes become a living knowledge graph.'
)

pdf.bold_body(
    'The Pendant: ',
    'wearable voice capture. Press a button, talk, thoughts transcribed and structured by the time '
    'you\'re home. Working prototype with custom enclosure.'
)

pdf.bold_body(
    'Current state: ',
    'Python/FastAPI server, Flutter app, graph-native storage, local transcription (Sherpa-ONNX), '
    'MCP server. Pendant prototype. Beta launching this month; production launch June 2026. PBC incorporated.'
)

# ═══════ COMPETITIVE DIFFERENTIATION ═══════
pdf.heading('Competitive Differentiation')

pdf.body(
    'Rather than joining the race to build another agent, Parachute is the layer underneath all of them:'
)

pdf.bullet('Agent-native, not agent-competitive. ',
    'Works with whatever AI you already use via MCP. Every AI user is a potential customer, '
    'not just people willing to migrate.')

pdf.bullet('Capture over conversation. ',
    'Tools that help us think for ourselves \u2014 not just think with AI \u2014 produce the quality '
    'of thinking that makes AI most useful.')

pdf.bullet('Deep memory, not shallow. ',
    'A real graph database queryable across months and years, not a flat text file of preferences.')

pdf.bullet('Open source as trust. ',
    'AGPL-3.0, local-first, data on your device. Public Benefit Corporation. '
    'The trust required for people to share their deepest thinking.', after=0.02)

# ═══════ MARKET & CUSTOMER ANALYSIS ═══════
pdf.heading('Market & Customer Analysis')

pdf.body(
    'Every AI user is a potential customer \u2014 100M+ people paying $20+/mo and growing. Plus everyone '
    'who wants a great journal. Comparables: TwinMind ($5.7M at $60M val), Obsidian (~$25M ARR), '
    'Day One (~$4.8M ARR), Mem.ai ($28.6M raised). Two segments: AI users ($2/mo sync + MCP is a '
    'no-brainer) and non-AI users (voice-first journal, pendant, AI-light features as on-ramp).'
)

pdf.bold_body('Validation: ',
    '300+ community members ready to onboard. 13 builders completed first Learn Vibe Build cohort. '
    'Active private beta users providing feedback.', after=0.02)

# ═══════ INTELLECTUAL PROPERTY ═══════
pdf.heading('Intellectual Property')

pdf.body(
    'AGPL-3.0 \u2014 anyone running a modified version as a service must share changes. '
    'Defensible advantages: compounding user context, graph architecture, MCP layer, '
    'community ecosystem, and trust earned by building in the open.', after=0.02
)

# ═══════ MANAGEMENT TEAM ═══════
pdf.heading('Management Team')

pdf.bullet('Aaron Gabriel Neyer (Founder) \u2014 ',
    'MA Ecopsychology, MS Creative Technology & Design (CU ATLAS). Founding engineer at two startups. '
    'Former Google. 10+ years full stack. Boulder Human Relations Commission Chair.')
pdf.bullet('Jon Bo \u2014 ', 'Daily co-lead. Founding engineer at multiple startups.')
pdf.bullet('Lucian Hymer \u2014 ', 'Server co-lead. Founding engineer at multiple startups.')
pdf.bullet('Marvin Melzer \u2014 ', 'Hardware lead. Pendant prototype.')
pdf.bullet('Neil Yarnal \u2014 ', 'Brand and design.')
pdf.body('3\u20134 additional builders available for hire, scaling team from 4\u20135 to 9\u201310.', after=0.02)

# ═══════ FINANCIAL PROJECTIONS ═══════
pdf.heading('Financial Projections')

# Styled table
headers = ['', '2026', '2027', '2028']
data = [
    ['Free users', '5,000', '75,000', '500,000'],
    ['Paid subscribers ($2\u201310/mo)', '500', '8,000', '50,000'],
    ['Avg rev / subscriber', '~$5/mo', '~$5/mo', '~$5/mo'],
    ['ARR', '~$30K', '~$480K', '~$3M'],
    ['Team costs', '~$150K', '~$400K', '~$800K'],
    ['Infra + COGS', '~$10K', '~$100K', '~$400K'],
    ['Total opex', '~$160K', '~$500K', '~$1.2M'],
]

col_w = [2.3, 1.15, 1.15, 1.15]
rh = 0.22

# Header row
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
        pdf.set_fill_color(232, 245, 236)
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
    'Free (offline, zero cost), $2/mo (sync + MCP), $5/mo (transcription), $10/mo (AI + vector search). '
    '100M+ AI users are all potential customers. Lower COGS \u2014 transcription and embeddings, '
    'not heavy inference. Year two approaches breakeven; year three clearly profitable. '
    'Self-funded to date: $0 outside investment.',
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
    'NVC prize funds would accelerate timeline \u2014 faster team ramp-up and broader beta distribution.'
)

# ── Save ──
pdf_path = '/home/sandbox/parachute-computer/website/nvc/ES_Parachute.pdf'
pdf.output(pdf_path)

with open(pdf_path, 'rb') as f:
    content = f.read()
    pages = content.count(b'/Type /Page') - content.count(b'/Type /Pages')
print(f'Saved PDF to {pdf_path} ({pages} pages)')
