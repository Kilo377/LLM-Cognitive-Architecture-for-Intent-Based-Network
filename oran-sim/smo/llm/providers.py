"""
Author: Chongyu Bao (zt25108@bristol.ac.uk)

File: providers.py

Description:
This module defines LLM providers for the simulation backend.

It contains:

1. OpenAIProvider
2. OllamaProvider

Both providers expose two unified interfaces:

- generate(prompts: str, model: str | None = None) -> str
- embed(text: str) -> list[float]

Ollama uses default model: qwen2.5:1.5b
Embedding is implemented as a single request endpoint.

This module does not perform routing logic.
Routing must be handled by APIManager.
"""


import requests
import os
from typing import List, Optional

debug = True

class OllamaProvider:
    """
    Ollama local provider.
    Default model: qwen2.5:1.5b
    """

    def __init__(self,
                 base_url: str = "http://localhost:11434",
                 default_model: str = "qwen2.5:14b",
                 embedding_model: str = "nomic-embed-text:latest"):
        """
        Initialize OllamaProvider.

        INPUT
          base_url: Ollama server base URL.
          default_model: Default generation model.
          embedding_model: Embedding model nam4132e.
        OUTPUT
          None
        """
        self.base_url = base_url
        self.default_model = default_model
        self.embedding_model = embedding_model

    def generate(self, prompt: str, model: Optional[str] = None) -> str:
        """
        Generate text using Ollama.

        INPUT
          prompt: Prompt string.
          model: Optional model override.
        OUTPUT
          Generated text string.
        EXAMPLE OUTPUT
          "Sure, let's start."
        """
        model_name = model or self.default_model

        data = {
            "model": model_name,
            "prompt": prompt,
            "think": False, #True, #False,
            "stream": False
        }

        response = requests.post(
            f"{self.base_url}/api/generate",
            json=data,
            timeout=120
        )

        response.raise_for_status()
        result = response.json()

        return result.get("response", "")

    def embed(self, text: str) -> List[float]:
        """
        Generate embedding using Ollama embedding endpoint.

        INPUT
          text: Input text.
        OUTPUT
          Embedding vector.
        EXAMPLE OUTPUT
          [0.0231, -0.1123, ...]
        """
        data = {
            "model": self.embedding_model,
            "prompt": text
        }

        response = requests.post(
            f"{self.base_url}/api/embeddings",
            json=data,
            timeout=60
        )

        response.raise_for_status()
        result = response.json()

        embedding = result.get("embedding", [])

        if debug:
            print("[Ollama] embedding length:", len(embedding))

        return embedding



class OpenAIProvider:
    """
    OpenAI API provider.
    """

    def __init__(self,
                 api_key: Optional[str] = None,
                 default_model: str = "gpt-4o-mini",
                 embedding_model: str = "text-embedding-3-small"):
        """
        Initialize OpenAIProvider.

        INPUT
          api_key: OpenAI API key.
          default_model: Default chat model name.
          embedding_model: Embedding model name.
        OUTPUT
          None
        """
        self.api_key = api_key or os.getenv("OPENAI_API_KEY")
        self.default_model = default_model
        self.embedding_model = embedding_model
        self.base_url = "https://api.openai.com/v1"

    def generate(self, prompt: str, model: Optional[str] = None) -> str:
        """
        Generate text using OpenAI chat completion.

        INPUT
          prompts: Prompt string.
          model: Optional model override.
        OUTPUT
          Generated text string.
        EXAMPLE OUTPUT
          "Hello, how can I help you today?"
        """
        model_name = model or self.default_model

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }

        data = {
            "model": model_name,
            "messages": [
                {"role": "user", "content": prompt}
            ]
        }

        response = requests.post(
            f"{self.base_url}/chat/completions",
            headers=headers,
            json=data,
            timeout=60
        )

        response.raise_for_status()
        result = response.json()

        if debug:
            print("[OpenAI] model:", model_name)

        return result["choices"][0]["message"]["content"]

    def embed(self, text: str) -> List[float]:
        """
        Generate embedding using OpenAI embedding API.

        INPUT
          text: Input text.
        OUTPUT
          Embedding vector.
        EXAMPLE OUTPUT
          [0.0123, -0.4421, ...]
        """
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }

        data = {
            "model": self.embedding_model,
            "input": text
        }

        response = requests.post(
            f"{self.base_url}/embeddings",
            headers=headers,
            json=data,
            timeout=60
        )

        response.raise_for_status()
        result = response.json()

        if debug:
            print("[OpenAI] embedding length:",
                  len(result["data"][0]["embedding"]))

        return result["data"][0]["embedding"]


