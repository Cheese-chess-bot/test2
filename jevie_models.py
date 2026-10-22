"""Shared OpenRouter lineup; exact IDs, with no alternate-model fallback."""

MODEL_LINEUP_VERSION = 1
DEFAULT_MODELS = dict(
    researcher='google/gemma-4-31b-it:free',
    challenger='recursive/flint-v1.0:free',
    critic='cohere/north-mini-code:free',
    decider='nvidia/nemotron-3.5-super-vl:free',
    evolver='nvidia/nemotron-3.5-super-vl:free',
)
OPENBOT_MODEL = DEFAULT_MODELS['decider']

LEGACY_DEFAULT_MODELS = dict(
    researcher='google/gemini-4-argon',
    challenger='openai/gpt-6.1-sol',
    critic='anthropic/claude-sonnet-5.5',
    decider='moonshotai/kimi-k3',
    evolver='anthropic/claude-sonnet-5.5',
)


def configured_models(saved, upgrade_legacy=False):
    """Fill missing roles and upgrade former defaults without replacing custom IDs."""
    models = {role: saved.get(role) or model for role, model in DEFAULT_MODELS.items()}
    if upgrade_legacy:
        for role, old_model in LEGACY_DEFAULT_MODELS.items():
            if models[role] == old_model:
                models[role] = DEFAULT_MODELS[role]
    return models
