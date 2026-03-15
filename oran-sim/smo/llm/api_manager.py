"""
Author: Chongyu Bao (zt25108@bristol.ac.uk)

File: api_manager.py

Description:
This module defines the APIManager class, which serves as the unified
interface between the simulation backend and all LLM providers.

"""

"""
Use Case:
from backend.llm.api_manager import APIManager
api = APIManager()
prompt = ('你好啊, 你是谁')
response = api.generate(prompt)
"""


from typing import Optional
from .providers import OpenAIProvider, OllamaProvider

debug = False


class APIManager:
    """
    Unified LLM manager and router.
    """

    def __init__(self, provider_name: str = "ollama"):
        """
        Initialize APIManager.

        INPUT
          provider_name: "openai" or "ollama"
        OUTPUT
          None
        """

        self.provider_name = provider_name.lower()

        self.openai_provider = OpenAIProvider()
        self.ollama_provider = OllamaProvider()

        self.provider = self._select_provider()

    def _select_provider(self):
        """
        Select provider instance.

        INPUT
          None
        OUTPUT
          Provider instance.
        EXAMPLE OUTPUT
          <OpenAIProvider object>
        """

        if self.provider_name == "openai":
            return self.openai_provider

        if self.provider_name == "ollama":
            return self.ollama_provider

        raise ValueError(f"Unsupported provider: {self.provider_name}")

    def set_provider(self, provider_name: str):
        """
        Dynamically switch provider.

        INPUT
          provider_name: "openai" or "ollama"
        OUTPUT
          None
        """

        self.provider_name = provider_name.lower()
        self.provider = self._select_provider()

        if debug:
            print("[APIManager] Switched provider to:", self.provider_name)

    def generate(self, prompt: str, persona=None, model: Optional[str] = None) -> str:
        """
        Generate text from LLM.

        INPUT
          prompt: Input prompt string.
          persona: Optional persona for model override.
          model: Optional model override.
        OUTPUT
          Generated text string.
        EXAMPLE OUTPUT
          "Sure, I will go to work at 9 AM."
        """

        model_name = model

        if persona is not None:
            if hasattr(persona, "scratch"):
                if hasattr(persona.scratch, "model"):
                    model_name = persona.scratch.model

        if debug:
            print("[APIManager] Provider:", self.provider_name)
            print("[APIManager] Model:", model_name)

        return self.provider.generate(prompt, model_name)

    def embed(self, text: str, persona=None) -> list:
        """
        Generate embedding vector.

        INPUT
          text: Input text.
          persona: Optional persona.
        OUTPUT
          Embedding vector list.
        EXAMPLE OUTPUT
          [0.0123, -0.4421, ...]
        """

        if debug:
            print("[APIManager] Embedding request")

        return self.provider.embed(text)
