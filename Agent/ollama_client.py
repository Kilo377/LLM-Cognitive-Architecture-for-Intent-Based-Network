# ollama_client.py
from dataclasses import dataclass
from typing import List, Dict, Any, Tuple
import requests
import json


@dataclass
class Message:
    role: str   # 'system' | 'user' | 'assistant' | 'tool'
    content: str


@dataclass
class ToolCall:
    id: str
    name: str
    arguments: Dict[str, Any]


class OllamaChatModel:
    def __init__(
        self,
        model_name: str,
        base_url: str = "http://127.0.0.1:11434",
        timeout: int = 600,
    ):
        self.model_name = model_name
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    # 普通聊天（不带工具），给纯 RAG 用
    def chat(self, messages: List[Message]) -> Message:
        payload = {
            "model": self.model_name,
            "messages": [
                {"role": m.role, "content": m.content} for m in messages
            ],
            "stream": False,
        }

        resp = requests.post(
            f"{self.base_url}/api/chat",
            json=payload,
            timeout=self.timeout,
        )
        resp.raise_for_status()
        data = resp.json()

        content = data.get("message", {}).get("content", "")
        return Message(role="assistant", content=content)

    # 带 tools 的聊天
    def chat_with_tools(
        self,
        messages: List[Message],
        tools: List[Dict[str, Any]],
        tool_choice: Any = "auto",  # "auto" | "none" | {...}
    ) -> Tuple[Message, List[ToolCall]]:
        payload = {
            "model": self.model_name,
            "messages": [
                {"role": m.role, "content": m.content} for m in messages
            ],
            "tools": tools,
            "stream": False,
        }
        if tool_choice is not None:
            payload["tool_choice"] = tool_choice

        resp = requests.post(
            f"{self.base_url}/api/chat",
            json=payload,
            timeout=self.timeout,
        )
        resp.raise_for_status()
        data = resp.json()

        msg = data.get("message", {}) or {}
        assistant_msg = Message(
            role=msg.get("role", "assistant"),
            content=msg.get("content", "") or "",
        )

        raw_tool_calls = msg.get("tool_calls") or []
        parsed_calls: List[ToolCall] = []

        for tc in raw_tool_calls:
            fn = tc.get("function") or {}
            name = fn.get("name") or ""
            raw_args = fn.get("arguments") or {}
            if isinstance(raw_args, str):
                try:
                    args = json.loads(raw_args)
                except Exception:
                    args = {}
            else:
                args = raw_args

            parsed_calls.append(
                ToolCall(
                    id=tc.get("id") or "",
                    name=name,
                    arguments=args,
                )
            )

        return assistant_msg, parsed_calls
