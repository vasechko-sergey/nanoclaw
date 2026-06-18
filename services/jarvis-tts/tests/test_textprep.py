from textprep import strip_markdown, chunk_text

def test_strip_markdown_removes_formatting():
    assert strip_markdown("**Готово**, см. `файл.py`") == "Готово, см. файл.py"

def test_strip_markdown_drops_code_fences():
    assert strip_markdown("Вот:\n```py\nx=1\n```\nготово") == "Вот: готово"

def test_strip_markdown_links_keep_text():
    assert strip_markdown("[отчёт](http://x/y)") == "отчёт"

def test_chunk_text_splits_on_sentence_under_limit():
    text = "Первое предложение. Второе предложение. Третье."
    chunks = chunk_text(text, max_chars=25)
    assert all(len(c) <= 25 for c in chunks)
    assert "".join(chunks).replace(" ", "") == text.replace(" ", "")

def test_chunk_text_single_when_short():
    assert chunk_text("Коротко.", max_chars=100) == ["Коротко."]
