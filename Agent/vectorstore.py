# vectorstore.py
from dataclasses import dataclass
from typing import Any, Dict, List, Optional
import requests
import math


@dataclass
class Document:
    id: str
    text: str
    metadata: Optional[Dict[str, Any]] = None


class SimpleVectorStore:
    """
    一个极简的“向量库”实现。

    当前模式（根据你的需求）：
    - docs: 直接保存从 txt 切出来的 chunks；
    - embeddings: 可以为空，不强制使用；
    - similarity_search(): 不做 embedding / 相似度计算，直接返回前 k 个文档。

    这样：
    - 所有 RAGChatSession 仍然能拿到知识库文本作为上下文；
    - 完全不会调用 /api/embed，不会再出现 500。
    """

    def __init__(
        self,
        embed_model: str = "nomic-embed-text",
        base_url: str = "http://127.0.0.1:11434",
        timeout: float = 30.0,
    ) -> None:
        self.embed_model = embed_model
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

        # 文本与向量
        self.docs: List[Document] = []
        self.embeddings: List[List[float]] = []

    # ==== 下面这两个函数暂时不会用到，但保留以防以后要恢复“真 RAG” ====

    def _embed(self, text: str) -> List[float]:
        """
        嵌入接口（当前模式不会被调用，只是保留以备将来需要）。

        支持 /api/embed 和旧版 /api/embeddings，两种都尝试。
        """
        url = f"{self.base_url}/api/embed"
        payload = {"model": self.embed_model, "input": text}

        resp = requests.post(url, json=payload, timeout=self.timeout)
        try:
            resp.raise_for_status()
        except requests.HTTPError as e:
            # 如果是 404，尝试旧版 embeddings 接口
            if resp.status_code == 404:
                url2 = f"{self.base_url}/api/embeddings"
                payload2 = {"model": self.embed_model, "prompt": text}
                resp2 = requests.post(url2, json=payload2, timeout=self.timeout)
                resp2.raise_for_status()
                data = resp2.json()
                if "embedding" in data:
                    return data["embedding"]
                if "data" in data and data["data"]:
                    return data["data"][0]["embedding"]
                raise RuntimeError(f"未知的 embeddings 返回格式: {data}")
            else:
                # 其它错误直接抛出
                raise e

        data = resp.json()
        # 兼容几种常见字段名
        if "embeddings" in data:
            return data["embeddings"][0]
        if "embedding" in data:
            return data["embedding"]
        if "data" in data and data["data"]:
            return data["data"][0].get("embedding", [])
        raise RuntimeError(f"未知的 embed 返回格式: {data}")

    @staticmethod
    def _cosine_similarity(a: List[float], b: List[float]) -> float:
        if not a or not b or len(a) != len(b):
            return 0.0
        dot = 0.0
        na = 0.0
        nb = 0.0
        for x, y in zip(a, b):
            dot += x * y
            na += x * x
            nb += y * y
        if na <= 0 or nb <= 0:
            return 0.0
        return dot / (math.sqrt(na) * math.sqrt(nb))

    # ==== 文档管理 ====

    def add_documents(self, docs: List[Document]) -> None:
        """
        旧模式：会对每个文档做 embedding 再存。

        当前工程里我们 **不会调用这个函数**（build_vector_store 会直接赋值 docs），
        保留只是为了以后如果你想恢复“真向量检索”时方便。
        """
        for d in docs:
            emb = self._embed(d.text)
            self.docs.append(d)
            self.embeddings.append(emb)

    # ==== 检索接口（核心修改点） ====

    def similarity_search(self, query: str, k: int = 4) -> List[Document]:
        """
        当前模式：不做任何 embedding / 相似度计算，直接返回前 k 个文档。

        因为：
        - 你现在知识库里只有一个 txt（被切成若干 chunks）；
        - 这些文档对所有 agent 都有用；
        - 做“检索 + embedding”没啥意义，还容易触发 /api/embed 500。
        """
        if not self.docs:
            return []

        k = max(1, int(k))
        k = min(k, len(self.docs))
        return self.docs[:k]
