---
layout: post.njk
title: "Opening the Parachute"
subtitle: "Building an extended mind for the year ahead"
date: 2026-01-01T12:00:00
author: "Aaron G Neyer"
permalink: /blog/opening-the-parachute/
description: "Building an extended mind for the year ahead"
substack_url: "https://openparachute.substack.com/p/opening-the-parachute"
---

![Parachute header image](https://substack-post-media.s3.amazonaws.com/public/images/ef6f8040-27ae-4372-95dc-9f3d80bcbd31_1376x768.png)

There's a Frank Zappa quote that's stayed with me: "The mind is like a parachute—it doesn't work if it's not open."

I've been looking for a good "second brain" tool for over a decade. Notion, Obsidian, Tana—each one taught me something about what I wanted, but none quite fit the way I actually think.

The friction was always the same. I'd have a thought while walking—something worth keeping—and by the time I pulled out my phone, opened the app, navigated to the right place... the thought had started slipping away. Or I'd sit down to journal, but the blank page felt like a wall. Or I'd have voice memos scattered in one app, typed notes in another, and no way to see them together.

Meanwhile, the past few years have brought AI tools that can genuinely help you think. But here's what I keep noticing: the AI that knows you best is the one that can actually help. And most of us aren't sharing our real thinking—the messy, unfiltered stuff—with tools we don't fully trust.

So I've been building something different.

---

## What is Parachute?

Parachute is local-first, voice-first software for thought. It's an "extended mind" that meets you where you actually think—on walks, in the car, away from the desk—not just when you're sitting at a keyboard.

The idea is simple: **instead of you learning the system, the system learns you.**

Most productivity tools ask you to become the architect of your own knowledge system. Design your folder structure. Choose tagging conventions. Decide on note formats. That works for some people. It never quite worked for me.

Parachute takes a different approach. You capture freely—by voice, by typing, by handwriting, by snapping a photo—and the tool helps with the rest. Your data stays on your devices in plain markdown files. You own it completely.

It's open source. AGPL licensed, genuinely community-first. That matters because the only way to earn trust with personal context is to be transparent about what's happening with your data.

---

## Parachute Daily

Daily is a journaling app that works entirely on your device. No server, no account, no subscription.

**Multiple ways to capture:**

- Voice recording with on-device transcription (powered by Parakeet)
- Typing when you're at a desk
- Handwriting via stylus or finger
- Photo capture for paper journals, sketches, whiteboard notes

Everything saves as standard markdown, organized by date. You can open your journal in Obsidian or any text editor. And semantic search helps you find past thoughts by meaning—even when you don't remember the exact words you used.

The transcription runs on your device. Your audio files stay on your device. There's no server involved.

Daily runs on macOS, Android, and iOS. We're currently onboarding beta testers—if you want early access, you can [sign up here](https://tally.so/r/D4kK6l).

→ [github.com/OpenParachutePBC/parachute-daily](https://github.com/OpenParachutePBC/parachute-daily)

---

## Parachute Chat

Chat is an AI companion that knows your context. It uses Claude under the surface and has access to your journal entries, notes, and whatever context you want to share with it.

This is where things get interesting.

If you've used ChatGPT or Claude, you know the pattern: every conversation starts fresh. You have to re-explain your situation each time. Progress is being made here but it's still messy and you have little control over it. Parachute Chat is different—it picks up where you left off. It knows your ongoing projects, your recurring questions, the things you've been thinking about. And you can guide it to work how you want it to.

And if you've used Claude Code, you know how powerful it can be to have an AI that actually works with your files—reading, searching, making changes. Chat brings that same capability to everyone, not just developers. You can use it as a regular chat interface for thinking through problems, or you can point it at a project and have it help you work.

**Where it is today:** Right now, Chat connects to a server (Parachute Base) that you run on your own machine—your laptop, or a computer you leave always-on at home. You can use something like Tailscale to access it from anywhere on your own private network. This setup is for people comfortable running their own software, or who have a friend who can help.

**Where it's going:** We're working to make this much more accessible. That might mean a hosted option that handles the server for you, or simpler ways to get Base running locally. The goal is to bring the kind of flexibility you find in tools like Claude Code to everyone—not just the technically inclined.

Chat is open source and available now:
→ [github.com/OpenParachutePBC/parachute-chat](https://github.com/OpenParachutePBC/parachute-chat)
→ [github.com/OpenParachutePBC/parachute](https://github.com/OpenParachutePBC/parachute) (full ecosystem)

It's early—there are rough edges—but it's real and usable.

---

## The Principles

A few things have guided the work:

**Local-first.** Your data lives on your devices in plain files. We use tools like Syncthing or Git for sync—no Parachute servers involved. If we disappeared tomorrow, your notes would still be there, readable in any text editor.

**Voice-first.** Talking is often more natural than typing. It's also accessible when typing isn't—while walking, while cooking, while your hands are full. We want to meet people where their thinking actually happens.

**Open source as trust.** The only way to deserve trust with personal thinking is transparency. You can see exactly what the software does.

**AI as partner.** The goal isn't to automate your thinking. It's to help you think more clearly, remember more completely, make connections you might have missed.

---

## Where We're Going

There's a lot ahead. Better search across your vault. More ways to sync. Simpler setup for Chat. Agents that help with specific thinking tasks—processing meeting notes, doing weekly reviews, surfacing patterns.

But what excites me most is what the community will build. The modular architecture, the standard file formats, the interoperability with other tools—it's all designed so people can take this in directions I haven't imagined.

---

## The Team

Parachute wouldn't be where it is without the people who've helped build it.

**[Jon Bo](https://jon.bo/)** has been my co-founder and primary thought partner throughout—shaping the vision and working through the hard problems together, always helping me return to simplicity when I make everything too complicated.

**[Lucian Hymer](http://www.lucianhymer.com/)** has made meaningful contributions to the architecture and development, both directly as well as indirectly through the variety of [open source](https://github.com/lucianHymer?tab=repositories) projects he continues developing which feed right into Parachute.

**[Neil Yarnal](https://www.neilyarnal.com/)** has helped shaped the [branding and design](https://www.localasterisk.agency/) that gives Parachute its identity and has been an incredibly vital thought partner in being able to look fresh at Parachute as a product and as a company from both the inside and outside.

This is a small team building something we believe in.

---

## Get Involved

**Want to try Daily?** We're onboarding beta testers now.

[Sign up for the Daily beta →](https://tally.so/r/D4kK6l)

**Want to explore Chat?** Check out the code at [github.com/OpenParachutePBC/parachute-chat](https://github.com/OpenParachutePBC/parachute-chat). Fair warning: this is early-stage open source software. But if you're comfortable with that, we'd love your feedback.

**Want to follow along?** Subscribe to hear about updates.

---

Here's to opening the parachute.

—Aaronji

---

*Open Parachute PBC is a Colorado Public Benefit Corporation building open & interoperable tools for thinking.*
