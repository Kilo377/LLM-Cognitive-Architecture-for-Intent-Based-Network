# kb_loader.py
import os
from typing import List
from vectorstore import Document


def split_text_into_chunks(text, max_chars=500, overlap=100):
    paragraphs = text.split("\n\n")
    chunks = []
    current = ""

    for para in paragraphs:
        para = para.strip()
        if not para:
            continue

        if len(current) + len(para) + 2 <= max_chars:
            if current:
                current += "\n\n" + para
            else:
                current = para
        else:
            if current:
                chunks.append(current)
            current = para

    if current:
        chunks.append(current)

    # 简单重叠，保持一点上下文
    if overlap > 0 and len(chunks) > 1:
        new_chunks = []
        for i, ch in enumerate(chunks):
            if i == 0:
                new_chunks.append(ch)
            else:
                prev = chunks[i - 1]
                tail = prev[-overlap:]
                new_chunks.append(tail + "\n\n" + ch)
        chunks = new_chunks

    return chunks


def load_knowledge_from_folder(folder_path, exts=None) -> List[Document]:
    if exts is None:
        exts = [".txt", ".md"]

    docs: List[Document] = []

    if not os.path.isdir(folder_path):
        return docs

    for root, dirs, files in os.walk(folder_path):
        for name in files:
            lower = name.lower()
            if not any(lower.endswith(ext) for ext in exts):
                continue

            full_path = os.path.join(root, name)
            try:
                with open(full_path, "r", encoding="utf-8", errors="ignore") as f:
                    text = f.read()
            except Exception:
                continue

            chunks = split_text_into_chunks(text, max_chars=500, overlap=100)
            for idx, chunk in enumerate(chunks):
                doc_id = "%s_%d" % (name, idx)
                docs.append(
                    Document(
                        id=doc_id,
                        text=chunk,
                        metadata={
                            "source": full_path,
                            "chunk_index": idx,
                        },
                    )
                )

    return docs
