# main_rag_tools_chat.py
from ollama_client import OllamaChatModel, Message
from chat_session import ToolRAGChatSession
from vectorstore import SimpleVectorStore
from kb_loader import load_knowledge_from_folder

# ⚠️ 知识库目录：改成你自己的
KNOWLEDGE_FOLDER = r"D:\agent_kb"   # 例如：D:\agent_kb\note1.txt 等


def build_vector_store() -> SimpleVectorStore:
    vs = SimpleVectorStore(
        embed_model="nomic-embed-text",       # 确保已经 ollama pull 了这个模型
        base_url="http://127.0.0.1:11434",
    )

    docs = load_knowledge_from_folder(KNOWLEDGE_FOLDER)

    if not docs:
        print("提示：知识库为空，当前 RAG 不会起作用。")
    else:
        vs.add_documents(docs)

    return vs


def main():
    # 1. 底层 LLM
    model = OllamaChatModel(
        model_name="gpt-oss:20b",       # 换成你在 Ollama 里的实际模型名
        base_url="http://127.0.0.1:11434",
    )

    # 2. 向量库
    vs = build_vector_store()

    # 3. 会话（RAG + 本地工具）
    session = ToolRAGChatSession(model=model, retriever=vs, k=3)
    session.history.append(
        Message(
            role="system",
            content=(
                "你是一个具备检索增强（RAG）和本地工具调用能力的中文 AI 助手。"
                "当需要做计算或读取本地文本文件时，可以调用工具来完成。"
                "回答问题时，先参考检索到的资料和工具结果。"
            ),
        )
    )

    print("已连接到模型（RAG + 本地工具）。输入 exit / quit 退出。\n")

    while True:
        user_input = input("你：").strip()
        if user_input.lower() in {"exit", "quit"}:
            break

        reply = session.ask(user_input)
        print("助手：", reply, "\n")


if __name__ == "__main__":
    main()
