# Open Parachute PBC — Executive Summary

**Startup:** Open Parachute PBC (Colorado Public Benefit Corporation)
**Founder:** Aaron Gabriel Neyer — aaron@parachute.computer
**Team:** Jon Bo (Daily Co-lead), Lucian Hymer (Computer Co-lead), Marvin Melzer (Hardware), Neil Yarnal (Brand & Design)
**Location:** Boulder, Colorado

---

## Opportunity Summary

Personal agentic computing is the defining shift in how people interact with technology. In the last six months, tools like OpenClaw (300,000+ GitHub stars in three months), Claude Cowork, ZoComputer, and Perplexity Computer have validated that people want an AI that works for them — not just answering questions but taking action, managing tools, and learning who they are over time. Hundreds of millions of people already pay $20-200/month for AI tools. The agentic AI market is projected to exceed $50B by 2030 at a 44% CAGR, and OpenAI alone projects $200B in annual revenue by that year.

But nearly every player is building for the power user — the person already paying $20-200/month and comfortable handing an AI agent full access to their digital life. That's roughly 5% of the addressable market. The other 95% — artists, small business owners, everyday people who know AI could help but don't know where to start — have no accessible entry point into this future. Parachute bridges that gap with two products that form one journey: **Parachute Daily**, a voice-first journaling app that gently introduces AI into daily life, and **Parachute Computer**, a full open-source agentic platform. Daily builds the context that makes Computer powerful, creating a natural upgrade path and a compounding moat that no competitor can shortcut.

## Product or Service

**Parachute Daily** is a voice-first journal. Users speak into a wearable pendant or their phone — on a walk, in the car, wherever thinking happens. Entries are transcribed (offline-capable via on-device models), organized, and enhanced with AI-powered daily reflections, pattern recognition, and weekly synthesis. It works fully offline as a simple journal for free; cloud sync and AI features unlock at accessible price points ($1-5/month).

**Parachute Computer** is a full personal agentic computing platform. It includes a knowledge graph (Brain) that connects journals, conversations, and structured data into a unified model of the user's thinking. It supports multi-agent teams, trust-tiered execution (from sandboxed to full system access), and connectors to Telegram, Discord, and other messaging platforms. Available as a hosted service at $20/month or fully self-hosted for free.

The critical insight is that **context compounds**. Every journal entry, every conversation, every voice note builds a richer knowledge graph. After months of Daily use, a user's system already understands how they think, what they care about, and what they're working on. When they're ready for more, they upgrade to Parachute Computer and their brain comes with them. This compounding context is both the core user value and the primary switching cost — no competitor can replicate months of accumulated personal context.

**Current state of development:** Working Python/FastAPI server, Flutter app (macOS, Android, web), graph-native memory infrastructure, local voice transcription via Sherpa-ONNX, multi-agent system, and three bot connectors (Telegram, Discord, Matrix). Over 200 pull requests merged since January 2026. Functional pendant prototype with custom Parachute enclosure. Beta launch planned for April 2026, with a polished production launch targeted for June 2026.

## Competitive Differentiation

The personal AI space is crowded and accelerating. Key players include OpenClaw (open-source agentic platform), TwinMind ($5.7M raised at $60M valuation), Mem.ai ($28.6M raised), ZoComputer, Perplexity Computer, and Manus. Parachute differentiates on three axes:

**1. The bridge to the 95%.** Competitors target power users who are already bought into AI. Parachute Daily gives everyday people a simple, voice-first entry point that requires no technical sophistication — just talk. This opens the mass market that every other player is ignoring.

**2. Open source as trust.** An AI works best when it knows everything about you. People will only share that depth of context with a system they trust. Parachute is fully open source (AGPL-3.0) and local-first — data lives on the user's device, portable and exportable. As a Public Benefit Corporation, our legal structure mandates that we consider the interests of our users, not just our shareholders.

**3. Context compounds as the real moat.** Software can be cloned in a day. Compounding personal context cannot. Every day a user journals, reflects, and converses with their AI, the switching cost grows — not through lock-in, but through genuine accumulated value that no competitor can replicate.

## Market and Customer Analysis

The personal AI and productivity AI market is growing at 44% CAGR, from projected to exceed $50B by 2030. Adjacent comparables demonstrate strong investor interest and viable business models: TwinMind ($5.7M raised at $60M valuation), Obsidian (~$25M ARR as a note-taking tool), Day One (~$4.8M ARR as a journaling app), and Mem.ai ($28.6M raised for AI-powered knowledge management).

We target two customer segments through one funnel:

- **Daily users (mass market):** People who aren't yet bought into AI but will journal, capture thoughts, and gradually experience AI's value in their lives. This is the 95% — the artist who wants to organize creative ideas, the small business owner tracking their days, the parent who wants a better way to remember and reflect. Entry at free or $1-5/month.

- **Computer users (power users):** Builders and professionals who want a full agentic AI platform they own and trust. $20/month hosted or free self-hosted. These users also create tools, integrations, and workflows that benefit the broader ecosystem.

**Validation:** 300+ community members in our Boulder ecosystem ready to onboard. 13 builders completed our first Learn Vibe Build AI learning cohort. Active users in private beta providing ongoing feedback.

## Intellectual Property

Parachute is open source under the AGPL-3.0 license. This is a deliberate strategic choice: AGPL requires that anyone who runs a modified version of Parachute as a service must share their changes, protecting against proprietary forks competing against us. Our defensible advantages are the compounding user context (which lives with each user), the knowledge graph architecture, the community ecosystem, and the trust earned by building in the open. We believe open source is a competitive advantage — it builds the trust necessary for people to share their thinking with an AI system.

## Management Team

- **Aaron Gabriel Neyer** (Founder) — Product vision and system architecture. Graduate of CU Boulder ATLAS Institute (Creative Technology & Design). Built the entire system solo with zero funding. Boulder Human Relations Commission Chair. Founder of Woven Web (501(c)(3) nonprofit).
- **Jon Bo** — Daily co-lead. Founding engineer at multiple startups. Leading product direction for Parachute Daily.
- **Lucian Hymer** — Computer co-lead. Founding engineer at multiple startups. Leading architecture for the full agentic platform.
- **Marvin Melzer** — Hardware lead. Developing the wearable pendant prototype. Experienced hardware designer and engineer.
- **Neil Yarnal** — Brand and design.
- An additional 3-4 experienced builders are available for hire as funding increases, enabling the team to scale from a core of 4-5 to 9-10.

## Financial Projections

|  | 2026 | 2027 | 2028 |
|---|---|---|---|
| Free + sync users | 5,000 | 50,000 | 250,000 |
| Paid subscribers ($2-20/mo) | 500 | 5,000 | 25,000 |
| Avg revenue per paid subscriber | ~$5/mo | ~$7/mo | ~$8/mo |
| MRR (end of year) | ~$2,500 | ~$35,000 | ~$200,000 |
| ARR (end of year) | ~$30K | ~$420K | ~$2.4M |
| Team (salaried) | 3 | 5-6 | 9-10 |
| Annual operating costs | ~$170K | ~$550K | ~$900K |

**Revenue model:** Tiered subscriptions. Free tier is fully offline with no hosting cost — paid users are not subsidizing free users, enabling healthy margins from the start. AI inference at the $2-5/month tiers is lightweight (daily reflections on 50-100K tokens using cost-efficient models like Nvidia Nemotron), keeping per-user costs minimal. As model inference costs continue to decline through 2026-2027, margins improve further.

**Path to profitability:** The company reaches profitability in 2028. Average revenue per subscriber increases over time as users' context compounds and they naturally upgrade to higher tiers — the product gets more valuable the longer you use it, which drives organic upselling.

**Funding to date:** $0. The entire product has been built by the founder with no outside funding.

## Investment

We are raising $300,000 over the next three months via a SAFE note at a $5,000,000 valuation cap, giving away less than 10% of the company. This is deliberately priced as early-believer terms — TwinMind raised at a $60M valuation with 30,000 users; we are raising before public launch to bring in the right investors at the right moment.

**Use of funds:** Pay the core team (founder + two co-leads) to build full-time through 2026, fund infrastructure and hosting costs, and execute a polished production launch by June 2026. The goal is to develop a revenue-generating product and demonstrate sufficient growth to raise a subsequent round by early 2027 at a significantly higher valuation ($50-100M+), scaling the team from 4-5 to 9-10.

**NVC prize funds** would accelerate this timeline — enabling faster team ramp-up and broader beta distribution.
