# web_chat.py
#
# 启动方式：
#   python web_chat.py
#
# 然后浏览器打开：http://127.0.0.1:5000
#
from flask import Flask, request, jsonify, render_template_string
from ollama_client import OllamaChatModel, Message
from chat_session import ToolRAGChatSession
from vectorstore import SimpleVectorStore
from kb_loader import load_knowledge_from_folder

# === 配置区域 ===

# 知识库目录：改成你自己的
KNOWLEDGE_FOLDER = r"D:\agent_kb"   # 例如：D:\agent_kb\note1.txt

# Ollama 配置：模型名要改成你实际用的
OLLAMA_MODEL_NAME = "gpt-oss:20b"
OLLAMA_BASE_URL = "http://127.0.0.1:11434"

# 每次检索返回几条文档
RAG_TOP_K = 3

# =============================

app = Flask(__name__)

# ---- 构建向量库（只在启动时做一次） ----
vector_store = SimpleVectorStore(
    embed_model="nomic-embed-text",
    base_url=OLLAMA_BASE_URL,
)
docs = load_knowledge_from_folder(KNOWLEDGE_FOLDER)
if not docs:
    print("提示：知识库为空，当前 RAG 不会起作用。")
else:
    vector_store.add_documents(docs)
    print(f"知识库已加载：{len(docs)} 个文档 chunks")

# ---- 构建模型封装（共享一个） ----
model = OllamaChatModel(
    model_name=OLLAMA_MODEL_NAME,
    base_url=OLLAMA_BASE_URL,
)

# ---- 会话管理：用 session_id 区分多个会话 ----
SESSIONS = {}  # session_id -> ToolRAGChatSession


def create_new_session() -> ToolRAGChatSession:
    session = ToolRAGChatSession(
        model=model,
        retriever=vector_store,
        k=RAG_TOP_K,
    )
    # 初始化 system prompt
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
    return session


# ---- 简单的 HTML 模板（用 render_template_string 渲染） ----
HTML_PAGE = r"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8" />
    <title>RAG + 本地工具 Chat</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            margin: 0;
            padding: 0;
            background: #f5f5f5;
            display: flex;
            flex-direction: column;
            height: 100vh;
        }
        #app {
            max-width: 900px;
            margin: 0 auto;
            display: flex;
            flex-direction: column;
            height: 100vh;
        }
        header {
            padding: 12px 16px;
            background: #222;
            color: #fff;
            font-size: 16px;
        }
        #chat-window {
            flex: 1;
            overflow-y: auto;
            padding: 16px;
            background: #fafafa;
        }
        .msg {
            margin-bottom: 12px;
            max-width: 80%;
            padding: 8px 10px;
            border-radius: 8px;
            line-height: 1.6;
            white-space: pre-wrap;
        }
        .msg.user {
            background: #d1e7ff;
            align-self: flex-end;
        }
        .msg.assistant {
            background: #ffffff;
            border: 1px solid #ddd;
            align-self: flex-start;
        }
        #input-area {
            display: flex;
            padding: 10px;
            background: #fff;
            border-top: 1px solid #ddd;
        }
        #input-text {
            flex: 1;
            resize: none;
            padding: 8px;
            border-radius: 6px;
            border: 1px solid #ccc;
            font-size: 14px;
            font-family: inherit;
            line-height: 1.5;
        }
        #send-btn {
            margin-left: 8px;
            padding: 0 18px;
            border-radius: 6px;
            border: none;
            background: #2563eb;
            color: #fff;
            font-size: 14px;
            cursor: pointer;
        }
        #send-btn:disabled {
            background: #9ca3af;
            cursor: not-allowed;
        }
        #status {
            font-size: 12px;
            color: #666;
            padding: 0 16px 8px;
        }
    </style>
</head>
<body>
<div id="app">
    <header>RAG + 本地工具 Chat（Ollama）</header>
    <div id="chat-window"></div>
    <div id="status"></div>
    <div id="input-area">
        <textarea id="input-text" rows="2" placeholder="说点什么...（Shift+Enter 换行，Enter 发送）"></textarea>
        <button id="send-btn">发送</button>
    </div>
</div>

<script>
    // --- 简单的 session_id: 用 localStorage 记住 ---
    function getSessionId() {
        const key = "rag_tools_session_id";
        let sid = localStorage.getItem(key);
        if (!sid) {
            sid = "sess_" + Math.random().toString(36).slice(2);
            localStorage.setItem(key, sid);
        }
        return sid;
    }
    const SESSION_ID = getSessionId();

    const chatWindow = document.getElementById('chat-window');
    const inputText = document.getElementById('input-text');
    const sendBtn = document.getElementById('send-btn');
    const statusEl = document.getElementById('status');

    function appendMessage(role, text) {
        const div = document.createElement('div');
        div.classList.add('msg');
        div.classList.add(role === 'user' ? 'user' : 'assistant');
        div.textContent = text;
        chatWindow.appendChild(div);
        chatWindow.scrollTop = chatWindow.scrollHeight;
    }

    async function sendMessage() {
        const text = inputText.value.trim();
        if (!text) return;

        appendMessage('user', text);
        inputText.value = '';
        inputText.focus();
        sendBtn.disabled = true;
        statusEl.textContent = "助手正在思考...";

        try {
            const resp = await fetch('/api/chat', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    session_id: SESSION_ID,
                    message: text
                })
            });
            if (!resp.ok) {
                throw new Error('HTTP ' + resp.status);
            }
            const data = await resp.json();
            appendMessage('assistant', data.reply || '[空回复]');
        } catch (err) {
            console.error(err);
            appendMessage('assistant', '[错误] 请求失败: ' + err);
        } finally {
            sendBtn.disabled = false;
            statusEl.textContent = "";
        }
    }

    sendBtn.addEventListener('click', sendMessage);

    inputText.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    });
</script>
</body>
</html>
"""


@app.route("/", methods=["GET"])
def index():
    return render_template_string(HTML_PAGE)


@app.route("/api/chat", methods=["POST"])
def api_chat():
    data = request.get_json(force=True) or {}
    session_id = data.get("session_id") or "default"
    user_msg = (data.get("message") or "").strip()

    if not user_msg:
        return jsonify({"reply": ""})

    # 获取 / 创建会话
    session = SESSIONS.get(session_id)
    if session is None:
        session = create_new_session()
        SESSIONS[session_id] = session

    # 调用你的 ToolRAGChatSession
    reply = session.ask(user_msg)
    return jsonify({"reply": reply})


if __name__ == "__main__":
    # 默认监听 127.0.0.1:5000
    app.run(host="127.0.0.1", port=5000, debug=True)
