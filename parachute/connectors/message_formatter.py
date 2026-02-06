"""
Message formatter: Claude markdown to platform-specific format.

Handles conversion between Claude's rich markdown output and the
limited formatting supported by Telegram (MarkdownV2) and Discord.
"""

import re


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
