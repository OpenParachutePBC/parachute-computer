"""
Message formatter: Claude markdown to platform-specific format.

Handles conversion between Claude's rich markdown output and the
limited formatting supported by Telegram (MarkdownV2), Discord, and Matrix.
"""

import re
from html import escape as html_escape


def claude_to_telegram(text: str) -> str:
    """Convert Claude markdown to Telegram MarkdownV2 format.

    Telegram MarkdownV2 requires escaping special characters outside
    of formatting entities. Special chars: _*[]()~`>#+-=|{}.!

    Key differences from standard markdown:
    - Bold: *text* (same)
    - Italic: _text_ (same)
    - Code: `code` (same)
    - Code block: ```lang\ncode\n``` (same)
    - Links: [text](url) (same)
    - Strikethrough: ~text~ (different from ~~text~~)
    """
    if not text:
        return ""

    # Preserve code blocks (don't escape inside them)
    code_blocks = []
    def save_code_block(match):
        code_blocks.append(match.group(0))
        return f"\x00CODEBLOCK{len(code_blocks) - 1}\x00"

    text = re.sub(r"```[\s\S]*?```", save_code_block, text)

    # Preserve inline code
    inline_codes = []
    def save_inline_code(match):
        inline_codes.append(match.group(0))
        return f"\x00INLINE{len(inline_codes) - 1}\x00"

    text = re.sub(r"`[^`]+`", save_inline_code, text)

    # Convert ~~strikethrough~~ to ~strikethrough~
    text = re.sub(r"~~(.+?)~~", r"~\1~", text)

    # Escape special characters (outside code blocks)
    special_chars = r"_*[]()~`>#+-=|{}.!"
    for char in special_chars:
        # Don't escape if it's part of formatting we want to keep
        if char in ("*", "_", "~", "`", "[", "]", "(", ")"):
            continue
        text = text.replace(char, f"\\{char}")

    # Restore code blocks and inline code
    for i, block in enumerate(code_blocks):
        text = text.replace(f"\x00CODEBLOCK{i}\x00", block)
    for i, code in enumerate(inline_codes):
        text = text.replace(f"\x00INLINE{i}\x00", code)

    return text


def claude_to_discord(text: str) -> str:
    """Convert Claude markdown to Discord format.

    Discord supports most standard markdown natively:
    - Bold: **text**
    - Italic: *text* or _text_
    - Code: `code` and ```code```
    - Links: auto-detected or [text](url)
    - Strikethrough: ~~text~~
    - Headers: # (displayed as bold, not actual headers)

    Main adjustment: strip excessive formatting that doesn't render well.
    """
    if not text:
        return ""

    # Discord handles standard markdown well, minimal conversion needed
    # Remove HTML tags that Claude might include
    text = re.sub(r"</?(?:details|summary|br|hr)>", "", text)

    return text.strip()


def claude_to_matrix(text: str) -> tuple[str, str]:
    """Convert Claude markdown to Matrix message format.

    Returns (plain_body, html_body) for the Matrix m.room.message event.
    plain_body is used as fallback; html_body uses Matrix's HTML subset:
    b, i, code, pre, blockquote, ul/ol/li, a, h1-h6, br, p.
    """
    if not text:
        return ("", "")

    plain = claude_to_plain(text)
    html = text

    # Preserve code blocks first (don't process markdown inside them)
    code_blocks: list[str] = []

    def _save_code_block(match: re.Match) -> str:
        lang = match.group(1) or ""
        code = html_escape(match.group(2))
        if lang:
            replacement = f"<pre><code class=\"language-{html_escape(lang)}\">{code}</code></pre>"
        else:
            replacement = f"<pre><code>{code}</code></pre>"
        code_blocks.append(replacement)
        return f"\x00CODEBLOCK{len(code_blocks) - 1}\x00"

    html = re.sub(r"```(\w*)\n?([\s\S]*?)```", _save_code_block, html)

    # Preserve inline code
    inline_codes: list[str] = []

    def _save_inline_code(match: re.Match) -> str:
        code = html_escape(match.group(1))
        inline_codes.append(f"<code>{code}</code>")
        return f"\x00INLINE{len(inline_codes) - 1}\x00"

    html = re.sub(r"`([^`]+)`", _save_inline_code, html)

    # Escape remaining HTML-special chars in body text
    # (but not our placeholders)
    parts = re.split(r"(\x00(?:CODEBLOCK|INLINE)\d+\x00)", html)
    for i, part in enumerate(parts):
        if not part.startswith("\x00"):
            parts[i] = html_escape(part)
    html = "".join(parts)

    # Headings (must come before bold since # lines shouldn't be treated as bold)
    html = re.sub(r"^######\s+(.+)$", r"<h6>\1</h6>", html, flags=re.MULTILINE)
    html = re.sub(r"^#####\s+(.+)$", r"<h5>\1</h5>", html, flags=re.MULTILINE)
    html = re.sub(r"^####\s+(.+)$", r"<h4>\1</h4>", html, flags=re.MULTILINE)
    html = re.sub(r"^###\s+(.+)$", r"<h3>\1</h3>", html, flags=re.MULTILINE)
    html = re.sub(r"^##\s+(.+)$", r"<h2>\1</h2>", html, flags=re.MULTILINE)
    html = re.sub(r"^#\s+(.+)$", r"<h1>\1</h1>", html, flags=re.MULTILINE)

    # Bold and italic (order matters: bold first since ** contains *)
    html = re.sub(r"\*\*\*(.+?)\*\*\*", r"<b><i>\1</i></b>", html)
    html = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html)
    html = re.sub(r"\*(.+?)\*", r"<i>\1</i>", html)

    # Strikethrough
    html = re.sub(r"~~(.+?)~~", r"<del>\1</del>", html)

    # Links: [text](url) — url was HTML-escaped, unescape for href
    def _restore_link(match: re.Match) -> str:
        link_text = match.group(1)
        url = match.group(2).replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
        return f'<a href="{url}">{link_text}</a>'

    html = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", _restore_link, html)

    # Blockquotes (consecutive > lines become one blockquote)
    def _convert_blockquote(match: re.Match) -> str:
        lines = match.group(0).split("\n")
        inner = "\n".join(re.sub(r"^&gt;\s?", "", line) for line in lines)
        return f"<blockquote>{inner}</blockquote>"

    html = re.sub(r"(?:^&gt;.*$\n?)+", _convert_blockquote, html, flags=re.MULTILINE)

    # Unordered lists (- or * items)
    def _convert_ul(match: re.Match) -> str:
        lines = match.group(0).strip().split("\n")
        items = "".join(f"<li>{re.sub(r'^[*-]\\s+', '', line)}</li>" for line in lines)
        return f"<ul>{items}</ul>"

    html = re.sub(r"(?:^[*-]\s+.+$\n?)+", _convert_ul, html, flags=re.MULTILINE)

    # Ordered lists (1. items)
    def _convert_ol(match: re.Match) -> str:
        lines = match.group(0).strip().split("\n")
        items = "".join(f"<li>{re.sub(r'^\\d+\\.\\s+', '', line)}</li>" for line in lines)
        return f"<ol>{items}</ol>"

    html = re.sub(r"(?:^\d+\.\s+.+$\n?)+", _convert_ol, html, flags=re.MULTILINE)

    # Restore code blocks and inline code
    for i, block in enumerate(code_blocks):
        html = html.replace(f"\x00CODEBLOCK{i}\x00", block)
    for i, code in enumerate(inline_codes):
        html = html.replace(f"\x00INLINE{i}\x00", code)

    # Clean up: convert double newlines to <br/> for readability
    html = re.sub(r"\n{2,}", "<br/><br/>", html)
    html = html.strip()

    return (plain, html)


def claude_to_plain(text: str) -> str:
    """Strip all markdown formatting for plain text output."""
    if not text:
        return ""

    # Remove code block markers
    text = re.sub(r"```\w*\n?", "", text)

    # Remove inline code markers
    text = re.sub(r"`([^`]+)`", r"\1", text)

    # Remove bold/italic markers
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"\*(.+?)\*", r"\1", text)
    text = re.sub(r"__(.+?)__", r"\1", text)
    text = re.sub(r"_(.+?)_", r"\1", text)

    # Remove strikethrough
    text = re.sub(r"~~(.+?)~~", r"\1", text)

    # Remove link formatting, keep text
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)

    # Remove headers
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.MULTILINE)

    return text.strip()
