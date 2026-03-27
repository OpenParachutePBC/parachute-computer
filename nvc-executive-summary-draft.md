# Open Parachute PBC — Executive Summary

**Startup:** Open Parachute PBC (Colorado Public Benefit Corporation)
**Founder:** Aaron Gabriel Neyer — aaron@parachute.computer
**Team:** Jon Bo (Daily Co-lead), Lucian Hymer (Computer Co-lead), Marvin Melzer (Hardware), Neil Yarnal (Brand & Design)
**Location:** Boulder, Colorado

---

## Opportunity Summary

Personal agentic computing is the defining shift in how people interact with technology. In the last six months, tools like OpenClaw (300,000+ GitHub stars in three months), Claude Cowork, ZoComputer, and Perplexity Computer have validated that people want an AI that works for them — not just answering questions but taking action, managing tools, and learning who they are over time. Over 100 million people already pay $20+/month for AI — including 50M+ ChatGPT Pro subscribers. The agentic AI market is projected to exceed $50B by 2030 at a 44% CAGR, and OpenAI alone projects $200B in annual revenue by that year.

But nearly every player is building for the power user — the person already paying $20-200/month and comfortable handing an AI agent full access to their digital life. That's roughly 5% of the addressable market. The other 95% — artists, small business owners, everyday people who know AI could help but don't know where to start — have no accessible entry point into this future. Parachute bridges that gap with two products that form one journey: **Parachute Daily**, a voice-first journaling app that gently introduces AI into daily life, and **Parachute Computer**, a full open-source agentic platform. Daily builds the context that makes Computer powerful, creating a natural upgrade path and a compounding moat that no competitor can shortcut.

## Product or Service

**Parachute Daily** is a voice-first journal. Users speak into a wearable pendant or their phone — on a walk, in the car, wherever thinking happens. Entries are transcribed (offline-capable via on-device models), organized, and enhanced with AI-powered daily reflections, pattern recognition, and weekly synthesis. It works fully offline as a simple journal for free; cloud transcription unlocks at $5/month and AI features at $10/month.

**Parachute Computer** is a full personal agentic computing platform. It includes a knowledge graph (Brain) that connects journals, conversations, and structured data into a unified model of the user's thinking. It supports multi-agent teams, trust-tiered execution (from sandboxed to full system access), and connectors to Telegram, Discord, and other messaging platforms. Available as a hosted service at $40/month or fully self-hosted for free.

The critical insight is that **context compounds**. Every journal entry, every conversation, every voice note builds a richer knowledge graph. After months of Daily use, a user's system already understands how they think, what they care about, and what they're working on. When they're ready for more, they upgrade to Parachute Computer and their brain comes with them. This compounding context is both the core user value and the primary switching cost — no competitor can replicate months of accumulated personal context.

**Current state of development:** Working Python/FastAPI server, Flutter app (macOS, Android, web), graph-native memory infrastructure, local voice transcription via Sherpa-ONNX, multi-agent system, and three bot connectors (Telegram, Discord, Matrix). Functional pendant prototype with custom Parachute enclosure. Daily beta launching this month, with a polished production launch targeted for June 2026. OpenParachute PBC incorporated in Colorado.

## Competitive Differentiation

The personal AI space is crowded and accelerating. Key players include OpenClaw (open-source agentic platform), TwinMind ($5.7M raised at $60M valuation), Mem.ai ($28.6M raised), ZoComputer, Perplexity Computer, and Manus. Parachute differentiates on three axes:

**1. The bridge to the 95%.** Competitors target power users who are already bought into AI. Parachute Daily gives everyday people a simple, voice-first entry point that requires no technical sophistication — just talk. This opens the mass market that every other player is ignoring.

**2. Open source as trust.** An AI works best when it knows everything about you. People will only share that depth of context with a system they trust. Parachute is fully open source (AGPL-3.0) and local-first — data lives on the user's device, portable and exportable. As a Public Benefit Corporation, our legal structure mandates that we consider the interests of our users, not just our shareholders.

**3. Context compounds as the real moat.** Software can be cloned in a day. Compounding personal context cannot. Every day a user journals, reflects, and converses with their AI, the switching cost grows — not through lock-in, but through genuine accumulated value that no competitor can replicate.

## Market and Customer Analysis

The personal AI and productivity AI market is growing at 44% CAGR, from projected to exceed $50B by 2030. Adjacent comparables demonstrate strong investor interest and viable business models: TwinMind ($5.7M raised at $60M valuation), Obsidian (~$25M ARR as a note-taking tool), Day One (~$4.8M ARR as a journaling app), and Mem.ai ($28.6M raised for AI-powered knowledge management).

We target two customer segments through one funnel:

- **Daily users (mass market):** People who aren't yet bought into AI but will journal, capture thoughts, and gradually experience AI's value in their lives. This is the 95% — the artist who wants to organize creative ideas, the small business owner tracking their days, the parent who wants a better way to remember and reflect. Entry at free, cloud transcription at $5/month, AI features at $10/month.

- **Computer users (power users):** Builders and professionals who want a full agentic AI platform they own and trust. $40/month hosted or free self-hosted. These users also create tools, integrations, and workflows that benefit the broader ecosystem.

**Validation:** 300+ community members in our Boulder ecosystem ready to onboard. 13 builders completed our first Learn Vibe Build AI learning cohort. Active users in private beta providing ongoing feedback.

## Intellectual Property

Parachute is open source under the AGPL-3.0 license. This is a deliberate strategic choice: AGPL requires that anyone who runs a modified version of Parachute as a service must share their changes, protecting against proprietary forks competing against us. Our defensible advantages are the compounding user context (which lives with each user), the knowledge graph architecture, the community ecosystem, and the trust earned by building in the open. We believe open source is a competitive advantage — it builds the trust necessary for people to share their thinking with an AI system.

## Management Team

- **Aaron Gabriel Neyer** (Founder) — Product vision and system architecture. MA in Ecopsychology, MS in Creative Technology & Design (CU Boulder ATLAS). Founding engineer at two startups. Former Google. 10+ years full stack development. Boulder Human Relations Commission Chair. Founder of Woven Web (501(c)(3) nonprofit).
- **Jon Bo** — Daily co-lead. Founding engineer at multiple startups. Leading product direction for Parachute Daily.
- **Lucian Hymer** — Computer co-lead. Founding engineer at multiple startups. Leading architecture for the full agentic platform.
- **Marvin Melzer** — Hardware lead. Developing the wearable pendant prototype. Experienced hardware designer and engineer.
- **Neil Yarnal** — Brand and design.
- An additional 3-4 experienced builders are available for hire as funding increases, enabling the team to scale from a core of 4-5 to 9-10.

## Financial Projections

|  | 2026 | 2027 | 2028 |
|---|---|---|---|
| Free + sync users | 5,000 | 50,000 | 250,000 |
| Paid subscribers ($2-40/mo) | 500 | 5,000 | 25,000 |
| Avg revenue per paid subscriber | ~$7/mo | ~$9/mo | ~$12/mo |
| ARR | ~$42K | ~$540K | ~$3.6M |
| Team costs | ~$150K | ~$400K | ~$800K |
| Infra + COGS | ~$15K | ~$130K | ~$500K |
| Total opex | ~$165K | ~$530K | ~$1.3M |

**Revenue model:** Tiered subscriptions — Free (offline journal), $2/mo (cloud sync), $5/mo (cloud transcription + cleanup), $10/mo (AI reflections, synthesis, pattern surfacing), $40/mo (hosted Parachute Computer). The free tier is fully offline with no hosting cost — no subsidizing free users. Infrastructure costs include cloud transcription (~$1.50/1000 min) and AI inference (cost-efficient models for reflections). As model costs continue to decline, margins improve further.

**Path to profitability:** Year two approaches breakeven (~$540K ARR vs ~$530K total opex). Year three is clearly profitable (~$3.6M ARR vs ~$1.3M total opex) as the subscriber mix shifts toward higher tiers and infrastructure costs scale sub-linearly. Average revenue per subscriber increases over time as users' context compounds and they naturally upgrade — the product gets more valuable the longer you use it, which drives organic upselling.

**Funding to date:** $0. The entire product has been self-funded with no outside investment.

## Investment

Raising $300,000 via a SAFE note (YC standard) at a $5,000,000 valuation cap. This is deliberately priced as early-believer terms — TwinMind raised at a $60M valuation with 30,000 users; we are raising before public launch.

**Use of funds:** Bring the core team (founder + two co-leads) full-time through 2026, fund infrastructure and hosting costs, and execute a polished production launch by June 2026. The goal is revenue immediately upon launch, with sufficient growth to raise a subsequent round by early 2027 at a significantly higher valuation, scaling the team from 4-5 to 9-10.

**NVC prize funds** would accelerate this timeline — enabling faster team ramp-up and broader beta distribution.
