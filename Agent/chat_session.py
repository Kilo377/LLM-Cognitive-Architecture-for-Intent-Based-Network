# chat_session.py
from dataclasses import dataclass, field
from typing import List
from ollama_client import OllamaChatModel, Message
from vectorstore import SimpleVectorStore
from local_tools import TOOLS_SPEC, execute_tool


@dataclass
class ChatSession:
    """
    普通聊天会话：只管历史 + LLM
    """
    model: OllamaChatModel
    history: List[Message] = field(default_factory=list)

    def ask(self, user_input: str) -> str:
        self.history.append(Message(role="user", content=user_input))
        reply_msg = self.model.chat(self.history)
        self.history.append(reply_msg)
        return reply_msg.content


class RAGChatSession(ChatSession):
    """
    带 RAG：每次先检索向量库，加 system 消息
    """
    def __init__(
        self,
        model: OllamaChatModel,
        retriever: SimpleVectorStore,
        k: int = 4,
    ):
        super(RAGChatSession, self).__init__(model=model)
        self.retriever = retriever
        self.k = k

    def ask(self, user_input: str) -> str:
        docs = self.retriever.similarity_search(user_input, k=self.k)
        if docs:
            lines = []
            for i, d in enumerate(docs):
                source = d.metadata.get("source") if d.metadata else None
                header = "[%d] %s" % (i + 1, (source or d.id))
                lines.append(header + "\n" + d.text)
            context = "\n\n".join(lines)
            rag_system_content = (
                "下面是与用户问题相关的资料片段（方括号中是来源文件路径），"
                "请尽量基于这些内容回答，如果资料不足再结合你的常识补充：\n\n"
                f"{context}"
            )
            self.history.append(
                Message(role="system", content=rag_system_content)
            )

        return super(RAGChatSession, self).ask(user_input)


class ToolRAGChatSession(RAGChatSession):
    """
    RAG + 本地工具：
    - 先检索文档加 system
    - 加入 user 消息
    - 第一轮 chat_with_tools：让模型决定是否调用工具
    - 执行本地工具
    - 第二轮 chat_with_tools(tool_choice='none')：生成最终回答
    """

    def ask(self, user_input: str) -> str:
        # 1. RAG 部分（不调用 super().ask）
        docs = self.retriever.similarity_search(user_input, k=self.k)
        if docs:
            lines = []
            for i, d in enumerate(docs):
                source = d.metadata.get("source") if d.metadata else None
                header = "[%d] %s" % (i + 1, (source or d.id))
                lines.append(header + "\n" + d.text)
            context = "\n\n".join(lines)
            rag_system_content = (
                "下面是与用户问题相关的资料片段（方括号中是来源文件路径），"
                "请尽量基于这些内容回答，如果资料不足再结合你的常识补充：\n\n"
                f"{context}"
            )
            self.history.append(
                Message(role="system", content=rag_system_content)
            )

        # 2. 当前用户消息
        self.history.append(Message(role="user", content=user_input))

        # 3. 第一轮：让模型决定是否调用工具
        assistant_msg, tool_calls = self.model.chat_with_tools(
            messages=self.history,
            tools=TOOLS_SPEC,
            tool_choice="auto",
        )
        self.history.append(assistant_msg)

        # 如果没用工具，就直接返回这轮内容
        if not tool_calls:
            return assistant_msg.content

        # 4. 执行本地工具，把结果加回 history（role=tool）
        for tc in tool_calls:
            result_text = execute_tool(tc.name, tc.arguments)
            self.history.append(
                Message(role="tool", content=result_text)
            )

        # 5. 第二轮：不再允许新工具调用，只让模型根据工具结果回答
        final_msg, _ = self.model.chat_with_tools(
            messages=self.history,
            tools=TOOLS_SPEC,
            tool_choice="none",
        )
        self.history.append(final_msg)
        return final_msg.content
